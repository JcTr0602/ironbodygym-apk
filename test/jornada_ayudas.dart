/// Jornada 1.34 — ayudas compartidas de la auditoría práctica.
///
/// Arnés: el del banco de flujos v2 (databaseFactoryFfiNoIsolate):
/// las lecturas FFI de LocalDb completan con microtasks dentro de
/// testWidgets y las pantallas reales se pueden manejar con
/// pumpAndSettle / bucles de espera acotados.
///
/// Convención de TOQUES de la Jornada: 1 toque = 1 tap sobre un
/// control (botón, fila, chip, tarjeta) o 1 foco en un campo de
/// texto (el tecleo en sí no se cuenta: es teclado, no toque de
/// navegación). El contador se incrementa SOLO a través de
/// [ContadorToques], para que el número del informe sea el número
/// de interacciones reales del guión ejecutado, sin maquillar.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Inicialización común (setUpAll): Supabase dummy sin sesión
/// (todo corre como entrenador sin sesión, como el banco) y mocks
/// de app_links para que el plugin no truene.
Future<void> jornadaSetUpAll() async {
  const canalEventos = EventChannel('com.llfbandit.app_links/events');
  const canalMensajes = MethodChannel('com.llfbandit.app_links/messages');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          canalEventos, MockStreamHandler.inline(onListen: (_, __) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(canalMensajes, (_) async => null);
  SharedPreferences.setMockInitialValues({});
  await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
}

/// Siembra la foto de permisos en la caché DEL USUARIO
/// [username] (la clave lleva el sufijo `@<username>`; sin
/// sesión el username es '' y la clave queda en '@', como en
/// el banco). [gastos] controla la llave can_registrar_gastos
/// (contraste de la situación 11). Tras sembrar, carga la foto
/// en el singleton: sin cargar(), la memoria queda fail-closed.
/// La recarga intenta refrescar por RPC (servidor muerto en el
/// arnés: conserva la foto de la caché).
Future<void> jornadaSembrarPermisos(
    {bool gastos = true, String username = ''}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      'cache_permisos_entrenador_json@$username',
      jsonEncode({
        'can_cobrar_pagos': true,
        'can_inscribir_clientes': true,
        'can_editar_fichas': true,
        'can_gestionar_turnos': true,
        'can_registrar_gastos': gastos,
        'can_vender_suplementos': true,
        'can_view_payroll': true,
      }));
  await prefs.setBool('cache_entrenador_activo@$username', true);
  await prefs.setBool('cache_entrenador_habilitado@$username', true);
  PermisosEntrenador().limpiar();
  await PermisosEntrenador().cargar();
}

/// BD fresca (borra el archivo) + permisos sembrados + BD abierta.
/// Toda la preparación va en runAsync (zona real).
Future<void> jornadaPreparar(WidgetTester tester,
    {bool gastos = true}) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await jornadaSembrarPermisos(gastos: gastos);
    await LocalDb.instance.db;
  });
}

/// Viewport de TELÉFONO REAL (compuerta de campo): 420×800 dp.
void jornadaViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

// ── Sesiones falsas (pauta de compuertas_132_matriz: JWT de
// mentira + setInitialSession). «jc» es alias de dueño en
// AppConfig.ownerUsernames; Gabriel es entrenador real. ──

