/// 1.35 (UI-25) — arnés de CAPTURAS de la fuente de
/// marca (NO es un golden: vuelca PNG reales a
/// ~/workspace/cola-123/gestion/135_ui_ronda1/capturas/).
///
/// Se corre SOLO con --dart-define=UI135_CAPTURAS=true.
/// Dos tandas:
/// - COMPARATIVA (antes de tocar el tema): la misma
///   muestra de roles grandes en Roboto (lo de hoy),
///   Barlow Condensed y Oswald. La elección se hizo con
///   esta captura + la forense de cifras: Oswald y Saira
///   Condensed NO traen cifras tabulares (sin `tnum`,
///   verificado con fontTools) y las columnas de dinero
///   bailarían; Barlow Condensed sí (los 10 dígitos a
///   475/498 ud. exactas con la feature activa).
/// - ANTES/DESPUÉS: la muestra con los roles tal cual
///   salen de AppTexto (antes = sin familia; después =
///   con la familia ya en el tema).
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

const _capturasHabilitadas = bool.fromEnvironment('UI135_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/135_ui_ronda1/capturas';
const _dirCandidatas =
    '/home/hatch/workspace/cola-123/gestion/135_ui_ronda1/fuentes_candidatas';

Future<void> _cargarArchivo(String familia, List<String> rutas) async {
  final loader = FontLoader(familia);
  for (final r in rutas) {
    final bytes = await File(r).readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _cargarFuentes() async {
  const dirSdk =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  await _cargarArchivo('Roboto', [
    '$dirSdk/Roboto-Regular.ttf',
    '$dirSdk/Roboto-Medium.ttf',
    '$dirSdk/Roboto-Bold.ttf',
  ]);
  await _cargarArchivo('MaterialIcons', [
    '$dirSdk/MaterialIcons-Regular.otf',
  ]);
  await _cargarArchivo('Barlow Condensed', [
    '$_dirCandidatas/BarlowCondensed-SemiBold.ttf',
    '$_dirCandidatas/BarlowCondensed-Bold.ttf',
  ]);
  await _cargarArchivo('Oswald', [
    '$_dirCandidatas/Oswald-Medium.ttf',
    '$_dirCandidatas/Oswald-SemiBold.ttf',
  ]);
}

Future<void> _capturar(
    WidgetTester tester, GlobalKey key, String nombre) async {
  if (!_capturasHabilitadas) return;
  await tester.pump(const Duration(milliseconds: 350));
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

/// La muestra: los cuatro roles grandes con su contenido
/// real (titular, cifra de dinero, métrica y dos importes
/// alineados a la derecha para juzgar las tabulares).
Widget _muestra(String? familia) {
  TextStyle rol(TextStyle base) =>
      familia == null ? base : base.copyWith(fontFamily: familia);
  return Tarjeta(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mostrador', style: rol(AppTexto.tituloPagina)),
        const SizedBox(height: AppEspacio.sm),
        Text('\$15 600', style: rol(AppTexto.display)),
        Text('cobrado hoy', style: AppTexto.secundario),
        const SizedBox(height: AppEspacio.md),
        Text('Estadísticas Rápidas', style: rol(AppTexto.tituloPagina)),
        const SizedBox(height: AppEspacio.sm),
        Row(
          children: [
            Expanded(
                child: Text('Cuota del mes',
                    style: AppTexto.secundario)),
            Text('\$1 111', style: rol(AppTexto.metrica)),
          ],
        ),
        Row(
          children: [
            Expanded(
                child: Text('Cuota del mes',
                    style: AppTexto.secundario)),
            Text('\$9 999', style: rol(AppTexto.metrica)),
          ],
        ),
        const SizedBox(height: AppEspacio.md),
        Text('Turno de Duany', style: rol(AppTexto.displayPequeno)),
      ],
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capturas UI-25 a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentes);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    Future<void> montar(Widget cuerpo, {double alto = 800}) async {
      t.view.physicalSize = Size(360, alto);
      await t.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: RepaintBoundary(
            key: k,
            child: SizedBox(
              width: 360,
              child: Padding(
                padding: const EdgeInsets.all(AppEspacio.lg),
                child: cuerpo,
              ),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 350));
    }

    // Comparativa de candidatas (antes de tocar el tema).
    await montar(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _muestra(null),
            const SizedBox(height: AppEspacio.lg),
            _muestra('Barlow Condensed'),
            const SizedBox(height: AppEspacio.lg),
            _muestra('Oswald'),
          ],
        ),
        alto: 1250);
    await _capturar(t, k, 'ui25_comparativa.png');

    // Antes/después con los roles tal cual salen de
    // AppTexto (la tanda «después» se corre con la
    // familia ya aplicada en el tema).
    await montar(_muestra(null));
    await _capturar(t, k, 'ui25_roles.png');
  });
}
