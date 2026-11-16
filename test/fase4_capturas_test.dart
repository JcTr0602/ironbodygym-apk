/// 1.35 FASE 4 — arnés de CAPTURAS a 360 dp para la
/// compuerta visual de Jc (NO son goldens: vuelca PNG
/// reales a ~/workspace/cola-123/gestion/135_fase4/capturas/).
///
/// Se corre SOLO con --dart-define=UI135_CAPTURAS=true.
/// Cada pieza de la fase añade su captura aquí.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ironbody_gym/ui/arranque_marca.dart';
import 'package:ironbody_gym/ui/cierre_turno.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/confirmacion_cobro.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';
import 'package:ironbody_gym/ui/iconos_propios.dart';
import 'package:ironbody_gym/ui/login.dart';
import 'package:ironbody_gym/ui/marco.dart';

const _capturasHabilitadas = bool.fromEnvironment('UI135_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/135_fase4/capturas';

Future<void> _cargarFuentesReales() async {
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
  // Barlow Condensed (la display de marca, UI-25) desde
  // los assets del paquete.
  final barlow = FontLoader('Barlow Condensed');
  for (final f in [
    'assets/fonts/BarlowCondensed-SemiBold.ttf',
    'assets/fonts/BarlowCondensed-Bold.ttf'
  ]) {
    try {
      final bytes = await File(f).readAsBytes();
      barlow.addFont(Future.value(ByteData.view(bytes.buffer)));
    } catch (_) {}
  }
  await barlow.load();
}

Future<void> _capturar(
    WidgetTester tester, GlobalKey key, String nombre) async {
  if (!_capturasHabilitadas) return;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('UX-14: momento de marca a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(
        key: k,
        child: const EnvoltorioArranqueMarca(
          child: Scaffold(body: SizedBox.expand()),
        ),
      ),
    ));
    await t.pump();
    // El arte (Image.asset) decodifica fuera del reloj
    // falso: se le da tiempo real antes de capturar.
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await t.pump();
    await _capturar(t, k, 'ux14_marca.png');
  });

  testWidgets('UX-02: barra Grafito a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(
        key: k,
        child: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: BarraPilares(
            activo: 0,
            esDueno: true,
            urgencias: 3,
            onTap: (_) {},
          ),
        ),
      ),
    ));
    await t.pump();
    await _capturar(t, k, 'ux02_barra_grafito.png');
  });

  testWidgets('UX-04: la ficha como credencial a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(
        key: k,
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              CabeceraFicha(
                nombre: 'Luis Gómez',
                foto: null,
                colorMarco: AppColores.exito,
                esCasa: false,
                dias: 30,
                heroTag: null,
                onFotoTap: null,
                onCambiarFoto: () {},
                fraccionPeriodo: 0.45,
                pagadoHastaTexto: '16/12/2026',
              ),
            ],
          ),
        ),
      ),
    ));
    await t.pump();
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await t.pump();
    await _capturar(t, k, 'ux04_credencial.png');
  });

  testWidgets('UX-05: el recibo de la casa a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(
        key: k,
        child: const ConfirmacionOperacionScreen(
          titulo: 'Pago registrado',
          monto: '2 000 CUP',
          etiquetaMonto: 'Cobrado',
          detalles: [
            (etiqueta: 'Cliente', valor: 'Luis Gómez'),
            (etiqueta: 'Método', valor: 'Efectivo'),
          ],
          comprobantePie: 'pie',
        ),
      ),
    ));
    await t.pump();
    await _capturar(t, k, 'ux05_recibo.png');
  });

  testWidgets('UX-06: la puerta con el rayo a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    // El login lee las preferencias al nacer: sin el
    // mock, el arnés muere con MissingPluginException.
    SharedPreferences.setMockInitialValues({});
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(key: k, child: const LoginScreen()),
    ));
    await t.pump();
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    // La entrada del login anima fundido y deslizamiento
    // con el reloj FALSO: hay que dejarla terminar en
    // tiempo simulado o la captura sale con el velo solo.
    await t.pump(const Duration(milliseconds: 900));
    await t.pump(const Duration(milliseconds: 900));
    await _capturar(t, k, 'ux06_puerta.png');
  });

  testWidgets('UX-09: profundidad — tarjetas sobre el '
      'fondo a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(
        key: k,
        child: const Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              FondoProfundidad(),
              Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    Tarjeta(child: Text('Tarjeta plana')),
                    SizedBox(height: 12),
                    Tarjeta(child: Text('Otra tarjeta')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await t.pump();
    await _capturar(t, k, 'ux09_profundidad.png');
  });

  testWidgets('UX-11: la lámina de la familia de iconos '
      'propios a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    Widget celda(Widget icono, String nombre) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            icono,
            const SizedBox(height: 6),
            Text(nombre,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        );
    const color = AppColores.naranja;
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(
        key: k,
        child: Scaffold(
          backgroundColor: AppColores.grafitoTactico,
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              spacing: 26,
              runSpacing: 22,
              children: [
                celda(const IconoPomo(tamano: 40, color: color), 'Pomo'),
                celda(const IconoDosis(tamano: 40, color: color), 'Dosis'),
                celda(const IconoCobrar(tamano: 40, color: color), 'Cobrar'),
                celda(const IconoPase(tamano: 40, color: color), 'Pase'),
                celda(const IconoTurno(tamano: 40, color: color), 'Turno'),
                celda(const IconoVencimiento(tamano: 40, color: color),
                    'Vencimiento'),
                celda(const IconoMostrador(tamano: 40, color: color),
                    'Mostrador'),
                celda(const IconoClientes(tamano: 40, color: color),
                    'Clientes'),
                celda(const IconoTienda(tamano: 40, color: color), 'Tienda'),
                celda(const IconoNegocio(tamano: 40, color: color),
                    'Negocio'),
              ],
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    await _capturar(t, k, 'ux11_lamina.png');
  });

  testWidgets('UX-15: la tarjeta de cierre a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: RepaintBoundary(
        key: k,
        child: const TarjetaCierreTurnoScreen(prep: {
          'fechaTurno': '2026-11-16',
          'turno': 'Mañana',
          'horaApertura': '2026-11-16T07:00:00',
          'pagosCount': 7,
          'pendientesCount': 2,
          'pendientesCup': 4000,
          'pendientesUsd': 0,
          'revisionCount': 0,
        }),
      ),
    ));
    await t.pump();
    await _capturar(t, k, 'ux15_cierre.png');
  });
}
