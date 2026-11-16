/// 1.35 (campo nº 13) — la cabecera del Directorio.
///
/// Dos reglas de Jc sobre su captura del Directorio
/// (la cabecera fija ocupaba más de la mitad de la
/// pantalla y el estado de sync se decía dos veces):
///  (a) la cabecera del pilar también se pliega al
///      bajar — las acciones colapsan con la histéresis
///      de UI-22 y la lista gana su alto;
///  (b) el estado de sync se dice UNA sola vez en toda
///      la app: embebidas en el pilar, las vistas no
///      pintan su banda de sync (manda la píldora de la
///      cabecera); sueltas, la banda se queda.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/pilar_clientes.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<double> _altoAcciones(WidgetTester t, bool plegadas) async {
  await t.pumpWidget(MaterialApp(
    theme: AppTema.tacticoOscuro(),
    home: Scaffold(
      body: Column(
        children: [
          AccionesPilarClientes(
            esDueno: true,
            plegadas: plegadas,
            onInscribir: () {},
            onAcceso: () {},
            onPapelera: () {},
          ),
        ],
      ),
    ),
  ));
  await t.pumpAndSettle();
  return t.getSize(find.byType(AccionesPilarClientes)).height;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('el plegado de las acciones del pilar', () {
    testWidgets('plenas: los tres destinos y su alto',
        (t) async {
      final alto = await _altoAcciones(t, false);
      expect(find.byKey(const ValueKey('clientes-inscribir')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('clientes-acceso')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('clientes-papelera')),
          findsOneWidget);
      expect(alto, greaterThan(40));
    });

    testWidgets('plegadas: desaparecen y el alto cae a '
        'cero', (t) async {
      final plena = await _altoAcciones(t, false);
      final plegada = await _altoAcciones(t, true);
      expect(find.byKey(const ValueKey('clientes-inscribir')),
          findsNothing);
      expect(plegada, 0);
      expect(plena - plegada, greaterThanOrEqualTo(40),
          reason: 'plegar ahorra la fila entera ($plena)');
    });

    testWidgets('sin dueño no hay papelera ni en plenas',
        (t) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: AccionesPilarClientes(
            esDueno: false,
            plegadas: false,
            onInscribir: () {},
            onAcceso: () {},
            onPapelera: () {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('clientes-papelera')),
          findsNothing);
      expect(find.byKey(const ValueKey('clientes-inscribir')),
          findsOneWidget);
    });
  });

  group('sync una sola vez: la banda embebida', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      const canalEventos =
          EventChannel('com.llfbandit.app_links/events');
      const canalMensajes =
          MethodChannel('com.llfbandit.app_links/messages');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(canalEventos,
              MockStreamHandler.inline(onListen: (_, __) {}));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(canalMensajes, (_) async => null);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', anonKey: 'dummy');
      } catch (_) {}
    });

    testWidgets('Buscar embebida: sin banda de sync',
        (t) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: const BuscarScreen(embebida: true),
      ));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(SyncBanner), findsNothing);
    });

    testWidgets('Buscar suelta: la banda es su voz de '
        'sync y se queda', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: const BuscarScreen(embebida: false),
      ));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(SyncBanner), findsOneWidget);
    });
  });

  group('contratos de fuente', () {
    test('las cuatro vistas del pilar atan su banda al '
        'modo embebido y el pilar pliega por scroll', () {
      final buscar = File('lib/ui/buscar.dart').readAsStringSync();
      expect(buscar, contains('if (!widget.embebida)'));
      final listas = File('lib/ui/listas.dart').readAsStringSync();
      expect(listas,
          contains('if (!widget.embebida) const SyncBanner'));
      final invitados =
          File('lib/ui/invitados.dart').readAsStringSync();
      expect(invitados,
          contains('if (!widget.embebido) const SyncBanner'));
      final bandeja =
          File('lib/ui/bandeja_whatsapp.dart').readAsStringSync();
      expect(bandeja,
          contains('if (!widget.embebida) const SyncBanner'));
      final pilar =
          File('lib/ui/pilar_clientes.dart').readAsStringSync();
      expect(pilar,
          contains('NotificationListener<ScrollNotification>'));
      expect(pilar, contains('_accionesPlegadas'));
      expect(pilar, contains('p > 140'));
      expect(pilar, contains('p < 60'));
    });
  });
}
