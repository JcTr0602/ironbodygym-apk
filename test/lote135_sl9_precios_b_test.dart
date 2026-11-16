/// LOTE 1.35 · SL-9 — Pieza B (chequeo PreciosMetodoScreen) y
/// puros de A1.
///
/// B · VEREDICTO (con el código en la mano): la divergencia
/// ES REAL.
///
/// - PreciosMetodoScreen vive en lib/ui/panel_resto_caja.dart
///   (FUERA del mapa de SL-9: carril excluido expresamente) y
///   su autoguardado llama a `guardarConfigGym({clave: valor})`
///   (lib/bloque2_resto.dart), que escribe SOLO la clave plana
///   en ajustes + op `actualizar_config_gym`. Para la clave
///   'mensualidad_menores' NO toca el blob `tipos_pago`.
/// - `precioMenoresDesdeAjustes` (lib/tipos_pago.dart) lee
///   PRIMERO el blob `tipos_pago` (tipo 'menores') y solo cae
///   a la clave plana si el blob no trae precio válido. Es la
///   fuente única de: negocio.preciosVigentes,
///   precioMenor()/getTiposPago (el cobro), el diagnóstico de
///   admin_secciones y admin.dart.
/// - La OTRA vía de edición (el Panel, aplicarCambiosMontos
///   en lib/ui/config_precios_bancarios.dart) SÍ escribe las
///   dos cosas en una transacción (clave + blob vía
///   blobTiposConPrecioMenores + op guardar_tipos_pago) —
///   corrección A5-D2 de la 1.28, que no se aplicó a la vía
///   C6/PreciosMetodoScreen.
///
/// Consecuencia: tras editar «Mensualidad menores» en
/// PreciosMetodoScreen, la clave plana dice el precio nuevo
/// pero TODO lo que cobra sigue leyendo el precio viejo del
/// blob hasta que alguien guarde por la otra vía. Estos tests
/// lo fijan como caracterización (pasan con el comportamiento
/// actual): la corrección vive fuera del mapa de SL-9
/// (panel_resto_caja.dart / bloque2_resto.dart) y se reporta
/// como ancla fuera de mapa, sin invadir.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:ironbody_gym/ui/admin.dart';
import 'package:ironbody_gym/ui/config_precios_bancarios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

const _blobBase = [
  {'id': 'mensual', 'nombre': 'Mensualidad', 'monto': 2000.0, 'dias': 30, 'activo': true},
  {'id': 'menores', 'nombre': 'Mensualidad menores', 'monto': 1500.0, 'dias': 30, 'activo': true, 'solo_menores': true},
  {'id': 'semanal', 'nombre': 'Semana', 'monto': 600.0, 'dias': 7, 'activo': true},
  {'id': 'quincenal', 'nombre': 'Quincena', 'monto': 1200.0, 'dias': 15, 'activo': true},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
    final sesion = jsonEncode({
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-de-mentira',
      'user': {
        'id': '00000000-0000-0000-0000-0000000000dd',
        'aud': 'authenticated',
        'email': 'jc@ironbody.local',
        'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
        'user_metadata': <String, dynamic>{},
        'created_at': '2024-01-01T00:00:00.000Z',
      },
    });
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });

  Future<void> bdConPrecios() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    await LocalDb.instance.setAjustes({
      'mensualidad': 2000.0,
      'mensualidad_menores': 1500.0,
      'tipos_pago': _blobBase,
    });
  }

  group('B · divergencia del precio de menores', () {
    test('la vía PreciosMetodoScreen (guardarConfigGym) mueve '
        'la clave pero NO el blob: las lecturas del cobro '
        'siguen en el precio viejo', () async {
      await bdConPrecios();
      // Exactamente la llamada de _autoguardar en
      // PreciosMetodoScreen para 'mensualidad_menores'.
      await guardarConfigGym({'mensualidad_menores': 1800.0});
      final aj = await LocalDb.instance.getAjustes();
      // La clave plana SÍ cambió (lo que la pantalla enseña).
      expect(aj['mensualidad_menores'], 1800.0);
      // Pero la fuente única del cobro lee el blob primero:
      // sigue devolviendo 1500. DIVERGENCIA REAL.
      expect(precioMenoresDesdeAjustes(aj), 1500.0,
          reason: 'el blob tipos_pago manda y guardarConfigGym '
              'no lo actualizó');
      final tipos = await getTiposPago(soloActivos: false, paraMenor: true);
      expect(tipos.singleWhere((t) => t.id == 'menores').monto, 1500.0,
          reason: 'el diálogo de cobro cobraría el precio viejo');
    });

    test('la vía del Panel (aplicarCambiosMontos) SÍ mantiene '
        'las dos escrituras en acuerdo', () async {
      await bdConPrecios();
      await aplicarCambiosMontos({'mensualidad_menores': 1800.0});
      final aj = await LocalDb.instance.getAjustes();
      expect(aj['mensualidad_menores'], 1800.0);
      expect(precioMenoresDesdeAjustes(aj), 1800.0,
          reason: 'esta vía escribe clave + blob en una '
              'transacción (A5-D2): sin divergencia');
    });
  });

  group('A1 · puros del diff de precios', () {
    test('lineasDiffMontos solo lista lo que cambia, con '
        'viejo → nuevo', () {
      final lineas = lineasDiffMontos(
        {'mensualidad_menores': 1800.0, 'tasa_usd': 250.0},
        {'mensualidad_menores': 1500.0, 'tasa_usd': 250.0},
      );
      expect(lineas, hasLength(1));
      expect(lineas.single, contains('Mensualidad menores'));
      expect(lineas.single, contains('→'));
      expect(lineas.single, contains('1800'));
    });

    test('textoDiffTipoPago vacío si el tipo no cambia', () {
      const t = TipoPago(
          id: 'mensual', nombre: 'Mensualidad', monto: 2000, dias: 30);
      expect(textoDiffTipoPago(t, t), isEmpty);
      const t2 = TipoPago(
          id: 'mensual', nombre: 'Mensualidad', monto: 2500, dias: 30);
      expect(textoDiffTipoPago(t, t2), contains('→'));
      expect(textoDiffTipoPago(t, t2), contains('2500'));
    });

    test('lineasDiffTipos detecta altas, bajas y cambios', () {
      const antes = [
        TipoPago(id: 'mensual', nombre: 'Mensualidad', monto: 2000, dias: 30),
        TipoPago(id: 'semanal', nombre: 'Semana', monto: 600, dias: 7),
      ];
      const despues = [
        TipoPago(id: 'mensual', nombre: 'Mensualidad', monto: 2500, dias: 30),
        TipoPago(id: 'anual', nombre: 'Anual', monto: 20000, dias: 365),
      ];
      final lineas = lineasDiffTipos(antes, despues);
      expect(lineas, hasLength(3));
      expect(lineas.join('\n'), contains('Se elimina: Semana'));
      expect(lineas.join('\n'), contains('Nuevo: Anual'));
    });
  });
}
