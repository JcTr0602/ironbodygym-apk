// 1.33 (rapidez de fotos): test de CICLO de la vía inmediata de
// 'original' en FotosColaService.procesarCola.
//
// Qué se prueba (sin red real):
// - Una 'original' PEQUEÑA (≤512 KB) con la puerta QoS cerrada sube
//   en el MISMO ciclo si no hay ops pendientes: es el caso de campo
//   (foto de cliente de ~70 KB que esperaba 5/15 min de holgura).
// - Una 'original' GRANDE (>512 KB) elegida ANTES que ella no la
//   bloquea: se difiere dentro del ciclo (su fila queda intacta:
//   pendiente, sin intentos, sin worker) y el ciclo termina.
//
// Cómo se evita la red: las filas llevan storage_path ya persistido
// (estado real: bytes en Storage, vinculación pendiente), que
// _subirUna resuelve sin subir nada; y la sonda de red de
// procesarCola (_hayRed, HEAD a Supabase) se responde con un
// HttpOverrides local que devuelve 200. La subida TUS real no se
// ejerce aquí (no hay punto de inyección sin tocar el carril sync);
// la decisión de vía queda cubierta además por los tests puros de
// test/fotos_qos_test.dart (originalInmediataPermitida).
//
// En la base 5043360 (sin el cambio) el primer test es ROJO: la
// exclusión SQL dejaba ambas originales fuera y el ciclo devolvía 0.
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

// --- Red falsa para _hayRed (solo se usa statusCode de un HEAD) ---

class _RespRedOk extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;
}

class _ReqRedOk extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _RespRedOk();
}

class _ClienteRedOk extends Fake implements HttpClient {
  @override
  set connectionTimeout(Duration? _) {}

  @override
  Future<HttpClientRequest> headUrl(Uri url) async => _ReqRedOk();

  @override
  void close({bool force = false}) {}
}

class _OverridesRedOk extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _ClienteRedOk();
}

// --- Arnés (mismo patrón que test/argon_fotos_caza_test.dart) ---

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

Future<int> _sembrarOriginal(
  Database db,
  Directory dir, {
  required String opUuid,
  required int clienteId,
  required int bytes,
  required String creadoEn,
  bool conStoragePath = true,
}) async {
  final archivo = File('${dir.path}/$opUuid-original.jpg');
  await archivo.writeAsBytes(List.filled(bytes, 7));
  return db.insert('fotos_cola', {
    'op_uuid': opUuid,
    'tipo': 'original',
    'cliente_id': clienteId,
    'ruta_local': archivo.path,
    'estado': 'pendiente',
    'intentos': 0,
    'creado_en': creadoEn,
    'actualizado_en': creadoEn,
    // Bytes ya en Storage; solo falta vincular (vía sin red de
    // _subirUna). La DECISIÓN de reclamarla es lo que se prueba.
    // Fase 1 (FOTOS-02): la «grande» de este test es una
    // subida REAL pendiente (sin storage_path): con los
    // bytes ya en Storage no hay red que proteger y la vía
    // inmediata la completa — ese caso vive en
    // fase1_correcciones_fotos_test.dart.
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
    docs = await Directory.systemTemp.createTemp('fotos_rapida_docs');
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

  test('original pequeña sube en el mismo ciclo con la puerta QoS '
      'cerrada; la grande de delante se difiere sin bloquearla',
      () async {
    final db = await _preparar();
    for (final id in [901, 902]) {
      await db.insert('clientes', {
        'id': id,
        'data': jsonEncode({'nombre': 'Cliente $id'}),
        'sync_seq': 1,
      });
    }
    final hace5 = isoHabana(
        ahoraHabana().subtract(const Duration(minutes: 5)));
    // La grande se creó ANTES: la selección la elige primero.
    // Es una subida real pendiente (sin storage_path).
    await _sembrarOriginal(db, docs,
        opUuid: 'op-grande',
        clienteId: 902,
        bytes: 600 * 1024,
        creadoEn: hace5,
        conStoragePath: false);
    await _sembrarOriginal(db, docs,
        opUuid: 'op-peq',
        clienteId: 901,
        bytes: 70 * 1024,
        creadoEn: isoHabana(ahoraHabana()));

    final n = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));

    expect(n, 1, reason: 'solo la pequeña completa en este ciclo');
    final peq = await _fila(db, 'op-peq');
    expect(peq['estado'], 'completada',
        reason: 'la pequeña se reclamó por la vía inmediata');
    final espejo = await db.query('clientes',
        columns: ['data'], where: 'id = ?', whereArgs: [901], limit: 1);
    final dataEspejo =
        jsonDecode(espejo.first['data'] as String) as Map<String, dynamic>;
    expect(dataEspejo['foto_storage'],
        'clientes/901/op-peq_original.jpg',
        reason: 'la pequeña quedó vinculada al cliente');

    final grande = await _fila(db, 'op-grande');
    expect(grande['estado'], 'pendiente',
        reason: 'la grande sigue esperando su puerta QoS');
    expect(grande['intentos'], 0,
        reason: 'diferir no quema intentos');
    expect(grande['worker_id'], isNull,
        reason: 'diferir no la reclama');
    expect(grande['storage_path'], isNull,
        reason: 'su fila queda intacta (sigue siendo una '
            'subida real pendiente)');
  });

  test('solo una original grande: el ciclo termina sin reclamarla '
      'ni quemarla', () async {
    final db = await _preparar();
    await db.insert('clientes', {
      'id': 902,
      'data': jsonEncode({'nombre': 'Cliente 902'}),
      'sync_seq': 1,
    });
    await _sembrarOriginal(db, docs,
        opUuid: 'op-grande',
        clienteId: 902,
        bytes: 600 * 1024,
        creadoEn: isoHabana(ahoraHabana()),
        conStoragePath: false);

    final n = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));

    expect(n, 0);
    final grande = await _fila(db, 'op-grande');
    expect(grande['estado'], 'pendiente');
    expect(grande['intentos'], 0);
    expect(grande['worker_id'], isNull);
  });
}
