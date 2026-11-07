/// 1.28 M5-A + ítem fijo (compositor de Anuncios):
///
/// - ÍTEM FIJO: el compositor pinta los anuncios con el
///   Markdown renderizado, crea uno nuevo con la
///   audiencia elegida (incluida «específicos» con los
///   ids marcados) y un error de la RPC se muestra
///   honesto sin cerrar el editor.
/// - A2 (parsers endurecidos): los conteos de Premios
///   nunca son negativos y una fila con el id degradado
///   a 0 se descarta; Comunidad acepta el id como texto
///   y un nombre vacío pasa a «Sin nombre».
/// - A9: compararVersiones ignora el sufijo «+build»
///   (la versión guardada '1.26.1+87' se leía como
///   1.26.0 y las notas se repetían).
/// - Pieza G (parser del compositor): parseAnunciosAdmin
///   descarta ids ≤ 0, deduplica la audiencia específica
///   y mensajeErrorAnuncio traduce los códigos del
///   servidor.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/anuncios_admin.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/novedades.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/ui/panel_anuncios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
          '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

/// flutter_test instala un HttpClient simulado que
/// responde 400 a todo: para hablar con el servidor
/// falso local hace falta el cliente real (patrón de
/// ajustes_127).
class _HttpReal extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return HttpClient(context: context);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

