/// 1.34 · CARRIL ARTE — arnés de CAPTURAS para la compuerta
/// visual de Jc (NO es un golden de regresión: vuelca PNG
/// reales a ~/workspace/cola-123/gestion/134_arte_capturas/ y
/// Jc juzga las imágenes antes de cualquier build).
///
/// Fase por --dart-define=FASE=antes|despues (defecto: antes):
/// «antes» pinta los `vacio_*.jpg` con el fondo horneado;
/// «después» pinta los `vacio_*.webp` con alfa real.
///
/// ESCRIBIR las capturas exige la bandera explícita
/// --dart-define=ARTE134_CAPTURAS=true. Sin ella los tests
/// corren como humo pero _capturar no toca el disco: una
/// corrida ordinaria de la suite JAMÁS pisa la evidencia de
/// la compuerta visual (lección de la 1.33).
///
/// Superficies: los temas VIVOS de la app (AppTema.sol() y
/// AppTema.tacticoOscuro(), los que main.dart monta), con la
/// Roboto real del SDK nombrada (pauta del arnés de la casa).
/// Widgets REALES: EstadoVacio (con marco y sin marco) y
/// CabeceraCategoriaGympedia, sin sesión ni BD: son puramente
/// presentacionales.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/gympedia.dart';

const _fase = String.fromEnvironment('FASE', defaultValue: 'antes');

/// Sin esta bandera, [_capturar] no escribe NADA.
const _capturasHabilitadas = bool.fromEnvironment('ARTE134_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/134_arte_capturas';

/// La ruta de un vacío según lo que el árbol tenga: en la
/// base (fase «antes») los spots viven en JPG con fondo
/// horneado; en la rama arreglada (fase «después»), en WebP
/// con alfa. Se resuelve por existencia del archivo para que
/// el arnés corra como humo en cualquier árbol y fase.
String _vacio(String nombre) =>
    File('assets/vacio_$nombre.webp').existsSync()
        ? 'assets/vacio_$nombre.webp'
        : 'assets/vacio_$nombre.jpg';

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

/// El tema de la captura: las superficies y colores REALES
/// del tema vivo (sol o táctico oscuro) con la Roboto
/// nombrada como familia — la pauta del arnés matriz.
ThemeData _temaCaptura(bool oscuro) {
  final t = oscuro ? AppTema.tacticoOscuro() : AppTema.sol();
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
    textTheme: t.textTheme.apply(fontFamily: 'Roboto'),
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
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await File('${dir.path}/$nombre.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// Monta [hijo] en un teléfono 420×800 con el tema vivo,
/// precarga las imágenes [activos] (la decodificación real
/// ocurre fuera del reloj falso) y captura si la bandera
/// está puesta.
Future<void> _escena(
  WidgetTester tester, {
  required bool oscuro,
  required Widget hijo,
  required List<String> activos,
  required String nombre,
}) async {
  _telefono(tester);
  final llave = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: _temaCaptura(oscuro),
      home: RepaintBoundary(key: llave, child: hijo),
    ),
  );
  final ctx = tester.element(find.byType(Scaffold).first);
  await tester.runAsync(() async {
    for (final a in activos) {
      await precacheImage(AssetImage(a), ctx);
    }
  });
  await tester.pump(const Duration(milliseconds: 120));
  await _capturar(tester, llave, 'widget_${_fase}_$nombre');
}

void main() {
  setUpAll(() async {
    await _cargarRobotoReal();
  });

  for (final oscuro in [false, true]) {
    final tema = oscuro ? 'oscuro' : 'claro';
    testWidgets('EstadoVacio con marco (reloj) — $tema', (tester) async {
      await _escena(
        tester,
        oscuro: oscuro,
        activos: [_vacio('reloj')],
        nombre: 'vacio_marco_reloj_$tema',
        hijo: Scaffold(
          body: Center(
            child: EstadoVacio(
              ilustracion: _vacio('reloj'),
              icono: Icons.schedule_rounded,
              titulo: 'Nadie vence hoy',
              subtitulo: 'Todo al día.',
            ),
          ),
        ),
      );
      expect(find.byType(EstadoVacio), findsOneWidget);
    });

    testWidgets('EstadoVacio sin marco en tarjeta (pomo) — $tema',
        (tester) async {
      await _escena(
        tester,
        oscuro: oscuro,
        // pomo: en la base era JPG (escena con mueble);
        // desde la regeneración 1.34 es spot WebP con alfa
        // y _vacio() resuelve la ruta por existencia.
        activos: [_vacio('pomo')],
        nombre: 'vacio_sinmarco_pomo_$tema',
        hijo: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: EstadoVacio(
                  sinMarco: true,
                  ilustracion: _vacio('pomo'),
                  icono: Icons.inventory_2_rounded,
                  titulo: 'Sin suplementos',
                  subtitulo: 'Registra el primer producto del catálogo.',
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(EstadoVacio), findsOneWidget);
    });

    testWidgets('Cabeceras GymPedia — $tema', (tester) async {
      await _escena(
        tester,
        oscuro: oscuro,
        activos: const [
          'assets/gympedia_entrenamiento.jpg',
          'assets/gympedia_nutricion.jpg',
          'assets/gympedia_tecnica.jpg',
        ],
        nombre: 'gympedia_cabeceras_$tema',
        hijo: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CabeceraCategoriaGympedia(categoria: 'entrenamiento'),
                SizedBox(height: 16),
                CabeceraCategoriaGympedia(categoria: 'nutricion'),
                SizedBox(height: 16),
                CabeceraCategoriaGympedia(categoria: 'tecnica'),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(CabeceraCategoriaGympedia), findsNWidgets(3));
    });
  }

  testWidgets('Tres vacíos con marco en columna — oscuro', (tester) async {
    await _escena(
      tester,
      oscuro: true,
      activos: [_vacio('caja'), _vacio('lupa'), _vacio('pastel')],
      nombre: 'vacios_columna_oscuro',
      hijo: Scaffold(
        body: ListView(
          children: [
            EstadoVacio(
              ilustracion: _vacio('caja'),
              icono: Icons.point_of_sale_rounded,
              titulo: 'Sin ventas todavía',
            ),
            EstadoVacio(
              ilustracion: _vacio('lupa'),
              icono: Icons.search_off_rounded,
              titulo: 'Sin resultados',
            ),
            EstadoVacio(
              ilustracion: _vacio('pastel'),
              icono: Icons.cake_rounded,
              titulo: 'Sin cumpleaños próximos',
            ),
          ],
        ),
      ),
    );
    expect(find.byType(EstadoVacio), findsNWidgets(3));
  });
}
