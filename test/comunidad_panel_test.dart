// test/comunidad_panel_test.dart
// 1.27 (Comunidad, Pieza G): el parseo de
// admin_comunidad_perfiles es tolerante y fiel.
// Delta Argón 1.27 (#5): la pantalla lleva guarda
// defensiva de dueño (patrón PremiosHubScreen): los
// tests de widget fijan la sesión con un JWT de
// mentira (isOwner sale del email, como en
// producción) vía setInitialSession.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/ui/panel_comunidad.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtDeMentira(String email) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000aa',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(WidgetTester tester, String email) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira(email),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Patrón de la casa: sin estos mocks, la escucha
    // de deep links de Supabase Auth tumba tests en la
    // suite (ver ajustes_127_test).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });
  group('parsePerfilesComunidad', () {
    test('ok falso o forma rara: lista vacía', () {
      expect(parsePerfilesComunidad(const {'ok': false}), isEmpty);
      expect(parsePerfilesComunidad(const {}), isEmpty);
      expect(
          parsePerfilesComunidad(const {'ok': true, 'perfiles': 42}),
          isEmpty);
    });

    test('lee los perfiles con sus interruptores', () {
      final perfiles = parsePerfilesComunidad(const {
        'ok': true,
        'perfiles': [
          {
            'cliente_id': 5,
            'nombre': 'Ana',
            'visible': true,
            'oculto_admin': false,
            'mostrar_marcas': true,
            'mostrar_actividad': false,
            'mostrar_rutina': true,
            'mostrar_constancia': true,
          },
          {
            'cliente_id': 6,
            'nombre': 'Luis',
            'visible': false,
            'oculto_admin': true,
            'mostrar_marcas': false,
            'mostrar_actividad': false,
            'mostrar_rutina': false,
            'mostrar_constancia': false,
          },
          {'nombre': 'Sin id'}, // fila rara: se salta.
        ],
      });
      expect(perfiles.length, 2);
      expect(perfiles.first.nombre, 'Ana');
      expect(perfiles.first.bloquesActivos,
          ['Marcas', 'Rutina', 'Constancia']);
      expect(perfiles.last.ocultoAdmin, isTrue);
      expect(perfiles.last.bloquesActivos, isEmpty);
    });
  });

  testWidgets('la pantalla lista perfiles y ocultar '
      'llama con el valor invertido', (tester) async {
    await _fijarSesion(tester, 'jctr0602@ironbody.gym');
    int? clienteOcultado;
    bool? valorOcultar;
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => const {
          'ok': true,
          'perfiles': [
            {
              'cliente_id': 5,
              'nombre': 'Ana',
              'visible': true,
              'oculto_admin': false,
              'mostrar_marcas': true,
              'mostrar_actividad': true,
              'mostrar_rutina': false,
              'mostrar_constancia': false,
            },
          ],
        },
        ocultarPerfil: (id, ocultar) async {
          clienteOcultado = id;
          valorOcultar = ocultar;
          return const {'ok': true};
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Ana'), findsOneWidget);
    expect(find.textContaining('Visible en el directorio'),
        findsOneWidget);

    await tester.tap(find.text('Ocultar'));
    await tester.pumpAndSettle();
    expect(clienteOcultado, 5);
    expect(valorOcultar, isTrue);
    expect(find.text('Mostrar'), findsOneWidget);
    expect(find.textContaining('Oculto por administración'),
        findsOneWidget);
  });

  group('Comunidad C3 · parseos nuevos', () {
    test('la raíz trae denominador y pendientes (COM-24/25)',
        () {
      final raiz = parseRaizComunidad(const {
        'ok': true,
        'total_clientes': 179,
        'reportes_pendientes': 3,
        'perfiles': [],
      });
      expect(raiz.totalClientes, 179);
      expect(raiz.reportesPendientes, 3);
      final degradada = parseRaizComunidad(const {'ok': false});
      expect(degradada.totalClientes, 0);
      expect(degradada.reportesPendientes, 0);
    });

    test('el perfil lee nick, alta y los interruptores '
        'de la 0.19', () {
      final perfiles = parsePerfilesComunidad(const {
        'ok': true,
        'perfiles': [
          {
            'cliente_id': 9,
            'nombre': 'Mario Ruiz',
            'nick': 'MarioFit',
            'alta_en': '2026-11-05T10:00:00Z',
            'visible': true,
            'oculto_admin': false,
            'mostrar_marcas': true,
            'mostrar_actividad': false,
            'mostrar_rutina': false,
            'mostrar_constancia': false,
            'mostrar_nivel': true,
            'mostrar_logros': true,
          },
        ],
      });
      final p = perfiles.single;
      expect(p.nick, 'MarioFit');
      expect(p.bloquesActivos, ['Marcas', 'Nivel', 'Logros']);
      expect(
          p.esNuevo(DateTime.parse('2026-11-08T10:00:00Z')),
          isTrue);
      expect(
          p.esNuevo(DateTime.parse('2026-12-08T10:00:00Z')),
          isFalse);
    });

    test('los reportes parsean con su proyección '
        'compacta (A-08.2)', () {
      final reportes = parseReportesComunidad(const {
        'ok': true,
        'reportes': [
          {
            'id': 7,
            'creado_en': '2026-11-07T15:00:00Z',
            'motivo': 'nombre_inadecuado',
            'reportado': {
              'cliente_id': 9,
              'nick': 'MarioFit',
              'nick_anterior': 'MarioX',
              'nombre_real': 'Mario Ruiz',
              'proyeccion': {
                'cliente_id': 9,
                'identidad': 'MarioFit',
                'marcas': {'lista': []},
              },
            },
            'reportante': {
              'cliente_id': 11,
              'nick': null,
              'nombre_real': 'Ana Paz',
            },
          },
          {'id': 'malo'}, // fila rara: se salta.
        ],
      });
      expect(reportes.length, 1);
      final r = reportes.single;
      expect(r.reportadoNick, 'MarioFit');
      expect(r.reportadoNickAnterior, 'MarioX');
      expect(r.bloquesProyeccion, ['Marcas']);
      expect(r.reportanteNombreReal, 'Ana Paz');
      expect(motivoReporteTexto(r.motivo),
          'Nombre o Nick inadecuado');
    });

    test('el historial parsea y traduce las acciones '
        '(COM-27)', () {
      final eventos = parseHistorialComunidad(const {
        'ok': true,
        'eventos': [
          {
            'id': 3,
            'cliente_id': 9,
            'nombre_real': 'Mario Ruiz',
            'nick': 'MarioFit',
            'accion': 'nick_borrado',
            'creado_en': '2026-11-07T16:00:00Z',
            'reporte_id': null,
          },
        ],
      });
      expect(eventos.single.accionTexto, 'Nick retirado');
    });

    test('ver perfil lee la proyección bajo «perfil» '
        'y los apagados (COM-26)', () {
      final v = parseVerPerfilComunidad(const {
        'ok': true,
        'perfil': {'identidad': 'MarioFit'},
        'visible': true,
        'oculto_admin': true,
        'apagados': ['rutina', 'foto'],
      });
      expect(v.ok, isTrue);
      expect(v.proyeccion['identidad'], 'MarioFit');
      expect(v.ocultoAdmin, isTrue);
      expect(v.apagados, ['rutina', 'foto']);
    });

    test('reportes nuevos = ids pendientes sobre la '
        'marca de vistos (DF-27 · A1-M5-01)', () {
      // La marca es el id mayor visto, no un conteo.
      expect(reportesNuevosComunidad([1, 2, 3], 0), 3);
      expect(reportesNuevosComunidad([1, 2, 3], 3), 0);
      expect(reportesNuevosComunidad([], 3), 0);
      // El caso de la auditoría: vistos [1,2,3] (marca
      // 3); se resuelve el 1 y entra el 4 → solo el 4
      // es nuevo (con la marca por conteo, la cuenta
      // volvía a 3 y el nuevo quedaba tapado).
      expect(reportesNuevosComunidad([2, 3, 4], 3), 1);
      // Resolver sin que entre nadie no fabrica nuevos.
      expect(reportesNuevosComunidad([2, 3], 3), 0);
    });

    test('los ids pendientes se parsean del payload '
        '(A1-M5-01)', () {
      expect(
        parseIdsReportesPendientes(const {
          'ok': true,
          'reportes_pendientes_ids': [5, 9, 12],
        }),
        [5, 9, 12],
      );
      expect(
        parseIdsReportesPendientes(const {'ok': true}),
        isEmpty,
      );
      expect(
        parseIdsReportesPendientes(const {
          'ok': false,
          'reportes_pendientes_ids': [5],
        }),
        isEmpty,
      );
      // La clave de la marca lleva la semántica nueva.
      expect(claveReportesComunidadVistos(735772141),
          contains('maxid'));
    });
  });

  testWidgets('C3: la pestaña Reportes resuelve un '
      'reporte ocultando el perfil', (tester) async {
    await _fijarSesion(tester, 'jctr0602@ironbody.gym');
    int? reporteResuelto;
    String? accionResuelta;
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => const {
          'ok': true,
          'total_clientes': 179,
          'reportes_pendientes': 1,
          'perfiles': [
            {
              'cliente_id': 9,
              'nombre': 'Mario Ruiz',
              'nick': 'MarioFit',
              'visible': true,
              'oculto_admin': false,
              'mostrar_marcas': true,
              'mostrar_actividad': false,
              'mostrar_rutina': false,
              'mostrar_constancia': false,
            },
          ],
        },
        cargarReportes: () async => const {
          'ok': true,
          'reportes': [
            {
              'id': 7,
              'creado_en': '2026-11-07T15:00:00Z',
              'motivo': 'nombre_inadecuado',
              'reportado': {
                'cliente_id': 9,
                'nick': 'MarioFit',
                'nombre_real': 'Mario Ruiz',
                'proyeccion': {'cliente_id': 9},
              },
              'reportante': {
                'cliente_id': 11,
                'nombre_real': 'Ana Paz',
              },
            },
          ],
        },
        cargarHistorial: () async =>
            const {'ok': true, 'eventos': []},
        resolverReporte: (id, accion) async {
          reporteResuelto = id;
          accionResuelta = accion;
          return const {'ok': true};
        },
      ),
    ));
    await tester.pumpAndSettle();
    // Perfiles enseña el denominador y el Nick.
    expect(find.textContaining('de 179 clientes'),
        findsOneWidget);
    expect(find.textContaining('«MarioFit»'), findsOneWidget);

    await tester.tap(find.text('Reportes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reporta: Ana Paz'),
        findsOneWidget);
    await tester.tap(find.text('Ocultar perfil'));
    await tester.pumpAndSettle();
    expect(reporteResuelto, 7);
    expect(accionResuelta, 'ocultar');
    // La tarjeta del reporte desaparece y la cola
    // queda en su estado vacío.
    expect(find.textContaining('Reporta: Ana Paz'),
        findsNothing);
    expect(find.textContaining('Sin reportes pendientes'),
        findsOneWidget);
  });

  // Delta Argón 1.27 (#5): sin sesión de dueño la
  // pantalla pinta la guarda y ni siquiera pide los
  // perfiles (la RPC de administración no se dispara).
  testWidgets('sin sesión de dueño: guarda defensiva '
      'y no se piden los perfiles', (tester) async {
    await _fijarSesion(tester, 'duany@ironbody.gym');
    var pedidos = 0;
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async {
          pedidos++;
          return const {'ok': true, 'perfiles': <dynamic>[]};
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Solo el dueño administra la comunidad.'),
        findsOneWidget);
    expect(pedidos, 0);
  });
}
