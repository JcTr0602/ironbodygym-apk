/// Tests v1.3.5 — Detalle ampliable "Bajados/Subidos" (veredicto de
/// Argón, LUZ ÁMBAR 2026-10-16).
///
/// Cubre:
/// - [serializarDetallePull] / [parsearDetallePull]: el desglose por
///   tabla del pull (solo tablas con filas > 0, tolerante a JSON roto).
/// - [debeActualizarDetallePull]: la trampa 2 — un pull vacío NO
///   sobreescribe el desglose anterior.
/// - [serializarUuidsPush] / [parsearUuidsPush]: los UUIDs del último
///   push (trampa 1 — la UI lee exactamente estos UUIDs).
/// - [LocalDb.opsPorUuids]: lectura del detalle por UUIDs, orden
///   creada_ts DESC, lista vacía → lista vacía.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BD limpia (instalación v26) y singleton reseteado.
Future<void> _abrirLimpia() async {
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

Future<void> _insertarOp({
  required String uuid,
  required String tipo,
  required String estado,
  required String creadaTs,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode({'cliente_id': 7}),
    'estado': estado,
    'creada_ts': creadaTs,
  });
}

void main() {
  group('serializarDetallePull / parsearDetallePull', () {
    test('solo incluye tablas con filas > 0', () {
      final json = serializarDetallePull({
        'clientes': 3,
        'pagos': 0,
        'suplementos': 1,
      });
      final m = jsonDecode(json) as Map<String, dynamic>;
      expect(m, {'clientes': 3, 'suplementos': 1});
    });

    test('roundtrip preserva el desglose', () {
      const porTabla = {'clientes': 2, 'pagos_diarios': 5};
      expect(parsearDetallePull(serializarDetallePull(porTabla)), porTabla);
    });

    test('parsear es tolerante: null, vacío, roto', () {
      expect(parsearDetallePull(null), isEmpty);
      expect(parsearDetallePull(''), isEmpty);
      expect(parsearDetallePull('no-es-json'), isEmpty);
      expect(parsearDetallePull('{"a": "x"}'), isEmpty);
    });
  });

  group('debeActualizarDetallePull (trampa 2 de Argón)', () {
    test('pull con filas SÍ actualiza', () {
      expect(debeActualizarDetallePull(1), isTrue);
      expect(debeActualizarDetallePull(42), isTrue);
    });

    test('pull vacío NO actualiza (preserva el desglose anterior)', () {
      expect(debeActualizarDetallePull(0), isFalse);
    });
  });

  group('serializarUuidsPush / parsearUuidsPush (trampa 1 de Argón)', () {
    test('roundtrip preserva orden y contenido', () {
      const uuids = ['a-1', 'b-2', 'c-3'];
      expect(parsearUuidsPush(serializarUuidsPush(uuids)), uuids);
    });

    test('lista vacía serializa y parsea a vacía', () {
      expect(parsearUuidsPush(serializarUuidsPush([])), isEmpty);
    });

    test('parsear es tolerante: null, vacío, roto', () {
      expect(parsearUuidsPush(null), isEmpty);
      expect(parsearUuidsPush(''), isEmpty);
      expect(parsearUuidsPush('[[[invalido'), isEmpty);
    });
  });

  group('LocalDb.opsPorUuids', () {
    test('devuelve solo los UUIDs pedidos en orden creada_ts DESC',
        () async {
      await _abrirLimpia();
      final t1 = isoHabana(ahoraHabana().subtract(const Duration(minutes: 3)));
      final t2 = isoHabana(ahoraHabana().subtract(const Duration(minutes: 2)));
      final t3 = isoHabana(ahoraHabana().subtract(const Duration(minutes: 1)));
      await _insertarOp(
          uuid: 'u1', tipo: 'pago_mensual', estado: 'aplicada', creadaTs: t1);
      await _insertarOp(
          uuid: 'u2', tipo: 'inscribir', estado: 'aplicada', creadaTs: t2);
      await _insertarOp(
          uuid: 'u3', tipo: 'gasto', estado: 'pendiente', creadaTs: t3);

      final filas = await LocalDb.instance.opsPorUuids(['u1', 'u3']);
      expect(filas.map((f) => f['op_uuid']), ['u3', 'u1']);
    });

    test('lista vacía de UUIDs → lista vacía sin tocar la BD', () async {
      await _abrirLimpia();
      expect(await LocalDb.instance.opsPorUuids([]), isEmpty);
    });

    test('UUIDs inexistentes → lista vacía', () async {
      await _abrirLimpia();
      expect(await LocalDb.instance.opsPorUuids(['no-existe']), isEmpty);
    });
  });

  group('esTerminalParaDetalle (Argón ajuste 2)', () {
    test('aplicada es terminal', () {
      expect(
          SyncEngine.esTerminalParaDetalle(
              (estado: 'aplicada', resultado: {'ok': true}, error: null)),
          isTrue);
    });

    test('rechazada es terminal', () {
      expect(
          SyncEngine.esTerminalParaDetalle(
              (estado: 'rechazada', resultado: {'ok': false}, error: 'x')),
          isTrue);
    });

    test('necesita_revision es terminal', () {
      expect(
          SyncEngine.esTerminalParaDetalle(
              (estado: 'necesita_revision', resultado: null, error: null)),
          isTrue);
    });

    test('aplicada con rechazo del puente es terminal (va como rechazada)',
        () {
      expect(
          SyncEngine.esTerminalParaDetalle((
            estado: 'aplicada',
            resultado: {'ok': false, 'error': 'rechazado'},
            error: null
          )),
          isTrue);
    });

    test('pendiente NO es terminal', () {
      expect(
          SyncEngine.esTerminalParaDetalle(
              (estado: 'pendiente', resultado: null, error: null)),
          isFalse);
    });
  });

  group('contarEnDetallePull (auditoría 2026-10-16)', () {
    test('incrementa desde cero', () {
      final m = <String, int>{};
      contarEnDetallePull(m, 'clientes');
      expect(m, {'clientes': 1});
    });

    test('acumula upserts y tombstones en la misma tabla', () {
      final m = <String, int>{'clientes': 2};
      contarEnDetallePull(m, 'clientes'); // tombstone
      contarEnDetallePull(m, 'pagos'); // otra tabla
      expect(m, {'clientes': 3, 'pagos': 1});
    });

    test('un pull de solo-eliminaciones produce detalle no vacío', () {
      final m = <String, int>{};
      contarEnDetallePull(m, 'clientes');
      contarEnDetallePull(m, 'clientes');
      // serializarDetallePull solo incluye > 0: el detalle se actualiza.
      final json = serializarDetallePull(m);
      expect(parsearDetallePull(json), {'clientes': 2});
      expect(debeActualizarDetallePull(m.values.fold(0, (a, b) => a + b)),
          isTrue);
    });
  });
}
