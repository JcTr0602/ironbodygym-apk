/// 1.32 (Oleada 2, Fase 2 · G-33): el Historial de Caja adopta
/// la plantilla del Día de Servicios — cabecera por día con
/// los totales del día y filas con el entrenador de
/// protagonista, el turno en chip y el cobrado en tabulares.
///
/// Contrato que se fija:
/// 1. El puro itemsHistorialCajaPorDia agrupa por la fecha de
///    NEGOCIO habanera: la fecha plana manda tal cual, un
///    instante con zona se convierte a La Habana antes de
///    cortar el día (cruce de medianoche) y los días sin
///    movimientos no existen como grupo.
/// 2. Los totales de la cabecera suman el cobrado CUP y el
///    USD de los cierres VISIBLES de ese día, sin mezclar
///    monedas.
/// 3. Costura a 420×800 (teléfono real): la pantalla montada
///    enseña las dos cabeceras con sus conteos, los nombres
///    de los entrenadores y el cobrado derivado del espejo
///    de pagos (solo efectivo, H12).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart' show fmtMonto;
import 'package:ironbody_gym/ui/historial_caja.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion({
  required String email,
  required int telegramId,
}) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
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
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  for (final t in ['turnos_cierre', 'pagos', 'pagos_diarios', 'servicio_ventas']) {
    try {
      await db.delete(t);
    } catch (_) {}
  }
  await db.delete('meta');
}

Future<bool> _esperarTexto(WidgetTester tester, String fragmento) async {
  for (var i = 0; i < 90; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.textContaining(fragmento).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Map<String, dynamic> _cierre({
  required String fecha,
  required String turno,
  required int tid,
  String nombre = 'Gabriel',
  double cobrado = 0,
  double cobradoUsd = 0,
}) =>
    {
      'fecha': fecha,
      'turno': turno,
      'telegram_id': tid,
      'entrenador_nombre': nombre,
      'cobrado': cobrado,
      'cobrado_usd': cobradoUsd,
      'pagos_count': 1,
      'cerrado_en': '${fecha}T12:00:00',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('itemsHistorialCajaPorDia (puro)', () {
    test('agrupa por día con totales CUP y USD sin mezclar', () {
      final items = itemsHistorialCajaPorDia([
        _cierre(fecha: '2026-11-10', turno: 'tarde', tid: 2, cobrado: 3000, cobradoUsd: 10),
        _cierre(fecha: '2026-11-10', turno: 'manana', tid: 1, cobrado: 2000),
        _cierre(fecha: '2026-11-08', turno: 'manana', tid: 1, cobrado: 1500),
      ]);
      // Cabecera + 2 filas + cabecera + 1 fila.
      expect(items.length, 5);
      final h1 = items[0] as Map<String, dynamic>;
      expect(h1['encabezado'], isTrue);
      expect(h1['dia'], '2026-11-10');
      expect(h1['cierres'], 2);
      expect(h1['cobrado'], 5000.0);
      expect(h1['cobrado_usd'], 10.0);
      final h2 = items[3] as Map<String, dynamic>;
      expect(h2['dia'], '2026-11-08');
      expect(h2['cierres'], 1);
      expect(h2['cobrado'], 1500.0);
      // El día sin movimientos (2026-11-09) no existe como grupo.
      expect(
          items.whereType<Map<String, dynamic>>().any((m) => m['dia'] == '2026-11-09'),
          isFalse);
    });

    test('cruce de medianoche: el instante UTC cae en su día habanero', () {
      final items = itemsHistorialCajaPorDia([
        // 2026-11-01T02:30Z = 2026-10-31 por la noche en La Habana.
        _cierre(fecha: '2026-11-01T02:30:00.000Z', turno: 'noche', tid: 1, cobrado: 700),
        _cierre(fecha: '2026-10-31', turno: 'tarde', tid: 1, cobrado: 300),
      ]);
      expect(items.length, 3);
      final h = items[0] as Map<String, dynamic>;
      expect(h['dia'], '2026-10-31');
      expect(h['cierres'], 2);
      expect(h['cobrado'], 1000.0);
    });

    test('fecha plana e instante con offset habanero se respetan', () {
      final items = itemsHistorialCajaPorDia([
        _cierre(fecha: '2026-11-10T23:30:00-04:00', turno: 'noche', tid: 1),
        _cierre(fecha: '2026-11-10', turno: 'manana', tid: 1),
      ]);
      expect(items.length, 3);
      expect((items[0] as Map<String, dynamic>)['dia'], '2026-11-10');
    });

    test('sin cierres, sin ítems', () {
      expect(itemsHistorialCajaPorDia(const []), isEmpty);
    });
  });

  group('HistorialCajaScreen (costura 420×800)', () {
    testWidgets('cabeceras por día, protagonistas y cobrado del espejo',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await _fijarSesion(
            email: 'jctr0602@ironbody.gym', telegramId: 735772141);
        final db = LocalDb.instance;
        await db.upsertMirror('turnos_cierre', 1, {
          'id': 1,
          'fecha': '2026-11-10',
          'turno': 'manana',
          'telegram_id': 1403501391,
          'entrenador_nombre': 'Gabriel',
          'pagos_count': 3,
          'cerrado_en': '2026-11-10T12:05:00',
        }, 1);
        await db.upsertMirror('turnos_cierre', 2, {
          'id': 2,
          'fecha': '2026-11-10',
          'turno': 'tarde',
          'telegram_id': 969869611,
          'entrenador_nombre': 'Duany',
          'pagos_count': 2,
          'cerrado_en': '2026-11-10T20:10:00',
        }, 2);
        await db.upsertMirror('turnos_cierre', 3, {
          'id': 3,
          'fecha': '2026-11-09',
          'turno': 'manana',
          'telegram_id': 1403501391,
          'entrenador_nombre': 'Gabriel',
          'pagos_count': 1,
          'cerrado_en': '2026-11-09T12:00:00',
        }, 3);
        // Pago en efectivo de la mañana de Gabriel: entra al
        // cobrado (H12); la transferencia NO (no es dinero
        // cobrado en el turno).
        await db.upsertMirror('pagos', 501, {
          'id': 501,
          'fecha': '2026-11-10',
          'hora': '09:15',
          'metodo': 'efectivo',
          'telegram_user_id': 1403501391,
          'monto': 2000,
        }, 4);
        await db.upsertMirror('pagos', 502, {
          'id': 502,
          'fecha': '2026-11-10',
          'hora': '09:45',
          'metodo': 'transferencia',
          'telegram_user_id': 1403501391,
          'monto': 2500,
        }, 5);
      });
      await tester.pumpWidget(
          const MaterialApp(home: HistorialCajaScreen()));
      expect(await _esperarTexto(tester, '10 de noviembre'), isTrue,
          reason: 'la cabecera del día más reciente se pinta en palabras');
      expect(await _esperarTexto(tester, '2 cierres'), isTrue,
          reason: 'la cabecera cuenta los cierres del día');
      expect(find.textContaining('${fmtMonto(2000)} CUP'), findsWidgets,
          reason: 'el total del día y la fila suman solo el efectivo');
      expect(find.text('Gabriel'), findsWidgets);
      expect(find.text('Duany'), findsOneWidget);
      expect(find.text('Mañana'), findsWidgets);
      expect(find.text('Tarde'), findsOneWidget);
      // El día anterior queda bajo el pliegue: se llega
      // desplazando y su cabecera trae su propio conteo.
      await tester.scrollUntilVisible(
          find.text('9 de noviembre'), 300);
      expect(find.text('9 de noviembre'), findsOneWidget);
      expect(find.textContaining('1 cierre ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
