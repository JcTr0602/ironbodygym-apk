/// Rediseño Suplementos 1.20: tests de widget de la lista y
/// el detalle SIN sesión de dueño (la sesión de dueño no es
/// fingible localmente: isOwner sale del email del JWT y el
/// Supabase de pruebas no emite sesiones — menú ⋮ del dueño,
/// Editar/Eliminar y switches se verifican en campo).
///
/// Harness: FFI sin isolate + preparación en runAsync (patrón
/// del banco v2), para que las lecturas del espejo completen.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
import 'package:ironbody_gym/ui/venta_suplemento.dart';
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
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // app_links (deep links de Supabase Auth): sin mock, la
    // activación de su canal de eventos lanza
    // MissingPluginException de forma intermitente y tumba el
    // test que esté corriendo.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(
                onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  testWidgets(
      'Lista: badge de stock bajo, presentación y contador con filtro',
      (tester) async {
    await _prepararBase(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('suplementos', 1, {
        'id': 1,
        'nombre': 'Proteína Banco',
        'stock': 2,
        'precio_oficial': 5000,
        'activo': 1,
        'moneda': 'CUP',
        'peso_valor': 300,
        'peso_unidad': 'g',
        'servicios_estandar': 60,
      }, 1);
      await LocalDb.instance.upsertMirror('suplementos', 2, {
        'id': 2,
        'nombre': 'Creatina Banco',
        'stock': 10,
        'precio_oficial': 3500,
        'activo': 1,
        'moneda': 'CUP',
      }, 2);
    });
    await tester.pumpWidget(
        const MaterialApp(home: SuplementosScreen()));
    await tester.pumpAndSettle();

    // Contador sin filtros y badge con la regla única (2 <= 3).
    expect(find.text('2 suplementos'), findsOneWidget);
    expect(find.text('Stock bajo · 2'), findsWidgets);
    expect(find.text('10 disponibles'), findsWidgets);
    // Presentación compartida con el detalle.
    expect(find.text('300 g · 60 servicios'), findsWidgets);

    // Con búsqueda activa el contador pasa a «M de N».
    await tester.enterText(
        find.byType(TextField).first, 'Creatina');
    await tester.pumpAndSettle();
    expect(find.text('1 de 2 suplementos'), findsOneWidget);
  });

  testWidgets(
      'Detalle sin stock: barra fija con «Sin stock» y venta completa',
      (tester) async {
    await _prepararBase(tester);
    await tester.pumpWidget(const MaterialApp(
      home: DetalleSuplementoScreen(
        suplemento: {
          'id': 7,
          'nombre': 'Proteína Agotada',
          'precio_oficial': 5000,
          'stock': 0,
          'activo': 1,
          'moneda': 'CUP',
        },
        categoriaNombre: 'Proteínas',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Sin stock'), findsWidgets);
    expect(find.text('Vender 1 unidad'), findsNothing);
    expect(find.text('Registrar venta completa'), findsOneWidget);
    // El primario está deshabilitado sin stock.
    final primario =
        tester.widget<BotonPrimario>(find.byType(BotonPrimario));
    expect(primario.onPressed, isNull);
    expect(primario.texto, 'Sin stock');
  });

  testWidgets(
      'Venta en USD: sin switch de fiado y total visible en la barra',
      (tester) async {
    await _prepararBase(tester);
    await tester.pumpWidget(const MaterialApp(
      home: VentaSuplementoScreen(suplemento: {
        'id': 9,
        'nombre': 'Proteína USD',
        'precio_oficial': 20,
        'stock': 10,
        'activo': 1,
        'moneda': 'USD',
      }),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Vender a fiado'), findsNothing);
    expect(find.text('Total'), findsOneWidget);
    expect(find.textContaining('20.00 USD'), findsWidgets);
    expect(find.text('Confirmar venta'), findsOneWidget);
    // El resumen del comprador vive bajo el selector (la
    // pantalla es una lista: hay que desplazar hasta él).
    for (var i = 0; i < 4; i++) {
      await tester.drag(
          find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(find.text('Comprador: sin seleccionar'), findsOneWidget);
  });

  testWidgets(
      'Venta en CUP: fiado visible y aviso de deuda al activarlo',
      (tester) async {
    await _prepararBase(tester);
    await tester.pumpWidget(const MaterialApp(
      home: VentaSuplementoScreen(suplemento: {
        'id': 10,
        'nombre': 'Creatina CUP',
        'precio_oficial': 3500,
        'stock': 10,
        'activo': 1,
        'moneda': 'CUP',
      }),
    ));
    await tester.pumpAndSettle();

    for (var i = 0; i < 4; i++) {
      await tester.drag(
          find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(find.text('Vender a fiado'), findsOneWidget);
    expect(find.text('Quedará registrada como deuda del cliente'),
        findsNothing);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.text('Quedará registrada como deuda del cliente'),
        findsOneWidget);
  });

  testWidgets(
      'F12 Duplicar: el editor abre en modo crear con los campos llenos y sin foto',
      (tester) async {
    await _prepararBase(tester);
    await tester.pumpWidget(const MaterialApp(
      home: EditarSuplementoScreen(plantilla: {
        'id': 42,
        'nombre': 'Proteína Original',
        'descripcion': 'Suero de leche',
        'precio_oficial': 5000,
        'stock': 7,
        'umbral_stock': 4,
        'peso_valor': 300,
        'peso_unidad': 'g',
        'servicios_estandar': 60,
        'activo': 1,
        'moneda': 'CUP',
        'foto_storage': 'proteina.webp',
        'foto_local': '/tmp/proteina.jpg',
      }),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Duplicar suplemento'), findsOneWidget);
    expect(find.text('Proteína Original'), findsOneWidget);
    expect(find.text('Crear suplemento'), findsOneWidget);
    // La foto NO se hereda: el selector ofrece agregar una.
    expect(find.text('Agregar foto'), findsOneWidget);
    expect(find.text('Foto pendiente de sincronizar'), findsNothing);
  });

  testWidgets('Detalle con stock: primario «Vender 1 unidad»',
      (tester) async {
    await _prepararBase(tester);
    await tester.pumpWidget(const MaterialApp(
      home: DetalleSuplementoScreen(
        suplemento: {
          'id': 8,
          'nombre': 'Creatina Banco',
          'precio_oficial': 3500,
          'stock': 5,
          'activo': 1,
          'moneda': 'CUP',
        },
        categoriaNombre: 'Creatinas',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Vender 1 unidad'), findsOneWidget);
    expect(find.text('Registrar venta completa'), findsOneWidget);
    expect(find.text('5 disponibles'), findsWidgets);
  });
}
