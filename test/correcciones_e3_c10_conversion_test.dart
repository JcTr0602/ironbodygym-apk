/// 1.35 (corrección E3, C10-01 — BLOQUEANTE del Yunque de
/// Cambios): la conversión de invitado nacida SIN conexión
/// perdía su marca `nacidaOffline` en el paso real de
/// inscripción (`encolarInscripcionConversion` construía un
/// registro nuevo copiando solo `creadaEn`): al sincronizar,
/// la verificación confirmaba con el uuid local que el
/// servidor no conoce y la conversión quedaba sin confirmar
/// para siempre.
///
/// La batería del campo 14 no lo cazó porque siembra el
/// registro a mano. Este test NO siembra el registro: recorre
/// el camino entero con las funciones reales —
/// prepararConversionLocal → encolarInscripcionConversion
/// (con el queueOp real, como hace InscribirScreen) →
/// verificarConversiones contra la RPC falsa — y exige que
/// la confirmación prepare primero en el servidor y adopte
/// SU uuid.
///
/// Discriminante: sobre la base de074a6 el registro tras
/// encolar lee `nacidaOffline == false` y la verificación
/// confirma directo con el uuid local (la RPC de preparar
/// nunca se llama): el test es rojo. Con la corrección, la
/// marca sobrevive al encolado y la cadena confirma con el
/// uuid del servidor.
library;

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
  final respuestas = <String, dynamic>{};

  Future<dynamic> call(
      String nombre, Map<String, dynamic>? params) async {
    llamadas.add((nombre: nombre, params: params));
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

const _detalle = InvitadoDetalle(
  id: 'inv-1',
  nombre: 'Invitado Uno',
  telefono: '51234567',
  estado: 'activo',
  fechaNac: '1990-05-20',
  carnet: '90052012345',
);

void main() {
  group('E3 · C10-01: la marca nacidaOffline sobrevive al '
      'camino real de inscripción', () {
    setUp(() async {
      await _abrirBdLimpia();
    });

    test('preparar local → encolar → verificar: confirma '
        'con el uuid del servidor, no con el local', () async {
      final rpc = _RpcFalsa()
        ..respuestas['invitado_preparar_conversion'] = {
          'ok': true,
          'conversion_uuid': 'uuid-servidor',
        };
      final svc = InvitadosService(rpc: rpc.call);

      // 1. Preparación SIN conexión (función real): el
      // registro nace marcado y con uuid del teléfono.
      final datos = await svc.prepararConversionLocal(_detalle);
      final previa = await ConversionInvitadoStore().leer('inv-1');
      expect(previa, isNotNull);
      expect(previa!.nacidaOffline, isTrue);
      expect(previa.estado, EstadoConversion.preparada);

      // 2. Inscripción (función real de encolado, con el
      // queueOp real y el payload que InscribirScreen arma
      // para una conversión nacida offline).
      await encolarInscripcionConversion(
        invitadoId: datos.invitadoId,
        conversionUuid: datos.conversionUuid,
        opUuid: 'op-e3-1',
        encolar: (uuid) => LocalDb.instance.queueOp(
          opUuid: uuid,
          tipo: 'inscribir',
          payload: {
            'nombre': 'Invitado Uno',
            'invitado_id': datos.invitadoId,
            'conversion_uuid': datos.conversionUuid,
            // La pantalla declara el nacimiento offline en
            // la op (clave que la corrección añade a
            // InscribirScreen para esta conversión).
            'conversion_nacida_offline': true,
          },
        ),
      );

      // EL BLOQUEANTE: tras encolar, la marca sigue puesta
      // (en la base cae al default false del constructor).
      final trasEncolar =
          await ConversionInvitadoStore().leer('inv-1');
      expect(trasEncolar, isNotNull);
      expect(trasEncolar!.estado, EstadoConversion.opEncolada);
      expect(trasEncolar.opUuid, 'op-e3-1');
      expect(trasEncolar.nacidaOffline, isTrue,
          reason: 'la marca de la previa debe sobrevivir al '
              're-encolado; sin ella la verificación confirma '
              'con un uuid que el servidor no conoce');
      expect(trasEncolar.creadaEn, previa.creadaEn,
          reason: 'la fecha de creación de la previa se '
              'conserva, como ya hacía la base');
      expect(trasEncolar.conversionUuid, datos.conversionUuid);

      // 3. La op sube y se aplica con el cliente creado.
      final db = await LocalDb.instance.db;
      await db.update(
        'ops_queue',
        {
          'estado': 'aplicada',
          'resultado_servidor': '{"cliente_id": 44}',
        },
        where: 'op_uuid = ?',
        whereArgs: ['op-e3-1'],
      );

      // 4. Verificación (función real): primero prepara en
      // el servidor y adopta su uuid; confirma con ÉL.
      final n = await svc.verificarConversiones();
      expect(n, 1);
      expect(
          rpc.llamadas.map((l) => l.nombre).toList(),
          [
            'invitado_preparar_conversion',
            'invitado_confirmar_conversion'
          ],
          reason: 'una conversión nacida offline se prepara '
              'en el servidor ANTES de confirmarse');
      final conf = rpc.llamadas.last;
      expect(conf.params?['p_conversion_uuid'], 'uuid-servidor');
      expect(conf.params?['p_cliente_id'], 44);

      final fin = await ConversionInvitadoStore().leer('inv-1');
      expect(fin!.estado, EstadoConversion.confirmada);
      expect(fin.conversionUuid, 'uuid-servidor');
      expect(fin.clienteId, 44);
    });

    test('reconstrucción desde la op: el registro renacido '
        'conserva la marca que la op declara', () {
      final fila = <String, dynamic>{
        'op_uuid': 'op-e3-2',
        'tipo': 'inscribir',
        'creada_ts': '2026-11-15T10:00:00.000-05:00',
        'payload': {
          'nombre': 'Invitado Uno',
          'invitado_id': 'inv-1',
          'conversion_uuid': 'uuid-local',
          'conversion_nacida_offline': true,
        },
      };
      final res = reconstruccionDesdeOps(ops: [fila], existentes: []);
      expect(res, hasLength(1));
      expect(res.single.nacidaOffline, isTrue,
          reason: 'la op declara el nacimiento offline: el '
              'registro reconstruido debe nacer marcado');
      expect(res.single.estado, EstadoConversion.opEncolada);

      // Control: una op de conversión nacida EN línea (sin
      // la clave) reconstruye sin marca, como siempre.
      final filaEnLinea = <String, dynamic>{
        'op_uuid': 'op-e3-3',
        'tipo': 'inscribir',
        'creada_ts': '2026-11-15T10:00:00.000-05:00',
        'payload': {
          'nombre': 'Invitado Dos',
          'invitado_id': 'inv-2',
          'conversion_uuid': 'uuid-servidor-2',
        },
      };
      final res2 =
          reconstruccionDesdeOps(ops: [filaEnLinea], existentes: []);
      expect(res2, hasLength(1));
      expect(res2.single.nacidaOffline, isFalse);
    });
  });
}
