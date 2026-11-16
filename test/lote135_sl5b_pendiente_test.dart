/// LOTE 1.35 · SL-5B (suplemento de Caja) — Pendiente.
///
/// - G04-1: embebida en Mi Caja, PendienteScreen NO monta
///   su propio SyncBanner (la sync se dice una sola vez,
///   en la cabecera del marco): el patrón de Bandeja
///   WhatsApp es `if (!widget.embebida)`.
/// - G04-2: la tarjeta total de Mi Caja no se pinta en
///   cero (regla de Jc: filas en cero no aparecen).
/// - G04-3: en la tarjeta del entrenador solo la acción
///   principal ocupa espacio permanente; las ocasionales
///   van plegadas tras un control que las resume, y al
///   desplegarlo están las cinco acciones.
///
/// Arnés: el de gestion129_oleada2 (FFI + sesión de
/// mentira + bombeo real intercalado).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/pendiente.dart';
import 'package:ironbody_gym/ui/widgets.dart';
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
  for (final t in [
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
    'ops_queue',
    'gastos',
    'liquidaciones_caja',
    'entregas_efectivo',
    'espejo_entregas_efectivo',
  ]) {
    await db.delete(t);
  }
  await db.delete('meta', where: 'k = ?', whereArgs: ['usuarios_apk']);
}

Future<void> _pumpReal(WidgetTester tester, {int vueltas = 10}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < vueltas; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 16));
    }
  });
}

/// Siembra el pendiente de Gabriel (tid 222222): un pago
/// diario de hoy en efectivo, como en GD-12.
Future<void> _sembrarGabriel() async {
  final db = LocalDb.instance;
  var seq = 9000;
  final hoy = hoyHabanaIso();
  await db.upsertMirror('pagos_diarios', 1, {
    'fecha': hoy,
    'total': 200,
    'metodo': 'efectivo',
    'registrado_por': 222222,
    'registrado_por_nombre': 'Gabriel',
  }, seq++);
  await db.setMeta(
    'usuarios_apk',
    jsonEncode([
      {'telegram_id': 222222, 'nombre': 'Gabriel', 'username': 'gabriel'},
    ]),
  );
}

Future<void> _abrirPendiente(WidgetTester tester,
    {bool embebida = false, bool conPendiente = false}) async {
  tester.view.physicalSize = const Size(824, 1830);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await _bdVacia();
    await _fijarSesion('jctr0602@ironbody.gym', 735772141);
    if (conPendiente) await _sembrarGabriel();
    await tester.pumpWidget(
        MaterialApp(home: PendienteScreen(embebida: embebida)));
  });
  await _pumpReal(tester, vueltas: 12);
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

  group('G04-1 · banner de sync solo fuera de embebida', () {
    testWidgets('embebida: ninguna voz de sync propia',
        (tester) async {
      await _abrirPendiente(tester, embebida: true);
      expect(find.byType(SyncBanner), findsNothing,
          reason: 'embebida, la sync la dice la cabecera del marco');
      expect(find.byType(SyncPill), findsNothing);
    });

    testWidgets('suelta: su banner, una sola voz', (tester) async {
      await _abrirPendiente(tester, embebida: false);
      expect(find.byType(SyncBanner), findsOneWidget);
    });
  });

  group('G04-2 · tarjeta total en cero no se pinta', () {
    testWidgets('sin pendiente: no hay tarjeta total',
        (tester) async {
      await _abrirPendiente(tester);
      expect(find.text('Nada pendiente de recoger.'), findsOneWidget,
          reason: 'la pantalla cargó y está en cero');
      expect(find.byType(MontoAnimado), findsNothing,
          reason: 'la tarjeta total (su MontoAnimado) no existe en cero');
      expect(find.text('al día, nada que recoger'), findsNothing);
    });

    testWidgets('con pendiente: la tarjeta total existe',
        (tester) async {
      await _abrirPendiente(tester, conPendiente: true);
      expect(find.byType(MontoAnimado), findsWidgets);
      expect(find.text('por recoger de los entrenadores'),
          findsOneWidget);
    });
  });

  group('G04-3 · acciones ocasionales plegadas', () {
    testWidgets('solo la principal ocupa espacio permanente; '
        'desplegando el control están las cinco', (tester) async {
      await _abrirPendiente(tester, conPendiente: true);
      // La tarjeta del entrenador arranca plegada: se abre.
      await tester.tap(find.text('Gabriel'));
      await _pumpReal(tester, vueltas: 6);
      // La principal, visible sin desplegar nada más.
      expect(find.textContaining('Cobrar todo'), findsOneWidget);
      // Las ocasionales NO ocupan espacio permanente.
      expect(find.text('Cobrar parcial'), findsNothing);
      expect(find.text('Liquidar con arrastre…'), findsNothing);
      expect(find.text('Liquidar en arqueo…'), findsNothing);
      expect(find.text('Cuadre a WhatsApp'), findsNothing);
      // El control que las resume, presente.
      final control = find.textContaining('Más acciones');
      expect(control, findsOneWidget);
      await tester.ensureVisible(control);
      await tester.tap(control);
      await _pumpReal(tester, vueltas: 6);
      // Desplegado: las cinco acciones, ninguna perdida.
      expect(find.text('Cobrar parcial'), findsOneWidget);
      expect(find.textContaining('Cobrar todo'), findsOneWidget);
      expect(find.text('Liquidar con arrastre…'), findsOneWidget);
      expect(find.text('Liquidar en arqueo…'), findsOneWidget);
      expect(find.text('Cuadre a WhatsApp'), findsOneWidget);
    });
  });
}
