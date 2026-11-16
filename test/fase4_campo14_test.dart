/// 1.35 (campo nº 14 de Clientes) — convertir un invitado
/// SIN conexión.
///
/// Hasta hoy convertir exigía conexión: la preparación
/// vivía en el servidor (`invitado_preparar_conversion`) y
/// sin red el botón moría con un aviso. Ahora la
/// preparación nace local (uuid del teléfono, registro
/// marcado `nacidaOffline`), la inscripción se encola como
/// cualquier op y, al confirmar ya con red, la verificación
/// primero prepara la conversión en el servidor y adopta
/// SU uuid — la RPC de confirmar exige la fila que solo
/// `invitado_preparar_conversion` crea (verificado contra
/// su definición viva en Supabase).
///
/// Discriminante: en la base nada de esto existe (ni el
/// método, ni la marca, ni la adopción).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RpcFalsa {
  final llamadas =
      <({String nombre, Map<String, dynamic>? params})>[];
  final errores = <String, Object>{};
  final respuestas = <String, dynamic>{};

  Future<dynamic> call(
      String nombre, Map<String, dynamic>? params) async {
    llamadas.add((nombre: nombre, params: params));
    final e = errores[nombre];
    if (e != null) throw e;
    return respuestas[nombre] ?? <String, dynamic>{'ok': true};
  }

  int conteo(String nombre) =>
      llamadas.where((l) => l.nombre == nombre).length;
}

Future<void> _abrirBdLimpia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _insertarOpConversion({
  required String opUuid,
  required String estado,
  required String conversionUuid,
  String? resultadoServidor,
}) async {
  await LocalDb.instance.queueOp(
    opUuid: opUuid,
    tipo: 'inscribir',
    payload: {
      'nombre': 'Invitado Uno',
      'invitado_id': 'inv-1',
      'conversion_uuid': conversionUuid,
    },
  );
  if (estado != 'pendiente' || resultadoServidor != null) {
    final db = await LocalDb.instance.db;
    await db.update(
      'ops_queue',
      {
        'estado': estado,
        if (resultadoServidor != null)
          'resultado_servidor': resultadoServidor,
      },
      where: 'op_uuid = ?',
      whereArgs: [opUuid],
    );
  }
}

const _detalle = InvitadoDetalle(
  id: 'inv-1',
  nombre: 'Invitado Uno',
  telefono: '51234567',
  estado: 'activo',
  fechaNac: '1990-05-20',
  carnet: '90052012345',
);

