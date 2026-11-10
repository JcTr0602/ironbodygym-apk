/// Auditoría Definitiva · B-21 (el rollback de encolarFoto no
/// puede restaurar filas cuyos archivos ya se borraron).
///
/// encolarFoto invalida las variantes pendientes de la foto
/// anterior dentro de la transacción que inserta las nuevas.
/// Si algo posterior falla, filas y claves TUS revierten con
/// el rollback — el sistema de archivos, no: con el defecto,
/// la fila restaurada apuntaba a un archivo ya borrado y la
/// foto anterior se perdía sin haber subido nunca.
///
/// El fallo se fuerza con un trigger que aborta el insert de
/// la foto nueva: la transacción entera revierte y se
/// comprueba que la fila vieja Y SU ARCHIVO siguen intactos.
/// Y el camino feliz sigue invalidando (fila y archivo fuera).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('b21_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('fotos_cola');
    await db.delete('clientes');
    await db.delete('meta');
  });

  Future<File> sembrarFotoVieja() async {
    final db = await LocalDb.instance.db;
    await db.insert('clientes', {
      'id': 5,
      'data': jsonEncode({'nombre': 'Cinco', 'foto_uuid': 'op-vieja'}),
      'sync_seq': 1,
    });
    final fotosDir = Directory('${docs.path}/fotos');
    await fotosDir.create(recursive: true);
    final vieja = File('${fotosDir.path}/vieja-display.webp');
    await vieja.writeAsBytes([9, 9, 9]);
    final ahora = isoHabana(ahoraHabana());
    await db.insert('fotos_cola', {
      'op_uuid': 'op-vieja',
      'tipo': 'display',
      'cliente_id': 5,
      'ruta_local': vieja.path,
      'estado': 'pendiente',
      'intentos': 0,
      'creado_en': ahora,
      'actualizado_en': ahora,
    });
    await LocalDb.instance
        .setMeta('tus_loc_op-vieja_display', 'https://x/y');
    return vieja;
  }

  test('fallo tras invalidar: el rollback deja la foto '
      'anterior con fila y archivo intactos', () async {
    final db = await LocalDb.instance.db;
    final vieja = await sembrarFotoVieja();
    // El insert de la foto nueva aborta dentro de la
    // transacción: todo revierte.
    await db.execute('''
      CREATE TRIGGER test_b21_falla BEFORE INSERT ON fotos_cola
      WHEN NEW.op_uuid = 'op-falla'
      BEGIN SELECT RAISE(ABORT, 'fallo forzado b21'); END
    ''');
    final origen = File('${docs.path}/nueva.jpg');
    await origen.writeAsBytes([1, 2, 3]);

    await expectLater(
        FotosColaService.instance.encolarFoto(
            opUuid: 'op-falla',
            clienteId: 5,
            rutaOriginal: origen.path),
        throwsA(anything));

    final filas = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-vieja']);
    expect(filas, hasLength(1),
        reason: 'el rollback no restauró la fila vieja');
    expect(await vieja.exists(), isTrue,
        reason: 'el archivo de la foto anterior se borró '
            'dentro de la transacción: el rollback la restauró '
            'apuntando al vacío');
    expect(await LocalDb.instance.getMeta('tus_loc_op-vieja_display'),
        'https://x/y',
        reason: 'la clave TUS también revierte con la fila');
  });

  test('camino feliz: la invalidación sigue borrando fila y '
      'archivo tras el commit', () async {
    final db = await LocalDb.instance.db;
    final vieja = await sembrarFotoVieja();
    final origen = File('${docs.path}/nueva2.jpg');
    await origen.writeAsBytes([4, 5, 6]);

    await FotosColaService.instance.encolarFoto(
        opUuid: 'op-nueva', clienteId: 5, rutaOriginal: origen.path);

    expect(
        await db.query('fotos_cola',
            where: 'op_uuid = ?', whereArgs: ['op-vieja']),
        isEmpty);
    expect(await vieja.exists(), isFalse,
        reason: 'tras el commit, el archivo invalidado sí se '
            'borra');
    expect(
        await db.query('fotos_cola',
            where: 'op_uuid = ?', whereArgs: ['op-nueva']),
        isNotEmpty);
  });
}
