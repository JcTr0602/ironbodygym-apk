/// H-09 (1.20): el device_tag de subida es único por
/// instalación (`apk-<uuid>` persistido en la meta
/// `device_tag_id`), no la constante 'apk-android' de antes.
/// Ajustes del panel: única fuente para los dos caminos de
/// subida y prueba de generación/persistencia sin meta previa.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    try {
      await File('$dbPath-wal').delete();
    } catch (_) {}
    try {
      await File('$dbPath-shm').delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('sin meta previa: genera, persiste y reutiliza el tag',
      () async {
    expect(await LocalDb.instance.getMeta('device_tag_id'), isNull,
        reason: 'la instalación nace sin etiqueta');
    final tag1 = await SyncEngine.instance.deviceTag();
    expect(tag1, startsWith('apk-'));
    expect(tag1.length, 'apk-'.length + 36,
        reason: 'uuid v4 completo tras el prefijo');
    expect(tag1, isNot('apk-android'));

    final persistido =
        await LocalDb.instance.getMeta('device_tag_id');
    expect(persistido, isNotNull);
    expect(tag1, 'apk-$persistido',
        reason: 'el tag es la meta persistida con prefijo');

    final tag2 = await SyncEngine.instance.deviceTag();
    expect(tag2, tag1, reason: 'la segunda llamada reutiliza');
  });
}
