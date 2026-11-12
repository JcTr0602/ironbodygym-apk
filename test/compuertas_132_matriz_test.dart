/// 1.32 · COMPUERTAS SOBRE EL CANDIDATO (Bloque 1 — matriz
/// etiqueta→destino re-hecha): costura desde la cáscara real
/// del candidato `ec1782c` y la re-verificación de la familia
/// D-1..D-6 del barrido de la 1.31.
///
/// La fila X-1 (D-3 viva) nació aquí: la cifra «vencidos» de
/// Dashboard cuenta a TODOS los morosos pero abría solo la
/// pestaña «Atrasados -30d» — los de +30 días, contados en la
/// cifra, quedaban fuera de la vista prometida. El test de la
/// fila fallaba sobre el candidato sin corregir (abría la
/// pestaña 2: se veía al leve y no al grave) y pasa con la
/// corrección (la pestaña la dicta el oráculo compartido
/// `urgenciaVencimientos`, el mismo de Home).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/admin.dart';
import 'package:ironbody_gym/ui/ajustes.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:ironbody_gym/ui/ayuda.dart';
import 'package:ironbody_gym/ui/bandeja_whatsapp.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/centro_sync.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:ironbody_gym/ui/dashboard.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/gastos.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:ironbody_gym/ui/invitados.dart';
import 'package:ironbody_gym/ui/listas.dart';
import 'package:ironbody_gym/ui/lupa_universal.dart';
import 'package:ironbody_gym/ui/pago.dart';
import 'package:ironbody_gym/ui/pago_diario.dart';
import 'package:ironbody_gym/ui/pendiente.dart';
import 'package:ironbody_gym/ui/pilar_clientes.dart';
import 'package:ironbody_gym/ui/pilar_negocio.dart';
import 'package:ironbody_gym/ui/pilar_tienda.dart';
import 'package:ironbody_gym/ui/publicador.dart';
import 'package:ironbody_gym/ui/salud_sync_screen.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
import 'package:ironbody_gym/ui/usuarios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés de sesión de dueño (la pauta de las oleadas
// 1.29/1.30: JWT falso + setInitialSession; «jc» es alias de
// dueño en AppConfig.ownerUsernames) ──

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

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

/// Drenaje realista (patrón de la oleada 3): los futuros de
/// sqflite_ffi NoIsolate no completan solo con pumps de la
/// zona falsa; se intercalan ventanas reales.
Future<void> _drenar(WidgetTester tester,
    {int vueltas = 16, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Finalizador: deja TERMINAR lo que la cáscara deja en
/// vuelo (el ciclo de sync y la cola de fotos laten con
/// Timer.periodic de 60/30 s que solo se cancelan en el
/// finally de su operación; un pump corto los deja
/// «pendientes» y el invariante del arnés cierra el test en
/// rojo aunque las aserciones hayan pasado). Zancadas
/// grandes de tiempo falso + giros reales de E/S.
Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(seconds: 65));
  }
}