String _jornadaJwt(String email, int telegramId, String sub,
    {bool admin = false}) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': sub,
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {
      'telegram_id': telegramId,
      'provider': 'email',
      // La cuenta real de Jc lleva rol admin en app_metadata
      // (AuthService.isAdmin lo lee de ahí): sin esto, el
      // arnés escondía las acciones solo-admin (p. ej. el
      // ⋮ «Corregir pago» del historial, S20).
      if (admin) 'rol': 'admin',
    },
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _jornadaSesion(WidgetTester tester, String email, int tid,
    String sub, String username,
    {bool gastos = true, bool admin = false}) async {
  final sesion = jsonEncode({
    'access_token': _jornadaJwt(email, tid, sub, admin: admin),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': sub,
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {
        'telegram_id': tid,
        'provider': 'email',
        if (admin) 'rol': 'admin',
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
    // Con la sesión puesta, el username ya es el del usuario:
    // se siembra SU foto de permisos y se carga en memoria.
    await jornadaSembrarPermisos(username: username, gastos: gastos);
  });
}

/// Sesión del DUEÑO (Jc, telegram 735772141; su cuenta
/// real es además admin: isAdmin por rol en app_metadata).
Future<void> jornadaSesionDueno(WidgetTester tester) => _jornadaSesion(tester,
    'jc@ironbody.local', 735772141, '00000000-0000-0000-0000-0000000000e6', 'jc',
    admin: true);

/// Sesión de ENTRENADOR (Gabriel, telegram 1403501391).
/// [gastos] permite el contraste de la situación 11.
Future<void> jornadaSesionEntrenador(WidgetTester tester,
        {bool gastos = true}) =>
    _jornadaSesion(tester, 'gabriel@ironbody.local', 1403501391,
        '00000000-0000-0000-0000-0000000000e7', 'gabriel',
        gastos: gastos);

/// Sesión de ENTRENADOR (Duany, telegram 969869611).
Future<void> jornadaSesionDuany(WidgetTester tester, {bool gastos = true}) =>
    _jornadaSesion(tester, 'duany@ironbody.local', 969869611,
        '00000000-0000-0000-0000-0000000000e8', 'duany',
        gastos: gastos);

/// Drenaje realista: intercala ventanas reales de E/S con
/// pumps (los futuros FFI NoIsolate no completan solo con la
/// zona falsa).
Future<void> jornadaDrenar(WidgetTester tester,
    {int vueltas = 16, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Descarta los diálogos de arranque cerrando rutas hasta la
/// primera (sin hit-test).
Future<void> jornadaDescartarDialogos(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    final hay = find.byType(AlertDialog).evaluate().isNotEmpty ||
        find.byType(Dialog).evaluate().isNotEmpty;
    if (!hay) break;
    Navigator.of(tester.element(find.byType(Navigator).first))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Monta la cáscara REAL (HomeScreen) con la sesión ya puesta.
Future<void> jornadaMontarHome(WidgetTester tester) async {
  jornadaViewport(tester);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'), home: const HomeScreen()));
  await jornadaDrenar(tester, vueltas: 10);
  await jornadaDescartarDialogos(tester);
  await jornadaDrenar(tester, vueltas: 6);
  await jornadaDescartarDialogos(tester);
}

/// Cierre de tests de cáscara (receta de la matriz): los
/// ciclos de sync/fotos laten con Timer.periodic que solo se
/// cancelan en el finally de su operación; hacen falta
/// zancadas grandes de tiempo falso + giros reales de E/S
/// ANTES de desmontar, y giros reales después.
Future<void> jornadaCerrarCascara(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(seconds: 65));
  }
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump(const Duration(milliseconds: 50));
    // El desmontaje genera asientos de AppLog cuyo temporizador
    // de volcado (3 s, una sola vez) nace en la zona falsa:
    // hay que dejarlo vencer tras desmontar.
    await tester.pump(const Duration(seconds: 4));
  }
}

/// Carga Roboto REAL desde los artefactos del SDK (sin ella,
/// el host mide con Ahem y los desbordes son fantasma).
Future<void> jornadaCargarRoboto() async {
  const dir =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf'
  ]) {
    final bytes = await File('$dir/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// Contador de toques del guión (ver la convención en la cabecera).
class ContadorToques {
  int n = 0;

  Future<void> tap(WidgetTester tester, Finder finder,
      {bool warnIfMissed = true}) async {
    n++;
    await tester.tap(finder, warnIfMissed: warnIfMissed);
  }

  /// Foco en un campo + tecleo = 1 toque.
  Future<void> campo(WidgetTester tester, Finder finder, String texto) async {
    n++;
    await tester.enterText(finder, texto);
  }

  Future<void> scrollHasta(WidgetTester tester, Finder finder,
      {Finder? scrollable}) async {
    // El arrastre para revelar un control cuenta como 1 toque.
    n++;
    await tester.scrollUntilVisible(finder, 120,
        scrollable: scrollable ?? find.byType(Scrollable).first);
  }
}

/// Espera bombeando frames hasta que [finder] aparece (patrón
/// robusto del banco para acciones que disparan lecturas FFI).
Future<void> jornadaEsperar(WidgetTester tester, Finder finder,
    {int intentos = 60}) async {
  for (var i = 0; i < intentos; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(finder, findsWidgets,
      reason: 'no apareció tras ${intentos * 250} ms de frames');
}

/// Decodifica el payload de una op de la cola.
Map<String, dynamic> jornadaPayloadDe(Map<String, dynamic> op) {
  final crudo = op['payload'];
  return crudo is String
      ? jsonDecode(crudo) as Map<String, dynamic>
      : Map<String, dynamic>.from(crudo as Map);
}

/// Ops pendientes de un tipo dado.
Future<List<Map<String, dynamic>>> jornadaOps(String tipo) async {
  final ops = await LocalDb.instance.pendingOps();
  return ops.where((o) => o['tipo'] == tipo).toList();
}

/// Ops de un tipo dado en CUALQUIER estado de la cola. La
/// cáscara montada corre su ciclo de sync y puede dejar la op
/// en 'enviada' (fuera de pendingOps) sin que el dato deje de
/// estar encolado: para verificar «el dato cayó» manda la cola
/// entera, no solo lo pendiente.
Future<List<Map<String, dynamic>>> jornadaOpsTodas(String tipo) async {
  final d = await LocalDb.instance.db;
  return d.query('ops_queue', where: 'tipo=?', whereArgs: [tipo]);
}

/// Siembra [n] clientes en el espejo (padrón a escala real:
/// el gym real ronda los 190). Ids desde [desde].
Future<void> jornadaSembrarPadron(int n, {int desde = 1000}) async {
  for (var i = 0; i < n; i++) {
    final id = desde + i;
    await LocalDb.instance.upsertMirror('clientes', id, {
      'id': id,
      'nombre': 'Cliente Padron $i',
      'estado': 'activo',
      'pagado_hasta': '2027-01-01',
      'telefono': '53${100000 + i}',
    }, 1);
  }
}
