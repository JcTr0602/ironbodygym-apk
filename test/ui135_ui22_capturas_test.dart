/// 1.35 (UI-22) — arnés de CAPTURAS antes/después a
/// 360 dp para la compuerta visual de Jc (NO es un
/// golden: vuelca PNG reales a
/// ~/workspace/cola-123/gestion/135_ui_ronda1/capturas/).
///
/// Se corre SOLO con --dart-define=UI135_CAPTURAS=true.
/// «antes» = la cabecera como era siempre (plena también
/// con la lista bajada); «después» = la misma cabecera
/// plegada por el scroll: la identidad desaparece y
/// queda solo la píldora de sync.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/marco.dart';

const _capturasHabilitadas = bool.fromEnvironment('UI135_CAPTURAS');

/// Fuente real en el arnés (patrón de Campo 2): sin
/// esto, el test pinta bloques en vez de letras y la
/// captura no sirve para juzgar.
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
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/135_ui_ronda1/capturas';

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

  testWidgets('capturas UI-22 a 360 dp', (t) async {
    if (!_capturasHabilitadas) return;
    // La píldora de sync toca app_links; sin mock, el
    // plugin truena el test (patrón del arnés de UI-04).
    const canalEventos = EventChannel('com.llfbandit.app_links/events');
    const canalMensajes =
        MethodChannel('com.llfbandit.app_links/messages');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(canalEventos,
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canalMensajes, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    await t.runAsync(() async {
      await _cargarRobotoReal();
      try {
        await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'x');
      } catch (_) {}
    });
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    Future<void> montar(bool plegada) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: RepaintBoundary(
            key: k,
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CabeceraMarco(
                    rol: 'Dueño',
                    nombre: 'Julio César Pérez Ramírez',
                    onSyncTap: () {},
                    onLupa: () {},
                    onAccionPerfil: (_) {},
                    plegada: plegada,
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    await montar(false);
    await _capturar(t, k, 'ui22_cabecera_antes.png');
    await montar(true);
    await _capturar(t, k, 'ui22_cabecera_despues.png');
  });
}
