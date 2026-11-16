/// LOTE 1.35 · SL-5B — G07-11 (2ª mitad): el «por
/// decidir» de Adelantos se asienta con MontoAnimado:
/// el total pedido en SolicitudesAdelantoScreen y la
/// cifra de la fila «Adelantos por responder» en la
/// BandejaPorDecidir dejan de saltar en un Text crudo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:ironbody_gym/ui/solicitudes_adelanto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000ee',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000ee',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Future<void> _pumpReal(WidgetTester tester, {int vueltas = 10}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < vueltas; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 16));
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  testWidgets('G07-11 · la fila de Adelantos de la bandeja '
      'lleva su cifra en MontoAnimado', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BandejaPorDecidir(
          incidencias: 0,
          rellenos: 0,
          adelantos: 2,
          onIr: (_) {},
          cargarRemotas: () async =>
              const ConteosRemotosPorDecidir(
                  vales: 0, plus: 0, comunidad: 0, solicitudes: 0),
          cargarCongelaciones: () async =>
              (ok: true, pendientes: 0),
          cargarArqueos: () async => [],
          cargarCatalogo: () async => 0,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final fila = find.ancestor(
      of: find.text('Adelantos por responder'),
      matching: find.byType(ListTile),
    );
    expect(fila, findsOneWidget, reason: 'la fila se pintó');
    expect(
      find.descendant(of: fila, matching: find.byType(MontoAnimado)),
      findsOneWidget,
      reason: 'la cifra se asienta animada',
    );
    expect(find.descendant(of: fila, matching: find.text('2')),
        findsOneWidget);
  });

  testWidgets('G07-11 · el total por decidir de Solicitudes '
      'se asienta con MontoAnimado', (tester) async {
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      await _fijarSesion('jctr0602@ironbody.gym', 735772141);
      await LocalDb.instance.upsertMirror('solicitudes_adelanto', 5, {
        'id': 5,
        'entrenador_telegram_id': 222222,
        'entrenador_nombre': 'Gabriel',
        'monto': 5000,
        'motivo': 'adelanto',
        'estado': 'pendiente',
        'creado_en': '2026-11-16T10:00:00-05:00',
      }, 9001);
      await tester.pumpWidget(
          const MaterialApp(home: SolicitudesAdelantoScreen()));
    });
    await _pumpReal(tester, vueltas: 12);
    for (var i = 0;
        i < 20 && find.textContaining('por decidir').evaluate().isEmpty;
        i++) {
      await _pumpReal(tester, vueltas: 4);
    }
    final cabecera = find.ancestor(
      of: find.textContaining('por decidir'),
      matching: find.byType(Tarjeta),
    );
    expect(cabecera, findsOneWidget,
        reason: 'la cabecera «por decidir» se pintó');
    expect(
      find.descendant(
          of: cabecera, matching: find.byType(MontoAnimado)),
      findsOneWidget,
      reason: 'el total pedido se asienta animado',
    );
    expect(find.textContaining('CUP pedidos'), findsOneWidget);
  });
}
