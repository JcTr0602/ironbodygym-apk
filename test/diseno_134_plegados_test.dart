/// 1.34 · CARRIL DISEÑO — arnés de CAPTURAS para la compuerta
/// visual de Jc (NO es un golden de regresión: vuelca PNG reales
/// a ~/workspace/cola-123/gestion/134_diseno_capturas/ y Jc juzga
/// las imágenes antes de cualquier build).
///
/// Fase por --dart-define=FASE=antes|despues (defecto: antes):
/// «antes» se genera con la RAMA en la base 3a615ed (1.33) y
/// «después» con los plegados C-48 aplicados.
///
/// ESCRIBIR las capturas exige la bandera explícita
/// --dart-define=DISENO134_CAPTURAS=true. Sin ella los tests
/// corren como humo pero _capturar no toca el disco: una corrida
/// ordinaria de la suite JAMÁS pisa la evidencia de la compuerta
/// visual (lección de la 1.33).
///
/// Superficies: las 6 pantallas de los plegados C-48 (Auditoría,
/// Historial de ventas, Historial de servicios, Liquidaciones,
/// Control de acceso, Suplementos) y Servicios (zona del pomo,
/// por la adjudicación del desborde a 360 dp).
///
/// Arnés de la casa: Roboto REAL del SDK nombrada en el tema y
/// en cada componente (la app no declara fuente: en el teléfono
/// manda la Roboto del sistema), sesión de dueño con JWT falso,
/// BD de test (IRONBODY_TEST_DB=1) y viewport de teléfono real.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/actividad_cliente.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:ironbody_gym/ui/control_acceso.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';
import 'package:ironbody_gym/ui/liquidaciones_historial.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:ironbody_gym/ui/servicios_historial.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';



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
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 16, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}


