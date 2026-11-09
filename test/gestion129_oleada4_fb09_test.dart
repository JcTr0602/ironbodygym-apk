/// Gestión 1.29 · Oleada 4 · FB-09 (solicitudes de relleno)
/// + D-10 (iconos propios en venta y stock) + D-11 (punto de
/// color del entrenador).
///
/// Contrato que se fija:
/// 1. El puro fusiona espejo + ops en cola ('por_enviar') e
///    ignora payloads malformados y ops de otro tipo.
/// 2. pedir() encola la op con el payload del contrato
///    {suplemento_id, dosis_al_pedir}; mias() atribuye por la
///    sesión; tengoPendientePara detecta la petición viva;
///    pendientesParaDueno() lee solo el espejo pendiente.
/// 6. Ajuste H-03 de Argón al código de la 1.29: la petición
///    sigue VIVA con la op en 'enviada' o en 'error' (antes
///    solo 'pendiente': en vuelo desaparecía de «mías» y la
///    banda volvía a ofrecer «Pedir relleno», duplicando);
///    si el espejo ya trae la 'pendiente' de ese suplemento,
///    la op no se duplica; pedir() dispara el empujón del
///    motor al encolar.
/// 3. El espejo local nace con watermark 0 (sin heredar el
///    global: su descarga inicial no se salta).
/// 4. Pantalla del entrenador: con el pomo bajo se ve
///    «Pedir relleno»; al tocarlo la op queda encolada con
///    el saldo local como dosis_al_pedir y la banda pasa a
///    «Ya pediste relleno». La venta enseña IconoDosis ≥ 22.
/// 5. Pantalla del dueño: la sección lista la petición y
///    «Rellenar» abre el diálogo de ESE pomo; al rellenar,
///    la op reponer_pomo queda encolada y la petición se
///    oculta en la pantalla. Las filas de pomos llevan el
///    punto de color del entrenador (D-11) y el stock se
///    encabeza con IconoPomo (D-10).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque3.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/iconos_propios.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:ironbody_gym/ui/servicios_admin.dart';
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

Future<void> _fijarSesion({
  required String email,
  required int telegramId,
}) async {
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
  for (final t in [
    'ops_queue',
    'solicitudes_relleno',
    'servicio_pomos',
    'suplementos',
  ]) {
    try {
      await db.delete(t);
    } catch (_) {}
  }
  await db.delete('meta');
}

Future<void> _espejo(
    String tabla, Object id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': 1,
  });
}

/// Sondeo intercalado runAsync+pump (patrón de la casa para
/// pantallas con lecturas FFI bajo FakeAsync).
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

