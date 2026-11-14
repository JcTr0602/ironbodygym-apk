/// 1.34 · comprobantes: el comprobante WebP nunca nacía. Causa
/// raíz (misma que las variantes de fotos, informe
/// `cola-123/gestion/134_fotos_informe.md`): el destino
/// temporal de compresión se llamaba `<uuid>.webp.<rand>.tmp`
/// y el validador de flutter_image_compress exige que el nombre
/// destino TERMINE en `.webp` → ArgumentError en Dart antes de
/// comprimir, tragado por el catch de encolar (solo debugPrint;
/// con null del plugin, ni eso) → todo comprobante caía a la
/// copia JPG del original, sin una línea en la bitácora.
///
/// Estos tests corren la implementación REAL del canal del
/// plugin (FlutterImageCompressCommon, con su validador) sobre
/// un canal nativo simulado que escribe el archivo destino como
/// haría el codificador de Android:
///
///  1. Causa raíz: el nombre viejo muere en el validador; el
///     nuevo (`<uuid>.<rand>.tmp.webp`) atraviesa y produce
///     archivo.
///  2. Generación: encolar guarda el comprobante como WebP de
///     verdad (fila con storage_path .webp, archivo .webp, sin
///     temporales sueltos). (En la base da `.jpg`: el A/B.)
///  3. Registro del fallo: un null del plugin y una excepción
///     quedan asentados en la bitácora (compresion_fallo) con
///     su causa, y el comprobante cae al fallback JPG EXACTO de
///     siempre (ninguna imagen se pierde).
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_image_compress_common/flutter_image_compress_common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/app_log.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inyección de fallos del «nativo» simulado: si el destino
/// contiene el fragmento, la compresión devuelve null o lanza.
String? _falloNullEn;
String? _falloErrorEn;

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

/// Espera activa a que la bitácora deje ver el asiento buscado.
Future<List<Map<String, Object?>>> _esperarFallosCompresion(
    int n) async {
  final db = await LocalDb.instance.db;
  for (var i = 0; i < 40; i++) {
    // eventosRecientes fuerza el ciclo de volcado de AppLog.
    await AppLog.eventosRecientes(limite: 5);
    final filas = await db.query('app_log',
        where: 'modulo = ? AND evento = ?',
        whereArgs: ['comprobantes', 'compresion_fallo']);
    if (filas.length >= n) return filas;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return db.query('app_log',
      where: 'modulo = ? AND evento = ?',
      whereArgs: ['comprobantes', 'compresion_fallo']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('comp134_docs');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
    final origen = File('${docs.path}/captura.jpg');
    await origen.writeAsBytes(List.generate(64, (i) => i % 251));
    return origen;
  }

  test('causa raíz: el destino .webp.<rand>.tmp muere en el '
      'validador del plugin y el .tmp.webp produce archivo',
      () async {
    final origen = await fotoOrigen();
    // El validador hace assert(false, msg) y DESPUÉS throw
    // ArgumentError: con asserts activos (test/debug) salta el
    // AssertionError; en release salta el ArgumentError. Ambos
    // son el mismo lanzamiento antes del codificador.
    await expectLater(
      FlutterImageCompress.compressAndGetFile(
        origen.path,
        '${docs.path}/uuid-x.webp.ab12cd34.tmp',
        minWidth: 1600,
        minHeight: 1600,
        quality: 80,
        format: CompressFormat.webp,
      ),
      throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
      reason: 'el nombre viejo no termina en .webp: el validador '
          'del plugin lanza antes de llegar al codificador',
    );
    final destino = '${docs.path}/uuid-x.ab12cd34.tmp.webp';
    final res = await FlutterImageCompress.compressAndGetFile(
      origen.path,
      destino,
      minWidth: 1600,
      minHeight: 1600,
      quality: 80,
      format: CompressFormat.webp,
    );
    expect(res, isNotNull);
    expect(res!.path, destino);
    expect(await File(destino).exists(), isTrue);
  });

  test('generación: encolar guarda el comprobante como WebP',
      () async {
    await _preparar();
    final base = await Directory.systemTemp.createTemp('comp134_g');
    addTearDown(() async {
      try {
        await base.delete(recursive: true);
      } catch (_) {}
    });
    final origen = await fotoOrigen();
    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-134-webp',
        rutaOrigen: origen.path,
        baseDir: base);
    final fila = await ComprobantesService.instance
        .filaDe('uuid-134-webp');
    expect(fila, isNotNull);
    expect(fila!['estado'], 'pendiente');
    expect(fila['storage_path'], 'comprobantes/uuid-134-webp.webp',
        reason: 'el WebP nace: la ruta del bucket es la diseñada');
    final guardado = File(fila['ruta_local'] as String);
    expect(guardado.path, endsWith('uuid-134-webp.webp'));
    expect(await guardado.exists(), isTrue);
    expect(await guardado.length(), greaterThan(0));
    // Sin temporales sueltos en el directorio de comprobantes.
    final dirComp = Directory('${base.path}/comprobantes');
    final nombres =
        await dirComp.list().map((e) => p.basename(e.path)).toList();
    expect(nombres, ['uuid-134-webp.webp'],
        reason: 'solo el final; los staging se renombran: $nombres');
  });

  test('registro: el null del plugin queda en bitácora y el '
      'comprobante cae al JPG de siempre', () async {
    await _preparar();
    _falloNullEn = '.tmp.webp';
    final base = await Directory.systemTemp.createTemp('comp134_n');
    addTearDown(() async {
      try {
        await base.delete(recursive: true);
      } catch (_) {}
    });
    final origen = await fotoOrigen();
    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-134-null',
        rutaOrigen: origen.path,
        baseDir: base);
    final fila = await ComprobantesService.instance
        .filaDe('uuid-134-null');
    expect(fila, isNotNull);
    expect(fila!['storage_path'], 'comprobantes/uuid-134-null.jpg',
        reason: 'el fallback es el exacto: copia JPG del original');
    final guardado = File(fila['ruta_local'] as String);
    expect(await guardado.readAsBytes(),
        await origen.readAsBytes());
    final fallos = await _esperarFallosCompresion(1);
    expect(fallos, isNotEmpty,
        reason: 'el fallo ya no es silencioso: queda asiento');
    final detalle = fallos.map((f) => '${f['detalle']}').join(' | ');
    expect(detalle, contains('uuid=uuid-134-null'));
    expect(detalle, contains('causa=null'));
  });

  test('registro: la excepción del plugin queda en bitácora y '
      'el comprobante cae al JPG de siempre', () async {
    await _preparar();
    _falloErrorEn = '.tmp.webp';
    final base = await Directory.systemTemp.createTemp('comp134_e');
    addTearDown(() async {
      try {
        await base.delete(recursive: true);
      } catch (_) {}
    });
    final origen = await fotoOrigen();
    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-134-exc',
        rutaOrigen: origen.path,
        baseDir: base);
    final fila = await ComprobantesService.instance
        .filaDe('uuid-134-exc');
    expect(fila, isNotNull);
    expect(fila!['storage_path'], 'comprobantes/uuid-134-exc.jpg');
    final guardado = File(fila['ruta_local'] as String);
    expect(await guardado.readAsBytes(),
        await origen.readAsBytes());
    final fallos = await _esperarFallosCompresion(1);
    expect(fallos, isNotEmpty);
    final detalle = fallos.map((f) => '${f['detalle']}').join(' | ');
    expect(detalle, contains('uuid=uuid-134-exc'));
    expect(detalle, contains('causa=excepcion'));
  });
}
