/// Tests 1.15 Grupo B — Sync APP (S1.3, S1.4, S1.6, S1.7,
/// caso a, caso c).
///
/// Alcance honesto de estos tests: las decisiones puras y los
/// seams testeables (barridoSiHayEnviadas, metas de sync,
/// pendientesParaEnvio, antigüedad) se prueban directo. El
/// _uploadOps completo y el pull con red NO se bombean: exigen
/// sesión Supabase y red; su cableado a debeBarrerTrasPush y a
/// barridoSiHayEnviadas se verifica por código (el push usa la
/// decisión pura; el pull llama al seam solo si hay 'enviada').
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

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _insertarOp({
  required String uuid,
  required String estado,
  String? userId,
  String? proximoReintento,
  String creadaTs = '2026-10-23T09:38:00-04:00',
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'confirmar_entrega',
    'payload': jsonEncode({'cliente_id': 7}),
    'estado': estado,
    'user_id': userId,
    'proximo_reintento': proximoReintento,
    'creada_ts': creadaTs,
  });
}

Future<String?> _estadoDe(String uuid) async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('ops_queue',
      columns: ['estado'], where: 'op_uuid = ?', whereArgs: [uuid]);
  return rows.isEmpty ? null : rows.first['estado'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sync 1.15 — tiempo (S1.3/S1.4)', () {
    test('test_isoHabana_offset_del_instante_no_del_ahora', () {
      // Julio (verano Habana, UTC-4) y enero (invierno, UTC-5),
      // evaluados sobre el propio instante, no sobre el ahora.
      // Entradas con DateTime.utc: isoHabana lee solo los campos
      // (wall-clock Habana) y la bandera no los altera, así el
      // test es independiente de la TZ del proceso (el
      // constructor local desplaza las horas del salto DST).
      expect(isoHabana(DateTime.utc(2026, 7, 15, 14, 30)),
          '2026-07-15T14:30:00-04:00');
      expect(isoHabana(DateTime.utc(2026, 1, 15, 14, 30)),
          '2026-01-15T14:30:00-05:00');
      // La base conserva los campos Habana (no se desplaza).
      expect(isoHabana(DateTime.utc(2026, 7, 15, 14, 30)).substring(0, 19),
          '2026-07-15T14:30:00');
    });

    test('test_isoHabana_frontera_noviembre_2026', () {
      // Fall-back 2026: 1-nov. 00:30 Habana aún es horario de
      // verano (-04:00); 03:00 ya es estándar (-05:00).
      expect(isoHabana(DateTime.utc(2026, 11, 1, 0, 30)),
          '2026-11-01T00:30:00-04:00');
      expect(isoHabana(DateTime.utc(2026, 11, 1, 3, 0)),
          '2026-11-01T03:00:00-05:00');
    });

    test('test_isoHabana_frontera_marzo_2026', () {
      // Inicio DST 2026: 8-mar. 00:30 Habana aún es estándar
      // (-05:00); 03:00 ya es verano (-04:00).
      expect(isoHabana(DateTime.utc(2026, 3, 8, 0, 30)),
          '2026-03-08T00:30:00-05:00');
      expect(isoHabana(DateTime.utc(2026, 3, 8, 3, 0)),
          '2026-03-08T03:00:00-04:00');
    });

    test('test_marcas_sync_llevan_offset_habana', () async {
      await _bdVacia();
      await SyncEngine.instance.marcarGuardado();
      await SyncEngine.instance.marcarSincronizado();
      final g =
          await LocalDb.instance.getMeta('ultimo_guardado_local');
      final s = await LocalDb.instance.getMeta('ultimo_sincronizado');
      // Offset Habana explícito al final, no ISO local sin offset.
      expect(g, matches(RegExp(r'[-+]\d{2}:\d{2}$')));
      expect(s, matches(RegExp(r'[-+]\d{2}:\d{2}$')));
      // _marcarOk, last_pull_ok y last_pull_incidencias_ok usan
      // la misma llamada isoHabana(ahoraHabana()) (ver código:
      // no son invocables sin ciclo de sync con sesión).
      expect(isoHabana(ahoraHabana()),
          matches(RegExp(r'[-+]\d{2}:\d{2}$')));
    });

    test('test_parseFecha_isoHabana_instante_correcto', () {
      // Sin .toLocal(): el instante es el mismo que el ISO.
      final dt = parseFecha('2026-10-26T10:00:00-04:00');
      expect(dt, isNotNull);
      expect(dt!.toUtc(), DateTime.utc(2026, 10, 26, 14, 0));
      // Ida y vuelta con isoHabana: el instante se conserva.
      final iso = isoHabana(DateTime.utc(2026, 10, 26, 10, 0));
      expect(parseFecha(iso)!.toUtc(), DateTime.utc(2026, 10, 26, 14, 0));
      expect(parseFecha(null), isNull);
      expect(parseFecha(''), isNull);
      expect(parseFecha('no-es-fecha'), isNull);
    });
  });

  group('Sync 1.15 — scope, pull y push (S1.6/S1.7, caso c)', () {
    test('test_scope_no_pisa_last_pull_ok', () async {
      await _bdVacia();
      // Semilla: un pull completo anterior.
      await LocalDb.instance
          .setMeta('last_pull_ok', '2026-01-01T00:00:00-05:00');
      // Sin sesión, sincronizarScope no corre su cuerpo (lock
      // sin sesión) y no debe tocar ninguna de las dos metas.
      await SyncEngine.instance.sincronizarScope('papelera');
      expect(await LocalDb.instance.getMeta('last_pull_ok'),
          '2026-01-01T00:00:00-05:00');
      expect(await LocalDb.instance.getMeta('last_pull_scope_ok'), isNull);
      // En código, el camino con sesión escribe last_pull_scope_ok
      // con isoHabana(ahoraHabana()) y ya no escribe last_pull_ok.
    });

    test('test_pull_barrera_confirmacion_ops_enviadas', () async {
      await _bdVacia();
      await _insertarOp(uuid: 'op-enviada', estado: 'enviada');
      await _insertarOp(uuid: 'op-pendiente', estado: 'pendiente');
      List<String>? consultados;
      final res = await SyncEngine.instance.barridoSiHayEnviadas(
        verificar: (uuids) async {
          consultados = uuids;
          return {
            'op-enviada': (
              estado: 'aplicada',
              resultado: {'ok': true},
              error: null,
            ),
          };
        },
      );
      expect(consultados, contains('op-enviada'));
      expect(res.confirmadas, 1);
      expect(await _estadoDe('op-enviada'), 'aplicada');
      expect(await _estadoDe('op-pendiente'), 'pendiente');

      // Solo pendiente/error: el barrido NO se dispara.
      await _bdVacia();
      await _insertarOp(uuid: 'op-solo-pend', estado: 'pendiente');
      await _insertarOp(uuid: 'op-solo-err', estado: 'error');
      var llamo = false;
      final res2 = await SyncEngine.instance.barridoSiHayEnviadas(
        verificar: (uuids) async {
          llamo = true;
          return {};
        },
      );
      expect(llamo, isFalse);
      expect(res2.confirmadas, 0);
    });

    test('test_pull_barrera_confirmacion_lectura_fallida_no_modifica_ops',
        () async {
      await _bdVacia();
      await _insertarOp(uuid: 'op-enviada', estado: 'enviada');
      await _insertarOp(uuid: 'op-pendiente', estado: 'pendiente');
      final res = await SyncEngine.instance.barridoSiHayEnviadas(
        verificar: (uuids) async => throw Exception('sin red (fake)'),
      );
      // Triestado: la lectura fallida no marca nada.
      expect(res.confirmadas, 0);
      expect(await _estadoDe('op-enviada'), 'enviada');
      expect(await _estadoDe('op-pendiente'), 'pendiente');
    });

    test('test_upload_ops_omite_barrido_si_post_falla_y_no_habia_enviadas',
        () {
      // Decisión pura que _uploadOps aplica en su paso 3.
      bool decide(
              {required bool habia,
              required bool aceptado,
              required bool ambiguo,
              required bool fallo}) =>
          SyncEngine.debeBarrerTrasPush(
            habiaEnviadas: habia,
            algunEnvioAceptado: aceptado,
            resultadoAmbiguo: ambiguo,
            falloInequivoco: fallo,
          );
      // Caso pedido: POST falla, sin enviadas previas → se omite.
      expect(
          decide(habia: false, aceptado: false, ambiguo: false, fallo: true),
          isFalse);
      // Había enviadas previas → se barre aunque el POST falle.
      expect(
          decide(habia: true, aceptado: false, ambiguo: false, fallo: true),
          isTrue);
      // POST ambiguo (timeout/5xx) → NUNCA se omite el barrido.
      expect(
          decide(habia: false, aceptado: false, ambiguo: true, fallo: true),
          isTrue);
      // Algún envío aceptado → se barre.
      expect(
          decide(habia: false, aceptado: true, ambiguo: false, fallo: false),
          isTrue);
      // Sin POST ni fallo → barrido heredado (triestado, inocuo).
      expect(
          decide(habia: false, aceptado: false, ambiguo: false, fallo: false),
          isTrue);
    });
  });

  group('Sync 1.15 — cola local (caso a, pendientes)', () {
    test('test_pendientes_para_envio_incluye_user_id_null_y_respeta_backoff',
        () async {
      await _bdVacia();
      final futuro = isoHabana(ahoraHabana().add(const Duration(hours: 1)));
      final pasado =
          isoHabana(ahoraHabana().subtract(const Duration(hours: 1)));
      await _insertarOp(
          uuid: 'op-nula', estado: 'pendiente', userId: null);
      await _insertarOp(
          uuid: 'op-propia', estado: 'pendiente', userId: 'u1');
      await _insertarOp(
          uuid: 'op-ajena', estado: 'pendiente', userId: 'u2');
      await _insertarOp(
          uuid: 'op-backoff',
          estado: 'error',
          userId: null,
          proximoReintento: futuro);
      await _insertarOp(
          uuid: 'op-backoff-vencido',
          estado: 'pendiente',
          userId: null,
          proximoReintento: pasado);
      final ops = await LocalDb.instance.pendientesParaEnvio('u1');
      final uuids = [for (final o in ops) o['op_uuid'] as String];
      expect(uuids, containsAll(['op-nula', 'op-propia', 'op-backoff-vencido']),
          reason: 'user_id NULL se incluye con usuario no nulo');
      expect(uuids, isNot(contains('op-ajena')));
      expect(uuids, isNot(contains('op-backoff')),
          reason: 'el backoff futuro se respeta sin forzar');
      // Con forzar, el backoff se cancela.
      final forzadas =
          await LocalDb.instance.pendientesParaEnvio('u1', forzar: true);
      expect(
          [for (final o in forzadas) o['op_uuid'] as String],
          contains('op-backoff'));
    });

    test('test_aviso_antiguedad_incluye_op_enviada', () async {
      await _bdVacia();
      // Solo una op 'enviada' vieja: antes no activaba el aviso
      // (el filtro era solo pendiente/error).
      await _insertarOp(
          uuid: 'op-enviada-vieja',
          estado: 'enviada',
          creadaTs: '2026-10-20T09:38:00-04:00');
      await _insertarOp(
          uuid: 'op-pendiente-nueva',
          estado: 'pendiente',
          creadaTs: '2026-10-23T09:38:00-04:00');
      expect(await LocalDb.instance.isoOpPendienteMasAntigua(),
          '2026-10-20T09:38:00-04:00');
      // Sin pendiente/error, solo enviada: también la devuelve.
      await _bdVacia();
      await _insertarOp(
          uuid: 'op-solo-enviada',
          estado: 'enviada',
          creadaTs: '2026-10-20T09:38:00-04:00');
      expect(await LocalDb.instance.isoOpPendienteMasAntigua(),
          '2026-10-20T09:38:00-04:00');
    });
  });
}
