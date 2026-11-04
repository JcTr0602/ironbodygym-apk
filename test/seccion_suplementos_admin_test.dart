/// 1.23 (backlog de campo): TODA la administración de
/// suplementos a mano en la sección.
///
/// - SeccionSuplementosScreen (Panel del dueño) enlaza también
///   Dosis y botes, Reservas, Fiados por cobrar y Sin foto o sin
///   precio — antes solo se llegaba saltando a otras zonas.
/// - El menú ⋮ de SuplementosScreen ofrece «Administrar dosis y
///   botes» SOLO al dueño: sin sesión de dueño (la sesión de
///   dueño no es fingible localmente: isOwner sale del email del
///   JWT) la entrada no existe, igual que «Categorías».
///
/// Harness: FFI sin isolate + preparación en runAsync (patrón
/// del banco v2 / suplementos_rediseno_test).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/admin_secciones.dart';
import 'package:ironbody_gym/ui/panel_bloque2.dart';
import 'package:ironbody_gym/ui/reservas.dart';
import 'package:ironbody_gym/ui/servicios_admin.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _prepararBase(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'test_seccion_suplementos_admin.db'))
          .delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });
}

void main() {
  // Higiene (nota de Argón al APTO del backlog): BD propia del
  // test — sin nombre forzado, _prepararBase borraba el
  // ironbody.db por defecto y la suite en paralelo podía
  // cruzarlo con otro test.
  LocalDb.nombreArchivoDbForzado = 'test_seccion_suplementos_admin.db';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  testWidgets(
      'Sección Suplementos del Panel: enlaces de administración '
      'completos y navegando a su pantalla', (tester) async {
    Widget? destino;
    Future<void> ir(Widget w) async => destino = w;
    await tester.pumpWidget(MaterialApp(
      home: SeccionSuplementosScreen(onIr: ir),
    ));
    await tester.pumpAndSettle();

    // Lo que ya había.
    expect(find.text('Gestionar catálogo'), findsOneWidget);
    expect(find.text('Categorías'), findsOneWidget);
    expect(find.text('Historial de ventas'), findsOneWidget);
    // Lo nuevo de la 1.23.
    expect(find.text('Dosis y botes'), findsOneWidget);
    expect(find.text('Reservas'), findsOneWidget);
    expect(find.text('Fiados por cobrar'), findsOneWidget);
    expect(find.text('Sin foto o sin precio'), findsOneWidget);

    // Flujo básico: cada botón nuevo abre SU pantalla.
    await tester.ensureVisible(find.text('Dosis y botes'));
    await tester.tap(find.text('Dosis y botes'));
    expect(destino, isA<ServiciosAdminScreen>());

    await tester.ensureVisible(find.text('Reservas'));
    await tester.tap(find.text('Reservas'));
    expect(destino, isA<ReservasScreen>());

    await tester.ensureVisible(find.text('Sin foto o sin precio'));
    await tester.tap(find.text('Sin foto o sin precio'));
    expect(destino, isA<SinFotoPrecioScreen>());
  });

  testWidgets(
      'Catálogo sin rol dueño: el menú ⋮ NO ofrece las opciones '
      'de administración del dueño', (tester) async {
    // La fuente de prueba mide cada carácter a 1 em (mucho más
    // ancha que Roboto) y la fila «Servicios ⚡ por dosis» del
    // menú ⋮ desborda en el ancho del popup; en campo no pasa.
    // Se reduce la escala de texto SOLO en este test para poder
    // abrir el menú y verificar su contenido.
    await _prepararBase(tester);
    await tester.pumpWidget(MaterialApp(
      // El builder envuelve también al Navigator: la ruta del
      // menú hereda esta escala (un MediaQuery sobre home no).
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.7)),
        child: child!,
      ),
      home: const SuplementosScreen(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();

    // Lo de siempre para cualquier rol.
    expect(find.text('Mis ventas'), findsOneWidget);
    expect(find.text('Servicios ⚡ por dosis'), findsOneWidget);
    // Solo dueño: ni lo viejo (Categorías) ni lo nuevo.
    expect(find.text('Categorías'), findsNothing);
    expect(find.text('Administrar dosis y botes'), findsNothing);
  });
}
