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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

const _fase = String.fromEnvironment('FASE', defaultValue: 'antes');

/// Fase 1 (DIS-02): sin esta bandera, [_capturar] no
/// escribe NADA (ver la nota del encabezado).
const _capturasHabilitadas =
    bool.fromEnvironment('DISENO134_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/134_diseno_capturas';

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

Future<void> _capturar(
    WidgetTester tester, GlobalKey key, String nombre) async {
  // Fase 1 (DIS-02): la guarda vive AQUÍ, en el único
  // punto de escritura del arnés.
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

  // Siembra común a todas las superficies: sesión de dueño,
  // espejos de clientes/productos y la foto de accesos
  // persistida (Control de Acceso pinta de ella en frío).
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
      await LocalDb.instance.upsertMirror('suplementos', 1, {
        'id': 1,
        'nombre': 'Proteína Suero X',
        'precio_cup': 4500,
        'stock_dosis': 40,
        'activo': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('suplementos', 2, {
        'id': 2,
        'nombre': 'Creatina Monohidrato',
        'precio_cup': 3200,
        'stock_dosis': 3,
        'activo': 1,
      }, 1);
      final filasAcceso = <Map<String, dynamic>>[
        {
          'cliente_id': 5,
          'nombre': 'Ana Prueba',
          'telefono': '53000005',
          'activo': true,
          'debe_cambiar_pin': true,
          'ultimo_acceso_en':
              DateTime.now().subtract(const Duration(days: 40)).toIso8601String(),
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
  }

  Future<void> montar(
      WidgetTester tester, Widget pantalla, String nombre) async {
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(key: k, child: pantalla),
    ));
    await _drenar(tester);
    await _capturar(tester, k, '${nombre}_$_fase.png');
    await _descartarDialogos(tester);
    await _cerrarCascara(tester);
  }

  testWidgets('auditoria', (tester) async {
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
        ),
        '01_auditoria');
  });

  testWidgets('historial_ventas', (tester) async {
    _telefono(tester);
    await sembrarBase(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('ventas_suplementos', 1, {
        'id': 1,
        'suplemento_id': 1,
        'cliente_id': 5,
        'cantidad': 1,
        // Yunque 3.34 (K4-2): forma REAL del importe —
        // total ?? precio × cantidad (lib/negocio.dart:
        // 997-1002). precio_total no lo lee nadie: la
        // venta valía 0 en la captura.
        'precio': 4500,
        'total': 4500,
        'moneda': 'CUP',
        'fecha': hoyHabanaIso(),
        'vendedor_id': 735772141,
      }, 1);
      await LocalDb.instance.upsertMirror('ventas_suplementos', 2, {
        'id': 2,
        'suplemento_id': 2,
        'cliente_id': 7,
        'cantidad': 2,
        'precio': 3200,
        'total': 6400,
        'moneda': 'USD',
        'fecha': hoyHabanaIso(),
        'vendedor_id': 969869611,
      }, 1);
    });
    await montar(
        tester, const HistorialVentasScreen(), '02_historial_ventas');
  });

  testWidgets('historial_servicios', (tester) async {
    _telefono(tester);
    await sembrarBase(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('servicio_pomos', 10, {
        'id': 10,
        // Yunque 3.34 (K4-1): forma REAL del espejo
        // servicio_pomos (corrección E-2 de Y2): el nombre
        // del pomo sale de suplemento_id y el responsable de
        // es_principal/titular_telegram_id
        // (lib/servicios.dart:243-250). producto_id /
        // responsable_id no los trae la fila: sin
        // suplemento_id el pomo se resolvía como
        // «Suplemento» genérico en la captura.
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
        ),
        '03_historial_servicios');
  });

  testWidgets('liquidaciones', (tester) async {
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
    await montar(
        tester, const LiquidacionesHistorialScreen(), '04_liquidaciones');
  });

  testWidgets('control_acceso', (tester) async {
    _telefono(tester);
    await sembrarBase(tester);
    // El hub abre en «Entrenadores»; el plegado G-06 vive en
    // la pestaña «Clientes» (AccesosClientesTab): se captura
    // ESA, que es la superficie tocada por la 1.34.
    final k = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: _temaCaptura(),
      home: RepaintBoundary(key: k, child: const ControlAccesoScreen()),
    ));
    await _drenar(tester);
    await tester.tap(find.text('Clientes'));
    await _drenar(tester);
    await _capturar(tester, k, '05_control_acceso_$_fase.png');
    await _descartarDialogos(tester);
    await _cerrarCascara(tester);
  });

  testWidgets('suplementos', (tester) async {
    _telefono(tester);
    await sembrarBase(tester);
    await tester.runAsync(() async {
      await LocalDb.instance
          .upsertMirror('categorias_suplemento', 1, {
        'id': 1,
        'nombre': 'Proteínas',
      }, 1);
      await LocalDb.instance
          .upsertMirror('categorias_suplemento', 2, {
        'id': 2,
        'nombre': 'Rendimiento',
      }, 1);
      await LocalDb.instance.upsertMirror('suplementos', 1, {
        'id': 1,
        'nombre': 'Proteína Suero X',
        'precio_cup': 4500,
        'stock_dosis': 40,
        'categoria_id': 1,
        'activo': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('suplementos', 2, {
        'id': 2,
        'nombre': 'Creatina Monohidrato',
        'precio_cup': 3200,
        'stock_dosis': 3,
        'categoria_id': 2,
        'activo': 1,
      }, 1);
    });
    await montar(tester, const SuplementosScreen(), '06_suplementos');
  });

  testWidgets('servicios', (tester) async {
    _telefono(tester);
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
            {'telegram_id': 735772141, 'nombre': 'Tú (Jc)', 'rol': 'dueno'},
            {
              'telegram_id': 111222333,
              'nombre': 'Gabriel Alejandro Fernández Domínguez',
              'rol': 'entrenador'
            },
          ]));
    });
    await montar(tester, const ServiciosScreen(), '07_servicios');
  });
}
