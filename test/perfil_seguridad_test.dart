/// Auditoría perfil 2026-10-28: regresiones de los hallazgos
/// verificados contra el código vivo y corregidos.
/// - El hash v2 optimizado con buffer debe dar EXACTAMENTE el mismo
///   digest que el algoritmo viejo (si cambiara, ningún PIN guardado
///   funcionaría). Se comprueba con un hash precalculado con el
///   algoritmo viejo y verificarPin().
/// - Acertar el PIN limpia seg_pin_ciclos_bloqueo (antes acumulaba
///   castigos de por vida).
/// - resetAjustes ya no borra móvil/carnet ni el pendiente de sync,
///   y sí limpia las claves de deslizamiento.
/// - getDeviceId nuevo genera UUID v4 y lo conserva.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/perfil.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Algoritmo viejo de _hashPinV2, copiado literal (10000 iteraciones
/// con listas nuevas). Si el nuevo con buffer da otro digest, el
/// test de verificarPin falla.
String _hashViejo(String pin, String saltHex) {
  List<int> actual = utf8.encode(saltHex + pin);
  final pinBytes = utf8.encode(pin);
  for (var i = 0; i < 10000; i++) {
    actual =
        List<int>.from(sha256.convert([...actual, ...pinBytes]).bytes);
  }
  return actual.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('PIN v2 con buffer', () {
    test('verificarPin acepta un hash calculado con el algoritmo viejo',
        () async {
      const salt = '0123456789abcdef0123456789abcdef';
      const pin = '1234';
      final digest = _hashViejo(pin, salt);
      final p = await SharedPreferences.getInstance();
      await p.setString('seg_pin_hash', 'v2\$$salt\$$digest');
      await p.setString('seg_pin_salt', salt);
      await p.setInt('seg_pin_ciclos_bloqueo', 2);
      await p.setInt('seg_pin_fallos', 0);
      expect(await PerfilService.instance.verificarPin(pin), isTrue);
      // Acertar limpia los ciclos (antes quedaban en 2 para siempre).
      expect(p.getInt('seg_pin_ciclos_bloqueo'), 0);
      expect(await PerfilService.instance.verificarPin('0000'), isFalse);
    });
  });

  group('getDeviceId', () {
    test('sin id guardado genera UUID v4 y lo conserva', () async {
      final p = await SharedPreferences.getInstance();
      await p.remove('seg_device_id');
      final id1 = await PerfilService.instance.getDeviceId();
      final id2 = await PerfilService.instance.getDeviceId();
      expect(id1, equals(id2));
      expect(
          id1,
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });
  });

  group('resetAjustes', () {
    test('no borra identidad ni pendiente; sí limpia deslizamiento',
        () async {
      final p = await SharedPreferences.getInstance();
      await p.setString('perfil_movil', '51234567');
      await p.setString('perfil_carnet', '99010112345');
      await p.setBool('perfil_sucio', true);
      await p.setString('buscar_swipe_der', 'venta');
      await p.setString('buscar_swipe_izq', 'diario');
      await p.setString('nombre_visible', 'Mi Nombre');
      await PerfilService.instance.resetAjustes();
      // Identidad y pendiente intactos (antes móvil/carnet se
      // borraban y el sync subía nulls a la nube).
      expect(p.getString('perfil_movil'), '51234567');
      expect(p.getString('perfil_carnet'), '99010112345');
      expect(p.getBool('perfil_sucio'), isTrue);
      // Preferencias sí restablecidas, incluidas las de deslizamiento.
      expect(p.getString('buscar_swipe_der'), isNull);
      expect(p.getString('buscar_swipe_izq'), isNull);
      expect(p.getString('nombre_visible'), isNull);
    });
  });
}