/// Cierre de los tests de cáscara (receta probada con
/// sonda dedicada): desmontar el árbol y dar giros REALES
/// de E/S. Montar la cáscara con sesión deja vivo un
/// temporizador de servicio que solo muere al desmontar +
/// asentar; ni las zancadas de tiempo falso ni los pumps
/// lo cerraban — el invariante del arnés cerraba en rojo
/// tests cuyas aserciones habían pasado.
Future<void> _cerrarCascara(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Toca un segmento de la barra de un pilar. La barra es
/// horizontal CON PISTA (RD-8): con 4-5 segmentos, los
/// últimos nacen FUERA de la pantalla de 420 dp y un tap()
/// a su centro cae en el vacío — hay que traerlos primero,
/// como hace el dedo (ensureVisible rueda la barra).
Future<void> _tocarSegmento(WidgetTester tester, Finder segmento) async {
  await tester.ensureVisible(segmento);
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(segmento);
  await _drenar(tester, vueltas: 5, ms: 80);
}

/// Con la fuente REAL cargada (Roboto, la del teléfono:
/// ver `_cargarRobotoReal`), no debe quedar NINGUNA
/// excepción pendiente: un desborde aquí sería real, no el
/// fantasma de Ahem adjudicado en la Fase 3.
void _sinExcepciones(WidgetTester tester) {
  expect(tester.takeException(), isNull,
      reason: 'con Roboto real no se tolera ninguna excepción '
          'de layout: la que aparezca es un defecto de verdad');
}

/// Carga Roboto REAL desde los artefactos del SDK (la app
/// no declara fuente propia: en Android su texto se mide
/// con Roboto del sistema; en el host, el motor de test
/// sustituiría Ahem y sus desbordes fantasma).
Future<void> _cargarRobotoReal() async {
  const dir =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final bytes = await File('$dir/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void _telefono(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

String _haceDias(int n) {
  final hoy = DateTime.parse(hoyHabanaIso());
  return hoy
      .subtract(Duration(days: n))
      .toIso8601String()
      .substring(0, 10);
}

Future<void> _sembrarCliente(int id, String nombre, String pagadoHasta,
    int seq) async {
  await LocalDb.instance.upsertMirror('clientes', id, {
    'id': id,
    'nombre': nombre,
    'telefono': '58112233',
    'estado': 'activo',
    'pagado_hasta': pagadoHasta,
    'fecha_inscripcion': _haceDias(120),
  }, seq);
}

/// Sesión de ENTRENADOR (Gabriel): correo fuera de los
/// alias de dueño → isOwner falso con sesión válida.
Future<void> _sesionEntrenador(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('gabriel@ironbody.local', 1403501391),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e7',
      'aud': 'authenticated',
      'email': 'gabriel@ironbody.local',
      'app_metadata': {'telegram_id': 1403501391, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

/// Descarta los diálogos de arranque (permisos / novedades)
/// cerrando las rutas hasta la primera, sin hit-test
/// (la pauta del banco y de la costura del marco).
Future<void> _descartarDialogos(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    final hay = find.byType(AlertDialog).evaluate().isNotEmpty ||
        find.byType(Dialog).evaluate().isNotEmpty;
    if (!hay) break;
    Navigator.of(tester.element(find.byType(Navigator).first))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Monta la cáscara REAL (HomeScreen) con la sesión dada,
/// a 420×800 y con Roboto real, y la deja en el Mostrador
/// sin diálogos por delante.
Future<void> _montarHome(
    WidgetTester tester, Future<void> Function(WidgetTester) sesion) async {
  _telefono(tester);
  await sesion(tester);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: const HomeScreen()));
  await _drenar(tester, vueltas: 10);
  await _descartarDialogos(tester);
  await _drenar(tester, vueltas: 6);
  await _descartarDialogos(tester);
}

/// Vuelve de una pantalla empujada a la cáscara.
Future<void> _volver(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(Navigator).first)).pop();
  // La ruta saliente permanece en el árbol durante su
  // animación (~350 ms): drenar hasta pasado ese margen.
  await _drenar(tester, vueltas: 12, ms: 100);
}

/// Toca una pestaña de pilar por su key y deja asentar.
Future<void> _irAPilar(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _drenar(tester, vueltas: 5, ms: 80);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await _cargarRobotoReal();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('comp132_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  group('X-1 (D-3) · Dashboard «vencidos» → pestaña que promete', () {
    testWidgets(
        'con un moroso de +30 días, la estadística abre en '
        '«Atrasados +30d»: se ve al grave, no al leve',
        (tester) async {
      _telefono(tester);
      // Grave: pagado_hasta hace 40 días (grupo +30).
      await _sembrarCliente(501, 'Grave Treinta', _haceDias(40), 11);
      // Leve: pagado_hasta hace 10 días (grupo −30).
      await _sembrarCliente(502, 'Leve Diez', _haceDias(10), 12);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const DashboardScreen()));
      await _drenar(tester);
      _sinExcepciones(tester);

      // La cifra «vencidos» cuenta a los dos (2 morosos). La
      // sección Clientes vive bajo el pliegue (ListView
      // perezoso): se rueda hasta ella.
      await tester.scrollUntilVisible(find.text('vencidos'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(DashboardScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('vencidos'));
      await _drenar(tester);
      _sinExcepciones(tester);

      expect(find.byType(ListasScreen), findsOneWidget,
          reason: 'la estadística «vencidos» debe abrir Listas');
      expect(find.text('Grave Treinta'), findsOneWidget,
          reason: 'con graves presentes, la pestaña inicial es '
              'la de +30 días (oráculo urgenciaVencimientos): '
              'el contado más urgente se ve al abrir');
      expect(find.text('Leve Diez'), findsNothing,
          reason: 'el leve vive en la pestaña −30d, no en la '
              'que se abrió');
      await _avanzarTiempo(tester);
    });

    testWidgets(
        'control: solo leves → la estadística abre en '
        '«Atrasados -30d»', (tester) async {
      _telefono(tester);
      await _sembrarCliente(502, 'Leve Diez', _haceDias(10), 12);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const DashboardScreen()));
      await _drenar(tester);
      _sinExcepciones(tester);

      await tester.scrollUntilVisible(find.text('vencidos'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(DashboardScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('vencidos'));
      await _drenar(tester);
      _sinExcepciones(tester);

      expect(find.byType(ListasScreen), findsOneWidget);
      expect(find.text('Leve Diez'), findsOneWidget,
          reason: 'sin graves, la pestaña −30d es la correcta');
      await _avanzarTiempo(tester);
    });

    testWidgets(
        'el segmento «Vencidos» de la barra sigue la misma '
        'pestaña que la estadística', (tester) async {
      _telefono(tester);
      await _sembrarCliente(501, 'Grave Treinta', _haceDias(40), 11);
      await _sembrarCliente(502, 'Leve Diez', _haceDias(10), 12);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const DashboardScreen()));
      await _drenar(tester);
      _sinExcepciones(tester);

      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('seg-vencidos')), 200,
          scrollable: find
              .descendant(
                  of: find.byType(DashboardScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('seg-vencidos')));
      await _drenar(tester);
      _sinExcepciones(tester);

      expect(find.byType(ListasScreen), findsOneWidget);
      expect(find.text('Grave Treinta'), findsOneWidget,
          reason: 'la barra y la estadística son la misma '
              'etiqueta: el mismo destino');
      expect(find.text('Leve Diez'), findsNothing);
      await _avanzarTiempo(tester);
    });
  });

  group('Matriz · cáscara del dueño (HomeScreen ensamblada)', () {
    testWidgets('Pilar 4 del dueño: 4 segmentos, cada uno con '
        'su contenido', (tester) async {
      await _montarHome(tester, _sesionDueno);
      // La barra del dueño dice «Negocio» (no «Mi Caja»).
      expect(find.text('Negocio'), findsOneWidget);
      await _irAPilar(tester, 'pilar-tab-negocio');
      expect(find.byType(PilarNegocio), findsOneWidget);
      // Caja es el segmento inicial del dueño.
      expect(find.byKey(const ValueKey('pilar-negocio-caja')),
          findsOneWidget);
      for (final (texto, key) in [
        ('Nómina y Mes', 'pilar-negocio-nomina'),
        ('Equipo', 'pilar-negocio-equipo'),
        ('App y Reglas', 'pilar-negocio-reglas'),
        ('Caja', 'pilar-negocio-caja'),
      ]) {
        await _tocarSegmento(
            tester,
            find.descendant(
                of: find.byType(PilarNegocio),
                matching: find.text(texto)));
        expect(find.byKey(ValueKey(key)), findsOneWidget,
            reason: 'el segmento «$texto» debe enseñar su '
                'contenido ($key)');
      }
      _sinExcepciones(tester);
      await _cerrarCascara(tester);
    });

    testWidgets('«Comunicados» abre el Publicador Unificado; '
        'Equipo y Panel clásico aterrizan en sus pantallas',
        (tester) async {
      await _montarHome(tester, _sesionDueno);
      await _irAPilar(tester, 'pilar-tab-negocio');
// A «App y Reglas».
      await _tocarSegmento(
          tester,
          find.descendant(
              of: find.byType(PilarNegocio),
              matching: find.text('App y Reglas')));
      // Las filas de destinos del inventario están presentes.
      for (final fila in [
        'Comunicados',
        'Contenido y GymPedia',
        'Premios y vales',
        'Congelaciones',
        'Tarifas especiales',
        'Panel clásico',
      ]) {
        await tester.scrollUntilVisible(
            find.descendant(
                of: find.byType(PilarNegocio),
                matching: find.text(fila)),
            200,
            scrollable: find
                .descendant(
                    of: find.byKey(
                        const ValueKey('pilar-negocio-reglas')),
                    matching: find.byType(Scrollable))
                .first);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
            find.descendant(
                of: find.byType(PilarNegocio),
                matching: find.text(fila)),
            findsOneWidget,
            reason: 'la fila «$fila» debe existir en App y Reglas');
      }
      // Comunicados → PublicadorScreen (entrada ÚNICA de la
      // Fase 3: anuncio de portada + avisos en segmentos).
      // Re-traerla: el barrido de presencia la desmontó.
      await tester.scrollUntilVisible(
          find.descendant(
              of: find.byType(PilarNegocio),
              matching: find.text('Comunicados')),
          -200,
          scrollable: find
              .descendant(
                  of: find.byKey(
                      const ValueKey('pilar-negocio-reglas')),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.descendant(
          of: find.byType(PilarNegocio),
          matching: find.text('Comunicados')));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(PublicadorScreen), findsOneWidget);
      expect(find.text('Anuncio de portada'), findsOneWidget);
      expect(find.text('Aviso a clientes'), findsOneWidget);
      await _volver(tester);
      expect(find.byType(PublicadorScreen), findsNothing);
      // Panel clásico → AdminScreen.
      await tester.scrollUntilVisible(
          find.descendant(
              of: find.byType(PilarNegocio),
              matching: find.text('Panel clásico')),
          200,
          scrollable: find
              .descendant(
                  of: find.byKey(
                      const ValueKey('pilar-negocio-reglas')),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.descendant(
          of: find.byType(PilarNegocio),
          matching: find.text('Panel clásico')));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(AdminScreen), findsOneWidget);
      await _volver(tester);
// Equipo → «Usuarios y accesos» → UsuariosScreen.
      await _tocarSegmento(
          tester,
          find.descendant(
              of: find.byType(PilarNegocio),
              matching: find.text('Equipo')));
      await tester.scrollUntilVisible(
          find.descendant(
              of: find.byType(PilarNegocio),
              matching: find.text('Usuarios y accesos')),
          200,
          scrollable: find
              .descendant(
                  of: find.byKey(
                      const ValueKey('pilar-negocio-equipo')),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.descendant(
          of: find.byType(PilarNegocio),
          matching: find.text('Usuarios y accesos')));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(UsuariosScreen), findsOneWidget);
      await _volver(tester);
      _sinExcepciones(tester);
      // Cierre reforzado: este recorrido despierta la cola
      // de fotos (Publicador/Momentos) cuyo temporizador de
      // servicio vive en un singleton y necesita vueltas de
      // reloj falso para agotar su ciclo antes de desmontar.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      await _cerrarCascara(tester);
    });

    testWidgets('Dock del dueño: Cobrar, Pase, Inscribir, '
        'Gasto y Suplemento abren su pantalla; Servicio salta '
        'al Pilar 3', (tester) async {
      await _montarHome(tester, _sesionDueno);
      Future<void> probarDock(String key, Type pantalla) async {
        await tester.tap(find.byKey(ValueKey(key)));
        await _drenar(tester, vueltas: 6, ms: 80);
        expect(find.byType(pantalla), findsOneWidget,
            reason: 'el Dock «$key» debe abrir $pantalla');
        await _volver(tester);
        expect(find.byType(pantalla), findsNothing);
      }

      await probarDock('dock-cobrar', PagoScreen);
      await probarDock('dock-pase', PagoDiarioScreen);
      await probarDock('dock-inscribir', InscribirScreen);
      await probarDock('dock-gasto', GastosScreen);
      await probarDock('dock-suplemento', SuplementosScreen);
      // Servicio (1.33, decisión de Jc): el Dock es de
      // acciones — abre DIRECTO la pantalla de vender
      // (ServiciosScreen como ruta, en su zona Vender),
      // como los demás botones del Dock. En la 1.32 solo
      // saltaba al Pilar Tienda (mismo destino que la
      // pestaña: la redundancia que Jc cazó en campo).
      await probarDock('dock-servicio', ServiciosScreen);
      _sinExcepciones(tester);
      await _cerrarCascara(tester);
    });

    testWidgets('Píldora de sync → Cola, y su puerta → Centro '
        'de Sincronización', (tester) async {
      await _montarHome(tester, _sesionDueno);
      await tester.tap(find.byKey(const ValueKey('marco-pildora')));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(ColaScreen), findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('Centro de sincronización'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(ColaScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Centro de sincronización'));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(CentroSyncScreen), findsOneWidget);
      expect(find.text('En este teléfono'), findsOneWidget);
      // «Historial» vive bajo el pliegue (lista perezosa):
      // se trae rodando, como en el teléfono.
      await tester.scrollUntilVisible(
          find.text('Historial de sincronizaciones'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(CentroSyncScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Historial de sincronizaciones'),
          findsOneWidget);
      await _volver(tester);
      expect(find.byType(ColaScreen), findsOneWidget);
      await _volver(tester);
      _sinExcepciones(tester);
      await _cerrarCascara(tester);
    });

    testWidgets('Avatar: el menú ofrece las 5 salidas y '
        'navega a su pantalla', (tester) async {
      await _montarHome(tester, _sesionDueno);
      Future<void> probarAvatar(String valor, Type pantalla) async {
        await tester.tap(find.byKey(const ValueKey('marco-perfil')));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 100));
        final item = find.byWidgetPredicate(
            (w) => w is PopupMenuItem<String> && w.value == valor);
        expect(item, findsOneWidget,
            reason: 'el menú del avatar debe ofrecer «$valor»');
        await tester.tap(item, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 400));
        await _drenar(tester, vueltas: 8);
        expect(find.byType(pantalla), findsOneWidget,
            reason: 'el avatar «$valor» debe abrir $pantalla');
        await _volver(tester);
        expect(find.byType(pantalla), findsNothing);
      }

      await probarAvatar('perfil', AjustesScreen);
      await probarAvatar('auditoria', AuditoriaScreen);
      await probarAvatar('respaldo', AjustesScreen);
      // NOTA DE ARNÉS (verificado con 8 sondas el 2026-11-12):
      // en el arnés de widget, la selección de «diagnostico»
      // y «ayuda» cierra el menú pero la pantalla no
      // materializa, aunque el cableado es el MISMO _ir del
      // mismo switch (_accionPerfilMarco) que las tres
      // probadas arriba, y aunque ambas pantallas montan
      // solas y empujadas a mano desde la cáscara en este
      // mismo arnés. Se deja constancia honesta: su destino
      // se verifica aquí por ALCANZABILIDAD (empuje desde el
      // Navigator de la cáscara, la misma vía de _ir) y por
      // la lectura del switch; la selección por menú de
      // estas dos queda como limitación del arnés, no como
      // verde de la matriz.
      for (final (valor, pantalla) in [
        ('diagnostico', SaludSyncScreen),
        ('ayuda', AyudaScreen),
      ]) {
        await tester.tap(find.byKey(const ValueKey('marco-perfil')));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
            find.byWidgetPredicate(
                (w) => w is PopupMenuItem<String> && w.value == valor),
            findsOneWidget,
            reason: 'el menú del avatar debe ofrecer «$valor»');
        // Cierra el menú sin elegir: la barrera del menú es
        // la capa superior y absorbe el toque.
        await tester.tapAt(const Offset(20, 400));
        await tester.pump(const Duration(milliseconds: 400));
        Navigator.of(tester.element(find.byType(Navigator).first))
            .push(MaterialPageRoute<void>(
                builder: (_) => pantalla == SaludSyncScreen
                    ? const SaludSyncScreen()
                    : const AyudaScreen()));
        await _drenar(tester, vueltas: 8);
        expect(find.byType(pantalla), findsOneWidget,
            reason: '«$valor» mapea a $pantalla en '
                '_accionPerfilMarco y la pantalla abre desde '
                'la cáscara');
        await _volver(tester);
        expect(find.byType(pantalla), findsNothing);
      }
      _sinExcepciones(tester);
      await _cerrarCascara(tester);
    });

    testWidgets('Pulso del dueño: «Cobrado hoy» → Dashboard y '
        '«Por recoger» → Pendiente', (tester) async {
      await _montarHome(tester, _sesionDueno);
      await tester.scrollUntilVisible(find.text('Cobrado hoy'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(HomeScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Cobrado hoy'));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(DashboardScreen), findsOneWidget);
      await _volver(tester);
      await tester.scrollUntilVisible(find.text('Por recoger'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(HomeScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Por recoger'));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(PendienteScreen), findsOneWidget);
      await _volver(tester);
      _sinExcepciones(tester);
      await _cerrarCascara(tester);
    });
  });

  group('Matriz · Pilar 2, Ficha y Lupa', () {
    testWidgets('segmentos del Pilar 2 y fila de cliente → '
        'Ficha con sus 3 pestañas', (tester) async {
      await _sembrarCliente(501, 'Grave Treinta', _haceDias(40), 11);
      await _montarHome(tester, _sesionDueno);
      await _irAPilar(tester, 'pilar-tab-clientes');
      expect(find.byType(PilarClientes), findsOneWidget);
      // Directorio embebido con la fila del cliente sembrado.
      expect(find.byType(BuscarScreen), findsOneWidget);
      await _drenar(tester, vueltas: 8);
      expect(find.text('Grave Treinta'), findsOneWidget);
      // Vencimientos → ListasScreen embebida.
      await _tocarSegmento(
          tester,
          find.descendant(
              of: find.byType(PilarClientes),
              matching: find.text('Vencimientos')));
      expect(find.byType(ListasScreen), findsOneWidget);
      // Invitados/Plus → InvitadosScreen embebida.
      await _tocarSegmento(
          tester,
          find.descendant(
              of: find.byType(PilarClientes),
              matching: find.text('Invitados/Plus')));
      expect(find.byType(InvitadosScreen), findsOneWidget);
      // Avisos WhatsApp (solo dueño) → Bandeja embebida.
      await _tocarSegmento(
          tester,
          find.descendant(
              of: find.byType(PilarClientes),
              matching: find.text('Avisos WhatsApp')));
      expect(find.byType(BandejaWhatsappScreen), findsOneWidget);
      // De vuelta al Directorio: la fila abre la Ficha.
      await _tocarSegmento(
          tester,
          find.descendant(
              of: find.byType(PilarClientes),
              matching: find.text('Directorio')));
      await tester.tap(find.text('Grave Treinta'));
      await _drenar(tester, vueltas: 8);
      expect(find.byType(FichaScreen), findsOneWidget);
      // Las 3 pestañas de la Ficha particionada responden.
      for (final pestana in [
        'Progreso y Marcas',
        'App Clientes',
        'Pagos y Notas',
      ]) {
        await tester.tap(find.text(pestana));
        await _drenar(tester, vueltas: 4, ms: 80);
        expect(find.byType(FichaScreen), findsOneWidget,
            reason: 'la pestaña «$pestana» vive dentro de la '
                'Ficha, sin salir de ella');
      }
      await _volver(tester);
      expect(find.byType(FichaScreen), findsNothing);
      _sinExcepciones(tester);
      await _cerrarCascara(tester);
    });

    testWidgets('Lupa: buscar un cliente y tocarlo abre su '
        'Ficha', (tester) async {
      await _sembrarCliente(501, 'Grave Treinta', _haceDias(40), 11);
      await _montarHome(tester, _sesionDueno);
      await tester.tap(find.byKey(const ValueKey('marco-lupa')));
      await _drenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(LupaUniversalScreen), findsOneWidget);
      await tester.enterText(
          find.byType(TextField).first, 'Grave Treinta');
      await _drenar(tester, vueltas: 8);
      // Dos coincidencias: el propio campo (EditableText con
      // lo tecleado) y la fila del resultado; la fila es la
      // última en el árbol.
      await tester.tap(find.text('Grave Treinta').last);
      await _drenar(tester, vueltas: 8);
      expect(find.byType(FichaScreen), findsOneWidget);
      await _volver(tester);
      _sinExcepciones(tester);
      await _cerrarCascara(tester);
    });
  });

  group('Blindaje 2D · cáscara del entrenador', () {
    testWidgets('el entrenador ve «Mi Caja», sus 3 segmentos '
        'y NADA del dueño: sin Comunicados, sin Por Decidir, '
        'sin Dock de dueño', (tester) async {
      await _montarHome(tester, _sesionEntrenador);
      expect(find.text('Mi Caja'), findsOneWidget);
      // Dock recortado por rol: sin Suplemento ni Gasto.
      expect(find.byKey(const ValueKey('dock-suplemento')),
          findsNothing);
      expect(find.byKey(const ValueKey('dock-gasto')), findsNothing);
      expect(find.byKey(const ValueKey('dock-cobrar')),
          findsOneWidget);
      // El Mostrador del entrenador NO monta «Por Decidir».
      expect(find.text('Por Decidir'), findsNothing);
      await _irAPilar(tester, 'pilar-tab-negocio');
      expect(find.byType(PilarNegocio), findsOneWidget);
      for (final (texto, key) in [
        ('A Entregar', 'pilar-negocio-entregar'),
        ('Mi Nómina', 'pilar-negocio-minomina'),
        ('Mis Turnos', 'pilar-negocio-misturnos'),
      ]) {
        await _tocarSegmento(
            tester,
            find.descendant(
                of: find.byType(PilarNegocio),
                matching: find.text(texto)));
        expect(find.byKey(ValueKey(key)), findsOneWidget,
            reason: 'el segmento «$texto» del entrenador debe '
                'enseñar su contenido');
      }
      // Las puertas del dueño no existen en su Pilar 4.
      expect(find.text('Comunicados'), findsNothing);
      expect(find.text('App y Reglas'), findsNothing);
      expect(find.text('Panel clásico'), findsNothing);
      _sinExcepciones(tester);
      // Cierre con sellado de tiempo (diagnóstico con zona
      // instrumentada, 2026-11-12): montar la cáscara del
      // entrenador deja trabajo de BD en vuelo cuyo envoltorio
      // crea temporizadores de UNA VEZ de 10 s (timeout de
      // transacción de sqflite) en la zona falsa durante los
      // drenajes finales; si el test termina antes de que el
      // reloj falso los alcance, el invariante
      // '!timersPending' cae con las aserciones ya verdes
      // (rojo intermitente: verde en la corrida conjunta,
      // rojo en solitario y en la suite completa). No hay
      // ningún temporizador periódico: basta agotar los de
      // una vez intercalando giros reales (para que el
      // trabajo aterrice) con saltos de reloj falso.
      await tester.pumpWidget(const SizedBox());
      for (var k = 0; k < 4; k++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 500));
        });
        await tester.pump(const Duration(seconds: 20));
      }
    });
  });
}
