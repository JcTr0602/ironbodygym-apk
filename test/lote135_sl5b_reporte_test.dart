/// LOTE 1.35 · SL-5B — Reporte mensual de diarios.
///
/// - G07-4 (2ª mitad): las tarjetas de turno sin
///   importe no se generan (en cero no aparecen): un
///   mes solo de mañana no pinta la tarjeta «Tarde».
/// - G07-9: el área de toque de cada barra del gráfico
///   de días mide ≥44 dp de alto (la casa exige 44 dp
///   de objetivo; la barra visual sigue fina, alineada
///   abajo dentro de su zona de toque).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/reporte_mensual_diarios.dart';
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

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('pagos_diarios');
  await db.delete('ops_queue');
}

Future<void> _pumpReal(WidgetTester tester, {int vueltas = 10}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < vueltas; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 16));
    }
  });
}

Future<void> _abrirReporte(WidgetTester tester,
    {List<Map<String, dynamic>> diarios = const []}) async {
  tester.view.physicalSize = const Size(720, 1280);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await _bdVacia();
    await _fijarSesion('jctr0602@ironbody.gym', 735772141);
    var seq = 7000;
    for (var i = 0; i < diarios.length; i++) {
      await LocalDb.instance
          .upsertMirror('pagos_diarios', i + 1, diarios[i], seq++);
    }
    await tester.pumpWidget(const MaterialApp(
        home: ReporteMensualDiariosScreen()));
  });
  await _pumpReal(tester, vueltas: 12);
  for (var i = 0;
      i < 20 && find.text('Por turno').evaluate().isEmpty;
      i++) {
    await _pumpReal(tester, vueltas: 4);
  }
}

Map<String, dynamic> _diario(String fecha, String turno, double total) => {
      'fecha': fecha,
      'turno': turno,
      'total': total,
      'cantidad': 1,
      'metodo': 'efectivo',
      'registrado_por': 222222,
      'registrado_por_nombre': 'Gabriel',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  group('G07-4 · turnos en cero no se generan', () {
    testWidgets('mes vacío: ni «Mañana» ni «Tarde»', (tester) async {
      await _abrirReporte(tester);
      expect(find.text('Por turno'), findsOneWidget,
          reason: 'la pantalla cargó');
      expect(find.text('Mañana'), findsNothing);
      expect(find.text('Tarde'), findsNothing);
    });

    testWidgets('solo mañana con cobros: «Tarde» no existe',
        (tester) async {
      final hoy = hoyHabanaIso();
      await _abrirReporte(tester, diarios: [_diario(hoy, 'mañana', 200)]);
      expect(find.text('Mañana'), findsOneWidget);
      expect(find.text('Tarde'), findsNothing);
    });
  });

  group('G07-9 · objetivo de toque de las barras', () {
    testWidgets('a 360 dp, cada barra se toca con ≥44 dp de alto',
        (tester) async {
      final hoy = hoyHabanaIso();
      final otroDia = hoy.substring(0, 8) +
          (hoy.substring(8) == '10' ? '09' : '10');
      await _abrirReporte(tester, diarios: [
        _diario(hoy, 'mañana', 200),
        _diario(otroDia, 'mañana', 20),
      ]);
      final tarjetaGrafico = find.ancestor(
        of: find.text('Diarios por día').first,
        matching: find.byType(Tarjeta),
      );
      expect(tarjetaGrafico, findsOneWidget);
      final barras = find.descendant(
        of: tarjetaGrafico,
        matching: find.byType(GestureDetector),
      );
      expect(barras, findsWidgets,
          reason: 'el gráfico de días se pintó (total > 0)');
      for (final e in barras.evaluate()) {
        final size = tester.getSize(find.byWidget(e.widget));
        expect(size.height, greaterThanOrEqualTo(44),
            reason: 'objetivo de toque de la casa: 44 dp');
      }
    });
  });
}
