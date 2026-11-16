/// 1.35 (UI-23) — arnés de CAPTURAS antes/después a
/// 360 dp para la compuerta visual de Jc (NO es un
/// golden: vuelca PNG reales a
/// ~/workspace/cola-123/gestion/135_ui_ronda1/capturas/).
///
/// Se corre SOLO con --dart-define=UI135_CAPTURAS=true.
/// Composición fiel del arranque del Mostrador: la
/// primera tarjeta (el Pulso) con y sin la línea de
/// contexto encima — la línea se compone con la función
/// pura real de la pieza y se pinta con su mismo
/// relleno y rol de texto.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

const _capturasHabilitadas = bool.fromEnvironment('UI135_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/135_ui_ronda1/capturas';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capturas UI-23 a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarRobotoReal);
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final linea = lineaContextoMostrador(
      ahora: DateTime(2026, 11, 14, 10, 0),
      patron: const {
        6: {'manana': 'Duany'},
      },
      excepciones: const {},
      aperturas: const [],
    );
    final k = GlobalKey();
    Future<void> montar(bool conLinea) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: RepaintBoundary(
            key: k,
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (conLinea)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppEspacio.lg,
                          AppEspacio.md,
                          AppEspacio.lg,
                          0),
                      child: Text(linea,
                          style: AppTexto.secundario),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: Tarjeta(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text('Estadísticas Rápidas',
                              style: AppTexto.titulo),
                          const SizedBox(height: AppEspacio.sm),
                          Text('\$12 400',
                              style: AppTexto.metrica),
                          Text('cobrado hoy',
                              style: AppTexto.secundario),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 350));
    }

    await montar(false);
    await _capturar(t, k, 'ui23_mostrador_antes.png');
    await montar(true);
    await _capturar(t, k, 'ui23_mostrador_despues.png');
  });
}
