/// Gestión 1.29 · Oleada 8 (FB-23 · Auditoría Total).
///
/// Contrato que se fija, contra el plan §9 + S-4 + H-02 +
/// P-08:
/// · La RPC `admin_actividad_cliente` unifica las 3 fuentes
///   de Supabase por persona y rango, con el detalle saneado
///   por LISTA BLANCA en el servidor y cursor compuesto —
///   verificado EN VIVO con la simulación por roles de
///   cola-123/gestion/oleada8/03_simulacion.sql (30
///   aserciones, todo_ok). Aquí se fija el lado de la app.
/// · La sección pinta primero la CACHÉ de la persona con su
///   fecha y enriquece con la RPC (timeout 12 s) en segundo
///   plano; sin conexión dice «sin conexión: mostrando lo
///   último descargado el [fecha]»; si nunca se descargó, lo
///   dice también: error ≠ vacío.
/// · La caché es de consulta (P-08): 200 filas por persona
///   y 20 personas (sale la menos reciente), en metadatos,
///   SIN tabla espejo ni migración, y se PURGA al cerrar
///   sesión (higiene en teléfono compartido).
/// · La sección solo se pinta con sesión de dueño (la misma
///   compuerta que la Auditoría actual).
/// · La pantalla NO pinta jamás las claves fuera de la
///   lista blanca aunque una fila vieja de caché las trajera
///   (defensa en profundidad de H-02).
/// · FB-20 (reverso): el panel de Comunidad puede nacer
///   filtrado por un nombre (salto desde la ficha).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/actividad_cliente.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/actividad_cliente.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/panel_comunidad.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés común (la pauta de las oleadas 4–7) ────────

String _jwtFalso(String email, int telegramId,
    {bool admin = false}) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e8',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {
      'telegram_id': telegramId,
      'provider': 'email',
      if (admin) 'rol': 'admin',
    },
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesion(WidgetTester tester,
    {required String email,
    required int telegramId,
    bool admin = false}) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId, admin: admin),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e8',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {
        'telegram_id': telegramId,
        'provider': 'email',
        if (admin) 'rol': 'admin',
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _sesionDueno(WidgetTester tester) => _sesion(tester,
    email: 'jctr0602@ironbody.local', telegramId: 735772141, admin: true);

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
}

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ActividadCliente _fila({
  String fuente = 'auditoria',
  int id = 1,
  String accion = 'auto_activacion',
  Map<String, dynamic> detalle = const {},
  String creado = '2026-11-07T15:00:00.000Z',
  String? actor,
}) =>
    ActividadCliente(
      fuente: fuente,
      idOrigen: id,
      actor: actor,
      accion: accion,
      detalle: detalle,
      creadoEn: DateTime.parse(creado),
    );

