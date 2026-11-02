/// 1.21 (Argón 121B): bitácora utilizable — topes de peso por
/// fila (BT-01), agrupación de tormentas en dos etapas (BT-02),
/// reinicio que no resucita el buffer (BT-03), poda por peso
/// medida sobre la tabla (BT-04) y exportación por delta con
/// marca confirmada por el llamador.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/app_log.dart';
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

/// Espera a que el flush asíncrono deje visible la fila buscada.
Future<Map<String, dynamic>?> _esperarFila(String evento) async {
  for (var i = 0; i < 30; i++) {
    final filas = await AppLog.eventosRecientes(limite: 200);
    for (final f in filas) {
      if (f['evento'] == evento) return f;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => Directory.systemTemp.path);
  });

  test('v58: app_log tiene firma, repeticiones y primer_ts',
      () async {
    await _preparar();
    expect(LocalDb.versionActual, 58);
    final d = await LocalDb.instance.db;
    final cols = await d.rawQuery('PRAGMA table_info(app_log)');
    final nombres = cols.map((c) => '${c['name']}').toSet();
    expect(nombres,
        containsAll(['firma', 'repeticiones', 'primer_ts']));
  });

  test('BT-01: detalle cortado a 2000 y migas a las últimas 10',
      () async {
    await _preparar();
    for (var i = 0; i < 15; i++) {
      AppLog.breadcrumb('paso numero $i');
    }
    AppLog.error('test', 'fallo_topes', d: 'x' * 5000);
    final fila = await _esperarFila('fallo_topes');
    expect(fila, isNotNull);
    expect((fila!['detalle'] as String).length, lessThanOrEqualTo(2010));
    final ctx = jsonDecode(fila['contexto'] as String)
        as Map<String, dynamic>;
    final migas = ctx['breadcrumbs'] as List;
    expect(migas.length, 10,
        reason: 'solo las últimas 10 migas acompañan al error');
  });

  test('BT-01: el stack lleva tope defensivo de 4 KB', () async {
    await _preparar();
    final stack = StackTrace.fromString(List.generate(
            20, (i) => 'linea$i ${'y' * 600}')
        .join('\n'));
    AppLog.error('test', 'fallo_stack', d: 'con stack', stack: stack);
    final fila = await _esperarFila('fallo_stack');
    expect(fila, isNotNull);
    expect((fila!['stack'] as String).length,
        lessThanOrEqualTo(4106));
  });

  test('BT-02: la tormenta de 5 errores es UNA fila con '
      'repeticiones 5', () async {
    await _preparar();
    for (var i = 1; i <= 5; i++) {
      AppLog.error('sync', 'tormenta_x',
          d: 'fallo de red intento $i (errno = 7)');
    }
    final fila = await _esperarFila('tormenta_x');
    expect(fila, isNotNull);
    // El colapso en RAM es inmediato, pero la absorción en SQL
    // ocurre en el flush siguiente (el temporizador de respaldo
    // tarda 2 s): se espera activamente a que la fila única
    // acumule las 5 repeticiones en vez de fijar una espera.
    final d = await LocalDb.instance.db;
    List<Map<String, Object?>> filas = [];
    for (var i = 0; i < 60; i++) {
      await AppLog.eventosRecientes(limite: 5);
      filas = await d.query('app_log',
          where: 'evento = ?', whereArgs: ['tormenta_x']);
      if (filas.length == 1 &&
          (filas.first['repeticiones'] as num).toInt() == 5) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(filas.length, 1,
        reason: 'los 5 errores idénticos salvo dígitos se agrupan');
    expect((filas.first['repeticiones'] as num).toInt(), 5);
    expect(filas.first['primer_ts'], isNotNull);
    expect('${filas.first['ts']}'
        .compareTo('${filas.first['primer_ts']}'),
        greaterThanOrEqualTo(0),
        reason: 'el ts visible es el de la última repetición');
  });

  test('BT-03: reiniciar no resucita el buffer y la semilla '
      'trae el resumen', () async {
    await _preparar();
    AppLog.error('test', 'antes_del_reinicio', d: 'ya en disco');
    await _esperarFila('antes_del_reinicio');
    // Dos infos que se quedan SOLO en el buffer (timer de 3 s):
    // el reinicio debe descartarlas, nunca deben aparecer.
    AppLog.info('test', 'en_vuelo_1');
    AppLog.info('test', 'en_vuelo_2');
    final d = await LocalDb.instance.db;
    final antes = await d.rawQuery(
        'SELECT COUNT(*) AS c FROM app_log');
    final enDisco = (antes.first['c'] as num).toInt();

    final r = await AppLog.reiniciar();
    expect(r['total'], enDisco,
        reason: 'el resumen cuenta solo lo que había en disco');

    await Future<void>.delayed(const Duration(milliseconds: 400));
    final filas = await d.query('app_log');
    expect(filas.length, 1,
        reason: 'solo queda la fila semilla; el buffer no resucita');
    expect(filas.first['evento'], 'bitacora.reiniciada');
    final ctx = jsonDecode(filas.first['contexto'] as String)
        as Map<String, dynamic>;
    expect(ctx['borrados_total'], enDisco);
  });

  test('Delta: exportar no mueve la marca; confirmar sí',
      () async {
    await _preparar();
    await AppLog.reiniciar(); // tabla limpia: solo la semilla
    final (path1, maxId1) =
        await AppLog.exportar(soloNovedades: true, versionApp: 'test');
    expect(maxId1, isNotNull);
    final texto1 = await File(path1).readAsString();
    expect(texto1, contains('Tipo: novedades'));
    expect(texto1, contains('Versión de la app: test'));
    expect(texto1, contains('bitacora.reiniciada'));

    // Sin confirmar, el mismo delta vuelve a salir entero.
    final (_, maxId2) = await AppLog.exportar(soloNovedades: true);
    expect(maxId2, maxId1);

    await AppLog.confirmarMarcaExportada(maxId1!);
    final (_, maxId3) = await AppLog.exportar(soloNovedades: true);
    expect(maxId3, isNull,
        reason: 'tras confirmar no quedan novedades');

    AppLog.error('test', 'novedad_real', d: 'posterior a la marca');
    await _esperarFila('novedad_real');
    final (path4, maxId4) =
        await AppLog.exportar(soloNovedades: true);
    expect(maxId4, isNotNull);
    final texto4 = await File(path4).readAsString();
    expect(texto4, contains('novedad_real'));
    expect(texto4, isNot(contains('bitacora.reiniciada')),
        reason: 'la semilla ya confirmada no se repite');
  });

  test('BT-04: la poda por peso sacrifica info gorda y '
      'conserva los errores', () async {
    await _preparar();
    final d = await LocalDb.instance.db;
    final gordo = 'x' * (3 * 1024 * 1024);
    for (var i = 0; i < 3; i++) {
      await d.insert('app_log', {
        'ts': '2026-11-02T08:00:0$i',
        'modulo': 'test',
        'evento': 'info_gorda_$i',
        'detalle': gordo,
        'nivel': 'info',
      });
    }
    await d.insert('app_log', {
      'ts': '2026-11-02T08:01:00',
      'modulo': 'test',
      'evento': 'error_gordo',
      'detalle': gordo,
      'nivel': 'error',
    });
    await AppLog.podar();
    final infos = await d.query('app_log',
        where: "nivel = 'info' AND LENGTH(detalle) > 1000000");
    expect(infos, isEmpty,
        reason: 'las info de 3 MB se podan por peso');
    final errores = await d.query('app_log',
        where: "evento = 'error_gordo'");
    expect(errores.length, 1,
        reason: 'la poda por peso nunca sacrifica errores');
  });
}