/// Servidor falso mínimo: solo auth (la sesión de
/// dueño); el resto responde vacío.
Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'access_token': _jwtFalso(),
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-falso',
          'user': {
            'id': 'uuid-dueno',
            'email': 'jctr0602@ironbody.gym',
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
          },
        }));
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
      } else {
        res.statusCode = 201;
        res.write('[]');
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

void main() {
  group('Pieza G — parser y errores de Anuncios', () {
    test('parseAnunciosAdmin: descarta id ≤ 0 y deduplica', () {
      final lista = parseAnunciosAdmin({
        'ok': true,
        'anuncios': [
          {
            'id': 0,
            'cuerpo_md': 'fantasma',
            'audiencia': 'todos',
          },
          {
            'id': 4,
            'titulo': '  Horario  ',
            'cuerpo_md': 'Texto',
            'audiencia': 'especificos',
            'cliente_ids': [5, 5, 7, -1, '9'],
            'descartable': false,
            'activo': true,
          },
          'basura',
        ],
      });
      expect(lista, hasLength(1));
      expect(lista.single.id, 4);
      expect(lista.single.titulo, 'Horario');
      expect(lista.single.clienteIds, [5, 7, 9]);
      expect(lista.single.descartable, isFalse);
      expect(lista.single.audienciaTexto, 'Solo 3 clientes');
    });

    test('estadoEn: retirado manda sobre la ventana', () {
      final ahora = DateTime.utc(2026, 11, 7, 12);
      AnuncioAdmin con({bool activo = true, String? desde, String? hasta}) =>
          AnuncioAdmin(
            id: 1,
            titulo: null,
            cuerpoMd: 'x',
            audiencia: 'todos',
            clienteIds: const [],
            descartable: true,
            desde: desde,
            hasta: hasta,
            activo: activo,
            creadoEn: '2026-11-06T10:00:00Z',
            actualizadoEn: '2026-11-06T10:00:00Z',
          );
      expect(con(activo: false).estadoEn(ahora), 'retirado');
      expect(con(desde: '2026-11-08T00:00:00Z').estadoEn(ahora),
          'programado');
      expect(con(hasta: '2026-11-07T11:00:00Z').estadoEn(ahora),
          'expirado');
      expect(con().estadoEn(ahora), 'visible');
    });

    test('mensajeErrorAnuncio traduce los códigos del servidor', () {
      expect(mensajeErrorAnuncio('SOLO_DUENO'),
          contains('Solo el dueño'));
      expect(mensajeErrorAnuncio('CUERPO_INVALIDO'),
          contains('entre 1 y 4000'));
      expect(mensajeErrorAnuncio('SIN_DESTINATARIOS'),
          contains('al menos un cliente'));
      expect(mensajeErrorAnuncio('VENTANA_INVALIDA'),
          contains('«hasta» debe ser posterior'));
      expect(mensajeErrorAnuncio('NO_EXISTE'),
          contains('ya no existe'));
      expect(mensajeErrorAnuncio('OTRA_COSA'),
          contains('OTRA_COSA'));
      expect(mensajeErrorAnuncio(null),
          contains('no aplicó el cambio'));
    });
  });

  group('A2 — parsers de Premios y Comunidad endurecidos', () {
    test('la bandeja descarta id 0 y acota los conteos a 0', () {
      final b = parseBandejaPremios({
        'vales': [
          {
            'id': 0,
            'cliente_id': 7,
            'nombre': 'Fantasma',
            'premio_dias': 15,
            'dias_al_reclamar': 90,
          },
          {
            'id': 3,
            'cliente_id': 7,
            'nombre': 'Ana',
            'premio_dias': -4,
            'dias_al_reclamar': -1,
          },
        ],
        'recientes': [
          {'id': 9, 'premio_dias': -2, 'estado': 'canjeado'},
        ],
      });
      expect(b.vales, hasLength(1));
      expect(b.vales.single.premioDias, 0);
      expect(b.vales.single.diasAlReclamar, 0);
      expect(b.recientes.single.premioDias, 0);
    });

    test('el detalle acota meta/premio/faltan y el historial', () {
      final d = parseDetallePremiosCliente({
        'ok': true,
        'nombre': 'Ana',
        'progreso': {
          'meta_dias': -5,
          'premio_dias': -15,
          'dias': 12,
          'faltan': -3,
        },
        'vales': [
          {'id': 2, 'premio_dias': -7, 'estado': 'canjeado'},
        ],
      });
      expect(d.metaDias, 0);
      expect(d.premioDias, 0);
      expect(d.dias, 12);
      expect(d.faltan, 0);
      expect(d.vales.single.premioDias, 0);
    });

    test('Comunidad: id como texto y nombre vacío con oficio', () {
      final perfiles = parsePerfilesComunidad({
        'ok': true,
        'perfiles': [
          {'cliente_id': '42', 'nombre': '   ', 'visible': true},
          {'cliente_id': 7, 'nombre': 'Luis', 'visible': true},
          {'cliente_id': 'no-numero', 'nombre': 'X'},
        ],
      });
      expect(perfiles, hasLength(2));
      expect(perfiles.first.clienteId, 42);
      expect(perfiles.first.nombre, 'Sin nombre');
    });
  });

  group('A9 — compararVersiones con sufijo de build', () {
    test('1.26.1+87 ya no se lee como 1.26.0', () {
      expect(compararVersiones('1.26.1+87', '1.26.1'), 0);
      expect(compararVersiones('1.26.1+87', '1.26.0'), greaterThan(0));
      expect(compararVersiones('1.27.0+88', '1.26.1+87'),
          greaterThan(0));
      expect(compararVersiones('1.26.1', '1.26.1+87'), 0);
    });
  });

  group('Ítem fijo — compositor de Anuncios (widget)', () {
    late HttpServer server;
    var sesionLista = false;

    final anunciosServidor = <Map<String, dynamic>>[
      {
        'id': 3,
        'titulo': 'Horario especial',
        'cuerpo_md': '**Cerrado** el lunes por mantenimiento.',
        'audiencia': 'todos',
        'cliente_ids': <int>[],
        'descartable': true,
        'desde': null,
        'hasta': null,
        'activo': true,
        'creado_en': '2026-11-06T10:00:00Z',
        'actualizado_en': '2026-11-06T10:00:00Z',
      },
    ];
    DatosAnuncio? capturado;
    Map<String, Object> respuestaGuardar = const {'ok': true, 'id': 9};

    Future<void> sesionDueno(WidgetTester tester) async {
      if (sesionLista) return;
      await tester.runAsync(() async {
        await Supabase.initialize(
          url: 'http://127.0.0.1:${server.port}',
          anonKey: 'dummy',
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'jctr0602@ironbody.gym',
          password: 'la-que-sea',
        );
      });
      expect(AuthService().isOwner, isTrue);
      sesionLista = true;
    }

    Future<void> montar(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: PanelAnunciosScreen(
          cargarAnuncios: () async {
            return {
              'ok': true,
              'anuncios': [
                for (final a in anunciosServidor) {...a},
              ],
            };
          },
          guardarAnuncio: (d) async {
            capturado = d;
            return Map<String, dynamic>.from(respuestaGuardar);
          },
          borrarAnuncio: (id) async => {'ok': true},
          buscarClientes: () async => [
            (id: 5, nombre: 'Ana Prueba'),
            (id: 7, nombre: 'Luis Prueba'),
          ],
        ),
      ));
      await tester.pumpAndSettle();
    }

    setUpAll(() async {
      HttpOverrides.global = _HttpReal();
      SharedPreferences.setMockInitialValues({});
      // Supabase.initialize escucha el canal de app_links
      // (deep links de auth): sin plugin en el arnés de
      // tests, la activación del stream revienta con
      // MissingPluginException y tumba el test que la
      // recibe. Se silencia con un stream vacío.
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(
          onListen: (Object? arguments,
              MockStreamHandlerEventSink events) {},
        ),
      );
      server = await _servidorFake();
    });

    tearDownAll(() async {
      await server.close(force: true);
      HttpOverrides.global = null;
    });

    testWidgets('la lista pinta el Markdown y el estado', (tester) async {
      await montar(tester);
      expect(find.text('Horario especial'), findsOneWidget);
      expect(find.text('Visible ahora'), findsOneWidget);
      // El cuerpo llega renderizado (MarkdownBody), no crudo.
      expect(find.textContaining('Cerrado'), findsWidgets);
      expect(find.textContaining('**Cerrado**'), findsNothing);
    });

    testWidgets('crear para todos: vista previa y guardado con la '
        'audiencia correcta', (tester) async {
      capturado = null;
      respuestaGuardar = const {'ok': true, 'id': 9};
      await montar(tester);
      await tester.tap(find.text('Nuevo anuncio'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(
            TextFormField, 'Texto del anuncio (Markdown)'),
        'Aviso de **prueba** para todos.',
      );
      await tester.pump();
      await tester.tap(find.text('Vista previa'));
      await tester.pumpAndSettle();
      // La vista previa renderiza el mismo Markdown.
      expect(find.textContaining('Aviso de'), findsWidgets);
      await tester.tap(find.text('Guardar anuncio'));
      await tester.pumpAndSettle();
      expect(capturado, isNotNull);
      expect(capturado!.audiencia, 'todos');
      expect(capturado!.cuerpoMd, 'Aviso de **prueba** para todos.');
      expect(capturado!.descartable, isTrue);
      expect(capturado!.clienteIds, isEmpty);
      expect(find.text('Guardar anuncio'), findsNothing);
      expect(find.text('Anuncio guardado'), findsOneWidget);
    });

    testWidgets('audiencia específicos: viajan los ids elegidos',
        (tester) async {
      capturado = null;
      respuestaGuardar = const {'ok': true, 'id': 10};
      await montar(tester);
      await tester.tap(find.text('Nuevo anuncio'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(
            TextFormField, 'Texto del anuncio (Markdown)'),
        'Solo para ti.',
      );
      await tester.tap(find.text('Solo algunos clientes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ana Prueba'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar anuncio'));
      await tester.pumpAndSettle();
      expect(capturado, isNotNull);
      expect(capturado!.audiencia, 'especificos');
      expect(capturado!.clienteIds, [5]);
    });

    testWidgets('un error de la RPC se muestra y el editor sigue '
        'abierto', (tester) async {
      respuestaGuardar = const {'ok': false, 'error': 'CUERPO_INVALIDO'};
      await montar(tester);
      await tester.tap(find.text('Nuevo anuncio'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(
            TextFormField, 'Texto del anuncio (Markdown)'),
        'Texto cualquiera.',
      );
      await tester.tap(find.text('Guardar anuncio'));
      await tester.pumpAndSettle();
      expect(
        find.text('El texto del anuncio debe tener entre '
            '1 y 4000 caracteres.'),
        findsOneWidget,
      );
      expect(find.text('Guardar anuncio'), findsOneWidget);
    });
  });
}
