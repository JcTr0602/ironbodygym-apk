/// Correcciones de la auditoría 2 (bordes) de la ronda 2
/// de la 1.28:
///
/// - D2-1 (media): la meta mirror_corruptas_<tabla> nunca
///   volvía a 0 tras la autocura y la Salud quedaba en
///   rojo para siempre.
/// - D2-2 (media): casts duros `as num?` sobre importes
///   que pueden llegar como texto (blob de tipos, clave
///   de menores, preciosVigentes).
/// - D2-3 (media): DateTime.parse sin red en el panel de
///   anuncios + ventana sin validar en el parser: un
///   anuncio sucio hacía la pantalla inabrible.
/// - D2-4 (baja): diasQuitablesVale aceptaba fechas
///   imposibles normalizadas por tryParse.
/// - D2-5 (baja): el buscador de Comunidad no plegaba
///   acentos descompuestos (letra + marca combinante).
/// - D2-6 (baja): registraFecha sin validación de
///   calendario (la antigüedad del pendiente se
///   desviaba con fechas imposibles).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/anuncios_admin.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:ironbody_gym/ui/panel_anuncios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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
/// gestion128_m5a).
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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D2-2 · importes como texto no tumban los precios', () {
    test('precioMenoresDesdeAjustes: texto en el blob manda', () {
      expect(
        precioMenoresDesdeAjustes({
          'tipos_pago': [
            {'id': 'menores', 'monto': '1600'},
          ],
        }),
        1600,
      );
    });

    test('precioMenoresDesdeAjustes: texto en la clave fija', () {
      expect(
        precioMenoresDesdeAjustes({'mensualidad_menores': '1700'}),
        1700,
      );
    });

    test('precioMenoresDesdeAjustes: blob ilegible cae al '
        'respaldo y luego al suelo', () {
      expect(
        precioMenoresDesdeAjustes({
          'tipos_pago': [
            {'id': 'menores', 'monto': 'basura'},
          ],
          'mensualidad_menores': '1700',
        }),
        1700,
      );
      expect(precioMenoresDesdeAjustes(const {}), 1500);
    });

    test('TipoPago.desdeJson tolera monto y días como texto', () {
      final t = TipoPago.desdeJson(const {
        'id': 'menores',
        'nombre': 'Menores',
        'monto': '1600',
        'dias': '30',
      });
      expect(t.monto, 1600);
      expect(t.dias, 30);
    });
  });

  group('D2-3 · ventana de anuncio saneada', () {
    test('parseAnunciosAdmin: desde/hasta vacíos o no-ISO '
        'entran como null; el ISO válido se conserva', () {
      final lista = parseAnunciosAdmin({
        'ok': true,
        'anuncios': [
          {
            'id': 1,
            'cuerpo_md': 'sucio',
            'desde': '',
            'hasta': 'no-es-fecha',
          },
          {
            'id': 2,
            'cuerpo_md': 'limpio',
            'desde': '2026-11-01T05:00:00Z',
            'hasta': null,
          },
        ],
      });
      expect(lista, hasLength(2));
      expect(lista[0].desde, isNull);
      expect(lista[0].hasta, isNull);
      expect(lista[1].desde, '2026-11-01T05:00:00Z');
    });

    test('el panel ya no contiene ningún DateTime.parse duro',
        () {
      final src = File('lib/ui/panel_anuncios.dart').readAsStringSync();
      expect(src.contains('DateTime.parse('), isFalse,
          reason: 'todo parseo de ventana debe ir por '
              '_habanaDeIso (tryParse)');
    });
  });

  group('D2-4 · diasQuitablesVale con fechas imposibles', () {
    test('pagado_hasta imposible → 0 (antes tryParse lo '
        'normalizaba al 3 de marzo y devolvía días)', () {
      expect(
        diasQuitablesVale(
          pagadoHasta: '2026-02-31',
          resueltoEn: '2026-02-10',
          premioDias: 15,
          hoy: DateTime(2026, 2, 10),
        ),
        0,
      );
      expect(
        diasQuitablesVale(
          pagadoHasta: '2026-03-10',
          resueltoEn: '2026-02-31',
          premioDias: 15,
          hoy: DateTime(2026, 2, 10),
        ),
        0,
      );
    });

    test('el caso válido no cambia: manda el menor entre '
        'lo que queda de mensualidad y la ventana', () {
      expect(
        diasQuitablesVale(
          pagadoHasta: '2026-03-10',
          resueltoEn: '2026-02-10',
          premioDias: 15,
          hoy: DateTime(2026, 2, 10),
        ),
        15,
      );
    });
  });

  group('D2-5 · buscador de Comunidad y acentos descompuestos',
      () {
    PerfilComunidadAdmin perfil(String nombre) =>
        PerfilComunidadAdmin(
          clienteId: 1,
          nombre: nombre,
          visible: true,
          ocultoAdmin: false,
          mostrarMarcas: false,
          mostrarActividad: false,
          mostrarRutina: false,
          mostrarConstancia: false,
        );

    test('«Jose + U+0301» se encuentra buscando «jose»', () {
      final lista = [perfil('Jose\u0301 Pe\u0301rez')];
      expect(filtrarPerfilesComunidad(lista, 'jose'), hasLength(1));
      expect(filtrarPerfilesComunidad(lista, 'perez'), hasLength(1));
    });

    test('la consulta descompuesta encuentra el nombre '
        'precompuesto', () {
      final lista = [perfil('José Pérez')];
      expect(
          filtrarPerfilesComunidad(lista, 'jose\u0301'), hasLength(1));
    });
  });

  group('D2-6 · registraFecha pasa por las puertas estrictas',
      () {
    test('la composición que usa registraFecha descarta la '
        'fecha imposible y conserva la real', () {
      expect(fechaNegocioHabana('2026-02-31'), '');
      expect(fechaIsoEstricta(fechaNegocioHabana('2026-02-31')),
          isNull);
      expect(fechaNegocioHabana('2026-02-27'), '2026-02-27');
      expect(fechaIsoEstricta(fechaNegocioHabana('2026-02-27')),
          DateTime.utc(2026, 2, 27));
    });

    test('registraFecha ya no usa tryParse a secas', () {
      final src = File('lib/negocio.dart').readAsStringSync();
      final i = src.indexOf('void registraFecha');
      expect(i, greaterThan(0));
      final cuerpo = src.substring(i, i + 700);
      expect(cuerpo.contains('fechaNegocioHabana'), isTrue);
      expect(cuerpo.contains('fechaIsoEstricta'), isTrue);
      expect(cuerpo.contains('DateTime.tryParse'), isFalse);
    });
  });

  group('BD real (D2-1 y preciosVigentes)', () {
    Future<String?> esperarMeta(String clave, String valor) async {
      final db = LocalDb.instance;
      for (var i = 0; i < 60; i++) {
        final v = await db.getMeta(clave);
        if (v == valor) return v;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return db.getMeta(clave);
    }

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_correccion_a2.db';
      await LocalDb.resetParaTest();
    });

    test('D2-1: la meta de corruptas se apaga tras la '
        'autocura y también con la meta rancia de otra vida',
        () async {
      final db = LocalDb.instance;
      final d = await db.db;
      // (a) Meta rancia de una «vida anterior» (la caché
      // del isolate nace vacía): una lectura LIMPIA debe
      // apagarla igualmente.
      await db.setMeta('mirror_corruptas_pagos_diarios', '2');
      await db.upsertMirror('pagos_diarios', 1, {'id': 1, 'total': 5}, 1);
      await db.allMirror('pagos_diarios');
      expect(
          await esperarMeta('mirror_corruptas_pagos_diarios', '0'),
          '0');
      // (b) Corrupción real → la meta sube a 1; al curarse
      // la fila, la siguiente lectura la devuelve a 0.
      await db.upsertMirror('pagos', 9001, {
        'id': 9001,
        'monto': 100,
        'fecha': '2026-11-07',
        'metodo': 'efectivo',
      }, 1);
      await d.update('pagos', {'data': '{roto'},
          where: 'id = ?', whereArgs: [9001]);
      await db.allMirror('pagos');
      expect(await esperarMeta('mirror_corruptas_pagos', '1'), '1');
      await d.update(
          'pagos',
          {
            'data': jsonEncode({
              'id': 9001,
              'monto': 100,
              'fecha': '2026-11-07',
              'metodo': 'efectivo',
            }),
          },
          where: 'id = ?',
          whereArgs: [9001]);
      await db.allMirror('pagos');
      expect(await esperarMeta('mirror_corruptas_pagos', '0'), '0');
    });

    test('D2-2: preciosVigentes lee los importes como texto '
        'sin lanzar', () async {
      await LocalDb.instance.setAjustes({
        'mensualidad': '2100',
        'mensualidad_menores': '1600',
        'transferencia': '2600',
      });
      final p = await preciosVigentes();
      expect(p['mensual'], 2100);
      expect(p['menores'], 1600);
      expect(p['transfer'], 2600);
    });

    test('D2-2: getTiposPago sin blob lee la clave de menores '
        'como texto (fallback de claves fijas)', () async {
      await LocalDb.instance.setAjustes({
        'mensualidad_menores': '1600',
      });
      final tipos = await getTiposPago(paraMenor: true);
      final menores = tipos.firstWhere((t) => t.id == 'menores');
      expect(menores.monto, 1600);
    });
  });

  group('D2-3 · la pantalla abre y borra con un anuncio sucio',
      () {
    late HttpServer server;
    var sesionLista = false;
    var borrado = false;
    int? idBorrado;

    setUpAll(() async {
      HttpOverrides.global = _HttpReal();
      SharedPreferences.setMockInitialValues({});
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

    testWidgets('ventana ilegible: la tarjeta pinta y el '
        'anuncio se puede borrar', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      if (!sesionLista) {
        await tester.runAsync(() async {
          await Supabase.initialize(
            url: 'http://127.0.0.1:${server.port}',
            anonKey: 'dummy',
          );
          await Supabase.instance.client.auth.signInWithPassword(
            email: 'jctr0602@ironbody.gym',
            password: 'x',
          );
        });
        expect(AuthService().isOwner, isTrue);
        sesionLista = true;
      }
      await tester.pumpWidget(MaterialApp(
        home: PanelAnunciosScreen(
          cargarAnuncios: () async => {
            'ok': true,
            'anuncios': [
              if (!borrado)
                {
                  'id': 3,
                  'titulo': 'Aviso sucio',
                  'cuerpo_md': 'Texto del aviso.',
                  'audiencia': 'todos',
                  'cliente_ids': <int>[],
                  'descartable': true,
                  // La ventana sucia que tumbaba la
                  // pantalla entera:
                  'desde': '',
                  'hasta': 'no-es-fecha',
                  'activo': true,
                  'creado_en': '2026-11-06T10:00:00Z',
                  'actualizado_en': '2026-11-06T10:00:00Z',
                },
            ],
          },
          borrarAnuncio: (id) async {
            borrado = true;
            idBorrado = id;
            return {'ok': true};
          },
          buscarClientes: () async => const [],
        ),
      ));
      await tester.pumpAndSettle();
      // La pantalla ABRE y la tarjeta pinta (con la
      // ventana saneada a «sin ventana»).
      expect(find.text('Aviso sucio'), findsOneWidget);
      expect(find.text('Sin ventana: visible hasta retirarlo'),
          findsOneWidget);
      // Y el anuncio se puede borrar: botón → confirmar.
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Borrar'));
      await tester.pumpAndSettle();
      expect(idBorrado, 3);
      expect(find.text('Anuncio borrado'), findsOneWidget);
    });
  });
}
