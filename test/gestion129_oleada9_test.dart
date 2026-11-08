/// Gestión 1.29 · Oleada 9 (cierre OG-5).
///
/// Lo que esta oleada certifica, punto por punto del plan §10:
/// · D-07 · Un concepto = un icono: las variantes extinguidas
///   de la tabla canónica (estudio_diseno.md §4.2) dan 0 en
///   todo `lib/` — `warning_rounded` en rol de estado,
///   `error_rounded`, `info_outline_rounded`, `delete_rounded`,
///   `person_add_alt*`, `camera_alt_rounded` y
///   `lock_outline_rounded` fuera de su rol. `delete_sweep`
///   sobrevive SOLO en su rol propio, «vaciar» (los dos usos
///   de «Reiniciar bitácora» de ajustes).
/// · Cabo O5 · El dock `_mostradorRapido` deja de forzar
///   blanco sobre naranja: su frente es `sobreMarca` (la
///   regla D-01: 6,32:1 contra 2,75:1 del blanco).
/// · Cabo O5 · El gradiente del FAB del dial vive tokenizado
///   con nombre propio (`AppColores.gradienteDial`), con los
///   mismos extremos de siempre (#FF8A00 → #EA580C).
/// · Cabo O6 · El esqueleto de carga de Auditoría a 800×600
///   ya no desborda: la pantalla se pinta en ventana baja,
///   cargando y cargada, sin excepción de layout. (En la O6
///   desbordaba 16 px y el test de FB-16 tuvo que usar
///   superficie de teléfono real; la reordenación de la O8
///   metió el cuerpo vacío/cargando en un scroll propio y
///   esta es su constancia.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés común (la pauta de las oleadas 4–8) ─────────

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(
    WidgetTester tester, String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {
        'telegram_id': telegramId,
        'provider': 'email'
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _sesionDueno(WidgetTester t) =>
    _fijarSesion(t, 'jc@ironbody.local', 735772141);

Future<Database> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// El banner de sync programa un temporizador de un solo
/// disparo (≤30 s) al pintar un resumen reciente: se drena
/// avanzando el reloj falso más allá (pauta de la casa).
Future<void> _drenarBanner(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 31));
}

/// Todo el código fuente de `lib/`, archivo a archivo.
Map<String, String> _fuentesLib() {
  final raiz = Directory('lib');
  final out = <String, String>{};
  for (final e in raiz.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) {
      out[e.path] = e.readAsStringSync();
    }
  }
  return out;
}

int _cuenta(Map<String, String> fuentes, String patron) {
  final re = RegExp(patron);
  var n = 0;
  for (final texto in fuentes.values) {
    n += re.allMatches(texto).length;
  }
  return n;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
        url: 'http://127.0.0.1:9',
        anonKey: 'dummy',
      );
    } catch (_) {}
  });

  group('D-07 · variantes extinguidas a cero', () {
    final fuentes = _fuentesLib();

    test('warning_rounded / error_rounded / info_outline_rounded: 0',
        () {
      // Ojo: los canónicos (warning_amber_rounded,
      // error_outline_rounded, info_rounded) NO contienen
      // estas cadenas como subcadena exacta con el prefijo
      // Icons. — el conteo es de la variante extinguida.
      expect(_cuenta(fuentes, r'Icons\.warning_rounded\b'), 0,
          reason: 'el aviso de estado canónico es '
              'warning_amber_rounded');
      expect(_cuenta(fuentes, r'Icons\.error_rounded\b'), 0,
          reason: 'el error de estado canónico es '
              'error_outline_rounded');
      expect(_cuenta(fuentes, r'Icons\.info_outline_rounded\b'), 0,
          reason: 'la info de estado canónica es info_rounded');
    });

    test('delete_rounded / person_add_alt / camera_alt / '
        'lock_outline: 0', () {
      expect(_cuenta(fuentes, r'Icons\.delete_rounded\b'), 0,
          reason: 'eliminar canónico: delete_outline_rounded');
      expect(_cuenta(fuentes, r'Icons\.person_add_alt'), 0,
          reason: 'inscribir canónico: person_add_rounded '
              '(ni alt ni alt_1)');
      expect(_cuenta(fuentes, r'Icons\.camera_alt_rounded\b'), 0,
          reason: 'cámara canónica: photo_camera_rounded');
      expect(_cuenta(fuentes, r'Icons\.lock_outline_rounded\b'), 0,
          reason: 'candado canónico: lock_rounded / '
              'lock_open_rounded');
    });

    test('delete_sweep_rounded sobrevive SOLO en «vaciar» '
        '(reiniciar bitácora, ajustes)', () {
      final conSweep = fuentes.entries
          .where((e) => e.value.contains('Icons.delete_sweep_rounded'))
          .map((e) => e.key)
          .toList();
      expect(conSweep, ['lib/ui/ajustes.dart'],
          reason: 'fuera de ajustes no hay ningún vaciar con '
              'este glifo');
      expect(
          _cuenta(fuentes, r'Icons\.delete_sweep_rounded\b'), 2,
          reason: 'los dos usos son el diálogo y la opción de '
              '«Reiniciar bitácora» (vaciar el registro)');
    });
  });

  group('Cabos de diseño · dock y FAB (fuente y token)', () {
    test('el dock _mostradorRapido va en sobreMarca, no en blanco',
        () {
      final home = File('lib/ui/home.dart').readAsStringSync();
      final ini = home.indexOf('Widget _mostradorRapido()');
      final fin = home.indexOf('Widget _cabecera()', ini);
      expect(ini, greaterThanOrEqualTo(0));
      expect(fin, greaterThan(ini));
      final dock = home.substring(ini, fin);
      expect(dock.contains('foregroundColor: AppColores.sobreMarca'),
          isTrue,
          reason: 'sobre la marca va sobreMarca (D-01)');
      expect(dock.contains('foregroundColor: Colors.white'), isFalse,
          reason: 'el blanco sobre naranja (2,75:1) era el cabo');
    });

    test('el FAB del dial usa el token propio gradienteDial', () {
      final home = File('lib/ui/home.dart').readAsStringSync();
      expect(home.contains('AppColores.gradienteDial'), isTrue);
      expect(home.contains('Color(0xFFFF8A00)'), isFalse,
          reason: 'el extremo del dial ya no es un literal '
              'en home.dart: vive en diseno.dart');
      expect(AppColores.gradienteDial.colors,
          const [Color(0xFFFF8A00), Color(0xFFEA580C)],
          reason: 'los extremos de siempre, sin cambio visual');
      expect(AppColores.gradienteDial.begin, Alignment.topLeft);
      expect(AppColores.gradienteDial.end, Alignment.bottomRight);
    });
  });

  group('Cabo O6 · esqueleto de Auditoría en ventana baja', () {
    testWidgets('a 800×600 no desborda ni cargando ni cargada',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: AuditoriaScreen()));
      // Primer frame: la pantalla está cargando y pinta el
      // esqueleto con la forma de la lista — a 800×600 era
      // donde desbordaba 16 px en la O6.
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'el esqueleto no desborda en ventana baja');
      await _pumps(tester, 20);
      expect(tester.takeException(), isNull,
          reason: 'ni el estado cargado (vacío) desborda');
      expect(find.text('Sin operaciones registradas'),
          findsOneWidget);
      await _drenarBanner(tester);
    });
  });
}
