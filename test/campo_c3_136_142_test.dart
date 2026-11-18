/// 1.36 · CAMPO C-3 (fila 136-142, E-01 de la auditoría propia
/// de la 1.35) — conteo veraz del trabajo fuera de `ops_queue`,
/// reconocimiento del rechazo explicado y semáforo de autocura
/// honesto.
///
/// Caso de campo citado (PLAN.md, Bloque C): el banner de Salud
/// de Jc en rojo para siempre por dos `liquidar_caja`
/// RECHAZADAS con motivo correcto del servidor (guarda
/// CAMPO-15 y «liquidación sin operaciones incluidas») que la
/// app no sabía archivar; y la autocura «en rojo» por estale
/// (sin completa desde el 9/11, 0 divergentes).
///
/// (a) el conteo incluye lo fuera de cola sin reconocer y
///     excluye lo reconocido;
/// (b) reconocer una rechazada con motivo la mueve a
///     bitácora, baja la cuenta y la op NO resucita en el
///     ciclo siguiente (sigue 'rechazada', fuera de
///     countPendingOps, y el conteo la sigue excluyendo);
/// (c) una en revisión NO se puede descartar con este gesto,
///     ni una rechazada sin motivo;
/// (d) el semáforo de autocura pinta distinto estale y
///     divergente.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/centro_sync.dart';
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

Future<void> _op({
  required String uuid,
  required String estado,
  String tipo = 'liquidar_caja',
  String? error,
  String? resultadoServidor,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode({'x': 1}),
    'estado': estado,
    'creada_ts': '2026-11-17T00:23:00.000Z',
    if (error != null) 'error': error,
    if (resultadoServidor != null)
      'resultado_servidor': resultadoServidor,
  });
}

