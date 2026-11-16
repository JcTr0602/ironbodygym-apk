// 1.35 (SP-03 + SP-11): la línea de autor del héroe cuadra.
//
// SP-03: el total contaba pendiente+enviada+error
// (LocalDb.countPendingOps) pero el desglose «A tuyas ·
// B de otros» solo miraba las 'pendiente': en cuanto una
// op entraba en error o quedaba enviada, A+B ≠ N en la
// misma frase. SP-11: una op legada SIN FIRMA contaba
// como «tuya» de cualquier sesión (esOpMia la acredita
// sin actor); ahora es una tercera clase, «sin autor
// conocido», y no se atribuye a nadie.
//
// Se prueba la función pura del desglose y la pantalla:
// con ops en los tres estados del conjunto, la línea del
// dueño suma el total y nombra la tercera clase.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés (la pauta de gestion129_oleada6_test.dart) ────

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {
        'telegram_id': 735772141,
        'provider': 'email'
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<Database> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _insertarOp(
  Database db, {
  required String uuid,
  required String tipo,
  String estado = 'pendiente',
  Map<String, dynamic> payload = const {},
}) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': '${hoyHabanaIso()}T09:00:00.000-04:00',
  });
}

void main() {
  late Directory docsDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
    docsDir = await Directory.systemTemp.createTemp('sp03_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docsDir.path);
  });

  group('SP-11 · desglosePendientesPorAutor (pura)', () {
    test('la op sin firma no se atribuye: tercera clase', () {
      final ops = <Map<String, dynamic>>[
        {'payload': jsonEncode({'registrado_por': 735772141})},
        {'payload': jsonEncode({'registrado_por': 969869611})},
        {'payload': '{}'},
        {'payload': jsonEncode({'registrado_por_nombre': 'Jc'})},
      ];
      final d = desglosePendientesPorAutor(ops,
          miActor: 'Jc', miTelegramId: 735772141);
      expect(d.mias, 2,
          reason: 'la firmada numérica propia y la de texto');
      expect(d.deOtros, 1);
      expect(d.sinAutor, 1,
          reason: 'la legada sin firma no es «tuya» de nadie');
      expect(d.mias + d.deOtros + d.sinAutor, ops.length,
          reason: 'el desglose suma el conjunto entero');
    });
  });

  group('SP-03 · la línea del héroe en pantalla', () {
    testWidgets(
        'con ops en pendiente/enviada/error la línea suma el '
        'total y nombra «sin autor conocido»', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        // El conjunto del total: pendiente + enviada + error.
        await _insertarOp(db,
            uuid: 'o-mia',
            tipo: 'pago_diario',
            payload: {'registrado_por': 735772141});
        await _insertarOp(db,
            uuid: 'o-ajena-enviada',
            tipo: 'pago_diario',
            estado: 'enviada',
            payload: {'registrado_por': 969869611});
        await _insertarOp(db,
            uuid: 'o-legada-error',
            tipo: 'pago_mensual',
            estado: 'error',
            payload: const {});
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(home: ColaScreen()));
      await _pumps(tester);
      expect(
        find.text('3 pendientes · 1 tuyas · 1 de otros · '
            '1 sin autor conocido'),
        findsOneWidget,
        reason: 'en la base el desglose solo leía las '
            'pendiente y la legada contaba como tuya: la '
            'línea no cuadraba con el total',
      );
      await tester.pump(const Duration(seconds: 31));
    });
  });
}
