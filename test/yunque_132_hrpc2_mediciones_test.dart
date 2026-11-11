/// 1.32 · Pieza 5 (H-RPC-2, Corte A): nunca un UUID a las RPC
/// de mediciones. guardar_medicion_staff/eliminar_medicion
/// declaran p_medicion_id BIGINT y la tabla viva
/// (sync_progreso_mediciones) no tiene columna medicion_id:
/// el UUID de la vía de ops rebotaba con 400 disfrazado de
/// «revisa la conexión». La medición solo-UUID se edita/borra
/// por la vía de ops (cancelar su op pendiente + fila nueva).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/ui/pestana_progreso.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Medicion _med({required int id, String? idCrudo}) => Medicion(
      id: id,
      idCrudo: idCrudo,
      clienteId: '55',
      pesoKg: 90,
      registradoPor: 'staff',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

/// Siembra la op `registrar_medicion_cliente` tal como la
/// encola registrarMedicionCliente (que no se usa directo
/// aquí porque lee la sesión de Supabase, ausente en test).
Future<void> _sembrarOpMedicion(String medicionId) =>
    LocalDb.instance.queueOp(
      opUuid: 'op-$medicionId',
      tipo: 'registrar_medicion_cliente',
      payload: {
        'medicion_id': medicionId,
        'cliente_id': 55,
        'fecha_medicion': '2026-11-10',
        'medidas': {'peso_kg': 90.0},
        'registrado_por': 111,
      },
    );

void main() {
  group('H-RPC-2: Medicion.idServidor', () {
    test('fila del servidor (id numérico): ese, nunca el UUID',
        () {
      expect(_med(id: 55, idCrudo: '55').idServidor, 55);
      // Aunque el crudo trajera un UUID, manda el entero.
      expect(
          _med(id: 123, idCrudo: '9b1d8f2e-0000-4000-8000-000000000000')
              .idServidor,
          123);
    });

    test('crudo numérico sin entero: se resuelve el número', () {
      expect(_med(id: 0, idCrudo: '77').idServidor, 77);
    });

    test('solo UUID (vía de ops): null — no hay id para la RPC',
        () {
      expect(
          _med(id: 0, idCrudo: '9b1d8f2e-1111-4000-8000-000000000000')
              .idServidor,
          isNull);
      expect(_med(id: 0).idServidor, isNull);
      expect(_med(id: 0, idCrudo: '').idServidor, isNull);
    });

    test('fromJson de la fila RPC viva: sin medicion_id, id '
        'numérico y crudo null', () {
      final m = Medicion.fromJson({
        'id': 88,
        'cliente_id': 55,
        'peso_kg': 91.5,
        'registrado_por': 'Duany',
        'created_at': '2026-11-01T10:00:00Z',
      });
      expect(m.id, 88);
      expect(m.idCrudo, isNull);
      expect(m.idServidor, 88);
    });
  });

  group('H-RPC-2: la vía de ops para la medición solo-UUID', () {
    test('cancelarMedicionPendienteSiExiste cancela la op y la '
        'fila desaparece de la lectura local', () async {
      await _preparar();
      const medicionId = '9b1d8f2e-1111-4000-8000-0000000000aa';
      await _sembrarOpMedicion(medicionId);
      var locales = await medicionesClienteLocal(55);
      expect(locales, hasLength(1));
      expect(locales.single['medicion_id'], medicionId);

      expect(
          await cancelarMedicionPendienteSiExiste(medicionId),
          isTrue);
      locales = await medicionesClienteLocal(55);
      expect(locales, isEmpty,
          reason: 'la fila vivía de la op pendiente: cancelada '
              'la op, no queda medición');
      // Segunda vez: ya no hay op que cancelar.
      expect(
          await cancelarMedicionPendienteSiExiste(medicionId),
          isFalse);
    });

    test('un UUID desconocido no cancela nada', () async {
      await _preparar();
      await _sembrarOpMedicion(
          '9b1d8f2e-2222-4000-8000-0000000000bb');
      expect(
          await cancelarMedicionPendienteSiExiste(
              '00000000-0000-4000-8000-000000000000'),
          isFalse);
      expect(await medicionesClienteLocal(55), hasLength(1));
    });
  });
}
