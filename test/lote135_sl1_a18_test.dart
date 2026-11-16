/// Lote 1.35 · SL-1 · A-18 (g06 nº18): la purga de caducados
/// eliminaba más de lo confirmado — el diálogo confirmaba el
/// conteo de la página visible (≤50) pero la RPC purga TODOS
/// los vencidos del servidor.
///
/// Escenario: 3 caducados visibles en la página y 7 en total
/// en el servidor (el resumen lo sabe). El diálogo de
/// confirmación debe decir «7», no «3». Y con una búsqueda
/// activa debe avisar de que la purga es global.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/invitados.dart' as ui_inv;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 12, int ms = 110}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _jwtDeMentira(String email) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000aa',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(WidgetTester tester, String email) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira(email),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Map<String, dynamic> _caducadoJson(String id, String nombre) => {
      'id': id,
      'nombre': nombre,
      'telefono': '58112233',
      'estado': 'activo',
      'creado_en': '2026-09-01T10:00:00',
      'caduca_en': '2026-11-01T10:00:00',
      'dias_restantes': -15,
    };

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('sl1_a18_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
  });

  setUp(() async {
    await _bdVacia();
    ui_inv.servicioInvitadosParaTest = null;
    ui_inv.conteoReportesPlusParaTest = () async => 0;
  });

  tearDown(() {
    ui_inv.servicioInvitadosParaTest = null;
    ui_inv.conteoReportesPlusParaTest = null;
  });

  Future<void> abrirBandejaCaducados(WidgetTester tester) async {
    await _fijarSesion(tester, 'jctr0602@ironbody.gym');
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) async {
        if (nombre == 'invitados_listar') {
          // La página visible: SOLO 3 caducados.
          return {
            'invitados': [
              _caducadoJson('inv-1', 'Caducado Uno'),
              _caducadoJson('inv-2', 'Caducado Dos'),
              _caducadoJson('inv-3', 'Caducado Tres'),
            ],
          };
        }
        if (nombre == 'invitados_resumen') {
          // El servidor sabe el total real: 7 caducados.
          return {'total': 12, 'caducados': 7, 'convertidos': 2};
        }
        if (nombre == 'invitados_purgar_vencidos') {
          return {'ok': true, 'purgados': 7};
        }
        throw Exception('RPC no simulada: $nombre');
      },
    );
    await tester.pumpWidget(const MaterialApp(
        home: ui_inv.InvitadosScreen(filtroInicial: 'caducados')));
    await _drenar(tester);
    expect(find.textContaining('Limpiar caducados'), findsOneWidget,
        reason: 'el botón de purga debe verse (dueño, filtro '
            'de caducados)');
  }

  testWidgets(
      'A-18: el diálogo de purga confirma el TOTAL del '
      'servidor (7), no la página visible (3)', (tester) async {
    await abrirBandejaCaducados(tester);
    await tester.tap(find.textContaining('Limpiar caducados'));
    await _drenar(tester, vueltas: 6);
    expect(find.text('Limpiar caducados'), findsWidgets);
    expect(find.textContaining('Se eliminarán las 7 cuentas'),
        findsOneWidget,
        reason: 'la confirmación debe pedir el total real '
            'del servidor antes de purgar');
    expect(find.textContaining('Se eliminarán las 3 cuentas'),
        findsNothing,
        reason: 'confirmar 3 y purgar 7 es el defecto');
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await _drenar(tester, vueltas: 3);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  });

  testWidgets(
      'A-18: con búsqueda activa, el diálogo avisa de que la '
      'purga es global', (tester) async {
    await abrirBandejaCaducados(tester);
    // Búsqueda que deja 1 visible de los 3 cargados.
    await tester.enterText(
        find.byType(TextField).first, 'Caducado Uno');
    await _drenar(tester, vueltas: 4);
    await tester.tap(find.textContaining('Limpiar caducados'));
    await _drenar(tester, vueltas: 6);
    expect(find.textContaining('global'), findsWidgets,
        reason: 'con búsqueda activa debe avisarse de que la '
            'purga alcanza a TODO el servidor');
    expect(find.textContaining('Se eliminarán las 7 cuentas'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await _drenar(tester, vueltas: 3);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  });
}
