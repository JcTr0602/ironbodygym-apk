/// 1.34 · fotos-variantes: las variantes ligeras (thumb/display)
/// nunca nacían en campo. Causa raíz (adjudicación 2026-11-13 e
/// informe `cola-123/gestion/134_fotos_informe.md`): los destinos
/// temporales de compresión se llamaban `...webp.tmp` y el
/// validador de flutter_image_compress exige que el nombre destino
/// TERMINE en `.webp` → ArgumentError en Dart antes de comprimir,
/// tragado por el catch de encolarFoto (solo debugPrint) → caía
/// siempre la copia JPG de la original (variantes=1, 92/92 en
/// bitácoras reales).
///
/// Estos tests corren la implementación REAL del canal del plugin
/// (FlutterImageCompressCommon, con su validador) sobre un canal
/// nativo simulado que escribe el archivo destino como haría el
/// codificador de Android:
///
///  1. Causa raíz: el nombre viejo muere en el validador; el nuevo
///     (`.tmp.webp`) atraviesa y produce archivo.
///  2. Generación: encolarFoto encola las 3 variantes WebP, sin
///     temporales sueltos y con foto_local en la display.
///     (En la base este test da 1 fila `.jpg`: el A/B del arreglo.)
///  3. Registro del fallo: un null del plugin y una excepción por
///     variante quedan asentados en la bitácora (variante_fallo)
///     con tipo y causa, y el resto de variantes sigue su curso.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_image_compress_common/flutter_image_compress_common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/app_log.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inyección de fallos del «nativo» simulado: si el destino
/// contiene el fragmento, esa variante devuelve null o lanza.
String? _falloNullEn;
String? _falloErrorEn;

Future<Database> _preparar() async {
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
  return LocalDb.instance.db;
}

