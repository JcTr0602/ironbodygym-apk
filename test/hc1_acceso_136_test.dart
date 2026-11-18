/// H-C1 (1.36): login/PIN/candado/acceso/auth —
/// 136-439, 136-445, 136-463 (parte confirmada).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ironbody_gym/acceso_bloqueo.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/ui/capa_candado.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/pin_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('136-463 · el cambio de clave distingue red de credenciales', () {
    expect(mensajeErrorCambioClave(Exception('Invalid login credentials')),
        'Tu contraseña actual no es correcta.');
    expect(
        mensajeErrorCambioClave(Exception('SocketException: cerrado')),
        contains('Sin conexión'));
    expect(mensajeErrorCambioClave(Exception('TimeoutException')),
        contains('Sin conexión'));
    expect(mensajeErrorCambioClave(Exception('otra cosa')),
        contains('No se pudo cambiar'));
  });

  testWidgets('136-439 · el PIN nace «comprobando» y luego pide el PIN',
      (t) async {
    t.view.physicalSize = const Size(420, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    // Patrón de ui135_ui17_test: inicializar fuera del
    // reloj falso para no dejar temporizadores colgados.
    await t.runAsync(() async {
      try {
        await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'x');
      } catch (_) {}
    });
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: const PinLockScreen(),
    ));
    // Primera frame: aún no resolvió la comprobación.
    expect(find.text('Comprobando…'), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.text('Escribe tu PIN para continuar'), findsOneWidget);
    // Drenar temporizadores (patrón de ui135_ui17_test).
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets(
      '136-445 · CapaCandado con mensaje muy largo no desborda en pantalla corta',
      (t) async {
    t.view.physicalSize = const Size(360, 480);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: CapaCandado(
        bloqueo: BloqueoVigente(
          alcance: 'global',
          objetivo: null,
          mensaje: 'Mensaje del dueño muy largo. ' * 30,
          expiraEn: DateTime(2027, 1, 1),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Acceso pausado'), findsOneWidget);
  });
}
