/// Fase 1 (auditoría de cambios 2026-11-13) — regresión de
/// las correcciones MEDIA del carril de fotos (QoS):
///
/// - FOTOS-02: la vía inmediata de 'original' mide el
///   trabajo de RED que queda, no el archivo entero:
///   (a) con storage_path persistido los bytes ya están en
///   Storage — una original GRANDE en ese estado completa
///   sin esperar la puerta QoS (solo vincula);
///   (b) con una subida TUS reanudada, solo cuentan los
///   bytes tras el offset: una grande con el resto pequeño
///   se reclama e intenta, no se difiere intacta.
/// - FOTOS-03: la guarda «sin ops» de la vía inmediata se
///   re-evalúa AL RECLAMAR: si un cobro entra entre la
///   selección de la fila y el reclamo (la sonda de red de
///   por medio), la original se difiere dentro del ciclo
///   sin tocar su fila.
///
/// Arnés: el de fotos_cola_original_rapida_test.dart (la
/// sonda _hayRed se responde con HttpOverrides locales).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RespRedOk extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;
}

class _ReqRedOk extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _RespRedOk();
}

/// Cliente de red falsa: el HEAD de la sonda _hayRed puede
/// ejecutar una acción (FOTOS-03: encolar un cobro en ese
/// instante, entre la selección y el reclamo).
class _ClienteRedOk extends Fake implements HttpClient {
  @override
  set connectionTimeout(Duration? _) {}

  @override
  Future<HttpClientRequest> headUrl(Uri url) async {
    final accion = accionAlSondearRed;
    if (accion != null) await accion();
    return _ReqRedOk();
  }

  @override
  void close({bool force = false}) {}
}

class _OverridesRedOk extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ClienteRedOk();
}

Future<void> Function()? accionAlSondearRed;

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

Future<void> _sembrarCliente(Database db, int id) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({'nombre': 'Cliente $id'}),
    'sync_seq': 1,
  });
}

Future<void> _sembrarOriginal(
  Database db,
  Directory dir, {
  required String opUuid,
  required int clienteId,
  required int bytes,
  bool conStoragePath = false,
  int? tamanoBytes,
  bool crearArchivo = true,
}) async {
  final archivo = File('${dir.path}/$opUuid-original.jpg');
  if (crearArchivo) {
    await archivo.writeAsBytes(List.filled(bytes, 7));
  }
  await db.insert('fotos_cola', {
    'op_uuid': opUuid,
    'tipo': 'original',
    'cliente_id': clienteId,
    'ruta_local': archivo.path,
    'estado': 'pendiente',
    'intentos': 0,
    'creado_en': isoHabana(ahoraHabana()),
    'actualizado_en': isoHabana(ahoraHabana()),
    if (tamanoBytes != null) 'tamano_bytes': tamanoBytes,
    if (conStoragePath)
      'storage_path': 'clientes/$clienteId/${opUuid}_original.jpg',
  });
}

