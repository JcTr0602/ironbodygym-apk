/// Yunque de cambios 1.31 · RONDA 3 · M3 (colas hermanas) y
/// M1-4 (push): correcciones de la ronda.
///
/// M3-2/3 (conducta por contrato de fuente): la pausa QoS en
/// el PUT monolítico _subirFotoSimple ya no se devuelve como
/// `false` (indistinguible del fallo): LANZA _PausaQosSimple
/// y sus tres llamadores la capturan ANTES de contar el
/// intento — incidencias restaura la foto a 'retry' sin
/// quemar otro intento, el fallback de subirFotoCola la
/// devuelve como pausadaPorQos (no permitirFallback) y la
/// foto suelta de suplemento la traduce a null sin PUT.
///
/// M3-4 (conductual): la puerta de la Regla de Hierro a la
/// entrada de ComprobantesService.procesar(): con una op de
/// cobro pendiente en la cola, el ciclo se omite entero —
/// devuelve 0, no reclama lease ni toca la fila (sin la
/// puerta, la subida intentaba red y quemaba un intento).
///
/// M1-4 (contrato de fuente): _uploadUnaPorUna devuelve las
/// ops aceptadas y el llamador alimenta con ellas la
/// contabilidad del lote adaptativo (loteOk).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _src(String ruta) => File(ruta).readAsStringSync();

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('r3_m3_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  test('M3-4: con un cobro pendiente, comprobantes no entra: '
      'ni lease, ni intento, ni red', () async {
    final db = await _preparar();
    final tmp = await Directory.systemTemp.createTemp('r3_m3_comp');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final origen = File('${tmp.path}/captura.jpg');
    await origen.writeAsBytes([1, 2, 3]);
    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-puerta',
        rutaOrigen: origen.path,
        baseDir: tmp);
    // Una op de cobro pendiente (no foto): la Regla de Hierro
    // manda que las fotos/comprobantes no compitan con ella.
    await db.insert('ops_queue', {
      'op_uuid': 'op-cobro-puerta',
      'tipo': 'registrar_pago',
      'payload': jsonEncode({'cliente_id': 7}),
      'estado': 'pendiente',
      'creada_ts': '2026-11-09T09:00:00.000-04:00',
    });

    final n = await ComprobantesService.instance.procesar();

    expect(n, 0);
    final fila =
        await ComprobantesService.instance.filaDe('uuid-puerta');
    expect(fila, isNotNull);
    expect(fila!['estado'], 'pendiente');
    expect(fila['intentos'], 0,
        reason: 'la puerta no quema intentos: no hubo intento');
    // Ni siquiera reclamó el lease de worker.
    final lease =
        await LocalDb.instance.getMeta('comprobantes_worker_lease');
    expect(lease ?? '', '',
        reason: 'la puerta va ANTES de reclamar el lease');
  });

  test('M3-2/3: la pausa QoS del PUT monolítico es excepción, '
      'no un false más', () {
    final s = _src('lib/sync.dart');
    expect(s, contains('class _PausaQosSimple implements Exception'));
    expect(s, contains('throw _PausaQosSimple();'));
    // Tres llamadores la capturan: foto suelta de suplemento,
    // fallback de subirFotoCola e incidencias.
    expect('on _PausaQosSimple'.allMatches(s).length,
        greaterThanOrEqualTo(3));
    // El fallback la devuelve como pausa, no como fallback
    // reintentable que quema intento.
    final i = s.indexOf('pausa en el PUT de respaldo =');
    expect(i, greaterThan(0));
    final tramo = s.substring(i, i + 900);
    expect(tramo, contains('EstadoSubida.pausadaPorQos'));
    // Y el texto de error del fallback ya no mezcla la pausa.
    expect(s, isNot(contains('PUT falló o pausó por cobro')));
  });

  test('M3-2: incidencias restaura la foto sin quemar intento', () {
    final s = _src('lib/sync.dart');
    // lastIndexOf: la guarda previa por archivo usa la misma
    // etiqueta de bitácora; la de la pausa a mitad de subida
    // (la de esta corrección) es la última.
    final i = s.lastIndexOf('foto_inc_pausa_qos');
    expect(i, greaterThan(0));
    final tramo = s.substring(i - 700, i);
    // La rama de pausa devuelve la fila a 'retry' y libera el
    // claim, sin pasar por el incremento de intentos del fallo.
    expect(tramo, contains("'sync_estado': 'retry'"));
    expect(tramo, contains("'reclamada_en': null"));
  });

  test('M1-4: el fallback una-por-una contabiliza aceptadas', () {
    final s = _src('lib/sync.dart');
    expect(s, contains('Future<int> _uploadUnaPorUna'));
    expect(s, contains('return aceptadas;'));
    expect(s, contains('aceptadas++;'));
    expect(s, contains('if (await _uploadUnaPorUna(lote) > 0)'));
    expect(s, contains('loteOk = true;'));
  });
}
