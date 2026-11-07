/// Correcciones de la auditoría 4 (offline) de la ronda 2
/// de la 1.28:
///
/// - D4-1 (media): la pasada del manifiesto no tenía
///   presupuesto ni cortacircuitos (40 tablas × 60 s en
///   serie con la conexión «en negro», dentro del lock
///   en la pasada diaria).
/// - D4-2 (baja): la explicación por op decía «No hay
///   conexión a internet» sin el contrafuerte del ciclo
///   (el síntoma de campo de Jc del 2026-11-05).
/// - D4-3 (baja): Salud y Diagnóstico esperaban el DNS
///   de fotoEstado (hasta 5 s) para pintar datos locales
///   que ni usan el enLinea.
/// - D4-4 (baja): las creaciones admin por RPC (anuncio,
///   vale manual) afirmaban «no se guardó» tras un
///   timeout que podía esconder la escritura aplicada:
///   el reintento duplicaba.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/panel_anuncios.dart';
import 'package:ironbody_gym/ui/panel_premios_clientes.dart';
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

/// Patrón de gestion128_m5a: cliente HTTP real para el
/// servidor falso local de auth.
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
  group('D4-1 · CorteManifiesto', () {
    test('el cortacircuitos salta a los 3 fallos de '
        'transporte seguidos; una respuesta lo reinicia', () {
      var t = Duration.zero;
      final c = CorteManifiesto(reloj: () => t);
      expect(c.agotado, isFalse);
      c.registrarTransporte(false);
      c.registrarTransporte(false);
      expect(c.agotado, isFalse);
      c.registrarTransporte(true); // el servidor respondió
      c.registrarTransporte(false);
      c.registrarTransporte(false);
      expect(c.agotado, isFalse,
          reason: 'la respuesta reinició la racha');
      c.registrarTransporte(false);
      expect(c.agotado, isTrue);
    });

    test('el presupuesto de tiempo agota la pasada aunque '
        'la red responda', () {
      var t = Duration.zero;
      final c = CorteManifiesto(
          presupuesto: const Duration(seconds: 150), reloj: () => t);
      t = const Duration(seconds: 149);
      expect(c.agotado, isFalse);
      t = const Duration(seconds: 150);
      expect(c.agotado, isTrue);
    });

    test('la pasada usa el corte y el POST del manifiesto '
        'lleva su timeout propio de 12 s', () {
      final src = File('lib/sync.dart').readAsStringSync();
      expect(src.contains('final corte = CorteManifiesto();'),
          isTrue);
      expect(src.contains('corte.registrarTransporte('), isTrue);
      final i = src.indexOf('rpc/sync_manifiesto');
      expect(i, greaterThan(0));
      expect(
          src.substring(i, i + 700).contains('Duration(seconds: 12)'),
          isTrue);
    });
  });

  group('D4-2 · explicacionOp con el contrafuerte', () {
    const errCrudo =
        'SocketException: Failed host lookup: x.supabase.co';

    test('sin dato de internet: la traducción clásica', () {
      final e = explicacionOp(estado: 'error', error: errCrudo);
      expect(e.motivo, 'No hay conexión a internet.');
    });

    test('con internet confirmado: quien no responde es '
        'el servidor (el mensaje del ciclo)', () {
      final e = explicacionOp(
          estado: 'error', error: errCrudo, hayInternet: true);
      expect(e.motivo, 'No se pudo contactar el servidor.');
      expect(e.accion,
          'Tus cambios están guardados en el teléfono.');
    });

    test('sin internet de verdad: no se corrige nada', () {
      final e = explicacionOp(
          estado: 'error', error: errCrudo, hayInternet: false);
      expect(e.motivo, 'No hay conexión a internet.');
    });

    test('otros errores no se tocan aunque haya internet',
        () {
      final e = explicacionOp(
          estado: 'error',
          error: 'TimeoutException after 0:00:12',
          hayInternet: true);
      expect(e.motivo, 'La conexión está muy lenta.');
    });
  });

  group('D4-3 · la Salud se lee sin esperar a la foto', () {
    test('fuente: ni salud_sync ni el Diagnóstico esperan '
        'fotoEstado', () {
      final s1 = File('lib/salud_sync.dart').readAsStringSync();
      final s2 =
          File('lib/ui/admin_secciones.dart').readAsStringSync();
      expect(s1.contains('await SyncEngine.instance.fotoEstado()'),
          isFalse);
      expect(s2.contains('await SyncEngine.instance.fotoEstado()'),
          isFalse);
    });

    test('funcional: el semáforo se mide contra el '
        'server_seq de la meta local', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_correccion_a4.db';
      await LocalDb.resetParaTest();
      final db = LocalDb.instance;
      await db.upsertMirror(
          'clientes', 1, {'id': 1, 'nombre': 'Ana'}, 1);
      await db.setMeta('server_seq', '500');
      var datos = await cargarSaludSync();
      final clientes =
          datos.tablas.firstWhere((t) => t.tablaLocal == 'clientes');
      expect(clientes.estado, SemaforoTabla.ambar,
          reason: 'watermark 0 < server_seq local 500');
      await db.setMeta('server_seq', '0');
      datos = await cargarSaludSync();
      final clientes2 =
          datos.tablas.firstWhere((t) => t.tablaLocal == 'clientes');
      expect(clientes2.estado, SemaforoTabla.verde);
    });
  });

  group('D4-4 · anuncios: timeout con la escritura aplicada',
      () {
    late HttpServer server;
    var sesionLista = false;

    /// El anuncio «fantasma»: lo que el servidor SÍ
    /// guardó aunque la respuesta se perdiera.
    final anuncioServidor = <String, dynamic>{
      'id': 9,
      'titulo': null,
      'cuerpo_md': 'Aviso importante del día.',
      'audiencia': 'todos',
      'cliente_ids': <int>[],
      'descartable': true,
      'desde': null,
      'hasta': null,
      'activo': true,
      'creado_en': '2026-11-07T10:00:00Z',
      'actualizado_en': '2026-11-07T10:00:00Z',
    };

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

    Future<void> montar(
      WidgetTester tester, {
      required Future<Map<String, dynamic>> Function() cargar,
      required Future<Map<String, dynamic>> Function(dynamic d)
          guardar,
    }) async {
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
          cargarAnuncios: cargar,
          guardarAnuncio: (d) => guardar(d),
          borrarAnuncio: (_) async => {'ok': true},
          buscarClientes: () async => const [],
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> crearAnuncio(WidgetTester tester) async {
      await tester.tap(find.text('Nuevo anuncio'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(
            TextFormField, 'Texto del anuncio (Markdown)'),
        'Aviso importante del día.',
      );
      await tester.pump();
      await tester.tap(find.text('Guardar anuncio'));
      await tester.pumpAndSettle();
    }

    testWidgets('la escritura aterrizó: se confirma y NO '
        'se invita a duplicar', (tester) async {
      var enServidor = false;
      await montar(
        tester,
        cargar: () async => {
          'ok': true,
          'anuncios': [if (enServidor) anuncioServidor],
        },
        guardar: (_) async {
          enServidor = true; // el servidor SÍ lo guardó…
          throw TimeoutException('respuesta perdida');
        },
      );
      await crearAnuncio(tester);
      // …y la pantalla lo comprueba: éxito, editor fuera.
      expect(find.text('Anuncio guardado'), findsOneWidget);
      expect(find.text('Guardar anuncio'), findsNothing);
    });

    testWidgets('la escritura NO aterrizó: el «no se '
        'guardó» vuelve a ser cierto', (tester) async {
      await montar(
        tester,
        cargar: () async => {'ok': true, 'anuncios': const []},
        guardar: (_) async =>
            throw TimeoutException('respuesta perdida'),
      );
      await crearAnuncio(tester);
      expect(find.text('Guardar anuncio'), findsOneWidget);
      expect(
        find.text('Sin conexión con el servidor: el '
            'anuncio no se guardó.'),
        findsOneWidget,
      );
    });

    testWidgets('ni la comprobación carga: el aviso dice '
        'que no se sabe', (tester) async {
      var cargas = 0;
      await montar(
        tester,
        cargar: () async {
          cargas++;
          if (cargas == 1) return {'ok': true, 'anuncios': const []};
          throw TimeoutException('sin ruta');
        },
        guardar: (_) async =>
            throw TimeoutException('respuesta perdida'),
      );
      await crearAnuncio(tester);
      expect(find.text('Guardar anuncio'), findsOneWidget);
      expect(find.textContaining('no se pudo comprobar si '
          'se guardó'), findsOneWidget);
    });
  });

  group('D4-4 · vales: timeout con el vale ya creado', () {
    Map<String, dynamic> detalleJson({required bool conVale}) => {
          'ok': true,
          'progreso': {
            'nombre': 'Ana Prueba',
            'logro_barra_id': 'constancia_90',
            'meta_dias': 90,
            'premio_dias': 15,
            'dias': 90,
            'faltan': 0,
          },
          'vales': [
            if (conVale)
              {
                'id': 9,
                'logro_id': 'constancia_90',
                'premio_dias': 15,
                'dias_al_reclamar': 0,
                'estado': 'reclamado',
                'creado_en': '2026-11-07T10:00:00Z',
                'creado_nota': 'Detalle del dueño',
              },
          ],
        };

    Future<void> montarVale(
      WidgetTester tester, {
      required Future<Map<String, dynamic>> Function(int, String,
              int, String)
          conceder,
      required Future<Map<String, dynamic>> Function(int) detalle,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PremiosClientesTab(
            buscarClientes: () async => [
              (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
            ],
            cargarDetalle: detalle,
            cargarCatalogo: () async => const [
              EntradaCatalogoPremio(
                logroId: 'constancia_90',
                nombre: 'Constancia 90',
                metaDias: 90,
                premioDias: 15,
                activo: true,
                ultimoCambioTexto: null,
              ),
            ],
            concederVale: conceder,
            reiniciarCiclo: (_, __) async => {'ok': true},
            pagadoHastaDe: (_) async => null,
            anulacionEnCursoDe: (_) async => false,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ana Prueba'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Conceder vale'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Nota (obligatoria)'),
        'Detalle del dueño',
      );
      await tester.pump();
      await tester.tap(find.text('Crear vale'));
      await tester.pumpAndSettle();
    }

    testWidgets('el vale SÍ se creó: el diálogo cierra '
        'como éxito y conceder se llamó UNA vez',
        (tester) async {
      var enServidor = false;
      var llamadas = 0;
      await montarVale(
        tester,
        conceder: (_, __, ___, ____) async {
          llamadas++;
          enServidor = true; // el servidor SÍ lo creó…
          throw TimeoutException('respuesta perdida');
        },
        detalle: (_) async => detalleJson(conVale: enServidor),
      );
      expect(llamadas, 1);
      expect(find.text('Crear vale'), findsNothing);
      expect(find.textContaining('Vale creado'), findsWidgets);
    });

    testWidgets('ni el detalle carga: el diálogo avisa de '
        'que no se sabe (no invita a duplicar)',
        (tester) async {
      var detalleLlamadas = 0;
      await montarVale(
        tester,
        conceder: (_, __, ___, ____) async =>
            throw TimeoutException('respuesta perdida'),
        detalle: (_) async {
          detalleLlamadas++;
          if (detalleLlamadas == 1) {
            return detalleJson(conVale: false);
          }
          throw TimeoutException('sin ruta');
        },
      );
      // El diálogo sigue abierto con el aviso honesto.
      expect(find.text('Crear vale'), findsOneWidget);
      expect(find.textContaining('no se pudo comprobar si '
          'el vale se creó'), findsOneWidget);
    });
  });
}
