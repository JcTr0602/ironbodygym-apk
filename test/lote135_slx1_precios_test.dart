/// LOTE SIGUIENTE 1.35 · SL-X1 · Ficha B (DINERO) —
/// guardarConfigGym debe mantener en acuerdo la clave plana
/// de precio y el blob `tipos_pago` (patrón A5-D2), como ya
/// hace aplicarCambiosMontos en el Panel.
///
/// Discriminante: con blob previo (menores=1500), tras
/// guardarConfigGym({'mensualidad_menores': 1800}) la fuente
/// única del cobro (precioMenoresDesdeAjustes / getTiposPago)
/// debe devolver 1800. En la base 6e1a809 devuelve 1500: ROJO.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

const _blobBase = [
  {'id': 'mensual', 'nombre': 'Mensualidad', 'monto': 2000.0, 'dias': 30, 'activo': true},
  {'id': 'menores', 'nombre': 'Mensualidad menores', 'monto': 1500.0, 'dias': 30, 'activo': true, 'solo_menores': true},
  {'id': 'semanal', 'nombre': 'Semana', 'monto': 600.0, 'dias': 7, 'activo': true},
  {'id': 'quincenal', 'nombre': 'Quincena', 'monto': 1200.0, 'dias': 15, 'activo': true},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final sesion = jsonEncode({
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-de-mentira',
      'user': {
        'id': '00000000-0000-0000-0000-0000000000dd',
        'aud': 'authenticated',
        'email': 'jc@ironbody.local',
        'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
        'user_metadata': <String, dynamic>{},
        'created_at': '2024-01-01T00:00:00.000Z',
      },
    });
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });

  Future<void> bdConPrecios() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    await LocalDb.instance.setAjustes({
      'mensualidad': 2000.0,
      'mensualidad_menores': 1500.0,
      'pago_semanal': 600.0,
      'pago_quincenal': 1200.0,
      'tipos_pago': _blobBase,
    });
  }

  test('B · guardarConfigGym(menores) actualiza clave Y blob: '
      'el cobro lee el precio nuevo', () async {
    await bdConPrecios();
    await guardarConfigGym({'mensualidad_menores': 1800.0});
    final aj = await LocalDb.instance.getAjustes();
    expect(aj['mensualidad_menores'], 1800.0);
    expect(precioMenoresDesdeAjustes(aj), 1800.0,
        reason: 'el blob tipos_pago debe moverse con la clave');
    final tipos = await getTiposPago(soloActivos: false, paraMenor: true);
    expect(tipos.singleWhere((t) => t.id == 'menores').monto, 1800.0);
    // El resto del blob queda intacto.
    final adultos = await getTiposPago(soloActivos: false);
    expect(adultos.singleWhere((t) => t.id == 'mensual').monto, 2000.0);
    expect(adultos.singleWhere((t) => t.id == 'semanal').monto, 600.0);
  });

  test('B · guardarConfigGym(semanal) actualiza el tipo '
      'semanal del blob', () async {
    await bdConPrecios();
    await guardarConfigGym({'pago_semanal': 700.0});
    final tipos = await getTiposPago(soloActivos: false);
    expect(tipos.singleWhere((t) => t.id == 'semanal').monto, 700.0);
    // Y el de menores no se toca.
    final aj = await LocalDb.instance.getAjustes();
    expect(precioMenoresDesdeAjustes(aj), 1500.0);
  });

  test('B · guardarConfigGym sin blob previo materializa el '
      'blob con el precio nuevo de menores', () async {
    await bdConPrecios();
    final aj0 = await LocalDb.instance.getAjustes();
    aj0.remove('tipos_pago');
    await LocalDb.instance.setAjustes(aj0);
    await guardarConfigGym({'mensualidad_menores': 1800.0});
    final aj = await LocalDb.instance.getAjustes();
    expect(precioMenoresDesdeAjustes(aj), 1800.0);
    final tipos = await getTiposPago(soloActivos: false, paraMenor: true);
    expect(tipos.singleWhere((t) => t.id == 'menores').monto, 1800.0);
  });

  test('B · clave que NO es de precio no crea ni toca el blob',
      () async {
    await bdConPrecios();
    await guardarConfigGym({'textos_base': {'aviso': 'hola'}});
    final aj = await LocalDb.instance.getAjustes();
    final blob = aj['tipos_pago'] as List;
    expect(blob.length, _blobBase.length);
    expect(precioMenoresDesdeAjustes(aj), 1500.0);
  });

  test('B · el guardado encola la op de config Y la op '
      'guardar_tipos_pago con el blob (patrón A5-D2, misma '
      'transacción)', () async {
    await bdConPrecios();
    await guardarConfigGym({'mensualidad_menores': 1800.0});
    final ops = await LocalDb.instance.pendingOps();
    Map<String, dynamic> payloadDe(Map<String, dynamic> o) =>
        o['payload'] is String
            ? jsonDecode(o['payload'] as String) as Map<String, dynamic>
            : Map<String, dynamic>.from(o['payload'] as Map);
    // La op de config lleva la clave plana, como siempre.
    final deConfig = ops
        .where((o) => '${o['tipo']}' == kTipoOpActualizarConfigGym)
        .toList();
    expect(deConfig, isNotEmpty);
    final config = payloadDe(deConfig.first)['config'];
    expect(config is Map && config['mensualidad_menores'] == 1800.0,
        isTrue);
    // Y la op guardar_tipos_pago (la que el servidor SÍ
    // aplica al blob; dentro de `config` la clave tipos_pago
    // sería ignorada por _op_actualizar_config_gym) lleva el
    // blob con el precio nuevo.
    final deTipos = ops
        .where((o) => '${o['tipo']}' == 'guardar_tipos_pago')
        .toList();
    expect(deTipos, isNotEmpty,
        reason: 'sin op guardar_tipos_pago el blob no baja a '
            'los demás teléfonos');
    final tipos = payloadDe(deTipos.first)['tipos'] as List;
    final menores = tipos
        .whereType<Map>()
        .singleWhere((t) => '${t['id']}' == 'menores');
    expect((menores['monto'] as num).toDouble(), 1800.0);
  });
}
