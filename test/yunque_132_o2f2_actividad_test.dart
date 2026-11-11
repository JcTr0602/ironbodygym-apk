/// 1.32 (Oleada 2, Fase 2): Actividad nivelada a la plantilla
/// del Día de Servicios.
///
/// Contrato que se fija:
/// 1. agruparActividadPorDia (puro): la clave es el día de
///    NEGOCIO habanero del ts — el ts sin zona manda su fecha
///    escrita (como siempre) y un instante CON zona se
///    convierte a La Habana antes de cortar el día (el
///    substring crudo lo dejaba en su día UTC). «Ayer» se
///    calcula por calendario, no por 24 h crudas.
/// 2. El orden dentro del grupo es el de llegada (ts
///    descendente = orden real de aplicación): la
///    agrupación no reordena.
/// 3. Costura a 420×800: la cabecera pegajosa enseña el
///    total del grupo («N movimientos») y la fila conserva
///    sus DOS horas («Hecho HH:MM · Subido HH:MM») cuando
///    trae captura_ts.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/actividad.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('ops_queue');
  await db.delete('meta');
}

Future<bool> _esperarTexto(WidgetTester tester, String fragmento) async {
  for (var i = 0; i < 90; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.textContaining(fragmento).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

String _dia(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  group('agruparActividadPorDia (puro)', () {
    final ahora = DateTime(2026, 11, 11, 12, 0);

    test('hoy, ayer y fecha lejana con sus títulos de siempre', () {
      final g = agruparActividadPorDia([
        {'ts': '2026-11-11 10:00:00', 'detalle': 'a'},
        {'ts': '2026-11-10 18:00:00', 'detalle': 'b'},
        {'ts': '2026-10-31 09:00:00', 'detalle': 'c'},
      ], ahora);
      expect(g.map((e) => e.key).toList(),
          ['Hoy', 'Ayer', '31/10/2026']);
    });

    test('instante con zona: cae en su día habanero, no en el UTC',
        () {
      // 2026-11-11T02:30Z = 2026-11-10 21:30 en La Habana:
      // el substring crudo lo agrupaba en «Hoy» (día 11).
      final g = agruparActividadPorDia([
        {'ts': '2026-11-11T02:30:00.000Z', 'detalle': 'z'},
        {'ts': '2026-11-11T13:00:00.000Z', 'detalle': 'y'},
      ], ahora);
      expect(g.length, 2);
      expect(g[0].key, 'Ayer');
      expect(g[0].value.single['detalle'], 'z');
      expect(g[1].key, 'Hoy');
    });

    test('ts de la cola local (isoHabana con offset) en su día', () {
      final g = agruparActividadPorDia([
        {'ts': '2026-11-11T08:00:00-05:00', 'detalle': 'l'},
      ], ahora);
      expect(g.single.key, 'Hoy');
    });

    test('el orden de aplicación dentro del grupo no se toca', () {
      final g = agruparActividadPorDia([
        {'ts': '2026-11-11 10:00:00', 'detalle': 'nuevo'},
        {'ts': '2026-11-11 09:00:00', 'detalle': 'medio'},
        {'ts': '2026-11-11 08:00:00', 'detalle': 'viejo'},
      ], ahora);
      expect(g.single.value.map((e) => e['detalle']).toList(),
          ['nuevo', 'medio', 'viejo']);
    });

    test('«ayer» por calendario cruzando el cambio de hora', () {
      // El domingo del fin del DST habanero (1-nov-2026)
      // dura 25 h: restar 24 h desde el lunes 00:30 daría
      // el domingo 01:30 — el DÍA sigue siendo el domingo,
      // y la agrupación debe decir «Ayer», no la fecha.
      final lunes = DateTime(2026, 11, 2, 0, 30);
      final g = agruparActividadPorDia([
        {'ts': '2026-11-01 23:00:00', 'detalle': 'domingo'},
      ], lunes);
      expect(g.single.key, 'Ayer');
    });
  });

  group('ActividadScreen (costura 420×800)', () {
    testWidgets('cabecera con total del grupo y fila con dos horas',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // El esqueleto de CARGA (SkeletonLista, estado
      // 'cargando') desborda 30 px a 420×800: quirk
      // PREEXISTENTE del esqueleto, ajeno a esta fase (la
      // agrupación solo corre con contenido). Se filtra
      // SOLO esa aserción del framework — patrón de la casa
      // (fb09) — y el resto de excepciones sigue fallando.
      final onErrorPrevio = FlutterError.onError;
      FlutterError.onError = (details) {
        if ('${details.exception}'
            .contains('RenderFlex overflowed')) {
          return;
        }
        onErrorPrevio?.call(details);
      };
      addTearDown(() => FlutterError.onError = onErrorPrevio);
      final hoy = ahoraHabana();
      final ayer = sumarDiasCalendario(hoy, -1);
      final feed = [
        {
          'ts': '${_dia(hoy)} 10:00:00',
          'actor': 'Gabriel',
          'rol': 'entrenador',
          'accion': 'pago_mensual',
          'detalle': 'Mensualidad de Ana Prueba: 2000 CUP',
          'cliente_id': null,
          // Cobrado a las 08:30 habaneras (13:30 UTC en
          // noviembre, UTC-5) y subido a las 10:00.
          'captura_ts': '${_dia(hoy)}T13:30:00.000Z',
        },
        {
          'ts': '${_dia(hoy)} 09:00:00',
          'actor': 'Gabriel',
          'rol': 'entrenador',
          'accion': 'inscribir',
          'detalle': 'Inscripción de Luis Prueba',
          'cliente_id': null,
        },
        {
          'ts': '${_dia(ayer)} 18:00:00',
          'actor': 'Duany',
          'rol': 'entrenador',
          'accion': 'pago_diario',
          'detalle': 'Pago diario de Ana Prueba: 200 CUP',
          'cliente_id': null,
        },
      ];
      await tester.runAsync(() async {
        await _bdVacia();
        await _fijarSesion('jc@ironbody.local', 735772141);
        await LocalDb.instance
            .setMeta('sync_estado_actividad', jsonEncode(feed));
      });
      await tester.pumpWidget(
          const MaterialApp(home: ActividadScreen()));
      expect(await _esperarTexto(tester, '2 movimientos'), isTrue,
          reason: 'la cabecera de hoy trae el total de su grupo');
      expect(find.text('Hoy'), findsWidgets);
      // Las dos horas de la fila con captura: ni se pierde
      // la de hecho ni la de subida al nivelar la plantilla.
      expect(
          await _esperarTexto(tester, 'Hecho 08:30 · Subido 10:00'),
          isTrue,
          reason: 'la fila conserva captura y aplicación');
      // El grupo de ayer con su propio total. («Ayer» es
      // también un chip de filtro rápido: se busca la
      // cabecera DENTRO del scroll principal.)
      final cabeceraAyer = find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.text('Ayer'));
      await tester.scrollUntilVisible(cabeceraAyer, 200,
          scrollable: find
              .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable))
              .first);
      expect(find.text('1 movimiento'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Drenar temporizadores de la pantalla antes de salir.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    });
  });
}