const _motivoCampo15 =
    'el liquidado es el propio dueño: su efectivo no entra al '
    'pendiente a entregar y no se liquida';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('C-3 (a) conteo fuera de cola', () {
    test(
        'cuenta revisión, rechazada sin reconocer, fotos, '
        'comprobantes e incidencias en error', () async {
      await _bdVacia();
      await _op(uuid: 'rev-1', estado: 'necesita_revision');
      await _op(
          uuid: 'rec-1', estado: 'rechazada', error: _motivoCampo15);
      await _op(uuid: 'apl-1', estado: 'aplicada', tipo: 'pago_mensual');
      final db = await LocalDb.instance.db;
      await db.insert('fotos_cola', {
        'op_uuid': 'op-foto-1',
        'tipo': 'thumb',
        'ruta_local': '/tmp/f1.jpg',
        'estado': 'pendiente',
        'creado_en': '2026-11-17T00:00:00.000Z',
        'actualizado_en': '2026-11-17T00:00:00.000Z',
      });
      await db.insert('fotos_cola', {
        'op_uuid': 'op-foto-2',
        'tipo': 'thumb',
        'ruta_local': '/tmp/f2.jpg',
        'estado': 'error',
        'creado_en': '2026-11-17T00:00:00.000Z',
        'actualizado_en': '2026-11-17T00:00:00.000Z',
      });
      await db.insert('comprobantes_pago', {
        'comprobante_uuid': 'comp-1',
        'estado': 'error',
        'creado_en': '2026-11-17T00:00:00.000Z',
      });
      // La foto referencia a su incidencia local (FK): la
      // incidencia dueña está sincronizada; la que está en
      // error es la otra.
      await db.insert('incidencias_local', {
        'id': 'inc-1',
        'sync_estado': 'synced',
      });
      await db.insert('incidencias_fotos', {
        'id': 'if-1',
        'incidencia_id': 'inc-1',
        'local_path': '/tmp/if1.jpg',
        'sync_estado': 'error',
        'creado_en': '2026-11-17T00:00:00.000Z',
      });
      await db.insert('incidencias_local', {
        'id': 'inc-2',
        'sync_estado': 'error',
      });

      final c = await LocalDb.instance.conteoTrabajoFueraCola();
      expect(c.enRevision, 1);
      expect(c.rechazadasSinReconocer, 1);
      expect(c.fotosPendientes, 1);
      expect(c.fotosError, 1);
      expect(c.comprobantesError, 1);
      expect(c.comprobantesPendientes, 0);
      expect(c.incidenciasEnError, 2);
      expect(c.total, 7);
      // La cola de subida, en cambio, está vacía: sin este
      // conteo TODAS las superficies dirían «al día».
      expect(await LocalDb.instance.countPendingOps(), 0);
      expect(await LocalDb.instance.countOpsFallidas(), 2,
          reason: 'revisión + rechazada sin reconocer');
    });

    test(
        'SyncResultado con trabajo fuera de cola NO está al día '
        'aunque la cola haya quedado vacía', () {
      const r = SyncResultado(
          corrio: true, pendientesRestantes: 0, trabajoFueraCola: 2);
      expect(r.alDia, isFalse);
      expect(r.resumenCorto, contains('fuera de la cola'));
      expect(r.textoPendientes, contains('fuera de'));
      const limpio = SyncResultado(corrio: true);
      expect(limpio.alDia, isTrue);
      expect(limpio.resumenCorto, 'Todo estaba al día');
    });

    test(
        'resumenMostradorSync no dice «Todo al día» con '
        'fueraCola > 0 (absorbe a D-11)', () {
      expect(
        resumenMostradorSync(
            corriendo: false,
            pendientes: 0,
            enLinea: true,
            hayError: false,
            hayNovedades: false,
            fueraCola: 3),
        contains('fuera de la cola'),
      );
      expect(
        resumenMostradorSync(
            corriendo: false,
            pendientes: 0,
            enLinea: true,
            hayError: false,
            hayNovedades: false),
        'Todo al día',
      );
    });

    test(
        'estadoSaludSync: fuera de cola > 0 es fallo; null es '
        'sin verificar; 0 con todo en 0 es todoSubio', () {
      expect(
          estadoSaludSync(
              pendientes: 0,
              fallidas: 0,
              hayTablasEnRojo: false,
              trabajoFueraCola: 2),
          EstadoSaludSync.fallo);
      expect(
          estadoSaludSync(
              pendientes: 0,
              fallidas: 0,
              hayTablasEnRojo: false,
              trabajoFueraCola: null),
          EstadoSaludSync.sinVerificar);
      expect(
          estadoSaludSync(
              pendientes: 0,
              fallidas: 0,
              hayTablasEnRojo: false,
              trabajoFueraCola: 0),
          EstadoSaludSync.todoSubio);
    });
  });

  group('C-3 (b) reconocer el rechazo explicado', () {
    test(
        'reconocer la mueve a bitácora, baja la cuenta y la op '
        'no resucita ni cambia de estado', () async {
      await _bdVacia();
      await _op(
          uuid: 'rec-campo',
          estado: 'rechazada',
          error: _motivoCampo15);
      expect(
          (await LocalDb.instance.conteoTrabajoFueraCola())
              .rechazadasSinReconocer,
          1);
      expect(await LocalDb.instance.countOpsFallidas(), 1);

      final ok = await LocalDb.instance
          .marcarOpRechazadaReconocida('rec-campo');
      expect(ok, isTrue);

      // Sale de TODAS las cuentas.
      expect(
          (await LocalDb.instance.conteoTrabajoFueraCola())
              .rechazadasSinReconocer,
          0);
      expect(await LocalDb.instance.countOpsFallidas(), 0);
      expect(
          (await LocalDb.instance.conteosHeroeCola()).error, 0);

      // Asiento en bitácora: qué op, qué motivo, cuándo.
      final db = await LocalDb.instance.db;
      final log = await db.query('app_log',
          where: "evento = 'op_rechazada_reconocida' AND op_id = ?",
          whereArgs: ['rec-campo']);
      expect(log, hasLength(1));
      expect('${log.first['detalle']}', contains('liquidar_caja'));
      expect('${log.first['detalle']}', contains('propio dueño'));
      expect('${log.first['detalle']}', contains('reconocida_en='));
      expect('${log.first['ts']}', isNotEmpty);

      // La op NO resucita: sigue 'rechazada' (terminal), no
      // entra en la cola de subida y un «ciclo siguiente»
      // (releer los conteos) la sigue excluyendo.
      final filas = await db.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['rec-campo']);
      expect(filas.first['estado'], 'rechazada');
      expect(await LocalDb.instance.countPendingOps(), 0);
      expect(
          (await LocalDb.instance.conteoTrabajoFueraCola()).total,
          0);
      // Reconocer dos veces es idempotente: un solo asiento.
      expect(
          await LocalDb.instance
              .marcarOpRechazadaReconocida('rec-campo'),
          isTrue);
      final log2 = await db.query('app_log',
          where: "evento = 'op_rechazada_reconocida'");
      expect(log2, hasLength(1));
    });

    test(
        'el motivo puede venir del resultado_servidor (JSON) '
        'sin columna error', () async {
      await _bdVacia();
      await _op(
          uuid: 'rec-json',
          estado: 'rechazada',
          tipo: 'liquidar_caja',
          resultadoServidor: jsonEncode(
              {'estado': 'rechazada', 'error': 'liquidación sin operaciones incluidas'}));
      expect(LocalDb.motivoServidorDeOp({
        'resultado_servidor':
            '{"error": "liquidación sin operaciones incluidas"}'
      }), 'liquidación sin operaciones incluidas');
      expect(
          await LocalDb.instance
              .marcarOpRechazadaReconocida('rec-json'),
          isTrue);
      expect(
          (await LocalDb.instance.conteoTrabajoFueraCola())
              .rechazadasSinReconocer,
          0);
    });
  });

  group('C-3 (c) lo que el gesto NO descarta', () {
    test(
        'una en revisión no se reconoce y sigue contando; una '
        'rechazada sin motivo tampoco', () async {
      await _bdVacia();
      await _op(
          uuid: 'rev-motivo',
          estado: 'necesita_revision',
          error: 'motivo que sea');
      await _op(uuid: 'rec-sin-motivo', estado: 'rechazada');

      expect(
          await LocalDb.instance
              .marcarOpRechazadaReconocida('rev-motivo'),
          isFalse);
      expect(
          await LocalDb.instance
              .marcarOpRechazadaReconocida('rec-sin-motivo'),
          isFalse);
      expect(
          await LocalDb.instance
              .marcarOpRechazadaReconocida('no-existe'),
          isFalse);

      final c = await LocalDb.instance.conteoTrabajoFueraCola();
      expect(c.enRevision, 1);
      expect(c.rechazadasSinReconocer, 1);
      expect(await LocalDb.instance.countOpsFallidas(), 2);
      final db = await LocalDb.instance.db;
      final log = await db.query('app_log',
          where: "evento = 'op_rechazada_reconocida'");
      expect(log, isEmpty);
    });
  });

  group('C-3 (d) autocura: estale ≠ divergente', () {
    final ahora = DateTime(2026, 11, 17, 12);
    test('divergente manda aunque la completa sea fresca', () {
      expect(
          estadoAutocura(
              completaEn: ahora.subtract(const Duration(days: 1)),
              divergentes: 2,
              ahora: ahora),
          EstadoAutocura.divergente);
    });
    test(
        'completa vieja (9/11 → 17/11) con 0 divergentes es '
        'ESTALE, no divergente', () {
      final e = estadoAutocura(
          completaEn: DateTime(2026, 11, 9, 12),
          divergentes: 0,
          ahora: ahora);
      expect(e, EstadoAutocura.estale);
      final texto = textoEstadoAutocura(
          completaEn: DateTime(2026, 11, 9, 12),
          divergentes: 0,
          ahora: ahora);
      expect(texto, contains('Sin verificar desde hace mucho'));
      expect(texto, contains('no encontró tablas divergentes'));
    });
    test('completa fresca y 0 divergentes: coincide', () {
      expect(
          estadoAutocura(
              completaEn: ahora.subtract(const Duration(days: 2)),
              divergentes: 0,
              ahora: ahora),
          EstadoAutocura.coincide);
    });
    test('sin completa nunca y sin leer se distinguen', () {
      expect(
          estadoAutocura(
              completaEn: null, divergentes: 0, ahora: ahora),
          EstadoAutocura.nuncaCompleta);
      expect(
          estadoAutocura(
              completaEn: null,
              divergentes: 0,
              ahora: ahora,
              sinLeer: true),
          EstadoAutocura.sinLeer);
    });
  });
}
