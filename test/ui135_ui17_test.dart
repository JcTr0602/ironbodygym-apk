/// 1.35 (UI-17): el PIN a la altura del login — al
/// fallar: Tacto.error, sacudida de los puntos y error
/// anunciado con semántica de región viva; el estado de
/// los puntos también se anuncia («PIN: N de 4»).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ironbody_gym/ui/pin_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('la pantalla del PIN anuncia cuántos '
      'dígitos van y el teclado responde', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.runAsync(() async {
      try {
        await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'x');
      } catch (_) {}
    });
    t.view.physicalSize = const Size(420, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: PinLockScreen()));
    await t.pump();
    expect(find.text('App bloqueada'), findsOneWidget);
    expect(find.bySemanticsLabel('PIN: 0 de 4 dígitos'),
        findsOneWidget);
    await t.tap(find.text('1'));
    await t.pump();
    await t.tap(find.text('2'));
    await t.pump();
    expect(find.bySemanticsLabel('PIN: 2 de 4 dígitos'),
        findsOneWidget);
    // Drenar el temporizador de la cuenta atrás si nació.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });

  test('contrato: fallo con Tacto.error, sacudida y '
      'región viva', () {
    final src = File('lib/ui/pin_lock.dart').readAsStringSync();
    expect(src, contains('Tacto.error()'));
    expect(src, contains('_sacudir()'));
    expect(src, contains('liveRegion: true'));
    expect(src, contains('disableAnimationsOf'));
    expect(src, contains('de 4 dígitos'));
  });
}
