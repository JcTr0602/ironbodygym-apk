/// Auditoría Definitiva · Capa 1 (parcial) — correcciones de la
/// oleada sobre Gestión 1.31 (base ef074cd). Cada grupo caza la
/// entrada numerada del consolidado
/// (cola-123/auditoria_definitiva/consolidado_capa1_parcial.md §E).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/diagnostico_espejo.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/foto_elegir.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    for (final nombre in ['ironbody.db', 'ironbody_$pid.db']) {
      try {
        await File(p.join(dir, nombre) + sufijo).delete();
      } catch (_) {}
    }
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Map<String, dynamic> _opPago({
  required int clienteId,
  required String? optimista,
  required String? anterior,
}) {
  return {
    'op_uuid': 'op-test',
    'tipo': 'pago_mensual',
    'payload': jsonEncode({
      'cliente_id': clienteId,
      if (optimista != null) 'pagado_hasta': optimista,
      'pagado_hasta_anterior': anterior,
    }),
  };
}

Future<String?> _pagadoHastaEspejo(int clienteId) async {
  final filas =
      await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
  if (filas.isEmpty) return null;
  final v = filas.first['pagado_hasta'];
  return v == null ? null : '$v';
}

void main() {
  group('A-3 · reversión del vencimiento con guarda de procedencia',
      () {
    test('revierte si el espejo aún lleva el valor de ESTA op',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          501,
          {'id': 501, 'nombre': 'A', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 501,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(501), '2026-11-10');
    });

    test('NO pisa el vencimiento de un pago posterior confirmado',
        () async {
      await _abrirDbVacia();
      // El espejo ya muestra el vencimiento del SEGUNDO pago
      // (confirmado); la op rechazada es la PRIMERA.
      await LocalDb.instance.upsertMirror(
          'clientes',
          502,
          {'id': 502, 'nombre': 'B', 'pagado_hasta': '2027-01-09'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 502,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(502), '2027-01-09',
          reason: 'la reversión tardía borró el pago válido');
    });

    test('anterior null limpia el vencimiento solo si es el suyo',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          503,
          {'id': 503, 'nombre': 'C', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 503, optimista: '2026-12-10', anterior: null));
      expect(await _pagadoHastaEspejo(503), isNull);
    });

    test('op sin vencimiento optimista en el payload: no toca nada',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          504,
          {'id': 504, 'nombre': 'D', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 504, optimista: null, anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(504), '2026-12-10');
    });
  });

  group('A-2 · el sello de éxito exige push limpio (estructural)',
      () {
    final sync = File('lib/sync.dart').readAsStringSync();

    test('los bumps del push ensucian el veredicto de la corrida',
        () {
      final i = sync.indexOf('Future<void> _bumpConReversion');
      expect(i, isNonNegative);
      final cuerpo = sync.substring(i, i + 400);
      expect(cuerpo, contains('_fallosUltimoPush++'),
          reason: 'un bump ya no cuenta como fallo del push: '
              'el ciclo volvería a sellar en verde con la '
              'subida rota');
      expect(sync, contains('pushOk = _ultimoPushLimpio;'),
          reason: 'run() volvió a dar el push por bueno solo '
              'porque _doPush no lanzó');
    });

    test('la rama de ciclo completo exige pushOk para sellar', () {
      expect(sync, contains('if (completo && pushOk)'),
          reason: 'la rama completo volvió a sellar sin mirar '
              'la subida');
      final j = sync.indexOf('} else if (completo) {');
      expect(j, isNonNegative,
          reason: 'falta la rama «bajada completa, subida '
              'sucia» que conserva el error');
      final rama = sync.substring(j, j + 700);
      expect(rama, contains("setMeta('last_sync_error', msgPushSucio)"));
      expect(rama, isNot(contains('_marcarOk()')),
          reason: 'la rama de subida sucia no puede sellar');
    });

    test('el gancho de éxito y la limpieza de error van '
        'condicionados', () {
      expect(
          sync,
          contains('if (errorCorrida == null) _avisarSyncExitoso();'),
          reason: 'run() volvió a avisar éxito con la corrida '
              'en error');
      expect(sync, contains('if (_ultimoPushLimpio) _avisarSyncExitoso();'),
          reason: 'push() volvió a avisar éxito sin push limpio');
      final k = sync.indexOf("if (_ultimoPushLimpio) {\n"
          "        await _db.setMeta('last_sync_error', '');");
      expect(k, isNonNegative,
          reason: 'push() volvió a limpiar last_sync_error '
              'incondicionalmente');
    });
  });

  group('A-4 · la bandera de comprobantes no queda pegada', () {
    test('tras la pausa QoS, el siguiente ciclo SÍ procesa',
        () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      // Comprobante pendiente con el archivo ausente: si un
      // ciclo llega a procesarlo, termina en 'error'
      // (archivo_ausente) sin tocar la red.
      await d.insert('comprobantes_pago', {
        'comprobante_uuid': 'comp-a4',
        'ruta_local': '/no/existe/comp-a4.jpg',
        'storage_path': 'comprobantes/comp-a4.jpg',
        'estado': 'pendiente',
        'creado_en': '2026-11-10T00:00:00-05:00',
        'intentos': 0,
        'proximo_intento_en': 0,
      });
      // Una op de cobro pendiente cierra la puerta QoS.
      await db.queueOp(
          opUuid: 'op-a4',
          tipo: 'pago_mensual',
          payload: {'cliente_id': 1});
      expect(await ComprobantesService.instance.procesar(), 0);
      var fila = await ComprobantesService.instance.filaDe('comp-a4');
      expect(fila?['estado'], 'pendiente',
          reason: 'la puerta QoS no debió tocar la fila');
      // La op se aplica y la puerta se abre. Con la bandera
      // pegada (el defecto), este procesar() devolvería 0 al
      // instante sin mirar la fila.
      await db.markOp('op-a4', 'aplicada');
      await ComprobantesService.instance.procesar();
      fila = await ComprobantesService.instance.filaDe('comp-a4');
      expect(fila?['estado'], 'error',
          reason: 'el ciclo tras la pausa QoS no corrió: '
              '_procesando quedó pegada');
    });
  });

  group('B-3 · SessionExpired no se traga en TUS (estructural)',
      () {
    final sync = File('lib/sync.dart').readAsStringSync();

    test('_tusCrear y _tusOffset relanzan SessionExpired', () {
      final i = sync.indexOf('Future<String?> _tusCrear');
      expect(i, isNonNegative);
      final crear = sync.substring(i, i + 2600);
      expect(crear, contains('on SessionExpired'),
          reason: '_tusCrear volvió a tragar la sesión vencida '
              'como «TUS no disponible»');
      final j = sync.indexOf('Future<int> _tusOffset');
      expect(j, isNonNegative);
      final offset = sync.substring(j, j + 900);
      expect(offset, contains('on SessionExpired'),
          reason: '_tusOffset volvió a disfrazar la sesión '
              'vencida de «no se pudo averiguar» (-2)');
      // La rama receptora existe: subirFotoCola la convierte en
      // reintentable, sin fallback a PUT con la sesión muerta.
      expect(sync, contains("error: 'sesión expirada'"));
    });
  });

  group('A-5 · migración v71 (columna generacion)', () {
    test('comprobantes_pago nace con generacion en limpio',
        () async {
      await _abrirDbVacia();
      final d = await LocalDb.instance.db;
      final cols = await d.rawQuery(
          "SELECT name FROM pragma_table_info('comprobantes_pago')");
      expect(cols.map((c) => c['name']), contains('generacion'));
      expect(LocalDb.versionActual, 71);
    });
  });

  group('B-18 · encolar asegura el nuevo antes de borrar el viejo',
      () {
    test('re-encolar con el origen ausente NO destruye el '
        'comprobante anterior', () async {
      await _abrirDbVacia();
      final tmp = await Directory.systemTemp.createTemp('comp_b18');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final origen = File('${tmp.path}/captura.jpg');
      await origen.writeAsBytes([1, 2, 3, 4, 5]);
      await ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-b18',
          rutaOrigen: origen.path,
          baseDir: tmp);
      var fila =
          await ComprobantesService.instance.filaDe('comp-b18');
      expect(fila?['estado'], 'pendiente');
      final rutaVieja = fila!['ruta_local'] as String;
      expect(await File(rutaVieja).exists(), isTrue);

      // Re-encolado cuyo origen ya no existe: la llamada falla
      // y el comprobante anterior queda intacto (con el orden
      // viejo, su archivo ya estaba borrado y la fila apuntaba
      // al vacío).
      await expectLater(
          ComprobantesService.instance.encolar(
              comprobanteUuid: 'comp-b18',
              rutaOrigen: '${tmp.path}/ya-no-esta.jpg',
              baseDir: tmp),
          throwsA(anything));
      fila = await ComprobantesService.instance.filaDe('comp-b18');
      expect(fila?['ruta_local'], rutaVieja);
      expect(fila?['estado'], 'pendiente');
      expect(await File(rutaVieja).readAsBytes(), [1, 2, 3, 4, 5]);
    });

    test('re-encolar válido sustituye el archivo', () async {
      await _abrirDbVacia();
      final tmp = await Directory.systemTemp.createTemp('comp_b18b');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final o1 = File('${tmp.path}/uno.jpg');
      await o1.writeAsBytes([9, 9]);
      await ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-b18b',
          rutaOrigen: o1.path,
          baseDir: tmp);
      final o2 = File('${tmp.path}/dos.jpg');
      await o2.writeAsBytes([7, 7, 7]);
      await ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-b18b',
          rutaOrigen: o2.path,
          baseDir: tmp);
      final fila =
          await ComprobantesService.instance.filaDe('comp-b18b');
      expect(
          await File(fila!['ruta_local'] as String).readAsBytes(),
          [7, 7, 7]);
    });
  });

  group('B-14 · foto de incidencia a documentos gestionados', () {
    late Directory docs;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docs = await Directory.systemTemp.createTemp('b14_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
    });

    test('copia con su extensión y devuelve la ruta gestionada',
        () async {
      final tmp = await Directory.systemTemp.createTemp('b14_tmp');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final origen = File('${tmp.path}/cache_picker.jpg');
      await origen.writeAsBytes([5, 6, 7, 8]);
      final ruta = await copiarFotoGestionada(
        subdirectorio: 'incidencias_fotos',
        nombreBase: 'foto-1',
        rutaOrigen: origen.path,
      );
      expect(ruta, '${docs.path}/incidencias_fotos/foto-1.jpg');
      expect(await File(ruta).readAsBytes(), [5, 6, 7, 8]);
      // La copia sobrevive a la purga de la caché temporal.
      await origen.delete();
      expect(await File(ruta).exists(), isTrue);
    });

    test('origen desaparecido o vacío: lanza y no crea copia',
        () async {
      await expectLater(
          copiarFotoGestionada(
            subdirectorio: 'incidencias_fotos',
            nombreBase: 'foto-x',
            rutaOrigen: '${docs.path}/no-existe.jpg',
          ),
          throwsA(isA<StateError>()));
      expect(
          await File('${docs.path}/incidencias_fotos/foto-x.jpg')
              .exists(),
          isFalse);
    });

    test('los dos sitios de detalle guardan la copia gestionada '
        '(estructural)', () {
      final detalle = File('lib/ui/incidencias/detalle_incidencia.dart')
          .readAsStringSync();
      expect(detalle, contains('copiarFotoGestionada'));
      expect(detalle.contains("'local_path': xfile.path"), isFalse,
          reason: 'la ruta temporal del selector volvió a '
              'guardarse como local_path');
      expect(detalle.contains("'local_path': fotoPath"), isFalse);
    });
  });

  group('B-13 · la foto en error conserva su única copia', () {
    late Directory docs;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docs = await Directory.systemTemp.createTemp('b13_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
    });

    test('limpiarHuerfanos purga la completada vieja y NO toca '
        'la fila en error ni su archivo', () async {
      await _abrirDbVacia();
      final db = await LocalDb.instance.db;
      final fotosDir = Directory('${docs.path}/fotos');
      await fotosDir.create(recursive: true);
      final hace8 = isoHabana(
          ahoraHabana().subtract(const Duration(days: 8)));
      final ahora = isoHabana(ahoraHabana());
      Future<void> sembrar(String uuid, String estado) async {
        final f = File('${fotosDir.path}/$uuid.jpg');
        await f.writeAsBytes([1, 2, 3]);
        await db.insert('fotos_cola', {
          'op_uuid': uuid,
          'tipo': 'display',
          'cliente_id': 5,
          'ruta_local': f.path,
          'estado': estado,
          'intentos': estado == 'error' ? 5 : 1,
          'creado_en': hace8,
          'actualizado_en': hace8,
        });
      }

      await sembrar('b13-error', 'error');
      await sembrar('b13-ok', 'completada');
      // Recién creada en error: tampoco se toca, obviamente.
      final fNueva = File('${fotosDir.path}/b13-nueva.jpg');
      await fNueva.writeAsBytes([4]);
      await db.insert('fotos_cola', {
        'op_uuid': 'b13-nueva',
        'tipo': 'display',
        'cliente_id': 5,
        'ruta_local': fNueva.path,
        'estado': 'error',
        'intentos': 5,
        'creado_en': ahora,
        'actualizado_en': ahora,
      });

      await FotosColaService.instance.limpiarHuerfanos();

      final quedan = await db.query('fotos_cola',
          columns: ['op_uuid'], orderBy: 'op_uuid ASC');
      expect(quedan.map((r) => r['op_uuid']).toList(),
          ['b13-error', 'b13-nueva'],
          reason: 'la completada vieja sale; las de error quedan '
              'con su fila');
      expect(
          await File('${fotosDir.path}/b13-error.jpg').exists(),
          isTrue,
          reason: 'el archivo de la foto en error es su única '
              'copia: no puede borrarse en silencio');
      expect(await File('${fotosDir.path}/b13-ok.jpg').exists(),
          isFalse,
          reason: 'la completada sí se purga (está en Storage)');
    });

    test('la reactivación desde la Cola cubre el estado error '
        '(estructural, base 1.30)', () {
      final cola = File('lib/ui/cola.dart').readAsStringSync();
      expect(cola, contains('reintentarTodasFotosCola'));
      expect(cola, contains("estado IN ('pendiente', 'error')"),
          reason: 'el reintento masivo dejó de cubrir las fotos '
              'en error');
    });
  });

  group('A-6 · autocura del espejo corrupto', () {
    test('la causa probable nombra la corrupción primero', () {
      final conCorrupcion = causaProbableEspejoVacio(
          haySyncOk: true, opsPendientes: 0, filasCorruptas: 3);
      expect(conCorrupcion, contains('dañados'));
      expect(conCorrupcion, contains('3'));
      // Sin corrupción, las ramas de siempre quedan intactas.
      final sinSync = causaProbableEspejoVacio(
          haySyncOk: false, opsPendientes: 0);
      expect(sinSync, contains('no registra ninguna'));
    });

    test('el consumidor traduce mirror_corruptas_* en '
        'forzar_redescarga_* solo en tablas del pull', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      await db.setMeta('mirror_corruptas_clientes', '2');
      await db.setMeta('mirror_corruptas_pagos', '0');
      await db.setMeta('mirror_corruptas_tabla_inventada', '5');
      await SyncEngine.instance
          .marcarRedescargaPorCorruptasParaTest();
      expect(await db.getMeta('forzar_redescarga_clientes'), '1',
          reason: 'la tabla corrupta no quedó marcada para '
              're-bajarse: la corrupción seguiría eterna');
      expect(await db.getMeta('forzar_redescarga_pagos'), isNull,
          reason: 'una señal en 0 no debe forzar nada');
      expect(
          await db.getMeta('forzar_redescarga_tabla_inventada'),
          isNull,
          reason: 'una clave ajena no crea banderas huérfanas');
    });

    test('evaluarEspejoVacio diagnostica corrupción cuando el '
        'espejo «vacío» son filas dañadas', () async {
      await _abrirDbVacia();
      final d = await LocalDb.instance.db;
      // La columna data exige JSON válido (CHECK de esquema):
      // la forma «corrupta» alcanzable es un JSON que no es el
      // mapa esperado — para todo lector del espejo esa fila
      // no existe (es el criterio de conteoMirrorLegible).
      await d.insert('clientes', {
        'id': 77,
        'data': '[1,2,3]',
        'sync_seq': 9,
      });
      await LocalDb.instance
          .setMeta('clientes_previos_buenos', '4');
      await LocalDb.instance.setMeta(
          'last_pull_ok', isoHabana(ahoraHabana()));
      final diag = await evaluarEspejoVacio();
      expect(diag, isNotNull);
      expect(diag!.causaProbable, contains('dañados'),
          reason: 'el W1 volvió a culpar a la bajada de una '
              'corrupción local');
    });
  });

  group('B-24 · la purga de sesión alcanza a las solo-dueño', () {
    late Directory docs;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docs = await Directory.systemTemp.createTemp('b24_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
    });

    test('borra las filas confirmadas de las prohibidas, '
        'conserva las locales y resetea su watermark', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      // Congelaciones: una confirmada del dueño anterior
      // (con motivo sensible) y una local sin confirmar.
      await d.insert('cliente_congelaciones', {
        'id': 'cong-confirmada',
        'data': '{"motivo":"dato de salud"}',
        'sync_seq': 42,
      });
      await d.insert('cliente_congelaciones', {
        'id': 'cong-local',
        'data': '{"motivo":"aun no sube"}',
        'sync_seq': 0,
      });
      await d.insert('servicio_lotes', {
        'id': 7,
        'data': '{"dosis":30}',
        'sync_seq': 9,
      });
      await db.setMeta('wm_cliente_congelaciones', '42');
      await db.setMeta('wm_servicio_lotes', '9');

      await db.purgarDatosSensibles();

      final congs = await d.query('cliente_congelaciones',
          columns: ['id']);
      expect(congs.map((r) => r['id']).toList(), ['cong-local'],
          reason: 'la congelación confirmada (con el motivo) '
              'sobrevivió al cierre de sesión');
      expect(await d.query('servicio_lotes'), isEmpty,
          reason: 'los lotes confirmados sobrevivieron');
      expect(await db.getMeta('wm_cliente_congelaciones'), '0');
      expect(await db.getMeta('wm_servicio_lotes'), '0');
    });
  });

  group('B-25 · el cursor de borrados no hereda el global', () {
    test('sin meta wm_borrados, el cursor es 0 aunque el '
        'global sea alto; con meta, manda la meta', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      await db.setWatermark(9999);
      expect(await db.getWatermarkTabla('borrados'), 0,
          reason: 'el cursor de tombstones heredó el global: '
              'los borrados viejos no se re-aplicarían nunca');
      await db.setWatermarkTabla('borrados', 123);
      expect(await db.getWatermarkTabla('borrados'), 123);
      // Las demás tablas con herencia siguen heredando.
      expect(await db.getWatermarkTabla('clientes'), 9999);
    });

    test('la migración v27 escribe 0 en vez de borrar '
        '(estructural)', () {
      final localdb = File('lib/localdb.dart').readAsStringSync();
      final i = localdb.indexOf('if (oldV < 27)');
      expect(i, isNonNegative);
      final bloque = localdb.substring(i, i + 700);
      expect(bloque, contains("'wm_borrados', 'v': '0'"),
          reason: 'la migración volvió a borrar la meta: el '
              'cursor caería al global heredado');
      expect(bloque.contains("delete('meta'"), isFalse);
    });
  });

  group('B-11/B-12/C-6 · el FGS cuenta la tubería completa', () {
    test('contarCompletadas solo cuenta las que llegaron',
        () async {
      await _abrirDbVacia();
      final d = await LocalDb.instance.db;
      final ahora = isoHabana(ahoraHabana());
      for (final (uuid, estado) in [
        ('fgs-c1', 'completada'),
        ('fgs-c2', 'completada'),
        ('fgs-p1', 'pendiente'),
        ('fgs-b1', 'pendiente'), // en backoff: NO es progreso
        ('fgs-e1', 'error'),
      ]) {
        await d.insert('fotos_cola', {
          'op_uuid': uuid,
          'tipo': 'display',
          'cliente_id': 5,
          'ruta_local': '/tmp/$uuid.jpg',
          'estado': estado,
          'intentos': 0,
          'creado_en': ahora,
          'actualizado_en': ahora,
        });
      }
      expect(await FotosColaService.instance.contarCompletadas(),
          2);
    });

    test('arranque, progreso, parada y sin-sesión miran las '
        'cuentas nuevas (estructural)', () {
      final fgs =
          File('lib/fotos_foreground.dart').readAsStringSync();
      // B-12: comprobantes y fotos de incidencias en el FGS.
      expect(fgs, contains('contarComprobantesSinSubir'));
      expect(fgs, contains('contarFotosIncidenciasPendientes'));
      // B-11: progreso por delta de completadas.
      expect(fgs, contains('contarCompletadas'));
      expect(fgs.contains('reclamablesAntes - reclamablesDespues'),
          isFalse,
          reason: 'el progreso volvió a medirse por reclamables: '
              'el backoff «progresa» en falso');
      // C-6: sin sesión persistente, el servicio se detiene.
      expect(fgs, contains('SyncMotivoNoCorrio.sinSesion'));
      expect(fgs, contains('_ticksSinSesion'));
    });
  });
}
