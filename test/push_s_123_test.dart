/// 1.23 (Push-S): las 5 correcciones del veredicto de Argón al
/// Push (pasada 2: «motor de subida certificado con ajustes»).
///
/// - P-1: normalizarFilaResultado fuerza 'rechazada' cuando el
///   envelope dice ok=false, con la excepción de la PAUSA
///   (ACCESO_PAUSADO no es rechazo).
/// - P-2: traducirErrorSync clasifica handshake/clientexception/
///   connection closed como sin_conexion (antes: «desconocido»
///   con datosGuardadosLocalmente en false).
/// - P-3: al confirmar una op, la fila optimista se limpia y la
///   incidencia se marca sincronizada desde
///   _aplicarEstadoServidor (todos los caminos, no solo el
///   barrido).
/// - P-4: enviadaDebeResetear compara instantes (epoch), no
///   texto ISO — la hora repetida del fall-back no resbala.
/// - P-5: barridoSiHayEnviadas también barre las 'pendiente'
///   con enviada_ts (salieron y el ciclo murió tras el reset).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
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
  Map<String, dynamic> payload = const {},
  String? enviadaTs,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'enviada_ts': enviadaTs,
    'creada_ts': '2026-11-03T09:00:00.000-04:00',
  });
}

Future<Map<String, ResultadoOpServidor>> Function(List<String>)
    _verificarAplicada() {
  return (uuids) async => {
        for (final u in uuids)
          u: (
            estado: 'aplicada',
            resultado: {'ok': true},
            error: null,
          ),
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P-1 · normalizarFilaResultado', () {
    test('aplicada con envelope ok=false → rechazada', () {
      final rec = normalizarFilaResultado({
        'estado': 'aplicada',
        'resultado': {'ok': false, 'error': 'duplicado'},
        'error': null,
      });
      expect(rec.estado, 'rechazada');
    });

    test('aplicada con PAUSA del candado → NO se fuerza rechazo', () {
      final rec = normalizarFilaResultado({
        'estado': 'aplicada',
        'resultado': {
          'ok': false,
          'codigo': 'ACCESO_PAUSADO',
          'reintentable': true,
        },
        'error': null,
      });
      expect(rec.estado, 'aplicada');
    });

    test('fallback GET (aplicada=true) con ok=false → rechazada', () {
      final rec = normalizarFilaResultado({
        'aplicada': true,
        'resultado': {'ok': false},
      });
      expect(rec.estado, 'rechazada');
    });

    test('pendiente con ok=false NO se fuerza (sigue en vuelo)', () {
      final rec = normalizarFilaResultado({
        'estado': 'pendiente',
        'resultado': {'ok': false},
      });
      expect(rec.estado, 'pendiente');
    });

    test('aplicada con ok=true queda aplicada', () {
      final rec = normalizarFilaResultado({
        'estado': 'aplicada',
        'resultado': {'ok': true},
      });
      expect(rec.estado, 'aplicada');
    });
  });

  group('P-2 · traducirErrorSync red', () {
    test('HandshakeException → sin_conexion con datos guardados', () {
      final e = traducirErrorSync(
          Exception('HandshakeException: Connection terminated '
              'during handshake'));
      expect(e.codigo, 'sin_conexion');
      expect(e.datosGuardadosLocalmente, isTrue);
    });

    test('ClientException connection closed → sin_conexion', () {
      final e = traducirErrorSync(Exception(
          'ClientException: Connection closed before full header '
          'was received'));
      expect(e.codigo, 'sin_conexion');
      expect(e.datosGuardadosLocalmente, isTrue);
    });

    test('connection reset → sin_conexion', () {
      final e = traducirErrorSync(
          Exception('Connection reset by peer'));
      expect(e.codigo, 'sin_conexion');
    });
  });

  group('P-4 · enviadaDebeResetear (instantes, no texto)', () {
    // Corte: 2026-11-03T12:00:00Z.
    final corte =
        DateTime.utc(2026, 11, 3, 12, 0).millisecondsSinceEpoch;

    test('sin sello (pre-v21) → resetea', () {
      expect(enviadaDebeResetear(null, corte), isTrue);
    });

    test('anterior al corte → resetea; posterior → no', () {
      // El corte YA es «ahora − 2 min»: 07:50-04:00 = 11:50Z
      // queda antes del corte (12:00Z); 08:01-04:00 = 12:01Z
      // queda después (envío más reciente que el corte).
      expect(
          enviadaDebeResetear('2026-11-03T07:50:00-04:00', corte),
          isTrue);
      expect(
          enviadaDebeResetear('2026-11-03T08:01:00-04:00', corte),
          isFalse);
    });

    test('sello ilegible → NO se toca', () {
      expect(enviadaDebeResetear('no-es-fecha', corte), isFalse);
    });

    test('la hora repetida del fall-back no resbala el corte', () {
      // 1-nov: 01:30 con -04:00 (primera ocurrencia, 05:30Z) vs
      // corte en la segunda ocurrencia 01:15 -05:00 (06:15Z).
      // Por instante, la op lleva 45 min esperando → resetea.
      // Por texto, '01:30' > '01:15' diría que es NUEVA y la
      // dejaría en limbo otra hora.
      final corteFallBack =
          DateTime.utc(2026, 11, 1, 6, 15).millisecondsSinceEpoch;
      expect(
          enviadaDebeResetear(
              '2026-11-01T01:30:00-04:00', corteFallBack),
          isTrue);
      // Y la simétrica: segunda ocurrencia 01:30 -05:00
      // (06:30Z) es POSTERIOR al corte → no resetea, aunque su
      // texto sea idéntico al caso anterior salvo el offset.
      expect(
          enviadaDebeResetear(
              '2026-11-01T01:30:00-05:00', corteFallBack),
          isFalse);
    });
  });

  group('P-3 · efectos laterales al confirmar', () {
    test('confirmar crear_categoria limpia su fila optimista',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await db.insert('categorias_suplemento', {
        'id': -5,
        'data': jsonEncode({'op_uuid': 'op-cat-1', 'nombre': 'X'}),
        'sync_seq': 0,
      });
      await _insertarOp(
          uuid: 'op-cat-1', tipo: 'crear_categoria', estado: 'enviada');
      final r = await SyncEngine.instance.barridoConfirmacion(
          verificar: _verificarAplicada());
      expect(r.confirmadas, 1);
      final filas = await db.query('categorias_suplemento',
          where: 'id = ?', whereArgs: [-5]);
      expect(filas, isEmpty,
          reason: 'sin la limpieza, la categoría quedaría '
              'duplicada al bajar la fila real');
    });

    test('confirmar una incidencia la marca sincronizada', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await db.insert('incidencias_local', {
        'id': 'inc-1',
        'tipo': 'otro',
        'descripcion': 'prueba',
        'creada_por': 'dueno',
        'creada_en': '2026-11-03T09:00:00-04:00',
        'sincronizada': 0,
      });
      await _insertarOp(
          uuid: 'op-inc-1',
          tipo: 'incidencia',
          estado: 'enviada',
          payload: {'id': 'inc-1'});
      final r = await SyncEngine.instance.barridoConfirmacion(
          verificar: _verificarAplicada());
      expect(r.confirmadas, 1);
      final filas = await db.query('incidencias_local',
          where: 'id = ?', whereArgs: ['inc-1']);
      expect(filas.single['sincronizada'], 1);
      expect(filas.single['sync_estado'], 'synced');
    });
  });

  group('P-5 · barridoSiHayEnviadas con sospechosas', () {
    test('pendiente CON enviada_ts sí dispara el barrido', () async {
      await _bdVacia();
      await _insertarOp(
          uuid: 'op-sosp-1',
          tipo: 'confirmar_entrega',
          estado: 'pendiente',
          enviadaTs: '2026-11-03T08:00:00-04:00');
      final r = await SyncEngine.instance.barridoSiHayEnviadas(
          verificar: _verificarAplicada());
      expect(r.confirmadas, 1);
    });

    test('pendiente SIN enviada_ts no dispara el barrido', () async {
      await _bdVacia();
      await _insertarOp(
          uuid: 'op-nueva-1',
          tipo: 'confirmar_entrega',
          estado: 'pendiente');
      var llamo = false;
      final r = await SyncEngine.instance.barridoSiHayEnviadas(
          verificar: (uuids) async {
        llamo = true;
        return {};
      });
      expect(r.confirmadas, 0);
      expect(llamo, isFalse);
    });
  });
}
