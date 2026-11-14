/// 1.34 · CAMPO 2 — arnés de CAPTURAS para la compuerta
/// visual de Jc del Bloque B (NO es un golden: vuelca PNG
/// reales a ~/workspace/cola-123/gestion/
/// 134_campo2_capturas/ y Jc juzga las imágenes).
///
/// Procedimiento oficial de la 1.34 (el del carril de
/// Diseño): --dart-define=DISENO134_CAPTURAS=true para
/// escribir y --dart-define=FASE=antes|despues. «antes»
/// se corre sobre la base 82e3549 (Jornada 2) y «después»
/// sobre el tip de Campo 2, con LOS MISMOS fixtures.
///
/// Fixtures HONESTOS (lección K4): nombres con forma real,
/// precios y stock reales de forma, conteos que mezclan
/// accionables y ceros — nada de totales en 0 ni productos
/// genéricos: la captura debe enseñar lo que Jc va a ver.
///
/// Superficies: la ficha (arriba y baja, con la barra
/// compacta), la bandeja «Por Decidir» y Suplementos
/// (arriba y scrolleado).
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
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _fase = String.fromEnvironment('FASE', defaultValue: 'antes');
const _capturasHabilitadas =
    bool.fromEnvironment('DISENO134_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/134_campo2_capturas';

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
    appBarTheme: t.appBarTheme
        .copyWith(titleTextStyle: _rob(t.appBarTheme.titleTextStyle)),
    cardTheme: t.cardTheme,
    dialogTheme: t.dialogTheme
        .copyWith(titleTextStyle: _rob(t.dialogTheme.titleTextStyle)),
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
  if (!_capturasHabilitadas) return;
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
    final docs = await Directory.systemTemp.createTemp('campo2_docs');
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

  Future<void> sembrarUsuarios(WidgetTester tester) async {
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
    });
  }

  Future<void> montar(WidgetTester tester, Widget pantalla,
      String nombre,
      {double bajar = 0}) async {
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(key: k, child: pantalla),
    ));
    await _drenar(tester);
    if (bajar > 0) {
      // El arrastre va sobre el scroll del CONTENIDO (el
      // CustomScrollView del catálogo en el tip; en la
      // base, el primer Scrollable, que es su lista): el
      // primer Scrollable del árbol puede ser el carrusel
      // horizontal de chips y el gesto se perdería en él.
      final objetivo =
          find.byType(CustomScrollView).evaluate().isNotEmpty
              ? find.byType(CustomScrollView).first
              : find.byType(Scrollable).first;
      await tester.drag(objetivo, Offset(0, -bajar));
      await tester.pumpAndSettle();
      await _drenar(tester, vueltas: 4);
    }
    await _capturar(tester, k, '${nombre}_$_fase.png');
    await _descartarDialogos(tester);
    await _cerrarCascara(tester);
  }

  testWidgets('ficha', (tester) async {
    _telefono(tester);
    await sembrarUsuarios(tester);
    await tester.runAsync(() async {
      final hoy = ahoraHabana();
      String fecha(DateTime d) =>
          isoHabana(d).substring(0, 10);
      final hasta = fecha(sumarDiasCalendario(hoy, 21));
      await LocalDb.instance.upsertMirror('clientes', 20, {
        'id': 20,
        'nombre': 'Yunior Pérez González',
        'telefono': '53421786',
        'carnet': '950312',
        'sexo': 'M',
        'estado': 'activo',
        'pagado_hasta': hasta,
        'fecha_inscripcion': fecha(sumarDiasCalendario(hoy, -95)),
      }, 1);
      // Tres mensualidades en efectivo, forma real.
      for (var i = 0; i < 3; i++) {
        await LocalDb.instance.upsertMirror('pagos', 500 + i, {
          'id': 500 + i,
          'cliente_id': 20,
          'fecha': fecha(sumarDiasCalendario(hoy, -51 + 30 * i)),
          'monto': 2000,
          'metodo': 'efectivo',
          'tipo': 'Mensualidad',
          'periodo': 'mensual',
          'meses': 1,
          'anulado': 0,
          'creado_por_nombre': 'Duany',
        }, 1);
      }
      // La foto de accesos SIN este cliente: en la base, la
      // barra compacta al bajar le ofrece «Dar acceso».
      await LocalDb.instance.setMeta(
          'acceso_app_cache_v1',
          jsonEncode({
            'filas': [
              {
                'cliente_id': 7,
                'nombre': 'Beto Ejemplo',
                'telefono': '53000007',
                'activo': true,
                'ultimo_acceso_en':
                    DateTime.now().toIso8601String(),
                'created_at': '2026-10-01T00:00:00Z',
                'token_version': 1,
              },
            ],
            'verificado_en': DateTime.now().toIso8601String(),
          }));
    });
    await montar(tester, const FichaScreen(clienteId: 20), '01_ficha');
  });

  testWidgets('ficha_baja', (tester) async {
    _telefono(tester);
    await sembrarUsuarios(tester);
    await tester.runAsync(() async {
      final hoy = ahoraHabana();
      String fecha(DateTime d) => isoHabana(d).substring(0, 10);
      await LocalDb.instance.upsertMirror('clientes', 20, {
        'id': 20,
        'nombre': 'Yunior Pérez González',
        'telefono': '53421786',
        'carnet': '950312',
        'sexo': 'M',
        'estado': 'activo',
        'pagado_hasta': fecha(sumarDiasCalendario(hoy, 21)),
        'fecha_inscripcion': fecha(sumarDiasCalendario(hoy, -95)),
      }, 1);
      for (var i = 0; i < 3; i++) {
        await LocalDb.instance.upsertMirror('pagos', 500 + i, {
          'id': 500 + i,
          'cliente_id': 20,
          'fecha': fecha(sumarDiasCalendario(hoy, -51 + 30 * i)),
          'monto': 2000,
          'metodo': 'efectivo',
          'tipo': 'Mensualidad',
          'periodo': 'mensual',
          'meses': 1,
          'anulado': 0,
          'creado_por_nombre': 'Duany',
        }, 1);
      }
      await LocalDb.instance.setMeta(
          'acceso_app_cache_v1',
          jsonEncode({
            'filas': [
              {
                'cliente_id': 7,
                'nombre': 'Beto Ejemplo',
                'telefono': '53000007',
                'activo': true,
                'ultimo_acceso_en': DateTime.now().toIso8601String(),
                'created_at': '2026-10-01T00:00:00Z',
                'token_version': 1,
              },
            ],
            'verificado_en': DateTime.now().toIso8601String(),
          }));
    });
    await montar(tester, const FichaScreen(clienteId: 20),
        '02_ficha_baja',
        bajar: 500);
  });

  testWidgets('por_decidir', (tester) async {
    _telefono(tester);
    await sembrarUsuarios(tester);
    final bandeja = BandejaPorDecidir(
      incidencias: 2,
      rellenos: 1,
      adelantos: 0,
      onIr: (_) {},
      // Mezcla honesta: dos remotas con algo que atender
      // (Plus 3, solicitudes 1) y dos verificadas en CERO
      // (vales y comunidad) — en la base saturan la
      // bandeja; en el tip no aparecen.
      cargarRemotas: () async => const ConteosRemotosPorDecidir(
          vales: 0, plus: 3, comunidad: 0, solicitudes: 1),
      cargarCongelaciones: () async => (ok: true, pendientes: 0),
      cargarArqueos: () async => [
        {
          'nombre': 'Duany',
          'cup': 900,
          'usd': 0,
          'telegram_id': 969869611,
        },
      ],
      cargarCatalogo: () async => 0,
    );
    await montar(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: bandeja,
          ),
        ),
        '03_por_decidir');
  });

  testWidgets('suplementos', (tester) async {
    _telefono(tester);
    await sembrarUsuarios(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('categorias_suplemento', 1, {
        'id': 1,
        'nombre': 'Proteínas',
        'activa': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('categorias_suplemento', 2, {
        'id': 2,
        'nombre': 'Creatinas',
        'activa': 1,
      }, 1);
      final productos = <(String, int, int, int)>[
        ('Proteína Suero Gold 908 g', 4500, 40, 1),
        ('Creatina Monohidrato 300 g', 3200, 25, 2),
        ('Pre-entreno Voltage 30 serv.', 5100, 12, 1),
        ('Proteína ISO Zero 907 g', 6900, 8, 1),
        ('Creatina Creapure 500 g', 4800, 3, 2),
        ('BCAA 2:1:1 120 cáps.', 2900, 17, 1),
        ('Glutamina Pura 300 g', 3400, 9, 1),
        ('Omega 3 90 softgels', 2100, 22, 2),
        ('Multivitamínico Diario 60 tab.', 1800, 31, 2),
        ('Proteína Vegana 907 g', 4300, 6, 1),
        ('ZMA Noche 90 cáps.', 2600, 14, 2),
        ('Quemador Termo X 60 cáps.', 3900, 0, 1),
        ('Avena Instantánea 1 kg', 950, 48, 1),
        ('Barra Proteica Choco 60 g', 350, 120, 1),
      ];
      for (var i = 0; i < productos.length; i++) {
        final (nombre, precio, stock, cat) = productos[i];
        await LocalDb.instance.upsertMirror('suplementos', i + 1, {
          'id': i + 1,
          'nombre': nombre,
          'precio': precio,
          'precio_oficial': precio,
          'stock': stock,
          'moneda': 'CUP',
          'activo': 1,
          'categoria_id': cat,
        }, 1);
      }
      for (var v = 0; v < 3; v++) {
        await LocalDb.instance
            .upsertMirror('ventas_suplementos', 100 + v, {
          'id': 100 + v,
          'suplemento_id': 1,
          'cantidad': 4,
          'anulada': 0,
          'activo': 1,
        }, 1);
      }
      await LocalDb.instance.setAjustes({'tasa_usd': 250});
    });
    await montar(tester, const SuplementosScreen(), '04_suplementos');
  });

  testWidgets('suplementos_baja', (tester) async {
    _telefono(tester);
    await sembrarUsuarios(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('categorias_suplemento', 1, {
        'id': 1,
        'nombre': 'Proteínas',
        'activa': 1,
      }, 1);
      final productos = <(String, int, int)>[
        ('Proteína Suero Gold 908 g', 4500, 40),
        ('Creatina Monohidrato 300 g', 3200, 25),
        ('Pre-entreno Voltage 30 serv.', 5100, 12),
        ('Proteína ISO Zero 907 g', 6900, 8),
        ('Creatina Creapure 500 g', 4800, 3),
        ('BCAA 2:1:1 120 cáps.', 2900, 17),
        ('Glutamina Pura 300 g', 3400, 9),
        ('Omega 3 90 softgels', 2100, 22),
        ('Multivitamínico Diario 60 tab.', 1800, 31),
        ('Proteína Vegana 907 g', 4300, 6),
        ('ZMA Noche 90 cáps.', 2600, 14),
        ('Quemador Termo X 60 cáps.', 3900, 0),
        ('Avena Instantánea 1 kg', 950, 48),
        ('Barra Proteica Choco 60 g', 350, 120),
      ];
      for (var i = 0; i < productos.length; i++) {
        final (nombre, precio, stock) = productos[i];
        await LocalDb.instance.upsertMirror('suplementos', i + 1, {
          'id': i + 1,
          'nombre': nombre,
          'precio': precio,
          'precio_oficial': precio,
          'stock': stock,
          'moneda': 'CUP',
          'activo': 1,
          'categoria_id': 1,
        }, 1);
      }
      for (var v = 0; v < 3; v++) {
        await LocalDb.instance
            .upsertMirror('ventas_suplementos', 100 + v, {
          'id': 100 + v,
          'suplemento_id': 1,
          'cantidad': 4,
          'anulada': 0,
          'activo': 1,
        }, 1);
      }
      await LocalDb.instance.setAjustes({'tasa_usd': 250});
    });
    await montar(tester, const SuplementosScreen(),
        '05_suplementos_baja',
        bajar: 700);
  });
}