Future<Map<String, dynamic>> _fila(Database db, String opUuid) async {
  final filas = await db.query('fotos_cola',
      where: 'op_uuid = ?', whereArgs: [opUuid], limit: 1);
  return filas.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('fase1_fotos_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    HttpOverrides.global = _OverridesRedOk();
  });

  tearDownAll(() async {
    HttpOverrides.global = null;
    try {
      await docs.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    accionAlSondearRed = null;
  });

  test('FOTOS-02a · original GRANDE ya en Storage (solo '
      'vincular) completa sin esperar la puerta QoS', () async {
    final db = await _preparar();
    await _sembrarCliente(db, 902);
    await _sembrarOriginal(db, docs,
        opUuid: 'op-grande-subida',
        clienteId: 902,
        bytes: 600 * 1024,
        conStoragePath: true);
    final n = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    expect(n, 1,
        reason: 'no hay transferencia que proteger: los '
            'bytes ya están en Storage');
    final fila = await _fila(db, 'op-grande-subida');
    expect(fila['estado'], 'completada');
  });

  test('FOTOS-02b · original grande con TUS reanudado y el '
      'resto pequeño se reclama (no se difiere intacta)',
      () async {
    final db = await _preparar();
    await _sembrarCliente(db, 903);
    await _sembrarOriginal(db, docs,
        opUuid: 'op-grande-tus', clienteId: 903, bytes: 600 * 1024);
    // Offset TUS: ya subieron 300 KB; quedan ~300 KB, bajo
    // el tope de la vía inmediata.
    await LocalDb.instance.setMeta(
        'tus_offset_op-grande-tus_original', '${300 * 1024}');
    await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    final fila = await _fila(db, 'op-grande-tus');
    // ignore: avoid_print
    print('FOTOS-02b fila: estado=${fila['estado']} '
        'intentos=${fila['intentos']} worker=${fila['worker_id']}');
    expect(
        (fila['intentos'] as int? ?? 0) > 0 ||
            fila['estado'] != 'pendiente',
        isTrue,
        reason: 'la fila se reclamó y se intentó subir (la '
            'subida contra la red falsa puede fallar: lo que '
            'se prueba es la DECISIÓN, no el transporte); en '
            'la base quedaba diferida e intacta');
  });

  test('FOTOS-03 · un cobro que entra entre la selección y '
      'el reclamo difiere la original dentro del ciclo',
      () async {
    final db = await _preparar();
    await _sembrarCliente(db, 901);
    await _sembrarOriginal(db, docs,
        opUuid: 'op-peq',
        clienteId: 901,
        bytes: 70 * 1024,
        conStoragePath: true);
    // La sonda de red (_hayRed) es el instante entre la
    // selección/decisión y el reclamo: ahí entra el cobro.
    accionAlSondearRed = () async {
      accionAlSondearRed = null; // una sola vez
      await db.insert('ops_queue', {
        'op_uuid': 'op-cobro-en-vuelo',
        'tipo': 'pago_mensual',
        'payload': jsonEncode({'cliente_id': 901}),
        'estado': 'pendiente',
        'creada_ts': isoHabana(ahoraHabana()),
      });
    };
    final n = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    expect(n, 0,
        reason: 'con el cobro encolado en el intervalo, la '
            'original NO se reclama en este ciclo');
    final fila = await _fila(db, 'op-peq');
    expect(fila['estado'], 'pendiente');
    expect(fila['worker_id'], isNull,
        reason: 'diferida sin reclamar: su fila no se tocó');
    expect(fila['intentos'], 0);
    final espejo = await db.query('clientes',
        columns: ['data'], where: 'id = ?', whereArgs: [901], limit: 1);
    final dataEspejo =
        jsonDecode(espejo.first['data'] as String) as Map<String, dynamic>;
    expect(dataEspejo['foto_storage'], isNull,
        reason: 'no se vinculó nada: el ciclo cedió la red '
            'al cobro');
  });

  test('B-3a · la columna tamano_bytes manda sobre el '
      'archivo: original con archivo de 600 KB y columna de '
      '200 KB se reclama por la vía inmediata', () async {
    final db = await _preparar();
    await _sembrarCliente(db, 904);
    await _sembrarOriginal(db, docs,
        opUuid: 'op-columna-manda',
        clienteId: 904,
        bytes: 600 * 1024,
        tamanoBytes: 200 * 1024);
    await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    final fila = await _fila(db, 'op-columna-manda');
    expect(
        (fila['intentos'] as int? ?? 0) > 0 ||
            fila['estado'] != 'pendiente',
        isTrue,
        reason: 'con la columna en 200 KB la vía inmediata '
            'aplica y la fila se reclama; midiendo el archivo '
            '(600 KB) quedaba diferida e intacta');
  });

  test('B-3b · con storage_path la fila no pasa por la '
      'puerta QoS ni sin archivo local (tamano 0): completa '
      'vinculando', () async {
    final db = await _preparar();
    await _sembrarCliente(db, 905);
    await _sembrarOriginal(db, docs,
        opUuid: 'op-sin-archivo',
        clienteId: 905,
        bytes: 0,
        conStoragePath: true,
        tamanoBytes: 0,
        crearArchivo: false);
    final n = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    expect(n, 1,
        reason: 'los bytes ya están en el servidor: reclamar '
            'y vincular no necesita ni el archivo ni la red');
    final fila = await _fila(db, 'op-sin-archivo');
    expect(fila['estado'], 'completada');
  });

  test('B-3c · contarPendientesReclamables cuenta la '
      'original pequeña sin ops (el FGS no se apaga tras '
      'la display) y deja de contarla con un cobro en cola',
      () async {
    final db = await _preparar();
    await _sembrarCliente(db, 906);
    await _sembrarOriginal(db, docs,
        opUuid: 'op-peq-conteo',
        clienteId: 906,
        bytes: 100 * 1024,
        tamanoBytes: 100 * 1024);
    expect(
        await FotosColaService.instance
            .contarPendientesReclamables(),
        1,
        reason: 'procesarCola la subiría por la vía '
            'inmediata: el conteo que gobierna el FGS debe '
            'verla reclamable');
    await db.insert('ops_queue', {
      'op_uuid': 'op-cobro-conteo',
      'tipo': 'pago_mensual',
      'payload': jsonEncode({'cliente_id': 906}),
      'estado': 'pendiente',
      'creada_ts': isoHabana(ahoraHabana()),
    });
    expect(
        await FotosColaService.instance
            .contarPendientesReclamables(),
        0,
        reason: 'con un cobro pendiente la vía inmediata '
            'está cerrada (Regla de Hierro) y la original '
            'pequeña vuelve a no contar');
  });
}
