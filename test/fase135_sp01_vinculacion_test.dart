// 1.35 (SP-01, BLOQUEANTE): la foto de una inscripción NO puede
// quedar 'completada' sin vincular.
//
// Escenario exacto del caso real (Claudia, 240, 2026-11-15): la
// corrida que aplica la inscripción procesa la foto EN LA MISMA
// pierna de push, antes de cualquier pull. Los bytes ya están en
// Storage (storage_path persistido), pero el cliente aún NO está
// en el espejo local (entra por pull). En la base, la vinculación
// devolvía en silencio («Cliente eliminado») y la fila se marcaba
// 'completada' sin encolar jamás la op 'foto': la foto se perdía
// con el panel diciendo «Al día».
//
// Qué se prueba:
//  1. Sin cliente en el espejo: la 'display' NO completa; vuelve
//     a 'pendiente' conservando storage_path y sin quemar
//     intentos, y NO nace op 'foto' (aún no hay nada que enlazar).
//  2. Cuando el espejo trae al cliente (el pull) y vence el
//     backoff: la misma fila completa, la op 'foto' determinista
//     queda encolada y el espejo enlaza foto_storage/foto_uuid.
//  3. Ventana amplia: si el espejo no trae al cliente en >24 h,
//     la fila pasa a 'error' VISIBLE con texto humano (no a
//     'completada' silenciosa).
//  4. Autocura: una 'completada' histórica sin enlace en el
//     espejo (el daño ya hecho en otro teléfono) se re-encola
//     conservando storage_path y termina vinculada; una
//     completada cuyo espejo enlaza OTRA foto no se toca.
//
// Sin red real: las filas llevan storage_path persistido (la vía
// sin red de _subirUna) y la sonda _hayRed se responde con un
// HttpOverrides local (mismo arnés que
// test/fotos_cola_original_rapida_test.dart).
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
import 'package:uuid/uuid.dart';

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

// --- Arnés ---

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

/// Siembra la variante 'display' de la foto de una inscripción ya
/// aplicada: ids resueltos y bytes ya en Storage (storage_path
/// persistido), como queda la fila tras _subirUna en la corrida
/// que aplicó la inscripción.
Future<void> _sembrarDisplay(
  Database db,
  Directory dir, {
  required String opUuid,
  required int clienteId,
  required String creadoEn,
  String estado = 'pendiente',
}) async {
  final archivo = File('${dir.path}/$opUuid-display.webp');
  await archivo.writeAsBytes(List.filled(1024, 7));
  await db.insert('fotos_cola', {
    'op_uuid': opUuid,
    'tipo': 'display',
    'cliente_id': clienteId,
    'ruta_local': archivo.path,
    'estado': estado,
    'intentos': 0,
    'creado_en': creadoEn,
    'actualizado_en': creadoEn,
    'storage_path': 'clientes/$clienteId/${opUuid}_display.webp',
  });
}

Future<Map<String, dynamic>> _filaDisplay(Database db, String opUuid) async {
  final filas = await db.query('fotos_cola',
      where: 'op_uuid = ? AND tipo = ?', whereArgs: [opUuid, 'display']);
  return filas.first;
}

