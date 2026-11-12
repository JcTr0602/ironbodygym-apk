/// 1.33 · PASADA DE DISEÑO — arnés de CAPTURAS para aprobación
/// de Jc (NO es un golden de regresión: vuelca PNG reales a
/// ~/workspace/cola-123/gestion/diseno_133_capturas/ y Jc juzga
/// las imágenes antes de cualquier build).
///
/// Fase por --dart-define=FASE=antes|despues (defecto: antes).
/// Superficies: la bandeja «Por Decidir» con conteos inyectados,
/// el Pilar Negocio en su pestaña Caja, el Mostrador completo
/// del dueño (orden de secciones) y la ficha del cliente
/// expandida y tras bajar (cabecera compacta / plegable).
///
/// Arnés calcado del de compuertas_132_matriz_test.dart:
/// Roboto REAL del SDK (la app no declara fuente: en el
/// teléfono manda la Roboto del sistema), sesión de dueño con
/// JWT falso, BD de test (IRONBODY_TEST_DB=1) y viewport de
/// teléfono real 420×800. El tema es el REAL de las capturas
/// de Jc: AppTema.tacticoOscuro().
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/pilar_negocio.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _fase = String.fromEnvironment('FASE', defaultValue: 'antes');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/diseno_133_capturas';

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

Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(seconds: 65));
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

Future<void> _capturar(
    WidgetTester tester, GlobalKey key, String nombre) async {
  await tester.pump(const Duration(milliseconds: 120));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(_dirCapturas);
    await dir.create(recursive: true);
    await File('${dir.path}/$nombre')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

String _dentroDias(int n) {
  final hoy = DateTime.parse(hoyHabanaIso());
  return hoy
      .add(Duration(days: n))
      .toIso8601String()
      .substring(0, 10);
}

String _haceDias(int n) {
  final hoy = DateTime.parse(hoyHabanaIso());
  return hoy
      .subtract(Duration(days: n))
      .toIso8601String()
      .substring(0, 10);
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
    final docs = await Directory.systemTemp.createTemp('diseno133_docs');
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

  testWidgets('captura · bandeja Por Decidir', (tester) async {
    _telefono(tester);
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(
        key: k,
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(AppEspacio.lg),
            children: [
              BandejaPorDecidir(
                incidencias: 2,
                rellenos: 1,
                adelantos: 1,
                onIr: (_) {},
                cargarRemotas: () async =>
                    const ConteosRemotosPorDecidir(
                        vales: 2, plus: 3, comunidad: null, solicitudes: 1),
                cargarCongelaciones: () async =>
                    (ok: true, pendientes: 1),
                cargarArqueos: () async => [
                  {
                    'nombre': 'Duany',
                    'cup': 4500.0,
                    'usd': 0.0,
                    'telegram_id': 969869611,
                  }
                ],
                cargarCatalogo: () async => 2,
              ),
            ],
          ),
        ),
      ),
    ));
    await _drenar(tester, vueltas: 8);
    expect(find.byType(BandejaPorDecidir), findsOneWidget);
    await _capturar(tester, k, 'por_decidir_$_fase.png');
    expect(tester.takeException(), isNull);
    await _cerrarCascara(tester);
  });

  testWidgets('captura · Pilar Negocio → Caja', (tester) async {
    _telefono(tester);
    await _sesionDueno(tester);
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(
        key: k,
        child: const Scaffold(body: PilarNegocio(esDueno: true)),
      ),
    ));
    await _drenar(tester, vueltas: 10);
    expect(find.byType(PilarNegocio), findsOneWidget);
    await _capturar(tester, k, 'pilar_negocio_caja_$_fase.png');
    expect(tester.takeException(), isNull);
    await _cerrarCascara(tester);
  });

  testWidgets('captura · Mostrador del dueño', (tester) async {
    _telefono(tester);
    await LocalDb.instance.upsertMirror('clientes', 501, {
      'id': 501,
      'nombre': 'Ada Aragon Herrera',
      'telefono': '58112233',
      'estado': 'activo',
      'pagado_hasta': _dentroDias(20),
      'fecha_inscripcion': _haceDias(120),
    }, 11);
    await _sesionDueno(tester);
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(key: k, child: const HomeScreen()),
    ));
    await _drenar(tester, vueltas: 10);
    await _descartarDialogos(tester);
    await _drenar(tester, vueltas: 6);
    await _descartarDialogos(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    await _capturar(tester, k, 'mostrador_$_fase.png');
    expect(tester.takeException(), isNull);
    await _cerrarCascara(tester);
    await _avanzarTiempo(tester);
  });

  testWidgets('captura · menú del avatar abierto', (tester) async {
    _telefono(tester);
    await _sesionDueno(tester);
    final k = GlobalKey();
    // El menú vive en el Overlay del Navigator, POR ENCIMA
    // del home: la frontera de captura envuelve aquí a la
    // MaterialApp entera o el menú no sale en la foto.
    await tester.pumpWidget(RepaintBoundary(
      key: k,
      child: MaterialApp(
        theme: _temaCaptura(),
        home: const HomeScreen(),
      ),
    ));
    await _drenar(tester, vueltas: 10);
    await _descartarDialogos(tester);
    await _drenar(tester, vueltas: 4);
    await tester.tap(find.byKey(const ValueKey('marco-perfil')));
    // La ruta del menú anima ~300 ms: se deja terminar
    // para capturar el menú asentado.
    await _drenar(tester, vueltas: 6, ms: 80);
    expect(find.text('Cerrar sesión'), findsOneWidget);
    await _capturar(tester, k, 'menu_avatar_$_fase.png');
    expect(tester.takeException(), isNull);
    await _cerrarCascara(tester);
    await _avanzarTiempo(tester);
  });

  testWidgets('captura · Servicio directo a vender (dock)',
      (tester) async {
    _telefono(tester);
    await _sesionDueno(tester);
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(key: k, child: const ServiciosScreen()),
    ));
    await _drenar(tester, vueltas: 10);
    expect(find.byType(ServiciosScreen), findsOneWidget);
    await _capturar(tester, k, 'servicio_directo_despues.png');
    expect(tester.takeException(), isNull);
    await _cerrarCascara(tester);
    await _avanzarTiempo(tester);
  });

  testWidgets('captura · Ficha expandida y al bajar', (tester) async {
    _telefono(tester);
    await LocalDb.instance.upsertMirror('clientes', 501, {
      'id': 501,
      'nombre': 'Ada Aragon Herrera',
      'telefono': '58112233',
      'estado': 'activo',
      'pagado_hasta': _dentroDias(20),
      'fecha_inscripcion': _haceDias(120),
    }, 11);
    await _sesionDueno(tester);
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(
          key: k, child: const FichaScreen(clienteId: 501)),
    ));
    await _drenar(tester, vueltas: 12);
    expect(find.byType(FichaScreen), findsOneWidget);
    await _capturar(tester, k, 'ficha_expandida_$_fase.png');
    // Bajar la lista de la pestaña activa más allá del
    // umbral de la cabecera compacta (170 dp).
    await tester.drag(
        find.byKey(const PageStorageKey<String>('ficha-pestana-0')),
        const Offset(0, -520));
    await _drenar(tester, vueltas: 6, ms: 60);
    await _capturar(tester, k, 'ficha_plegada_$_fase.png');
    expect(tester.takeException(), isNull);
    await _cerrarCascara(tester);
    await _avanzarTiempo(tester);
  });
}