Future<void> _sembrarClientes() async {
  final db = await LocalDb.instance.db;
  Future<void> uno(int id, Map<String, dynamic> data) =>
      db.insert('clientes', {
        'id': id,
        'data': jsonEncode(data),
        'sync_seq': 1,
      });
  await uno(11, {'nombre': 'Ana Pérez', 'telefono': '58111111'});
  await uno(12, {'nombre': 'Beto Ruiz', 'telefono': '58222222'});
  await uno(13, {'nombre': 'Zulema Díaz', 'estado': 'eliminado'});
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  // ── Puros: filas, títulos y detalles ────────────────
  group('FB-23 · ActividadCliente.desdeRpc y textos (puros)', () {
    test('desdeRpc tolera la forma de PostgREST y el '
        'detalle como texto', () {
      final a = ActividadCliente.desdeRpc(const {
        'fuente': 'auditoria',
        'id_origen': 66,
        'actor': 'sistema',
        'accion': 'auto_activacion',
        'detalle': {'origen': 'inicial', 'app_version': '0.19.0'},
        'creado_en': '2026-11-06T19:21:43.35723+00:00',
      });
      expect(a.fuente, 'auditoria');
      expect(a.idOrigen, 66);
      expect(a.detalle['origen'], 'inicial');
      expect(a.cursor.fuente, 'auditoria');
      expect(a.cursor.id, 66);
      final b = ActividadCliente.desdeRpc(const {
        'fuente': 'vale',
        'id_origen': 3,
        'actor': null,
        'accion': 'vale_reclamado',
        'detalle': '{"logro":"constancia_real","premio_dias":30}',
        'creado_en': '2026-11-06T19:21:43+00:00',
      });
      expect(b.detalle['logro'], 'constancia_real');
      // Ida y vuelta por la caché: la fila se conserva.
      final c = ActividadCliente.desdeCache(a.aJson());
      expect(c.accion, a.accion);
      expect(c.creadoEn, a.creadoEn);
      expect(c.detalle, a.detalle);
    });

    test('títulos en lenguaje humano por acción', () {
      expect(tituloActividadCliente(_fila(accion: 'auto_activacion')),
          'Activación de la app');
      expect(tituloActividadCliente(_fila(accion: 'sesion_subida')),
          'Sesión de entreno subida');
      expect(
          tituloActividadCliente(_fila(
              fuente: 'vale', accion: 'vale_canjeado')),
          'Vale de premio: canjeado');
      expect(tituloActividadCliente(_fila(accion: 'revocar')),
          'Acceso revocado');
    });

    test('el detalle SOLO pinta claves de la lista blanca: '
        'una fila con claves prohibidas no las enseña', () {
      final linea = detalleActividadCliente(_fila(detalle: const {
        'origen': 'inicial',
        'app_version': '0.19.0',
        'ip': '1.2.3.4',
        'telefono': '58000000',
        'device_model': 'SM-SIM',
        'clave_futura_xyz': 'secreto',
      }));
      expect(linea, contains('Origen: inicial'));
      expect(linea, contains('Versión de la app: 0.19.0'));
      expect(linea, isNot(contains('1.2.3.4')));
      expect(linea, isNot(contains('58000000')));
      expect(linea, isNot(contains('SM-SIM')));
      expect(linea, isNot(contains('secreto')));
    });

    test('detalle de sesión y de vale', () {
      final s = detalleActividadCliente(_fila(
        fuente: 'sesion',
        accion: 'sesion_subida',
        detalle: const {
          'rutina': 'Full Body A',
          'duracion_seg': 3600,
          'ejercicios': 8,
        },
      ));
      expect(s, contains('Rutina: Full Body A'));
      expect(s, contains('Duración: 60 min'));
      expect(s, contains('8 ejercicios'));
      final v = detalleActividadCliente(_fila(
        fuente: 'vale',
        accion: 'vale_reclamado',
        detalle: const {'logro': 'constancia_real', 'premio_dias': 30},
      ));
      expect(v, contains('Logro: constancia_real'));
      expect(v, contains('Premio: 30 días'));
    });
  });

  group('FB-23 · selector y rangos (puros)', () {
    test('clientes elegibles: ordenados, sin eliminados, '
        'con nombre de respaldo', () {
      final lista = clientesElegiblesFb23([
        {'id': 12, 'nombre': 'Beto Ruiz'},
        {'id': 11, 'nombre': 'Ana Pérez'},
        {'id': 13, 'nombre': 'Zulema Díaz', 'estado': 'eliminado'},
        {'id': 14},
      ]);
      expect(lista.map((c) => c.id), [11, 12, 14]);
      expect(lista.last.nombre, 'Cliente 14');
    });

    test('el rango son instantes UTC hacia atrás; «Todo» '
        'no acota', () {
      final ahora = DateTime.utc(2026, 11, 8, 12);
      expect(rangoFb23(RangoFb23.todo, ahoraUtc: ahora).desde,
          isNull);
      expect(rangoFb23(RangoFb23.dias30, ahoraUtc: ahora).desde,
          DateTime.utc(2026, 10, 9, 12));
      expect(rangoFb23(RangoFb23.dias7, ahoraUtc: ahora).desde,
          DateTime.utc(2026, 11, 1, 12));
    });

    test('la banda sin conexión nombra el día del volcado '
        'en hora de La Habana', () {
      final texto =
          textoSinConexionFb23(DateTime.utc(2026, 11, 8, 4, 30));
      expect(texto, startsWith('Sin conexión: mostrando lo '
          'último descargado el '));
      // 04:30 UTC en noviembre = 23:30 Habana del día 7.
      expect(texto, contains('7/11/2026'));
      expect(texto, contains('23:30'));
    });
  });

  // ── Caché acotada y purga ───────────────────────────
  group('FB-23 · caché acotada en metadatos (P-08)', () {
    test('cota de 200 filas por persona', () async {
      await _bdVacia();
      final svc = ActividadClienteService();
      final filas = [
        for (var i = 0; i < 250; i++) _fila(id: i + 1),
      ];
      await svc.guardarCache(11, filas, DateTime.utc(2026, 11, 8));
      final cache = await svc.leerCache(11);
      expect(cache, isNotNull);
      expect(cache!.filas, hasLength(200));
      expect(cache.filas.first.idOrigen, 1,
          reason: 'la RPC viene ordenada: se quedan las '
              'más recientes, que son las primeras');
    });

    test('cota de 20 personas: sale la consulta menos '
        'reciente y vuelve a entrar al reconsultarla', () async {
      await _bdVacia();
      final svc = ActividadClienteService();
      for (var id = 100; id < 121; id++) {
        await svc.guardarCache(
            id, [_fila(id: id)], DateTime.utc(2026, 11, 8));
      }
      expect(await svc.leerCache(100), isNull,
          reason: 'la persona 21 expulsa a la menos reciente');
      expect(await svc.leerCache(120), isNotNull);
      // Reconsultar a la 101 la pone al final (más reciente):
      // al entrar la 121 sale la 102, no la 101.
      await svc.guardarCache(
          101, [_fila(id: 101)], DateTime.utc(2026, 11, 8));
      await svc.guardarCache(
          121, [_fila(id: 121)], DateTime.utc(2026, 11, 8));
      expect(await svc.leerCache(101), isNotNull);
      expect(await svc.leerCache(102), isNull);
      expect(await svc.leerCache(121), isNotNull);
    });

    test('la purga al cerrar sesión borra TODA la caché '
        'FB-23 y nada más', () async {
      await _bdVacia();
      final svc = ActividadClienteService();
      await svc.guardarCache(
          11, [_fila()], DateTime.utc(2026, 11, 8));
      await svc.guardarCache(
          12, [_fila()], DateTime.utc(2026, 11, 8));
      await LocalDb.instance
          .setMeta('ajuste_ajeno_fb23', 'se queda');
      await LocalDb.purgaAlCerrarSesion();
      expect(await svc.leerCache(11), isNull);
      expect(await svc.leerCache(12), isNull);
      expect(await LocalDb.instance.metasConPrefijo('fb23_'),
          isEmpty);
      expect(
          await LocalDb.instance.getMeta('ajuste_ajeno_fb23'),
          'se queda');
    });
  });

  // ── La sección en pantalla ──────────────────────────
  group('FB-23 · sección «Actividad en la app de clientes»',
      () {
    Future<void> montar(WidgetTester tester,
        ActividadClienteService svc) async {
      await tester.runAsync(() async {
        await _bdVacia();
        await _sembrarClientes();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeccionActividadAppClientes(servicio: svc),
          ),
        ),
      ));
      await _pumps(tester);
    }

    testWidgets('con red: elige persona, la RPC pinta y la '
        'foto queda en caché', (tester) async {
      ActividadClienteParams? recibidos;
      final svc = ActividadClienteService(rpcParaTest: (p) async {
        recibidos = p;
        return [
          _fila(
              id: 66,
              detalle: const {
                'origen': 'inicial',
                'app_version': '0.19.0',
                'ip': '1.2.3.4',
              }),
          _fila(
              fuente: 'sesion',
              id: 29,
              accion: 'sesion_subida',
              detalle: const {
                'rutina': 'Hoy',
                'duracion_seg': 5872,
                'ejercicios': 8,
              },
              creado: '2026-11-07T16:23:40.000Z'),
        ];
      });
      await montar(tester, svc);
      expect(find.text('Actividad en la app de clientes'),
          findsOneWidget);
      expect(find.text('Persona'), findsOneWidget);

      await tester.tap(find.byType(SelectorIronForm<int>));
      await _pumps(tester);
      await tester.tap(find.text('Ana Pérez').last);
      await _pumps(tester);

      expect(recibidos?.clienteId, 11);
      expect(find.text('Activación de la app'), findsOneWidget);
      expect(find.text('Sesión de entreno subida'), findsOneWidget);
      expect(find.textContaining('Rutina: Hoy'), findsOneWidget);
      expect(find.textContaining('1.2.3.4'), findsNothing,
          reason: 'ni viniendo en la fila se pinta la IP: la '
              'pantalla solo conoce la lista blanca');
      // La foto quedó guardada para la próxima visita.
      final cache = await svc.leerCache(11);
      expect(cache?.filas, hasLength(2));
    });

    testWidgets('sin conexión con caché: pinta la foto y la '
        'banda honesta con su fecha', (tester) async {
      var llamadas = 0;
      final svc = ActividadClienteService(rpcParaTest: (p) async {
        llamadas++;
        throw StateError('sin red (simulado)');
      });
      await tester.runAsync(() async {
        await _bdVacia();
        await _sembrarClientes();
        await svc.guardarCache(11, [
          _fila(id: 66),
        ], DateTime.utc(2026, 11, 8, 4, 30));
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeccionActividadAppClientes(servicio: svc),
          ),
        ),
      ));
      await _pumps(tester);
      await tester.tap(find.byType(SelectorIronForm<int>));
      await _pumps(tester);
      await tester.tap(find.text('Ana Pérez').last);
      await _pumps(tester);
      expect(llamadas, 1);
      expect(find.text('Activación de la app'), findsOneWidget,
          reason: 'la foto cacheada se pinta aunque la RPC '
              'falle: primero lo local');
      expect(
          find.textContaining('Sin conexión: mostrando lo '
              'último descargado el 7/11/2026'),
          findsOneWidget);
    });

    testWidgets('sin conexión y sin caché: se dice, no se '
        'inventa un vacío', (tester) async {
      final svc = ActividadClienteService(rpcParaTest: (p) async {
        throw StateError('sin red (simulado)');
      });
      await montar(tester, svc);
      await tester.tap(find.byType(SelectorIronForm<int>));
      await _pumps(tester);
      await tester.tap(find.text('Ana Pérez').last);
      await _pumps(tester);
      expect(
          find.textContaining('Sin conexión y sin nada '
              'descargado todavía'),
          findsOneWidget);
      expect(find.text('Activación de la app'), findsNothing);
    });

    testWidgets('con red y sin actividad: vacío verdadero, '
        'dicho como tal', (tester) async {
      final svc =
          ActividadClienteService(rpcParaTest: (p) async => []);
      await montar(tester, svc);
      await tester.tap(find.byType(SelectorIronForm<int>));
      await _pumps(tester);
      await tester.tap(find.text('Beto Ruiz').last);
      await _pumps(tester);
      expect(
          find.textContaining('Sin actividad registrada de '
              'esta persona'),
          findsOneWidget);
    });

    testWidgets('sin sesión de dueño la sección ni se pinta',
        (tester) async {
      final svc =
          ActividadClienteService(rpcParaTest: (p) async => []);
      await tester.runAsync(() async {
        await _bdVacia();
        await _sembrarClientes();
      });
      await _sesion(tester,
          email: 'duany@ironbody.local', telegramId: 969869611);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SeccionActividadAppClientes(servicio: svc),
        ),
      ));
      await _pumps(tester);
      expect(find.text('Actividad en la app de clientes'),
          findsNothing);
      expect(find.text('Persona'), findsNothing);
    });
  });

  // ── FB-20 reverso: el panel nace filtrado ───────────
  group('FB-20 · Comunidad nace filtrada desde la ficha', () {
    testWidgets('busquedaInicial filtra la lista al abrir',
        (tester) async {
      Map<String, dynamic> perfilJson(int id, String nombre) => {
            'cliente_id': id,
            'nombre': nombre,
            'visible': true,
            'oculto_admin': false,
            'mostrar_marcas': false,
            'mostrar_actividad': false,
            'mostrar_rutina': false,
            'mostrar_constancia': false,
          };
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: ComunidadPanelScreen(
          busquedaInicial: 'Ana Pérez',
          cargarPerfiles: () async => {
            'ok': true,
            'total_clientes': 2,
            'perfiles': [
              perfilJson(11, 'Ana Pérez'),
              perfilJson(12, 'Beto Ruiz'),
            ],
          },
          cargarReportes: () async =>
              {'ok': true, 'reportes': const []},
          cargarHistorial: () async =>
              {'ok': true, 'eventos': const []},
        ),
      ));
      await _pumps(tester);
      final campo = tester.widget<TextField>(find.byType(TextField));
      expect(campo.controller?.text, 'Ana Pérez');
      expect(find.text('Ana Pérez'), findsWidgets);
      expect(find.text('Beto Ruiz'), findsNothing,
          reason: 'el filtro nace aplicado: solo la persona '
              'de la ficha');
    });
  });
}
