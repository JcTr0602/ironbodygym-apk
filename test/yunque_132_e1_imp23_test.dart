/// 1.32 · Escalón 1 — IMP-23 completo (sugerencias de
/// arquitectura de la Auditoría Definitiva, destino 1.32):
///
/// (1) CATÁLOGO ÚNICO DE ESPEJOS: la clasificación de
/// herencia vive en CatalogoEspejos (localdb). Paridad
/// CONDUCTUAL original: con la meta `wm_<t>` ausente y el
/// global alto, cada no-heredera devolvía 0 y cada heredera
/// el global — el fallo SB-02 convertido en test.
/// ACTUALIZADO por la síntesis AP-2 (1.32): la herencia
/// viva quedó jubilada — sin meta, TODAS devuelven 0; la
/// clasificación solo alimenta la materialización única
/// (v74) y la foto de semillas cubre ahora todo espejo
/// con columna sync_seq (49 claves `wm_*`).
/// (2) PUSH LIMPIO DECLARATIVO: el veredicto se publica UNA
/// vez al cierre de _doPush; un bump a mitad de corrida mueve
/// el acumulador pero NO republica el veredicto que leen los
/// consumidores.
/// (3) TRANSICIÓN DE INCIDENCIAS: matriz de los 4 tipos vivos
/// por el embudo central. El comentario era el tipo sin
/// resolutor (su fila quedaba 'pending' eterna al morir o ser
/// rechazada su op): ahora se resuelve SU fila sin tocar la
/// incidencia padre, por el barrido y por la muerte local.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  group('IMP-23(1) · Catálogo Único de Espejos', () {
    test('instalación limpia: las semillas wm_* son las 19 '
        'declaradas', () async {
      final db = await _abrirDbVacia();
      final rows = await db.query('meta',
          columns: ['k'], where: "k LIKE 'wm\\_%' ESCAPE '\\'");
      final semillas = {for (final r in rows) '${r['k']}'.substring(3)};
      // 1.32 (O2F2S, síntesis AP-2): la siembra ya no es
      // una lista corta de migraciones sueltas —
      // _sembrarWatermarksAp2 siembra TODA tabla local
      // con columna sync_seq al nacer (49 hoy: los 42
      // espejos del pull con tabla local + espejos de
      // incidencias, tumbas y ultimo_sync). La foto se
      // actualiza a ese universo; una semilla nueva o
      // retirada obliga a revisar el catálogo y esta
      // foto a la vez.
      expect(semillas, {
        'acceso_bloqueos', 'adelantos', 'avisos_entrenadores',
        'avisos_vistos', 'categorias_suplemento',
        'cliente_congelaciones', 'cliente_mediciones',
        'clientes', 'diferencias_caja',
        'espejo_entregas_efectivo', 'espejo_gympedia_borradores',
        'espejo_recordatorio_config', 'espejo_tarifas_especiales',
        'gastos', 'guia_borrados', 'guia_equipos', 'guia_fichas',
        'gympedia_articulos', 'gympedia_borrados',
        'gympedia_solicitudes', 'incidencia_eventos_mirror',
        'incidencias_cuarentena', 'incidencias_mirror',
        'incidencias_sync', 'incidencias_tipos_mirror',
        'liquidaciones_caja', 'nomina_bonos',
        'nomina_confirmaciones', 'nomina_liquidada',
        'nomina_liquidada_snapshot', 'pagos', 'pagos_diarios',
        'permisos_bandeja', 'reservas',
        'servicio_agua_movimientos', 'servicio_botes',
        'servicio_compras', 'servicio_lotes', 'servicio_pomos',
        'servicio_salidas', 'servicio_ventas',
        'solicitudes_adelanto', 'solicitudes_relleno',
        'suplemento_ajustes', 'suplementos', 'turnos_apertura',
        'turnos_cierre', 'ultimo_sync', 'ventas_suplementos',
      },
          reason: 'una semilla nueva o retirada obliga a '
              'actualizar el catálogo y esta foto a la vez');
      await db.close();
    });

    test('sin meta wm_<t> y global alto: NADIE hereda '
        '(AP-2 supersede la herencia viva de IMP-23)', () async {
      // IMP-23 fijó: meta ausente ⇒ las herederas leen el
      // global. La síntesis AP-2 lo revirtió a propósito:
      // si la fila se pierde (purga, restauración parcial,
      // borrarMeta), la heredera quedaba congelada en el
      // global alto para siempre y sin error. Desde v74
      // la herencia vive solo como materialización única
      // (la fila nace con el global copiado); la lectura
      // sin fila es 0 para TODAS y la tabla re-baja.
      final db = await _abrirDbVacia();
      await LocalDb.instance.setWatermark(999999);
      Future<int> sinMeta(String t) async {
        await db.delete('meta', where: 'k=?', whereArgs: ['wm_$t']);
        return LocalDb.instance.getWatermarkTabla(t);
      }

      for (final t in CatalogoEspejos.noHerederos) {
        expect(await sinMeta(t), 0,
            reason: '$t es no-heredera en el catálogo: con su '
                'meta ausente no puede heredar el global');
      }
      // Familias por prefijo (representantes reales).
      for (final t in [
        'incidencias_sync',
        'incidencias_comentarios',
        'servicio_pomos',
        'servicio_ventas',
      ]) {
        expect(await sinMeta(t), 0,
            reason: '$t entra por la familia de prefijo del '
                'catálogo');
      }
      // Las antiguas herederas: tampoco heredan en vivo.
      for (final t in [
        'clientes',
        'pagos',
        'gastos',
        'turnos_cierre',
        'cliente_mediciones',
      ]) {
        expect(await sinMeta(t), 0,
            reason: 'AP-2: $t sin fila lee 0 y re-baja; su '
                'posición heredada vive en la fila '
                'materializada por la migración v74');
      }
      await db.close();
    });

    test('la clasificación sigue siendo del catálogo: la '
        'consulta quien materializa, no quien lee (guarda '
        'de fuente AP-2)', () {
      final fuente = File('lib/localdb.dart').readAsStringSync();
      final i = fuente.indexOf('Future<int> getWatermarkTabla');
      final j = fuente.indexOf('Future<void> setWatermarkTabla', i);
      expect(i, isNonNegative);
      expect(j, isNonNegative);
      expect(fuente.substring(i, j),
          isNot(contains('CatalogoEspejos.heredaGlobal')),
          reason: 'AP-2: la lectura ya no hereda; si vuelve '
              'la consulta al catálogo aquí, la herencia '
              'viva resucitó');
      final k =
          fuente.indexOf('static Future<void> _sembrarWatermarksAp2');
      expect(k, isNonNegative);
      expect(
          fuente.substring(k, k + 2500),
          contains('CatalogoEspejos.heredaGlobal'),
          reason: 'la clasificación es del catálogo y la '
              'usa la materialización (única fuente, como '
              'mandaba la guarda original de IMP-23)');
    });
  });

  group('IMP-23(2) · veredicto declarativo del push', () {
    test('un bump mueve el acumulador pero NO republica el '
        'veredicto', () async {
      final db = await _abrirDbVacia();
      final motor = SyncEngine.instance;
      // Estado inicial: el veredicto nace limpio.
      expect(motor.veredictoUltimoPushParaTest.fallos, 0);
      expect(motor.veredictoUltimoPushParaTest.limpio, isTrue);

      // Una op golpeada a mitad de corrida (el embudo de
      // bumps incrementa el acumulador interno)...
      await db.insert('clientes', {
        'id': 42,
        'data': jsonEncode({'id': 42, 'nombre': 'V', 'estado': 'activo'}),
        'sync_seq': 1,
      });
      await db.insert('ops_queue', {
        'op_uuid': 'op-imp23-bump',
        'tipo': 'pago_mensual',
        'payload': jsonEncode(
            {'cliente_id': 42, 'pagado_hasta': '2026-12-01'}),
        'estado': 'enviada',
        'creada_ts': '2026-11-10T10:00:00-04:00',
      });
      final op = (await db.query('ops_queue',
              where: 'op_uuid=?', whereArgs: ['op-imp23-bump']))
          .single;
      await motor.bumpConReversionParaTest(op, 'HTTP 500',
          httpStatus: 500);

      // ...y el veredicto PUBLICADO sigue siendo el del
      // cierre anterior: los consumidores (sello, limpieza
      // de error, gancho de éxito) solo ven veredictos de
      // pushes CERRADOS, no acumuladores a medio camino.
      expect(motor.veredictoUltimoPushParaTest.fallos, 0,
          reason: 'el veredicto solo se publica al cierre de '
              '_doPush (IMP-23)');
      expect(motor.veredictoUltimoPushParaTest.limpio, isTrue);
      await db.close();
    });

    test('la publicación es única y vive al cierre de _doPush '
        '(guarda de fuente)', () {
      final fuente = File('lib/sync.dart').readAsStringSync();
      expect(
          '_veredictoUltimoPush = VeredictoPush(fallos: _fallosUltimoPush)'
              .allMatches(fuente)
              .length,
          1,
          reason: 'una sola escritura del veredicto con el '
              'acumulador de la corrida: su publicación al '
              'cierre (la declaración del campo nace con la '
              'constante limpia, no cuenta)');
      final i = fuente.indexOf('Future<int> _doPush(');
      final j = fuente.indexOf(
          '_veredictoUltimoPush = VeredictoPush(fallos: _fallosUltimoPush)',
          i);
      expect(j, isNonNegative,
          reason: 'la publicación está dentro de _doPush');
    });
  });

  group('IMP-23(3) · el comentario se resuelve por el embudo',
      () {
    Future<void> sembrarComentario(Database db,
        {required String opUuid}) async {
      await db.insert('incidencias_local', {
        'id': 'inc-imp23',
        'tipo': 'sync',
        'descripcion': 'Padre del comentario',
        'creada_por': 'test',
        'creada_en': '2026-11-10T10:00:00-04:00',
        'sync_estado': 'synced',
        'sincronizada': 1,
      });
      await db.insert('incidencias_comentarios', {
        'id': 'com-imp23',
        'incidencia_id': 'inc-imp23',
        'texto': 'Comentario de prueba',
        'creado_por': 'test',
        'creado_en': '2026-11-10T10:05:00-04:00',
        'sync_estado': 'pending',
        'op_uuid': opUuid,
      });
      await db.insert('ops_queue', {
        'op_uuid': opUuid,
        'tipo': 'agregar_comentario_incidencia',
        'payload': jsonEncode({
          'id': 'com-imp23',
          'incidencia_id': 'inc-imp23',
          'texto': 'Comentario de prueba',
        }),
        'estado': 'enviada',
        'creada_ts': '2026-11-10T10:05:00-04:00',
      });
    }

    Future<String?> estadoComentario(Database db) async {
      final f = await db.query('incidencias_comentarios',
          columns: ['sync_estado'],
          where: 'id=?',
          whereArgs: ['com-imp23']);
      return f.single['sync_estado'] as String?;
    }

    Future<String?> estadoPadre(Database db) async {
      final f = await db.query('incidencias_local',
          columns: ['sync_estado'],
          where: 'id=?',
          whereArgs: ['inc-imp23']);
      return f.single['sync_estado'] as String?;
    }

    Future<void> barrer(String estado, dynamic resultado) async {
      await SyncEngine.instance.barridoConfirmacion(
        verificar: (uuids) async => {
          for (final u in uuids)
            u: (estado: estado, resultado: resultado, error: null),
        },
      );
    }

    test('barrido RECHAZADA: el comentario sale a error y el '
        'padre queda intacto', () async {
      final db = await _abrirDbVacia();
      await sembrarComentario(db, opUuid: 'op-imp23-rec');
      await barrer('rechazada', {'ok': false, 'error': 'spam'});
      expect(await estadoComentario(db), 'error',
          reason: 'antes de la 1.32 el comentario quedaba '
              'pending para siempre: nadie resolvía su fila');
      expect(await estadoPadre(db), 'synced',
          reason: 'la muerte de un comentario no ensucia la '
              'incidencia padre');
      final op = await db.query('ops_queue',
          columns: ['estado'],
          where: 'op_uuid=?',
          whereArgs: ['op-imp23-rec']);
      expect(op.single['estado'], 'rechazada');
      await db.close();
    });

    test('barrido NECESITA_REVISION: el comentario también '
        'se resuelve', () async {
      final db = await _abrirDbVacia();
      await sembrarComentario(db, opUuid: 'op-imp23-rev');
      await barrer('necesita_revision', {'error': 'a revisar'});
      expect(await estadoComentario(db), 'error');
      expect(await estadoPadre(db), 'synced');
      final op = await db.query('ops_queue',
          columns: ['estado'],
          where: 'op_uuid=?',
          whereArgs: ['op-imp23-rev']);
      expect(op.single['estado'], 'necesita_revision');
      await db.close();
    });

    test('muerte local de la op: el embudo resuelve el '
        'comentario', () async {
      final db = await _abrirDbVacia();
      await sembrarComentario(db, opUuid: 'op-imp23-muerte');
      final op = (await db.query('ops_queue',
              where: 'op_uuid=?', whereArgs: ['op-imp23-muerte']))
          .single;
      final resuelta = await SyncEngine.instance
          .resolverIncidenciaSiOpMuereLocalParaTest(op,
              revision: false, motivo: 'HTTP 422 de PostgREST');
      expect(resuelta, isTrue,
          reason: 'el embudo reconoce el tipo comentario');
      expect(await estadoComentario(db), 'error');
      expect(await estadoPadre(db), 'synced');
      await db.close();
    });
  });
}
