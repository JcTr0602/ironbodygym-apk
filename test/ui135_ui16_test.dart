/// 1.35 (UI-16): el login deja de pelear con el teclado:
/// usuario con teclado de correo, sin corrector ni
/// sugerencias y pista de autorrelleno; contraseña con
/// su pista y «Entrar» desde su propio teclado (done);
/// el usuario avanza a la contraseña con «siguiente».
/// Y sus blancos sobre oscuro son tokens de diseno.dart.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/login.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('los campos del login traen el teclado y '
      'las pistas pedidas', (t) async {
    SharedPreferences.setMockInitialValues({});
    // Supabase se inicializa en zona real: en la zona
    // falsa del testWidgets sus temporizadores internos
    // quedan «pendientes» y tumban el test.
    await t.runAsync(() async {
      try {
        await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'x');
      } catch (_) {}
    });
    await t.pumpWidget(const MaterialApp(home: LoginScreen()));
    await t.pump();
    final campos = find.byType(TextField);
    expect(campos, findsNWidgets(2));
    final usuario = t.widget<TextField>(campos.at(0));
    expect(usuario.keyboardType, TextInputType.emailAddress);
    expect(usuario.autocorrect, isFalse);
    expect(usuario.enableSuggestions, isFalse);
    expect(usuario.autofillHints, contains(AutofillHints.username));
    expect(usuario.textInputAction, TextInputAction.next);
    expect(usuario.textCapitalization, TextCapitalization.none);
    final clave = t.widget<TextField>(campos.at(1));
    expect(clave.obscureText, isTrue);
    expect(clave.autocorrect, isFalse);
    expect(clave.enableSuggestions, isFalse);
    expect(clave.autofillHints, contains(AutofillHints.password));
    expect(clave.textInputAction, TextInputAction.done);
    // Drenar los temporizadores de la pantalla antes de
    // cerrar (la animación de entrada deja uno vivo).
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
  });

  test('contrato: los blancos del login son tokens', () {
    final src = File('lib/ui/login.dart').readAsStringSync();
    expect(src, isNot(contains('Colors.white')));
    expect(src, contains('AppColores.textoSobreOscuro'));
    expect(AppColores.textoSobreOscuro, const Color(0xFFFFFFFF));
    expect(AppColores.textoSobreOscuroTenue,
        const Color(0x61FFFFFF));
  });
}