Future<void> _cerrarCascara(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _cargarRobotoReal() async {
  const dir =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf'
  ]) {
    final bytes = await File('$dir/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  // La fuente de iconos Material tampoco viaja al host de
  // test: sin cargarla, los iconos se pintan como huecos y
  // la captura no sirve para juzgar el diseño.
  final iconos = FontLoader('MaterialIcons');
  final otf = await File('$dir/MaterialIcons-Regular.otf').readAsBytes();
  iconos.addFont(Future.value(ByteData.view(otf.buffer)));
  await iconos.load();
}

void _telefono(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// El tema de la captura: las superficies y colores REALES
/// de AppTema.tacticoOscuro() (pizarra/grafito/acero y sus
/// temas de componentes, leídos del objeto tema) con la
/// Roboto nombrada como familia — la pauta del arnés
/// matriz: en el teléfono la familia sale del sistema y
/// TODO texto la hereda; en el host, los estilos de texto
/// EXPLÍCITOS de los temas de componentes (título del
/// AppBar, botones elevados/con contorno/de texto, chips)
/// no heredan la familia del constructor y se pintarían
/// como huecos: aquí se les nombra la Roboto uno a uno,
/// sin tocar ni un color ni una métrica.
TextStyle _rob(TextStyle? s) =>
    (s ?? const TextStyle()).copyWith(fontFamily: 'Roboto');

ButtonStyle _robBoton(ButtonStyle? s) {
  if (s == null) return const ButtonStyle();
  final ts = s.textStyle?.resolve(<WidgetState>{});
  if (ts == null) return s;
  return s.copyWith(textStyle: WidgetStatePropertyAll(_rob(ts)));
}

ThemeData _temaCaptura() {
  final t = AppTema.tacticoOscuro();
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Roboto',
    brightness: t.brightness,
    colorScheme: t.colorScheme,
    scaffoldBackgroundColor: t.scaffoldBackgroundColor,
    appBarTheme:
        t.appBarTheme.copyWith(titleTextStyle: _rob(t.appBarTheme.titleTextStyle)),
    cardTheme: t.cardTheme,
    dialogTheme:
        t.dialogTheme.copyWith(titleTextStyle: _rob(t.dialogTheme.titleTextStyle)),
    bottomSheetTheme: t.bottomSheetTheme,
    navigationBarTheme: t.navigationBarTheme,
    segmentedButtonTheme: t.segmentedButtonTheme,
    filledButtonTheme: t.filledButtonTheme,
    elevatedButtonTheme:
        ElevatedButtonThemeData(style: _robBoton(t.elevatedButtonTheme.style)),
    outlinedButtonTheme:
        OutlinedButtonThemeData(style: _robBoton(t.outlinedButtonTheme.style)),
    textButtonTheme:
        TextButtonThemeData(style: _robBoton(t.textButtonTheme.style)),
    chipTheme: t.chipTheme.copyWith(
        labelStyle: _rob(t.chipTheme.labelStyle),
        secondaryLabelStyle: _rob(t.chipTheme.secondaryLabelStyle)),
    switchTheme: t.switchTheme,
    inputDecorationTheme: t.inputDecorationTheme.copyWith(
        labelStyle: _rob(t.inputDecorationTheme.labelStyle),
        floatingLabelStyle: _rob(t.inputDecorationTheme.floatingLabelStyle),
        hintStyle: _rob(t.inputDecorationTheme.hintStyle),
        errorStyle: _rob(t.inputDecorationTheme.errorStyle),
        helperStyle: _rob(t.inputDecorationTheme.helperStyle)),
    popupMenuTheme:
        t.popupMenuTheme.copyWith(textStyle: _rob(t.popupMenuTheme.textStyle)),
    listTileTheme: t.listTileTheme,
    dividerTheme: t.dividerTheme,
    snackBarTheme: t.snackBarTheme
        .copyWith(contentTextStyle: _rob(t.snackBarTheme.contentTextStyle)),
    floatingActionButtonTheme: t.floatingActionButtonTheme,
    progressIndicatorTheme: t.progressIndicatorTheme,
    textTheme: t.textTheme,
    primaryTextTheme: t.primaryTextTheme,
    pageTransitionsTheme: t.pageTransitionsTheme,
  );
}



Future<void> _descartarDialogos(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    final hay = find.byType(AlertDialog).evaluate().isNotEmpty ||
        find.byType(Dialog).evaluate().isNotEmpty;
    if (!hay) break;
    Navigator.of(tester.element(find.byType(Navigator).first))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await _cargarRobotoReal();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('diseno134_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  // Siembra común: sesión de dueño, usuarios del espejo y
  // clientes/productos base.
  Future<void> sembrarBase(WidgetTester tester) async {
    await _sesionDueno(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 735772141, 'nombre': 'Tú (Jc)', 'rol': 'dueno'},
            {
              'telegram_id': 969869611,
              'nombre': 'Duany',
              'rol': 'entrenador'
            },
            {
              'telegram_id': 1403501391,
              'nombre': 'Gabriel',
              'rol': 'entrenador'
            },
          ]));
      await LocalDb.instance.upsertMirror('clientes', 5, {
        'id': 5,
        'nombre': 'Ana Prueba',
        'telefono': '53000005',
        'activo': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('clientes', 7, {
        'id': 7,
        'nombre': 'Beto Ejemplo',
        'telefono': '53000007',
        'activo': 1,
      }, 1);
    });
  }

  Future<void> montar(WidgetTester tester, Widget pantalla) async {
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: pantalla,
    ));
    await _drenar(tester);
  }

  group('G-01 Auditoría', () {
    testWidgets('el botón resume el alcance; la hoja lo cambia '
        'y el recorte Hoy entra en el resumen', (tester) async {
      _telefono(tester);
      await sembrarBase(tester);
      final hoy = ahoraHabana();
      final ayer = sumarDiasCalendario(hoy, -1);
      String ts(DateTime d, int h) =>
          isoHabana(DateTime(d.year, d.month, d.day, h, 15));
      await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        Future<void> op(String uuid, String tipo, String estado,
            String cuando, Map<String, dynamic> payload) async {
          await db.insert('ops_queue', {
            'op_uuid': uuid,
            'tipo': tipo,
            'payload': jsonEncode(payload),
            'estado': estado,
            'creada_ts': cuando,
          });
        }

        await op('a1', 'pago_mensual', 'aplicada', ts(hoy, 9),
            {'cliente_id': 5, 'monto': 2000, 'metodo': 'efectivo'});
        await op('a2', 'inscribir', 'pendiente', ts(hoy, 10),
            {'cliente_id': 7, 'nombre': 'Beto Ejemplo'});
        await op('a3', 'gasto', 'aplicada', ts(ayer, 18),
            {'concepto': 'Luz del local', 'monto': 500});
      });
      await montar(
          tester,
          AuditoriaScreen(
            servicioActividad:
                ActividadClienteService(rpcParaTest: (_) async => []),
          ));
      // Estado por defecto: el botón nombra el alcance inicial
      // y NO quedan chips sueltos en la pantalla.
      expect(find.text('Filtrar · Otros y alertas'), findsOneWidget);
      // Los chips de filtro ya no viven sueltos en la pantalla
      // (la sección de actividad del servidor conserva los
      // suyos, que no son de este plegado).
      expect(find.widgetWithText(ChoiceChip, 'Otros y alertas'),
          findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Hoy'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Por entrenador'),
          findsNothing);
      expect(find.textContaining('Beto Ejemplo'), findsNothing,
          reason: 'la inscripción rutinaria propia queda fuera '
              'en «Otros y alertas»');
      // La hoja cambia el alcance a «Todo» y se aplica.
      await tester.tap(find.text('Filtrar · Otros y alertas'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Alcance'), findsOneWidget);
      // Acotado a la hoja: la pantalla también tiene un
      // «Todo» propio en la sección de actividad del servidor.
      await tester.tap(find.descendant(
          of: find.byType(BottomSheet), matching: find.text('Todo')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Aplicar'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Filtrar · Todo'), findsOneWidget);
      expect(find.textContaining('Beto Ejemplo'), findsWidgets,
          reason: 'en «Todo» la inscripción ya se ve');
      // Recorte «Solo hoy»: entra en el resumen y el gasto de
      // ayer sale de la lista.
      await tester.tap(find.text('Filtrar · Todo'));
      await _drenar(tester, vueltas: 6);
      await tester.tap(find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Solo hoy')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Aplicar'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Filtrar · Todo · Hoy'), findsOneWidget);
      expect(find.textContaining('Luz del local'), findsNothing);
      await _descartarDialogos(tester);
      await _cerrarCascara(tester);
    });

    testWidgets('Yunque 1.34 (C2-5): a 360 dp con texto 1.3 '
        'el botón de filtros admite 2 líneas y no desborda',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await sembrarBase(tester);
      // La misma siembra de ops del test G-01: sin actividad
      // la pantalla no compone aún el botón de filtros.
      final hoyC25 = ahoraHabana();
      await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        await db.insert('ops_queue', {
          'op_uuid': 'c25-1',
          'tipo': 'pago_mensual',
          'payload': jsonEncode(
              {'cliente_id': 5, 'monto': 2000, 'metodo': 'efectivo'}),
          'estado': 'aplicada',
          'creada_ts': isoHabana(
              DateTime(hoyC25.year, hoyC25.month, hoyC25.day, 9, 15)),
        });
      });
      await tester.pumpWidget(MaterialApp(
        theme: _temaCaptura(),
        home: MediaQuery(
          data: const MediaQueryData(
              textScaler: TextScaler.linear(1.3)),
          child: AuditoriaScreen(
            servicioActividad:
                ActividadClienteService(rpcParaTest: (_) async => []),
          ),
        ),
      ));
      await _drenar(tester);
      expect(tester.takeException(), isNull);
      final etiqueta =
          tester.widget<Text>(find.text('Filtrar · Otros y alertas'));
      expect(etiqueta.maxLines, 2,
          reason: 'el resumen no se elide a 1 línea (C2-5)');
      await _cerrarCascara(tester);
    });
  });

  group('G-02 Historial de ventas', () {
    testWidgets('el botón resume «Todos» (Yunque 2.34, F-7: '
        'gramática corta); la hoja filtra por moneda y el '
        'resumen lo nombra', (tester) async {
      _telefono(tester);
      await sembrarBase(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('suplementos', 1, {
          'id': 1,
          'nombre': 'Proteína Suero X',
          'precio_cup': 4500,
          'activo': 1,
        }, 1);
        await LocalDb.instance.upsertMirror('suplementos', 2, {
          'id': 2,
          'nombre': 'Creatina Monohidrato',
          'precio_cup': 3200,
          'activo': 1,
        }, 1);
        await LocalDb.instance.upsertMirror('ventas_suplementos', 1, {
          'id': 1,
          'suplemento_id': 1,
          'cliente_id': 5,
          'cantidad': 1,
          'precio_total': 4500,
          'moneda': 'CUP',
          'fecha': hoyHabanaIso(),
          'vendedor_id': 735772141,
        }, 1);
        await LocalDb.instance.upsertMirror('ventas_suplementos', 2, {
          'id': 2,
          'suplemento_id': 2,
          'cliente_id': 7,
          'cantidad': 2,
          'precio_total': 6400,
          'moneda': 'USD',
          'fecha': hoyHabanaIso(),
          'vendedor_id': 969869611,
        }, 1);
      });
      await montar(tester, const HistorialVentasScreen());
      expect(find.text('Filtrar · Todos'), findsOneWidget);
      expect(find.text('Proteína Suero X'), findsWidgets);
      expect(find.text('Creatina Monohidrato'), findsWidgets);
      await tester.tap(find.text('Filtrar · Todos'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Moneda'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'USD'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Aplicar'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Filtrar · Todos · USD'), findsOneWidget);
      expect(find.text('Creatina Monohidrato'), findsWidgets);
      expect(find.text('Proteína Suero X'), findsNothing,
          reason: 'con moneda USD la venta en CUP sale de la lista');
      await _descartarDialogos(tester);
      await _cerrarCascara(tester);
    });
  });

  group('G-03 Historial de servicios', () {
    testWidgets('el botón resume «Todas»; la hoja filtra por '
        'tipo y el resumen lo nombra', (tester) async {
      _telefono(tester);
      await sembrarBase(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('suplementos', 1, {
          'id': 1,
          'nombre': 'Proteína Suero X',
          'activo': 1,
        }, 1);
        await LocalDb.instance.upsertMirror('servicio_pomos', 10, {
          'id': 10,
          // Yunque 3.34 (K4-1): forma REAL del espejo
          // servicio_pomos (corrección E-2 de Y2): el nombre
          // del pomo sale de suplemento_id y el responsable
          // de es_principal/titular_telegram_id
          // (lib/servicios.dart:243-250). producto_id /
          // responsable_id no los trae la fila: sin
          // suplemento_id el pomo se resolvía como
          // «Suplemento» genérico.
          'suplemento_id': 1,
          'titular_telegram_id': 735772141,
          'es_principal': 1,
          'dosis_asignadas': 60,
          'activo': 1,
        }, 1);
        await LocalDb.instance.upsertMirror('servicio_ventas', 1, {
          'id': 1,
          'pomo_id': 10,
          'cliente_id': 5,
          'cliente_nombre': 'Ana Prueba',
          'tipo': 'dosis_con_agua',
          'cantidad': 1,
          'precio_unitario': 900,
          'vendedor_id': 735772141,
          'fecha': hoyHabanaIso(),
          'hora': '10:00',
        }, 1);
        await LocalDb.instance.upsertMirror('servicio_ventas', 2, {
          'id': 2,
          'pomo_id': 10,
          'cliente_id': 7,
          'cliente_nombre': 'Beto Ejemplo',
          'tipo': 'agua_suelta',
          'cantidad': 1,
          'precio_unitario': 300,
          'vendedor_id': 969869611,
          'fecha': hoyHabanaIso(),
          'hora': '11:00',
        }, 1);
      });
      await montar(
          tester,
          const ServiciosHistorialScreen(
            esDueno: true,
            personas: {
              735772141: 'Tú (Jc)',
              969869611: 'Duany',
              1403501391: 'Gabriel',
            },
          ));
      expect(find.text('Filtrar · Todas'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.textContaining('Ana Prueba'), findsWidgets);
      expect(find.textContaining('Beto Ejemplo'), findsWidgets);
      await tester.tap(find.text('Filtrar · Todas'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Tipo'), findsOneWidget);
      await tester.tap(find.text('Agua'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Aplicar'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Filtrar · Agua'), findsOneWidget);
      expect(find.textContaining('Beto Ejemplo'), findsWidgets);
      expect(find.textContaining('Ana Prueba'), findsNothing,
          reason: 'con tipo Agua la dosis con agua sale de la lista');
      // Yunque 3.34 (K4-1): el detalle de la venta nombra el
      // pomo por su producto REAL: la fila «Pomo» sale de
      // nombrePomoVenta → producto_nombre, resuelto por
      // suplemento_id (lib/servicios.dart:243-250, 382-391).
      // Con la forma falsa de E-2 (producto_id) el pomo se
      // resolvía como «Suplemento» genérico y esta aserción
      // habría nacido muerta.
      await tester.tap(find.text('Beto Ejemplo'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Pomo'), findsOneWidget);
      expect(find.text('Proteína Suero X'), findsOneWidget,
          reason: 'el pomo del detalle se resuelve por '
              'suplemento_id al suplemento sembrado');
      await _descartarDialogos(tester);
      await _cerrarCascara(tester);
    });
  });

  group('G-04 Liquidaciones', () {
    testWidgets('el botón «Mes · Todos» abre la hoja de meses '
        'y tocar un mes lo aplica', (tester) async {
      _telefono(tester);
      await sembrarBase(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('liquidaciones_caja', 1, {
          'id': 1,
          'entrenador_nombre': 'Duany',
          'entrenador_telegram_id': 969869611,
          'monto_entregado': 12000,
          'monto_esperado': 12000,
          'moneda': 'CUP',
          'creada_en': '2026-11-05T10:00:00-05:00',
        }, 1);
        await LocalDb.instance.upsertMirror('liquidaciones_caja', 2, {
          'id': 2,
          'entrenador_nombre': 'Gabriel',
          'entrenador_telegram_id': 1403501391,
          'monto_entregado': 8400,
          'monto_esperado': 8400,
          'moneda': 'CUP',
          'creada_en': '2026-10-31T10:00:00-05:00',
        }, 1);
        await LocalDb.instance.upsertMirror('liquidaciones_caja', 3, {
          'id': 3,
          'entrenador_nombre': 'Duany',
          'entrenador_telegram_id': 969869611,
          'monto_entregado': 5000,
          'monto_esperado': 5000,
          'moneda': 'CUP',
          'creada_en': '2026-09-30T10:00:00-05:00',
        }, 1);
      });
      await montar(tester, const LiquidacionesHistorialScreen());
      expect(find.text('Mes · Todos'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      await tester.tap(find.text('Mes · Todos'));
      await _drenar(tester, vueltas: 6);
      // La hoja lista los meses en orden inverso (noviembre
      // primero): se toca octubre y aplica al cerrar.
      await tester.tap(find.text('Octubre 2026'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Mes · Octubre 2026'), findsOneWidget);
      expect(find.text('Gabriel'), findsWidgets);
      expect(find.text('Duany'), findsNothing,
          reason: 'con el mes de octubre solo queda Gabriel');
      await _descartarDialogos(tester);
      await _cerrarCascara(tester);
    });
  });

  group('G-06 Control de acceso', () {
    testWidgets('el botón «Filtrar» resume el interruptor '
        'activo y la lista se recorta', (tester) async {
      _telefono(tester);
      await sembrarBase(tester);
      await tester.runAsync(() async {
        final filasAcceso = <Map<String, dynamic>>[
          {
            'cliente_id': 5,
            'nombre': 'Ana Prueba',
            'telefono': '53000005',
            'activo': true,
            'debe_cambiar_pin': true,
            'ultimo_acceso_en': DateTime.now()
                .subtract(const Duration(days: 40))
                .toIso8601String(),
            'created_at': '2026-09-01T00:00:00Z',
            'token_version': 1,
          },
          {
            'cliente_id': 7,
            'nombre': 'Beto Ejemplo',
            'telefono': '53000007',
            'activo': true,
            'ultimo_acceso_en': DateTime.now().toIso8601String(),
            'created_at': '2026-10-01T00:00:00Z',
            'token_version': 1,
          },
        ];
        await LocalDb.instance.setMeta(
            'acceso_app_cache_v1',
            jsonEncode({
              'filas': filasAcceso,
              'verificado_en': DateTime.now().toIso8601String(),
            }));
      });
      await montar(tester, const ControlAccesoScreen());
      // El hub abre en «Entrenadores»: el plegado vive en la
      // pestaña «Clientes».
      await tester.tap(find.text('Clientes'));
      await _drenar(tester, vueltas: 8);
      expect(find.text('Filtrar'), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.text('2 accesos'), findsOneWidget);
      await tester.tap(find.text('Filtrar'));
      await _drenar(tester, vueltas: 6);
      await tester.tap(find.text('PIN sin cambiar'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Aplicar'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Filtrar · PIN sin cambiar'), findsOneWidget);
      expect(find.text('1 accesos'), findsOneWidget,
          reason: 'solo Ana tiene el PIN pendiente');
      await _descartarDialogos(tester);
      await _cerrarCascara(tester);
    });
  });

  group('G-07 Suplementos (parcial)', () {
    testWidgets('la categoría se queda en la fila y el stock '
        'se pliega en su botón con hoja', (tester) async {
      _telefono(tester);
      await sembrarBase(tester);
      await tester.runAsync(() async {
        await LocalDb.instance
            .upsertMirror('categorias_suplemento', 1, {
          'id': 1,
          'nombre': 'Proteínas',
        }, 1);
        await LocalDb.instance.upsertMirror('suplementos', 1, {
          'id': 1,
          'nombre': 'Proteína Suero X',
          'precio_cup': 4500,
          'stock': 40,
          'stock_dosis': 40,
          'categoria_id': 1,
          'activo': 1,
        }, 1);
        await LocalDb.instance.upsertMirror('suplementos', 3, {
          'id': 3,
          'nombre': 'Omega Agotado',
          'precio_cup': 2000,
          'stock': 0,
          'stock_dosis': 0,
          'categoria_id': 1,
          'activo': 1,
        }, 1);
      });
      await montar(tester, const SuplementosScreen());
      expect(find.text('Stock · Todos'), findsOneWidget);
      // La categoría SIGUE en su fila (plegado parcial).
      expect(find.widgetWithText(ChoiceChip, 'Todas'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Agotados'), findsNothing);
      await tester.tap(find.text('Stock · Todos'));
      await _drenar(tester, vueltas: 6);
      await tester.tap(find.text('Agotados'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Stock · Agotados'), findsOneWidget);
      expect(find.text('Omega Agotado'), findsWidgets);
      expect(find.text('Proteína Suero X'), findsNothing,
          reason: 'con stock «Agotados» la proteína con stock sale');
      await _descartarDialogos(tester);
      await _cerrarCascara(tester);
    });
  });

  group('Servicios · desborde 360 dp ×1.3 (métricas reales)',
      () {
    testWidgets('la pantalla sola no desborda con la Roboto '
        'real (adjudicación del artefacto del arnés B-4)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(
          () => tester.platformDispatcher.clearTextScaleFactorTestValue());
      await sembrarBase(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('suplementos', 1, {
          'id': 1,
          'nombre': 'Proteína Suero X',
          'precio_cup': 4500,
          'dosis_precio': 600,
        }, 1);
        await LocalDb.instance.upsertMirror('servicio_pomos', 10, {
          'id': 10,
          'suplemento_id': 1,
          'titular_telegram_id': 111222333,
          'es_principal': 0,
          'dosis_asignadas': 40,
          'dosis_repartidas': 0,
          'activo': 1,
        }, 1);
        await LocalDb.instance.setMeta(
            'usuarios_apk',
            jsonEncode([
              {
                'telegram_id': 735772141,
                'nombre': 'Tú (Jc)',
                'rol': 'dueno'
              },
              {
                'telegram_id': 111222333,
                'nombre': 'Gabriel Alejandro Fernández Domínguez',
                'rol': 'entrenador'
              },
            ]));
      });
      await tester.pumpWidget(MaterialApp(
        theme: _temaCaptura(),
        home: const ServiciosScreen(),
      ));
      // Drenar recogiendo TODAS las excepciones: con las
      // métricas reales no debe quedar ninguna de layout.
      final excepciones = <Object>[];
      for (var i = 0; i < 16; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        });
        await tester.pump(const Duration(milliseconds: 50));
        var e = tester.takeException();
        while (e != null) {
          excepciones.add(e);
          e = tester.takeException();
        }
      }
      expect(find.text('Salida sin venta'), findsOneWidget,
          reason: 'la pantalla montó la zona del pomo del dueño');
      expect(excepciones, isEmpty,
          reason: 'con la Roboto real no hay desborde a 360×1.3: '
              'el de 76 px era la fuente de test del arnés B-4');
      await _descartarDialogos(tester);
      await _cerrarCascara(tester);
    });
  });
}
