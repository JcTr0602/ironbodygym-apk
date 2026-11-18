/// Corrección ARG136-10 (adjudicación Argón 1.36, residuo
/// de V5): «Reducir movimiento» sobrevivía a «Restablecer
/// ajustes» en las dos capas — `PerfilService.resetAjustes`
/// no borraba la clave 'reducir_movimiento_v1' (sí borraba
/// 'modo_sol_v1' y 'alto_contraste') y `_restablecer` de
/// Ajustes no resincronizaba el notificador con
/// `ThemeController.setReducirMovimiento(false)` (sí lo
/// hacía con tema, escala, alto contraste y modo sol).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/perfil.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // resetAjustes resuelve claves por usuario vía
    // AuthService: Supabase debe existir aunque sea de
    // mentira (la pauta de perfil_seguridad_test: primero
    // el mock de preferencias, que el propio initialize
    // toca).
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('resetAjustes borra también reducir_movimiento_v1',
      () async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('reducir_movimiento_v1', true);
    await p.setBool('modo_sol_v1', true);
    await PerfilService.instance.resetAjustes();
    expect(p.getBool('reducir_movimiento_v1'), isNull,
        reason: 'el ajuste restablecido no puede sobrevivir '
            'en la clave que lee ThemeController al arrancar');
    expect(p.getBool('modo_sol_v1'), isNull,
        reason: 'control: la clave vecina ya se borraba');
  });

  test('_restablecer resincroniza el notificador de '
      'reducir movimiento (contrato de fuente)', () {
    final src = File('lib/ui/ajustes.dart').readAsStringSync();
    final i = src.indexOf('Future<void> _restablecer()');
    expect(i, greaterThanOrEqualTo(0));
    final cuerpo = src.substring(i, i + 1800);
    expect(cuerpo.contains('setReducirMovimiento(false)'), isTrue,
        reason: 'sin la resincronización, la sesión sigue '
            'sin animaciones aunque la clave se borre');
  });
}