Future<void> _ciclos(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('FB-09 puros y servicio', () {
    test('el puro fusiona espejo + cola e ignora basura', () {
      final espejo = [
        const SolicitudRelleno(
            id: 's1', estado: 'pendiente', suplementoId: 7),
      ];
      final out = solicitudesRellenoConPendientes(
        espejo: espejo,
        opsPendientes: [
          {
            'tipo': 'solicitar_relleno',
            'estado': 'pendiente',
            'op_uuid': 'op-1',
            'payload': jsonEncode(
                {'suplemento_id': 9, 'dosis_al_pedir': 2}),
            'creada_ts': '2026-11-07T10:00:00',
          },
          {
            'tipo': 'solicitar_relleno',
            'estado': 'pendiente',
            'op_uuid': 'op-2',
            'payload': '{"sin_suplemento":true}',
            'creada_ts': '2026-11-07T11:00:00',
          },
          {
            'tipo': 'venta_servicio',
            'estado': 'pendiente',
            'op_uuid': 'op-3',
            'payload': jsonEncode({'suplemento_id': 9}),
            'creada_ts': '2026-11-07T12:00:00',
          },
          {
            'tipo': 'solicitar_relleno',
            'estado': 'enviada',
            'op_uuid': 'op-4',
            'payload': jsonEncode({'suplemento_id': 9}),
            'creada_ts': '2026-11-07T13:00:00',
          },
          {
            'tipo': 'solicitar_relleno',
            'estado': 'error',
            'op_uuid': 'op-5',
            'payload': jsonEncode({'suplemento_id': 11}),
            'creada_ts': '2026-11-07T14:00:00',
          },
        ],
      );
      // H-03 (ajuste de Argón a la 1.29): la petición sigue
      // viva en 'enviada' y en 'error'. Este mismo test
      // fijaba antes que la 'enviada' NO entraba — que era
      // justo el defecto: la petición desaparecía en vuelo y
      // la banda volvía a ofrecer «Pedir relleno».
      expect(out.length, 4);
      expect(out.first.id, 'op:op-5');
      expect(out.first.estado, 'por_enviar');
      expect(out[1].id, 'op:op-4');
      expect(out[1].estado, 'por_enviar');
      expect(out[2].id, 'op:op-1');
      expect(out[2].suplementoId, 9);
      expect(out.last.id, 's1');
    });

    test('H-03: si el espejo ya trae la pendiente de ese '
        'suplemento, la op no se duplica como por_enviar', () {
      final espejo = [
        const SolicitudRelleno(
            id: 's9', estado: 'pendiente', suplementoId: 9),
      ];
      final out = solicitudesRellenoConPendientes(
        espejo: espejo,
        opsPendientes: [
          {
            'tipo': 'solicitar_relleno',
            'estado': 'enviada',
            'op_uuid': 'op-9',
            'payload': jsonEncode(
                {'suplemento_id': 9, 'dosis_al_pedir': 1}),
            'creada_ts': '2026-11-07T13:00:00',
          },
          {
            'tipo': 'solicitar_relleno',
            'estado': 'pendiente',
            'op_uuid': 'op-10',
            'payload': jsonEncode(
                {'suplemento_id': 4, 'dosis_al_pedir': 1}),
            'creada_ts': '2026-11-07T13:05:00',
          },
        ],
      );
      expect(out.length, 2);
      expect(out.any((s) => s.id == 'op:op-9'), isFalse,
          reason: 'la misma petición no vive dos veces: '
              'ya bajó al espejo como pendiente');
      expect(out.any((s) => s.id == 'op:op-10'), isTrue,
          reason: 'la de otro suplemento sí entra');
    });

    test('pedir encola el payload del contrato y mias lo ve',
        () async {
      await _bdVacia();
      await _fijarSesion(
          email: 'gabriel@ironbody.gym', telegramId: 222222);
      await SolicitudesRellenoService.instance
          .pedir(suplementoId: 7, dosisAlPedir: 3);
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['solicitar_relleno']);
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.single['payload'] as String) as Map;
      expect(payload, {'suplemento_id': 7, 'dosis_al_pedir': 3});
      expect(await SolicitudesRellenoService.instance
          .tengoPendientePara(7), isTrue);
      expect(await SolicitudesRellenoService.instance
          .tengoPendientePara(8), isFalse);
      final mias = await SolicitudesRellenoService.instance.mias();
      expect(mias.length, 1);
      expect(mias.single.estado, 'por_enviar');
    });

    test('H-03: la petición sigue viva con la op en '
        'enviada y en error (no se ofrece dos veces)',
        () async {
      await _bdVacia();
      await _fijarSesion(
          email: 'gabriel@ironbody.gym', telegramId: 222222);
      await SolicitudesRellenoService.instance
          .pedir(suplementoId: 7, dosisAlPedir: 3);
      final db = await LocalDb.instance.db;
      // La op pasa a 'enviada' (en vuelo): antes la
      // petición desaparecía de «mías» en esta ventana y la
      // banda de pomo bajo volvía a ofrecer el botón.
      await db.update('ops_queue', {'estado': 'enviada'},
          where: 'tipo = ?', whereArgs: ['solicitar_relleno']);
      expect(await SolicitudesRellenoService.instance
          .tengoPendientePara(7), isTrue);
      var mias = await SolicitudesRellenoService.instance.mias();
      expect(mias.length, 1);
      expect(mias.single.estado, 'por_enviar');
      // Y en 'error' (subida fallida, reintentable): igual.
      await db.update('ops_queue', {'estado': 'error'},
          where: 'tipo = ?', whereArgs: ['solicitar_relleno']);
      expect(await SolicitudesRellenoService.instance
          .tengoPendientePara(7), isTrue);
      mias = await SolicitudesRellenoService.instance.mias();
      expect(mias.length, 1);
      expect(mias.single.estado, 'por_enviar');
    });

    test('el espejo nace con watermark 0 y el dueño lee sus '
        'pendientes del espejo', () async {
      await _bdVacia();
      expect(
          await LocalDb.instance.getWatermarkTabla(
              'solicitudes_relleno'),
          0);
      await _espejo('solicitudes_relleno', 'sol-1', {
        'id': 'sol-1',
        'entrenador_telegram_id': 111111,
        'entrenador_nombre': 'Duany',
        'suplemento_id': 7,
        'suplemento_nombre': 'C4',
        'estado': 'pendiente',
        'creado_en': '2026-11-07T10:00:00',
      });
      await _espejo('solicitudes_relleno', 'sol-2', {
        'id': 'sol-2',
        'entrenador_telegram_id': 111111,
        'suplemento_id': 7,
        'estado': 'atendida',
        'motivo_cierre': 'relleno',
        'creado_en': '2026-11-06T10:00:00',
      });
      final pend = await SolicitudesRellenoService.instance
          .pendientesParaDueno();
      expect(pend.length, 1);
      expect(pend.single.id, 'sol-1');
      expect(pend.single.suplementoNombre, 'C4');
    });
  });

  group('FB-09 pantallas + D-10/D-11', () {
    testWidgets(
        'entrenador: pomo bajo → Pedir relleno encola y la '
        'banda cambia; la venta enseña IconoDosis ≥ 22',
        (tester) async {
      // La siembra va en runAsync: bajo la zona FakeAsync de
      // testWidgets, los await de BD no entregan sin ciclos
      // reales (patrón de la casa, m3bc). La BD de este
      // archivo usa la factoría FFI sin isolate: con la de
      // isolate, las consultas del ciclo de sync desde la
      // zona falsa se quedan sin respuesta y el ciclo nunca
      // termina (Timer vivo al desmontar).
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.setMeta(
            'usuarios_apk',
            jsonEncode([
              {
                'telegram_id': 222222,
                'nombre': 'Gabriel',
                'username': 'gabriel'
              },
            ]));
        await _espejo('suplementos', 7, {'id': 7, 'nombre': 'C4'});
        await _espejo('servicio_pomos', 10, {
          'suplemento_id': 7,
          'titular_telegram_id': 222222,
          'es_principal': 0,
          'dosis_asignadas': 3,
          'dosis_repartidas': 0,
          'activo': 1,
        });
        await _fijarSesion(
            email: 'gabriel@ironbody.gym', telegramId: 222222);
      });
      await tester
          .pumpWidget(const MaterialApp(home: ServiciosScreen()));
      expect(await _esperarTexto(tester, 'Pedir relleno'), isTrue,
          reason: 'la banda de pomo bajo ofrece pedir relleno');

      final icono = find.byType(IconoDosis);
      expect(icono, findsOneWidget);
      expect(tester.getSize(icono).width, greaterThanOrEqualTo(22));

      await tester.tap(find.text('Pedir relleno'));
      // 1.30 (D3, UI130-15): pedir relleno ahora se confirma
      // en una HojaAccion antes de enviarse (antes era acción
      // directa). El contrato de la op encolada no cambia:
      // un toque más en «Enviar pedido» y la op es la misma.
      expect(await _esperarTexto(tester, 'Enviar pedido'),
          isTrue,
          reason: 'la hoja de confirmación se abre');
      // La hoja entra animada desde abajo: hay que dejarla
      // asentar antes de tocar (sin esto el toque cae en la
      // posición de entrada, fuera de la pantalla).
      await _ciclos(tester, 8);
      await tester.tap(find.text('Enviar pedido'));
      expect(await _esperarTexto(tester, 'Ya pediste relleno'),
          isTrue);
      final ops = (await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        return db.query('ops_queue',
            where: 'tipo = ?', whereArgs: ['solicitar_relleno']);
      }))!;
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.single['payload'] as String) as Map;
      expect(payload['suplemento_id'], 7);
      expect(payload['dosis_al_pedir'], 3,
          reason: 'el saldo local que el entrenador veía');
      // H-03: pedir() ahora dispara el empujón del motor;
      // el ciclo de sync que arranca se drena entrelazado
      // antes de desmontar (mismo patrón que el test del
      // dueño, abajo).
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'dueño: la sección resuelve con un toque y las filas '
        'llevan el punto del entrenador', (tester) async {
      // Pantalla larga: viewport alto para que la vista
      // perezosa construya también lo de abajo (patrón de la
      // casa, bloque4_t5).
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Las filas con onTap dentro de Tarjeta disparan la
      // aserción de tinta de ListTile del framework en cada
      // rebuild (patrón visual preexistente de la app, ajeno
      // a esta oleada): se filtra SOLO esa aserción para que
      // el resto de excepciones (p. ej. un used-after-dispose
      // del diálogo) sigan fallando el test.
      final onErrorPrevio = FlutterError.onError;
      FlutterError.onError = (details) {
        if ('${details.exception}'
            .contains('ListTile background color')) {
          return;
        }
        onErrorPrevio?.call(details);
      };
      addTearDown(() => FlutterError.onError = onErrorPrevio);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.setMeta(
            'usuarios_apk',
            jsonEncode([
              {
                'telegram_id': 735772141,
                'nombre': 'Jc',
                'username': 'jctr0602'
              },
              {
                'telegram_id': 111111,
                'nombre': 'Duany',
                'username': 'duany'
              },
              {
                'telegram_id': 222222,
                'nombre': 'Gabriel',
                'username': 'gabriel'
              },
            ]));
        await _espejo('suplementos', 7, {'id': 7, 'nombre': 'C4'});
        await _espejo('servicio_pomos', 20, {
          'suplemento_id': 7,
          'titular_telegram_id': 735772141,
          'es_principal': 1,
          'dosis_asignadas': 50,
          'dosis_repartidas': 0,
          'activo': 1,
        });
        await _espejo('servicio_pomos', 10, {
          'suplemento_id': 7,
          'titular_telegram_id': 111111,
          'es_principal': 0,
          'dosis_asignadas': 3,
          'dosis_repartidas': 0,
          'activo': 1,
        });
        await _espejo('solicitudes_relleno', 'sol-1', {
          'id': 'sol-1',
          'entrenador_telegram_id': 111111,
          'entrenador_nombre': 'Duany',
          'suplemento_id': 7,
          'suplemento_nombre': 'C4',
          'estado': 'pendiente',
          'creado_en': '2026-11-07T10:00:00',
        });
        await _fijarSesion(
            email: 'jctr0602@ironbody.gym', telegramId: 735772141);
      });
      await tester.pumpWidget(
          const MaterialApp(home: ServiciosAdminScreen()));
      expect(
          await _esperarTexto(tester, 'Solicitudes de relleno'),
          isTrue);

      expect(find.textContaining('Duany · C4'), findsWidgets);

      // D-10: el stock se encabeza con el icono propio.
      expect(find.byType(IconoPomo), findsWidgets);
      expect(tester.getSize(find.byType(IconoPomo).first).width,
          greaterThanOrEqualTo(22));

      // D-11: el punto de Duany (posición 1) está en su fila.
      final ctx = tester.element(find.byType(ServiciosAdminScreen));
      final colorDuany = AppColores.colorEntrenador(ctx, 1);
      final punto = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle &&
          (w.decoration as BoxDecoration).color == colorDuany);
      expect(punto, findsOneWidget);

      // Un toque abre el diálogo de ESE pomo; rellenar encola
      // la op y la petición se oculta en la pantalla.
      final botonSeccion = find.widgetWithText(FilledButton, 'Rellenar');
      expect(botonSeccion, findsOneWidget);
      await tester.tap(botonSeccion);
      expect(
          await _esperarTexto(tester, 'Rellenar pomo · Duany'),
          isTrue);
      // El campo del diálogo por su etiqueta: la pantalla
      // tiene otros TextField en línea (comisión) que van
      // antes en el árbol.
      await tester.enterText(
          find.byWidgetPredicate((w) =>
              w is TextField &&
              w.decoration?.labelText == 'Dosis a rellenar'),
          '6');
      // Con el diálogo abierto hay dos «Rellenar» en el
      // árbol: el de la sección (debajo) y el del diálogo
      // (encima, el último). Se toca el del diálogo; que la
      // sección desaparezca al final verifica el flujo.
      await tester
          .tap(find.widgetWithText(FilledButton, 'Rellenar').last);
      await _ciclos(tester);
      expect(await _esperarTexto(tester, 'Pomo rellenado'), isTrue);
      final ops = (await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        return db.query('ops_queue',
            where: 'tipo = ?', whereArgs: ['reponer_pomo']);
      }))!;
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.single['payload'] as String) as Map;
      expect(payload['dosis'], 6);
      // La petición atendida se oculta en la pantalla (el
      // setState llega un frame tras el aviso: se bombea
      // hasta verla desaparecer).
      for (var i = 0;
          i < 40 &&
              find.text('Solicitudes de relleno').evaluate().isNotEmpty;
          i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('Solicitudes de relleno'), findsNothing,
          reason: 'la petición atendida se oculta en la pantalla');
      // Drenaje entrelazado: el ciclo de sync que dispara el
      // relleno mezcla red real (avanza en runAsync),
      // esperas de la zona falsa (avanzan con pump) y el
      // latido del candado. Se entrelaza hasta que el ciclo
      // muere (si no, el desmontaje acusa un Timer vivo).
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(tester.takeException(), isNull,
          reason: 'sin used-after-dispose al cerrar el diálogo');
    });
  });
}