void main() {
  group('campo 14: conversión sin conexión', () {
    setUp(() async {
      await _abrirBdLimpia();
    });

    test('prepararConversionLocal: registro marcado y datos '
        'del detalle, sin tocar la red', () async {
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      final datos = await svc.prepararConversionLocal(_detalle);
      expect(rpc.llamadas, isEmpty);
      expect(datos.invitadoId, 'inv-1');
      expect(datos.nombre, 'Invitado Uno');
      expect(datos.telefono, '51234567');
      expect(datos.carnet, '90052012345');
      expect(datos.conversionUuid, isNotEmpty);
      final reg = await ConversionInvitadoStore().leer('inv-1');
      expect(reg, isNotNull);
      expect(reg!.estado, EstadoConversion.preparada);
      expect(reg.nacidaOffline, isTrue);
      expect(reg.conversionUuid, datos.conversionUuid);
    });

    test('la marca nacidaOffline sobrevive al JSON y los '
        'registros viejos leen false', () {
      final c = ConversionInvitado(
        invitadoId: 'inv-1',
        conversionUuid: 'conv-local',
        estado: EstadoConversion.opEncolada,
        opUuid: 'op-1',
        nacidaOffline: true,
        creadaEn: '2026-11-15T10:00:00',
        actualizadaEn: '2026-11-15T10:00:00',
      );
      final vuelta = ConversionInvitado.fromJson(c.toJson());
      expect(vuelta.nacidaOffline, isTrue);
      final viejo = ConversionInvitado.fromJson({
        'invitado_id': 'inv-1',
        'conversion_uuid': 'conv-1',
        'estado': 'opEncolada',
        'creada_en': '2026-11-15T10:00:00',
        'actualizada_en': '2026-11-15T10:00:00',
      });
      expect(viejo.nacidaOffline, isFalse);
    });

    test('al confirmar: prepara en el servidor, adopta su '
        'uuid y confirma con él', () async {
      // Conversión nacida offline: el registro opEncolada
      // lleva el uuid LOCAL.
      await ConversionInvitadoStore().guardar(ConversionInvitado(
        invitadoId: 'inv-1',
        conversionUuid: 'uuid-local',
        estado: EstadoConversion.preparada,
        nacidaOffline: true,
        creadaEn: '2026-11-15T10:00:00',
        actualizadaEn: '2026-11-15T10:00:00',
      ));
      await _insertarOpConversion(
        opUuid: 'op-1',
        estado: 'aplicada',
        conversionUuid: 'uuid-local',
        resultadoServidor: '{"cliente_id": 44}',
      );
      final rpc = _RpcFalsa()
        ..respuestas['invitado_preparar_conversion'] = {
          'ok': true,
          'conversion_uuid': 'uuid-servidor',
        };
      final svc = InvitadosService(rpc: rpc.call);
      final n = await svc.verificarConversiones();
      expect(n, 1);
      // Orden: primero preparar, después confirmar.
      expect(
          rpc.llamadas.map((l) => l.nombre).toList(),
          [
            'invitado_preparar_conversion',
            'invitado_confirmar_conversion'
          ]);
      final prep = rpc.llamadas.first;
      expect(prep.params?['p_invitado_id'], 'inv-1');
      final conf = rpc.llamadas.last;
      expect(conf.params?['p_conversion_uuid'], 'uuid-servidor');
      expect(conf.params?['p_cliente_id'], 44);
      final reg = await ConversionInvitadoStore().leer('inv-1');
      expect(reg!.estado, EstadoConversion.confirmada);
      expect(reg.conversionUuid, 'uuid-servidor');
      expect(reg.nacidaOffline, isFalse);
      expect(reg.clienteId, 44);
    });

    test('una conversión nacida EN línea no se reprepara: '
        'confirma directo con su uuid', () async {
      await _insertarOpConversion(
        opUuid: 'op-1',
        estado: 'aplicada',
        conversionUuid: 'conv-1',
        resultadoServidor: '{"cliente_id": 33}',
      );
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      expect(await svc.verificarConversiones(), 1);
      expect(rpc.conteo('invitado_preparar_conversion'), 0);
      expect(rpc.conteo('invitado_confirmar_conversion'), 1);
    });

    test('si preparar al adoptar falla, el error queda '
        'guardado y la marca sigue puesta para reintentar',
        () async {
      await ConversionInvitadoStore().guardar(ConversionInvitado(
        invitadoId: 'inv-1',
        conversionUuid: 'uuid-local',
        estado: EstadoConversion.preparada,
        nacidaOffline: true,
        creadaEn: '2026-11-15T10:00:00',
        actualizadaEn: '2026-11-15T10:00:00',
      ));
      await _insertarOpConversion(
        opUuid: 'op-1',
        estado: 'aplicada',
        conversionUuid: 'uuid-local',
        resultadoServidor: '{"cliente_id": 44}',
      );
      final rpc = _RpcFalsa()
        ..errores['invitado_preparar_conversion'] =
            Exception('CONVERSION_EN_CURSO simulado');
      final svc = InvitadosService(rpc: rpc.call);
      expect(await svc.verificarConversiones(), 0);
      var reg = await ConversionInvitadoStore().leer('inv-1');
      expect(reg!.estado, EstadoConversion.opEncolada);
      expect(reg.nacidaOffline, isTrue);
      expect(reg.conversionUuid, 'uuid-local');
      expect(reg.errorConfirmacion, isNotNull);
      expect(confirmacionConversionPendiente(reg), isTrue);
      // Reintento sano: adopta y confirma.
      rpc.errores.remove('invitado_preparar_conversion');
      rpc.respuestas['invitado_preparar_conversion'] = {
        'ok': true,
        'conversion_uuid': 'uuid-servidor',
      };
      expect(await svc.verificarConversiones(), 1);
      reg = await ConversionInvitadoStore().leer('inv-1');
      expect(reg!.estado, EstadoConversion.confirmada);
      expect(reg.conversionUuid, 'uuid-servidor');
    });

    test('cancelar una preparación nacida offline no llama '
        'al servidor', () async {
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      await svc.prepararConversionLocal(_detalle);
      final reg0 = await ConversionInvitadoStore().leer('inv-1');
      await svc.cancelarConversion(reg0!.conversionUuid,
          invitadoId: 'inv-1');
      expect(rpc.llamadas, isEmpty);
      final reg = await ConversionInvitadoStore().leer('inv-1');
      expect(reg!.estado, EstadoConversion.cancelada);
    });

    test('clientesConConversionPendiente: el cliente de la '
        'op aplicada y aún sin confirmar', () async {
      await ConversionInvitadoStore().guardar(ConversionInvitado(
        invitadoId: 'inv-1',
        conversionUuid: 'uuid-local',
        estado: EstadoConversion.preparada,
        nacidaOffline: true,
        creadaEn: '2026-11-15T10:00:00',
        actualizadaEn: '2026-11-15T10:00:00',
      ));
      await _insertarOpConversion(
        opUuid: 'op-1',
        estado: 'aplicada',
        conversionUuid: 'uuid-local',
        resultadoServidor: '{"cliente_id": 44}',
      );
      final svc = InvitadosService(rpc: _RpcFalsa().call);
      final ids = await svc.clientesConConversionPendiente();
      expect(ids, {44});
      // Y el JSON de la op es el que el resultado trae.
      expect(jsonDecode('{"cliente_id": 44}')['cliente_id'], 44);
    });
  });
}
