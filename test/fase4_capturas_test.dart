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

import 'package:ironbody_gym/ui/arranque_marca.dart';
import 'package:ironbody_gym/ui/diseno.dart';
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
}
