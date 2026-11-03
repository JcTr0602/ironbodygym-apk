/// Caza 1.21 — tests pedidos por Argón en su auditoría del
/// módulo Acceso (2026-11-02):
///  #1 la foto de permisos es POR USUARIO: tras limpiar, otro
///     usuario sin red NO hereda la foto anterior.
///  #2 fail-closed: sin foto (caché vacía y refresco fallido)
///     un no-dueño cuenta como «sin habilitar», no entra.
///  #6 PIN: un adelanto de reloj pasado no deja el bloqueo
///     pegado: la expiración monotónica manda.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/perfil.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('Argón Acceso #1/#2: permisos por usuario, fail-closed', () {
    setUp(() async {
      PermisosEntrenador().limpiar();
      final p = await SharedPreferences.getInstance();
      await p.clear();
    });

    test('sin foto y sin red: fail-closed (sin habilitar)', () async {
      await PermisosEntrenador().cargar();
      final p = PermisosEntrenador();
      expect(p.cargado, isFalse);
      expect(p.sinHabilitar, isTrue,
          reason: 'sin foto no se entra a la interfaz principal');
      expect(p.estaSuspendido, isFalse);
      expect(p.canVerCifras, isFalse);
      expect(p.canVerTodosPagos, isFalse);
      expect(p.canCobrarPagos, isFalse);
    });

    test('foto propia offline: suspendido se respeta', () async {
      final p = await SharedPreferences.getInstance();
      // Claves del usuario actual (sin sesión en tests: sufijo '@').
      await p.setString(
          'cache_permisos_entrenador_json@',
          jsonEncode({'can_ver_cifras': false}));
      await p.setBool('cache_entrenador_activo@', false);
      await p.setBool('cache_entrenador_habilitado@', true);
      await PermisosEntrenador().cargar();
      final per = PermisosEntrenador();
      expect(per.cargado, isTrue);
      expect(per.estaSuspendido, isTrue);
      expect(per.sinHabilitar, isFalse);
      expect(per.canVerCifras, isFalse);
    });

    test('tras limpiar, el siguiente usuario NO hereda la foto',
        () async {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          'cache_permisos_entrenador_json@',
          jsonEncode({'can_ver_cifras': true, 'can_cobrar_pagos': true}));
      await p.setBool('cache_entrenador_activo@', true);
      await p.setBool('cache_entrenador_habilitado@', true);
      await PermisosEntrenador().cargar();
      expect(PermisosEntrenador().canVerCifras, isTrue);

      // Cierre de sesión: la memoria se limpia y la caché de
      // ESE usuario se borra (cambio de teléfono/usuario).
      PermisosEntrenador().limpiar();
      await p.remove('cache_permisos_entrenador_json@');
      await p.remove('cache_entrenador_activo@');
      await p.remove('cache_entrenador_habilitado@');
      await PermisosEntrenador().cargar();
      final per = PermisosEntrenador();
      expect(per.canVerCifras, isFalse);
      expect(per.canCobrarPagos, isFalse);
      expect(per.sinHabilitar, isTrue);
    });

    test(
        'migración: la foto global vieja se DESCARTA, no se adopta',
        () async {
      // Panel final 1.21 (Terra por Zen, BLOQUEANTE): la foto
      // global pre-1.21 no lleva identidad; adoptarla regalaba
      // los permisos de su dueño al primer usuario que entrara
      // tras actualizar (teléfono compartido, entrenador
      // offline). Ahora se borra sin copiarse a ninguna clave.
      final p = await SharedPreferences.getInstance();
      await p.setString('cache_permisos_entrenador_json',
          jsonEncode({'can_ver_cifras': true}));
      await p.setBool('cache_entrenador_activo', true);
      await p.setBool('cache_entrenador_habilitado', true);
      await PermisosEntrenador().cargar();
      expect(PermisosEntrenador().canVerCifras, isFalse);
      expect(PermisosEntrenador().sinHabilitar, isTrue);
      expect(p.containsKey('cache_permisos_entrenador_json'),
          isFalse);
      expect(p.containsKey('cache_entrenador_activo'), isFalse);
      expect(
          p.containsKey('cache_permisos_entrenador_json@'), isFalse);
    });
  });

  group('Argón Acceso #6: PIN con reloj adelantado y restaurado', () {
    const canal = MethodChannel('ironbody/seguridad');
    var monoSimulado = 0;

    setUp(() async {
      final p = await SharedPreferences.getInstance();
      await p.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(canal, (call) async {
        if (call.method == 'elapsedRealtime') return monoSimulado;
        return null;
      });
      const salt = '0123456789abcdef0123456789abcdef';
      final digest = _hashViejo('1234', salt);
      await p.setString('seg_pin_hash', 'v2\$$salt\$$digest');
      await p.setString('seg_pin_salt', salt);
      await p.setInt('seg_pin_fallos', 0);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(canal, null);
    });

    test('la expiración monotónica gana al anti-retroceso', () async {
      final p = await SharedPreferences.getInstance();
      final ahora = DateTime.now().millisecondsSinceEpoch;
      // Contaminación: el reloj estuvo +2 h y quedó grabado.
      await p.setInt(
          'seg_pin_ultima_vez', ahora + 2 * 60 * 60 * 1000);
      // Bloqueo de 1 min anclado en mono=1000000.
      await p.setInt('seg_pin_bloqueado_hasta', ahora + 60000);
      await p.setInt('seg_pin_duracion_ms', 60000);
      await p.setInt('seg_pin_mono_ancla', 1000000);

      // A los 30 s monotónicos: sigue bloqueado.
      monoSimulado = 1000000 + 30000;
      expect(
          await PerfilService.instance.verificarPin('1234'), isFalse);

      // A los 61 s: expiró en tiempo real; el PIN correcto
      // entra aunque el reloj de pared «no haya alcanzado» la
      // marca contaminada (antes: bloqueo fantasma de 2 h).
      monoSimulado = 1000000 + 61000;
      expect(
          await PerfilService.instance.verificarPin('1234'), isTrue);
      // Y la marca contaminada se re-basó al ahora real.
      final ultima = p.getInt('seg_pin_ultima_vez') ?? 0;
      expect(ultima <= DateTime.now().millisecondsSinceEpoch + 1000,
          isTrue);
    });
  });
}