Future<List<Map<String, Object?>>> _opsFoto(Database db) =>
    db.query('ops_queue', where: 'tipo = ?', whereArgs: ['foto']);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('sp01_docs');
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

  test('SP-01: sin cliente en el espejo la display NO completa; '
      'al llegar el espejo, completa con su op foto encolada',
      () async {
    final db = await _preparar();
    // El cliente 240 NO está en el espejo (entra por pull).
    await _sembrarDisplay(db, docs,
        opUuid: 'op-insc-240',
        clienteId: 240,
        creadoEn: isoHabana(ahoraHabana()));

    final n1 = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    expect(n1, 0, reason: 'sin espejo no hay subida que contar');

    var fila = await _filaDisplay(db, 'op-insc-240');
    expect(fila['estado'], 'pendiente',
        reason: 'la base la marcaba completada sin vincular: '
            'la foto se perdía con el panel en «Al día»');
    expect(fila['storage_path'],
        'clientes/240/op-insc-240_display.webp',
        reason: 'los bytes no se re-suben: el path se conserva');
    expect(fila['intentos'], 0,
        reason: 'esperar al espejo no quema intentos');
    expect(await _opsFoto(db), isEmpty,
        reason: 'aún no hay enlace que enviar al servidor');

    // El pull trae al cliente al espejo y el backoff corto vence.
    await db.insert('clientes', {
      'id': 240,
      'data': jsonEncode({'nombre': 'Claudia Toledo Jimenez'}),
      'sync_seq': 1,
    });
    await db.update('fotos_cola', {'proximo_intento_en': null},
        where: 'op_uuid = ?', whereArgs: ['op-insc-240']);

    final n2 = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    expect(n2, 1, reason: 'con el espejo presente, la foto sube');

    fila = await _filaDisplay(db, 'op-insc-240');
    expect(fila['estado'], 'completada',
        reason: 'ahora sí: completada CON vinculación');

    final ops = await _opsFoto(db);
    expect(ops, hasLength(1),
        reason: 'la op foto que lleva el enlace al servidor existe');
    final esperado = const Uuid().v5(
        '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
        'foto:op-insc-240:display');
    expect(ops.first['op_uuid'], esperado,
        reason: 'uuid determinista de la variante display');
    final payload =
        jsonDecode(ops.first['payload'] as String) as Map<String, dynamic>;
    expect(payload['cliente_id'], 240);
    expect(payload['storage_path'],
        'clientes/240/op-insc-240_display.webp');
    expect(payload['foto_uuid'], 'op-insc-240');

    final espejo = await db.query('clientes',
        columns: ['data'], where: 'id = ?', whereArgs: [240]);
    final data =
        jsonDecode(espejo.first['data'] as String) as Map<String, dynamic>;
    expect(data['foto_storage'], 'clientes/240/op-insc-240_display.webp');
    expect(data['foto_uuid'], 'op-insc-240');
  });

  test('SP-01 ventana amplia: >24 h sin espejo → error visible '
      'con texto humano, nunca completada', () async {
    final db = await _preparar();
    await _sembrarDisplay(db, docs,
        opUuid: 'op-insc-vieja',
        clienteId: 241,
        creadoEn: isoHabana(
            ahoraHabana().subtract(const Duration(hours: 25))));

    await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));

    final fila = await _filaDisplay(db, 'op-insc-vieja');
    expect(fila['estado'], 'error',
        reason: 'la espera tiene fin VISIBLE, no completado '
            'silencioso ni espera eterna');
    expect('${fila['ultimo_error']}',
        contains('no pudo enlazarse'),
        reason: 'texto humano, no un código interno');
  });

  test('SP-01 autocura: la completada sin enlace se re-encola y '
      'vincula; la superada de verdad no se toca', () async {
    final db = await _preparar();
    // Cliente 240 en el espejo SIN foto enlazada; su display
    // quedó 'completada' por el bug histórico.
    await db.insert('clientes', {
      'id': 240,
      'data': jsonEncode({'nombre': 'Claudia Toledo Jimenez'}),
      'sync_seq': 1,
    });
    await _sembrarDisplay(db, docs,
        opUuid: 'op-perdida',
        clienteId: 240,
        creadoEn: isoHabana(ahoraHabana()),
        estado: 'completada');
    // Cliente 242 con OTRA foto ya enlazada: su display vieja
    // completada quedó superada de verdad — no se rescata.
    await db.insert('clientes', {
      'id': 242,
      'data': jsonEncode({
        'nombre': 'Otro',
        'foto_uuid': 'op-nueva-242',
        'foto_storage': 'clientes/242/op-nueva-242_display.webp',
      }),
      'sync_seq': 1,
    });
    await _sembrarDisplay(db, docs,
        opUuid: 'op-vieja-242',
        clienteId: 242,
        creadoEn: isoHabana(ahoraHabana()),
        estado: 'completada');

    final rescatadas = await FotosColaService.instance
        .reencolarVinculacionesPerdidas();
    expect(rescatadas, 1,
        reason: 'solo la perdida se re-encola; la superada, no');

    var fila = await _filaDisplay(db, 'op-perdida');
    expect(fila['estado'], 'pendiente');
    expect(fila['storage_path'], 'clientes/240/op-perdida_display.webp',
        reason: 'el rescate conserva el path: no se re-suben bytes');
    final superada = await _filaDisplay(db, 'op-vieja-242');
    expect(superada['estado'], 'completada',
        reason: 'su espejo enlaza otra foto: no se toca');

    // Y la re-encolada termina vinculada de verdad.
    final n = await FotosColaService.instance
        .procesarCola()
        .timeout(const Duration(seconds: 60));
    expect(n, 1);
    fila = await _filaDisplay(db, 'op-perdida');
    expect(fila['estado'], 'completada');
    final ops = await _opsFoto(db);
    expect(ops, hasLength(1));
    final payload =
        jsonDecode(ops.first['payload'] as String) as Map<String, dynamic>;
    expect(payload['cliente_id'], 240);
    expect(payload['foto_uuid'], 'op-perdida');
  });
}
