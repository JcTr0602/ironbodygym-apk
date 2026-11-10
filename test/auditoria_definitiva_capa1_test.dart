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
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
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
}
