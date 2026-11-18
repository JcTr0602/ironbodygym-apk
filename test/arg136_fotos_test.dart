/// Corrección ARG136-09 (adjudicación Argón 1.36, H7
/// rebajado a MEDIA acotada): `FotosColaService.encolarFoto`
/// invalidaba las variantes 'pendiente' anteriores solo
/// cuando la foto colgaba de un cliente o un suplemento.
/// En el camino de INSCRIPCIÓN (ambos ids nulos) la foto
/// cuelga del op_uuid de la op de inscripción, y re-encolar
/// bajo el MISMO op_uuid (descartar y rehacer la foto)
/// dejaba las variantes descartadas 'pendiente' bajo el
/// mismo op_uuid, con colisión de claves TUS de
/// reanudación (tus_loc_<op_uuid>_<tipo>) entre la foto
/// descartada y la vigente. La corrección invalida
/// también ese caso: filas, archivos y claves TUS de las
/// variantes 'pendiente' del mismo op_uuid. Una fila
/// 'subiendo' es de un worker activo y no se toca.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('arg136_fotos_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  test('re-encolar la foto de una inscripción bajo el '
      'mismo op_uuid invalida la variante pendiente '
      'anterior (fila, archivo y claves TUS)', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('$dbPath$sufijo').delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;

    final fotosDir = Directory('${docs.path}/fotos');
    await fotosDir.create(recursive: true);
    // La variante descartada de la inscripción 'op-insc'.
    final vieja = File('${fotosDir.path}/descartada-original.jpg');
    await vieja.writeAsBytes([7, 7, 7]);
    final ahora = isoHabana(ahoraHabana());
    await db.insert('fotos_cola', {
      'op_uuid': 'op-insc',
      'tipo': 'original',
      'cliente_id': null,
      'suplemento_id': null,
      'ruta_local': vieja.path,
      'estado': 'pendiente',
      'intentos': 0,
      'creado_en': ahora,
      'actualizado_en': ahora,
    });
    // Sus claves TUS de reanudación.
    await LocalDb.instance
        .setMeta('tus_loc_op-insc_original', 'https://tus/abc');
    await LocalDb.instance.setMeta('tus_offset_op-insc_original', '123');

    // La foto nueva de la misma inscripción.
    final nueva = File('${docs.path}/nueva.jpg');
    await nueva.writeAsBytes([1, 2, 3, 4]);
    final n = await FotosColaService.instance.encolarFoto(
      opUuid: 'op-insc',
      rutaOriginal: nueva.path,
    );
    expect(n, greaterThanOrEqualTo(1));

    final filas = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-insc']);
    expect(filas, hasLength(n),
        reason: 'solo quedan las variantes de la foto '
            'vigente; la descartada salió de la cola');
    expect(filas.any((f) => f['ruta_local'] == vieja.path), isFalse);
    expect(await vieja.exists(), isFalse,
        reason: 'el archivo descartado se borra tras el '
            'commit (patrón B-21)');
    expect(await LocalDb.instance.getMeta('tus_loc_op-insc_original'),
        isNull);
    expect(
        await LocalDb.instance.getMeta('tus_offset_op-insc_original'),
        isNull);
  });
}