/// Espera activa a que la bitácora deje ver el asiento buscado.
Future<List<Map<String, Object?>>> _esperarFallosVariante(
    Database db, int n) async {
  for (var i = 0; i < 40; i++) {
    // eventosRecientes fuerza el ciclo de volcado de AppLog.
    await AppLog.eventosRecientes(limite: 5);
    final filas = await db.query('app_log',
        where: 'modulo = ? AND evento = ?',
        whereArgs: ['fotos', 'variante_fallo']);
    if (filas.length >= n) return filas;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return db.query('app_log',
      where: 'modulo = ? AND evento = ?',
      whereArgs: ['fotos', 'variante_fallo']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('fotos134_docs');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => docs.path);
    // La plataforma real del plugin (con su validador); el canal
    // nativo se simula debajo. En Android la comprobación de
    // plataforma para WebP pasa sola; en el host Linux del test
    // hay que saltarla (no es el objeto de estos tests).
    FlutterImageCompressPlatform.instance = FlutterImageCompressCommon();
    FlutterImageCompress.validator.ignoreCheckSupportPlatform = true;
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_image_compress'), (call) async {
      if (call.method != 'compressWithFileAndGetFile') return null;
      final args = call.arguments as List;
      final fuente = args[0] as String;
      final destino = args[4] as String;
      if (_falloErrorEn != null && destino.contains(_falloErrorEn!)) {
        throw PlatformException(
            code: 'unknown', message: 'compress failed (simulado)');
      }
      if (_falloNullEn != null && destino.contains(_falloNullEn!)) {
        return null;
      }
      final f = File(destino);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(await File(fuente).readAsBytes());
      return destino;
    });
  });

  setUp(() {
    _falloNullEn = null;
    _falloErrorEn = null;
  });

  Future<File> fotoOrigen() async {
    final origen = File('${docs.path}/origen.jpg');
    await origen.writeAsBytes(List.generate(64, (i) => i % 251));
    return origen;
  }

  test('causa raíz: el destino .webp.tmp muere en el validador del '
      'plugin y el .tmp.webp produce archivo', () async {
    final origen = await fotoOrigen();
    // El validador hace assert(false, msg) y DESPUÉS throw
    // ArgumentError: con asserts activos (test/debug) salta el
    // AssertionError; en release salta el ArgumentError. Ambos son
    // el mismo lanzamiento antes del codificador.
    await expectLater(
      FlutterImageCompress.compressAndGetFile(
        origen.path,
        '${docs.path}/x-thumb.webp.tmp',
        minWidth: 200,
        minHeight: 200,
        quality: 65,
        format: CompressFormat.webp,
      ),
      throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
      reason: 'el nombre viejo no termina en .webp: el validador '
          'del plugin lanza antes de llegar al codificador',
    );
    final destino = '${docs.path}/x-thumb.tmp.webp';
    final res = await FlutterImageCompress.compressAndGetFile(
      origen.path,
      destino,
      minWidth: 200,
      minHeight: 200,
      quality: 65,
      format: CompressFormat.webp,
    );
    expect(res, isNotNull);
    expect(res!.path, destino);
    expect(await File(destino).exists(), isTrue);
  });

  test('generación: encolarFoto encola thumb+display+original WebP',
      () async {
    final db = await _preparar();
    await db.insert('clientes', {
      'id': 5,
      'data': jsonEncode({'nombre': 'Cinco'}),
      'sync_seq': 1,
    });
    final origen = await fotoOrigen();
    final n = await FotosColaService.instance.encolarFoto(
        opUuid: 'op-134', clienteId: 5, rutaOriginal: origen.path);
    expect(n, 3, reason: 'las tres variantes nacen');
    final filas = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-134']);
    expect(filas, hasLength(3));
    final porTipo = {for (final f in filas) f['tipo'] as String: f};
    expect(porTipo.keys, containsAll(['thumb', 'display', 'original']));
    for (final tipo in ['thumb', 'display', 'original']) {
      final ruta = porTipo[tipo]!['ruta_local'] as String;
      expect(ruta, endsWith('-$tipo.webp'),
          reason: 'la variante $tipo es WebP de verdad');
      expect(await File(ruta).exists(), isTrue);
      expect(porTipo[tipo]!['tamano_bytes'], isNotNull);
      expect((porTipo[tipo]!['tamano_bytes'] as int), greaterThan(0));
    }
    // Sin temporales sueltos en el directorio de fotos.
    final fotosDir = Directory('${docs.path}/fotos');
    final nombres =
        await fotosDir.list().map((e) => p.basename(e.path)).toList();
    expect(nombres.where((x) => x.contains('.tmp')), isEmpty,
        reason: 'los temporales se renombran, no quedan: $nombres');
    // foto_local apunta a la display (pintura ligera en listas).
    final filasCli = await db.query('clientes',
        columns: ['data'], where: 'id = ?', whereArgs: [5]);
    final data = jsonDecode(filasCli.first['data'] as String)
        as Map<String, dynamic>;
    expect(data['foto_local'], endsWith('-display.webp'));
  });

  test('registro: el null de una variante queda en bitácora con su '
      'causa y las demás variantes siguen', () async {
    final db = await _preparar();
    _falloNullEn = '-display.';
    final origen = await fotoOrigen();
    final n = await FotosColaService.instance.encolarFoto(
        opUuid: 'op-134-null', clienteId: null,
        rutaOriginal: origen.path);
    expect(n, 2, reason: 'thumb y original nacen; display, no');
    final filas = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-134-null']);
    expect(filas.map((f) => f['tipo']), containsAll(['thumb', 'original']));
    final fallos = await _esperarFallosVariante(db, 1);
    expect(fallos, isNotEmpty,
        reason: 'el fallo ya no es silencioso: queda asiento');
    final detalle = fallos.map((f) => '${f['detalle']}').join(' | ');
    expect(detalle, contains('tipo=display'));
    expect(detalle, contains('causa=null'));
  });

  test('registro: la excepción de una variante queda en bitácora '
      'con su causa y no arrastra a las demás', () async {
    final db = await _preparar();
    _falloErrorEn = '-thumb.';
    final origen = await fotoOrigen();
    final n = await FotosColaService.instance.encolarFoto(
        opUuid: 'op-134-exc', clienteId: null,
        rutaOriginal: origen.path);
    expect(n, 2,
        reason: 'display y original nacen aunque thumb lance: '
            'antes la excepción de la primera abortaba las tres');
    final filas = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-134-exc']);
    expect(
        filas.map((f) => f['tipo']), containsAll(['display', 'original']));
    final fallos = await _esperarFallosVariante(db, 1);
    expect(fallos, isNotEmpty);
    final detalle = fallos.map((f) => '${f['detalle']}').join(' | ');
    expect(detalle, contains('tipo=thumb'));
    expect(detalle, contains('causa=excepcion'));
  });
}
