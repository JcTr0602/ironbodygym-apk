/// F1 (1.20): comprobante del pago por transferencia — la
/// migración v55 crea la tabla local, encolar guarda la foto
/// y la fila pendiente, y descartar limpia ambas cosas (el
/// cobro deshecho no deja comprobante).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/localdb.dart';
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

void main() {
  test('ruta de bucket determinista por uuid y extensión', () {
    expect(rutaStorageComprobante('abc', 'webp'),
        'comprobantes/abc.webp');
    expect(rutaStorageComprobante('abc', 'jpg'),
        'comprobantes/abc.jpg');
  });

  test('v55: la tabla de comprobantes existe en limpio',
      () async {
    await _preparar();
    final d = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 61);
    final tablas = await d.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='comprobantes_pago'");
    expect(tablas, hasLength(1));
  });

  test('encolar guarda archivo y fila pendiente; descartar '
      'limpia ambos', () async {
    await _preparar();
    final tmp = await Directory.systemTemp.createTemp('comp_f1');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    // Origen «foto»: bytes cualquiera; sin plugin de
    // compresión en el entorno de test, encolar cae a la
    // copia .jpg (el camino de respaldo de producción).
    final origen = File('${tmp.path}/captura.jpg');
    await origen.writeAsBytes([1, 2, 3, 4, 5]);

    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-f1-test',
        rutaOrigen: origen.path,
        baseDir: tmp);

    final fila = await ComprobantesService.instance
        .filaDe('uuid-f1-test');
    expect(fila, isNotNull);
    expect(fila!['estado'], 'pendiente');
    expect(fila['storage_path'],
        'comprobantes/uuid-f1-test.jpg');
    final guardado = File(fila['ruta_local'] as String);
    expect(await guardado.exists(), isTrue);
    expect(await guardado.readAsBytes(), [1, 2, 3, 4, 5]);

    await ComprobantesService.instance.descartar('uuid-f1-test');
    expect(
        await ComprobantesService.instance.filaDe('uuid-f1-test'),
        isNull);
    expect(await guardado.exists(), isFalse);
  });
}
