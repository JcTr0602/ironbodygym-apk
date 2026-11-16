/// SL-8 · G08-3: la tarjeta del espejo vacío. Su botón
/// «Sincronizar ahora» solo EMPUJABA (push) cuando el
/// problema es un espejo vacío que necesita BAJADA, y el
/// aviso «Datos recuperados. Ya se ven los clientes.» se
/// afirmaba sin comprobar el espejo.
///
/// Corrección: el botón ejecuta el ciclo completo (bajada
/// incluida) y el aviso de recuperación solo se dice tras
/// comprobar que el espejo ya tiene filas; si sigue vacío,
/// la tarjeta lo dice.
///
/// La costura [TarjetaDiagnosticoEspejo.cicloSyncParaTest]
/// sustituye el ciclo del motor en el test: el «pull que
/// trae clientes» se simula sembrando el espejo durante el
/// ciclo, que es exactamente el efecto observable de una
/// bajada buena.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diagnostico_espejo.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/diagnostico_espejo_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _esperarTexto(
    WidgetTester t, String texto, {int intentos = 60}) async {
  for (var i = 0;
      i < intentos && find.textContaining(texto).evaluate().isEmpty;
      i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_sl8_g08_3.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDb.resetParaTest();
    final d = await LocalDb.instance.db;
    await d.delete('clientes');
    // Espejo vacío CON testigo: la tarjeta debe salir.
    await registrarTestigoClientes(7);
  });

  Future<void> sembrarClientes(WidgetTester t, int n) async {
    await t.runAsync(() async {
      final d = await LocalDb.instance.db;
      for (var i = 1; i <= n; i++) {
        await d.insert(
            'clientes', {'id': i, 'data': '{}', 'sync_seq': i});
      }
    });
  }

  testWidgets('pull que trae clientes: avisa SOLO con filas en el espejo',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TarjetaDiagnosticoEspejo(
          cicloSyncParaTest: () async {
            // La «bajada» del ciclo: el espejo recibe filas.
            final d = await LocalDb.instance.db;
            for (var i = 1; i <= 3; i++) {
              await d.insert(
                  'clientes', {'id': i, 'data': '{}', 'sync_seq': i});
            }
          },
        ),
      ),
    ));
    await _esperarTexto(t, 'Los clientes aparecen en cero');
    expect(find.text('Sincronizar ahora'), findsOneWidget);
    await t.tap(find.text('Sincronizar ahora'));
    await _esperarTexto(t, 'Datos recuperados');
    expect(find.textContaining('Datos recuperados. Ya se ven los clientes.'),
        findsOneWidget,
        reason: 'con filas en el espejo, el aviso de '
            'recuperación es verdad y se dice');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('pull sin filas: avisa que el espejo sigue vacío',
      (t) async {
    await sembrarClientes(t, 0);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TarjetaDiagnosticoEspejo(
          cicloSyncParaTest: () async {
            // El ciclo corre y no baja ningún cliente.
          },
        ),
      ),
    ));
    await _esperarTexto(t, 'Los clientes aparecen en cero');
    await t.tap(find.text('Sincronizar ahora'));
    await _esperarTexto(t, 'sigue vacía');
    expect(find.textContaining('sigue vacía'), findsOneWidget,
        reason: 'sin filas tras el ciclo, la tarjeta dice la '
            'verdad en vez de afirmar una recuperación');
    expect(find.textContaining('Datos recuperados'), findsNothing,
        reason: 'jamás se afirma «recuperados» sin comprobarlo');
    await t.pumpWidget(const SizedBox());
  });
}
