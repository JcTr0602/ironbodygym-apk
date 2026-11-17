/// Campo 1.35 (2026-11-17) — los defectos de campo de
/// Jc sobre la 1.35 entregada y la composición de la
/// pantalla principal que aprobó:
///
/// - Frescura corta «act.» (textoActCorto, pura): la
///   frescura se dice UNA vez, en la línea de contexto.
/// - Directorio: la FilaCliente mide lo mismo con
///   acción, con chip de avisado y con ambos (la acción
///   vive como pastilla en el trailing, a 48 dp; el
///   chip de avisado comparte la fila del de estado).
/// - La pastilla «65» de Vencimientos ya no tapa la
///   última letra (reserva de 16 dp con la pastilla
///   visible, réplica geométrica + contrato de fuente).
/// - BandejaPorDecidir embebida: sin tarjeta ni
///   cabecera propias; en cero verificado no pinta nada
///   y reporta «sin contenido»; con algo, reporta.
/// - Mostrador (arnés de fase4): el estado de la
///   captura de Jc (600 en efectivo cobrados por un
///   entrenador sin entregar) se prueba a nivel de
///   funciones de datos — cobrado hoy y por recoger
///   coinciden sin ser un error — porque el arnés de
///   la Home no aterriza _cargar (limitación conocida
///   de la casa, reverificada con sondas en esta
///   pieza); la Home ensamblada se prueba en el cero
///   de la captura y en su estructura (Zona 1 ausente,
///   frescura una vez, Zona 2 sin títulos internos,
///   Zona 3 sin plegar). La puerta «por recoger» →
///   PendienteScreen la cubre el contrato de fuente
///   de fase4_mostrador_test.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// Frescura corta (pura)
// ---------------------------------------------------------------------------

void _testsTextoActCorto() {
  test('textoActCorto: hoy, ayer y otro día', () {
    // 17-nov 19:43 UTC = 14:43 en La Habana (CST).
    final ahora = DateTime.utc(2026, 11, 17, 20, 0);
    expect(textoActCorto(DateTime.utc(2026, 11, 17, 19, 43), ahora),
        'act. 14:43');
    expect(textoActCorto(DateTime.utc(2026, 11, 16, 14, 5), ahora),
        'act. ayer 09:05');
    expect(textoActCorto(DateTime.utc(2026, 11, 3, 14, 5), ahora),
        'act. 03/11 09:05');
  });
}

// ---------------------------------------------------------------------------
// FilaCliente uniforme
// ---------------------------------------------------------------------------

Map<String, dynamic> _cliente({int dias = 30}) {
  final hoy = ahoraHabana();
  final f = DateTime(hoy.year, hoy.month, hoy.day + dias);
  return {
    'id': 51,
    'nombre': 'Cliente Fila',
    'pagado_hasta': '${f.year}-'
        '${f.month.toString().padLeft(2, '0')}-'
        '${f.day.toString().padLeft(2, '0')}',
  };
}

Future<double> _altoFila(WidgetTester t, Widget w) async {
  await t.pumpWidget(MaterialApp(
    theme: AppTema.tacticoOscuro(),
    home: Scaffold(body: Column(children: [w])),
  ));
  await t.pump();
  final ink = find.descendant(
      of: find.byType(FilaCliente), matching: find.byType(InkWell));
  return t.getSize(ink.first).height;
}

void _testsFilaCliente() {
  testWidgets('la fila mide lo mismo con acción, con '
      'chip de avisado y con ambos', (t) async {
    final base = await _altoFila(
        t, SizedBox(width: 360, child: FilaCliente(cliente: _cliente())));
    final cobrar = await _altoFila(
        t,
        SizedBox(
            width: 360,
            child: FilaCliente(
              cliente: _cliente(dias: -3),
              accionPrincipal: (
                texto: 'Cobrar',
                icono: Icons.payments_rounded,
                alTocar: () {},
              ),
            )));
    final avisarWa = await _altoFila(
        t,
        SizedBox(
            width: 360,
            child: FilaCliente(
              cliente: _cliente(dias: 4),
              accionPrincipal: (
                texto: 'Avisar',
                icono: Icons.chat_rounded,
                alTocar: () {},
              ),
              accionWhatsapp: () {},
            )));
    final chip = await _altoFila(
        t,
        SizedBox(
            width: 360,
            child: FilaCliente(
                cliente: _cliente(), avisoChip: 'Avisado hoy')));
    final chipAccion = await _altoFila(
        t,
        SizedBox(
            width: 360,
            child: FilaCliente(
              cliente: _cliente(dias: -3),
              avisoChip: 'Avisado · 12/11',
              accionPrincipal: (
                texto: 'Cobrar',
                icono: Icons.payments_rounded,
                alTocar: () {},
              ),
            )));
    for (final (nombre, alto) in [
      ('cobrar', cobrar),
      ('avisar+wa', avisarWa),
      ('chip', chip),
      ('chip+acción', chipAccion),
    ]) {
      expect((alto - base).abs(), lessThanOrEqualTo(0.5),
          reason: 'la variante $nombre debe medir como la '
              'base ($base) y mide $alto');
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('la pastilla «Cobrar» toca 48 dp y la de '
      '«Avisar» es el botón de WhatsApp (sin duplicar)',
      (t) async {
    var cobrado = false;
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
          body: Column(children: [
        SizedBox(
            width: 360,
            child: FilaCliente(
              cliente: _cliente(dias: -3),
              accionPrincipal: (
                texto: 'Cobrar',
                icono: Icons.payments_rounded,
                alTocar: () => cobrado = true,
              ),
              accionWhatsapp: () {},
            )),
      ])),
    ));
    await t.pump();
    final botonCobrar = find.widgetWithText(TextButton, 'Cobrar');
    expect(botonCobrar, findsOneWidget);
    expect(t.getSize(botonCobrar).height,
        greaterThanOrEqualTo(48));
    // Con «Cobrar», el botón de chat acompaña.
    expect(find.byTooltip('Avisar por WhatsApp'), findsOneWidget);
    await t.tap(botonCobrar);
    await t.pump();
    expect(cobrado, isTrue);

    var avisado = false;
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
          body: Column(children: [
        SizedBox(
            width: 360,
            child: FilaCliente(
              cliente: _cliente(dias: 4),
              accionPrincipal: (
                texto: 'Avisar',
                icono: Icons.chat_rounded,
                alTocar: () => avisado = true,
              ),
              accionWhatsapp: () {},
            )),
      ])),
    ));
    await t.pump();
    // Con «Avisar» no hay botón de chat aparte: la
    // pastilla ES el aviso.
    expect(find.byTooltip('Avisar por WhatsApp'), findsNothing);
    await t.tap(find.widgetWithText(TextButton, 'Avisar'));
    await t.pump();
    expect(avisado, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('el chip de avisado vive en la fila del '
      'chip de estado (misma banda vertical)', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
          body: Column(children: [
        SizedBox(
            width: 360,
            child: FilaCliente(
                cliente: _cliente(), avisoChip: 'Avisado · 12/11')),
      ])),
    ));
    await t.pump();
    final avisado = t.getRect(find.text('Avisado · 12/11'));
    // El chip de estado de un cliente al día dice su
    // estado con «días»/fecha; se localiza por su
    // contenedor hermano: basta comprobar que el
    // avisado queda en la mitad superior de la fila
    // (la banda del nombre+estado), no en una tercera
    // línea bajo ella.
    final fila = t.getRect(find.byType(FilaCliente));
    expect(avisado.center.dy - fila.top, lessThan(fila.height * 0.75),
        reason: 'el avisado no debe colgar en una línea '
            'propia al pie de la fila');
    expect(t.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// Pastilla de Vencimientos
// ---------------------------------------------------------------------------

void _testsPastillaVencimientos() {
  testWidgets('con la reserva, la pastilla no solapa '
      'la última letra de «Vencimientos»', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SegmentedButton<String>(
            segments: [
              const ButtonSegment(
                  value: 'directorio',
                  icon: Icon(Icons.people_rounded),
                  label: Text('Directorio')),
              ButtonSegment(
                  value: 'vencimientos',
                  icon: const Icon(Icons.event_busy_rounded),
                  label: Badge(
                    isLabelVisible: true,
                    label: const Text('65'),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: const Text('Vencimientos'),
                    ),
                  )),
            ],
            selected: const {'directorio'},
            onSelectionChanged: (_) {},
          ),
        ),
      ),
    ));
    await t.pump();
    final texto = t.getRect(find.text('Vencimientos'));
    final pastilla = t.getRect(find.text('65'));
    expect(pastilla.left, greaterThanOrEqualTo(texto.right - 1),
        reason: 'la pastilla debe empezar donde el texto '
            'ya terminó (antes lo solapaba 8 dp)');
  });

  test('fuente: el segmento de Vencimientos reserva el '
      'sitio de la pastilla en pilar_clientes.dart', () {
    final f = File('lib/ui/pilar_clientes.dart').readAsStringSync();
    final i = f.indexOf('label: Badge(');
    expect(i, greaterThanOrEqualTo(0));
    final seg = f.substring(i, i + 900);
    expect(seg.contains('EdgeInsets.only('), isTrue);
    expect(seg.contains('right:'), isTrue);
    expect(seg.contains('_urgenciaVenc'), isTrue,
        reason: 'la reserva solo existe con la pastilla '
            'visible (mismo predicado que isLabelVisible)');
  });
}

// ---------------------------------------------------------------------------
// BandejaPorDecidir embebida
// ---------------------------------------------------------------------------

BandejaPorDecidir _bandejaEmbebida({
  required int incidencias,
  required List<bool> reportes,
  bool remotasEnCero = true,
}) {
  return BandejaPorDecidir(
    incidencias: incidencias,
    rellenos: 0,
    adelantos: 0,
    onIr: (_) {},
    embebida: true,
    alCambiarContenido: reportes.add,
    cargarRemotas: () async => remotasEnCero
        ? const ConteosRemotosPorDecidir(
            vales: 0, plus: 0, comunidad: 0, solicitudes: 0)
        : const ConteosRemotosPorDecidir(),
    cargarCongelaciones: () async => (ok: true, pendientes: 0),
    cargarArqueos: () async => const [],
    cargarCatalogo: () async => 0,
  );
}

void _testsBandejaEmbebida() {
  testWidgets('en cero verificado no pinta nada y '
      'reporta «sin contenido»', (t) async {
    final reportes = <bool>[];
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
          body: _bandejaEmbebida(incidencias: 0, reportes: reportes)),
    ));
    await t.pump();
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await t.pump();
    expect(find.text('Por Decidir'), findsNothing);
    expect(find.text('Todo al día'), findsNothing);
    expect(find.textContaining('Incidencias'), findsNothing);
    // El frame 1 reporta contenido (la línea «sin
    // verificar» ES algo que decir, Compuerta 1); al
    // verificar las remotas en cero, el reporte asentado
    // es «sin contenido» y nada queda pintado: la
    // tarjeta de la Zona 2 no debe existir por la
    // bandeja en el estado asentado.
    expect(reportes.last, isFalse,
        reason: 'tras verificar en cero, la bandeja no '
            'sostiene la tarjeta de la Zona 2');
    expect(t.takeException(), isNull);
  });

  testWidgets('con incidencias pinta las filas sin '
      'tarjeta ni cabecera y reporta contenido', (t) async {
    final reportes = <bool>[];
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
          body: _bandejaEmbebida(incidencias: 2, reportes: reportes)),
    ));
    await t.pump();
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await t.pump();
    expect(find.text('Incidencias de sincronización'),
        findsOneWidget);
    expect(find.text('Por Decidir'), findsNothing,
        reason: 'embebida: la cabecera la pone la zona, '
            'no la bandeja');
    expect(reportes, contains(true));
    expect(t.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// Mostrador ensamblado (arnés de fase4)
// ---------------------------------------------------------------------------

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

Future<void> _fijarSesionDueno() async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira('jctr0602@ironbody.gym'),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': 'jctr0602@ironbody.gym',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': {'nombre': 'Jc', 'telegram_id': 735772141},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}

Future<void> _descartarDialogos(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    if (find.byType(AlertDialog).evaluate().isEmpty) break;
    Navigator.of(tester.element(find.byType(HomeScreen)))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _abrirHome360(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
  await _avanzarTiempo(tester);
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(seconds: 2));
  });
  await tester.pump(const Duration(milliseconds: 300));
  await _descartarDialogos(tester);
}

void _testsMostrador() {
  // ALCANCE (limitación conocida de la casa, la misma
  // que documenta fase4_mostrador_test): el arnés de la
  // Home ensamblada NO aterriza los valores de _cargar
  // bajo FakeAsync — verificado de nuevo en esta pieza
  // con sondas (con la siembra en el espejo, la función
  // cobradoHoyPorMetodo SÍ la devuelve; la pantalla no
  // la recoge en el arnés). Por eso: los estados CON
  // datos se prueban aquí a nivel de FUNCIONES de datos
  // (la semántica que pinta la Zona 1) y la Home
  // ensamblada se prueba en el estado que el arnés sí
  // produce (el cero de la captura de Jc) y en su
  // estructura. La fila «por recoger» como puerta se
  // cubre además por el contrato de fuente de fase4.
  test('la captura de Jc en datos: cobrado hoy 600 en '
      'efectivo y por recoger 600 son dos hechos que '
      'coinciden (flujo de hoy / stock en manos del '
      'entrenador)', () async {
    final hoy = _iso(DateTime.now());
    await LocalDb.instance.upsertMirror('pagos', 9201, {
      'id': 9201,
      'op_uuid': 'campo135-captura-9201',
      'cliente_id': 1,
      'fecha': hoy,
      'monto': 600,
      'metodo': 'efectivo',
      'concepto': 'semanal',
      'anulado': 0,
      'telegram_user_id': 111222,
      'registrado_por': 'Duany',
      'entregado': 0,
    }, 9201);

    // Lo cobrado hoy (el titular): 600, todo efectivo.
    final porMetodo = await cobradoHoyPorMetodo();
    expect(porMetodo['efectivo'], 600);
    expect(porMetodo['transferencia'], 0);

    // Lo por recoger (la fila ámbar): el MISMO 600 como
    // stock sin entregar del entrenador — no es un
    // error de dato: es el mismo pago visto como flujo
    // y como pendiente (diagnóstico del informe).
    expect(await pendienteRecoger(excluirTelegramId: 735772141),
        600);
    // Y el detalle que abre la puerta (PendienteScreen
    // lee pendientePorEntrenador): una entrada, Duany,
    // 600, 1 pago.
    final detalle =
        await pendientePorEntrenador(excluirTid: 735772141);
    expect(detalle.length, 1);
    expect(detalle.first['nombre'], 'Duany');
    expect(detalle.first['total'], 600);
    expect(detalle.first['n'], 1);
  });

  testWidgets('la Home en el cero de la captura: sin '
      'tarjeta de dinero, frescura una vez en la línea '
      'de contexto y Zona 3 abierta', (tester) async {
    await tester.runAsync(() => _fijarSesionDueno());
    await _abrirHome360(tester);

    // Doble cero: la Zona 1 no existe (regla dura de
    // Jc) — en la 1.35 este estado pintaba el titular
    // «Hoy: 0 cobrados · 0 por recoger».
    expect(find.byKey(const ValueKey('hoy-dinero')), findsNothing);
    expect(find.byKey(const ValueKey('hoy-por-recoger')),
        findsNothing);
    expect(find.textContaining('por recoger'), findsNothing);
    // La frescura, una vez y en la línea de contexto;
    // el botón de personalizar comparte su banda (fuera
    // la banda vacía de la captura). (La línea de
    // contexto misma la computa _cargar, que el arnés
    // no aterriza: la banda se mide con la frescura y
    // el botón, que siempre viven en ella.)
    expect(find.byKey(const ValueKey('home-act')), findsOneWidget);
    final dyAct = tester
        .getCenter(find.byKey(const ValueKey('home-act')))
        .dy;
    final dyPersonalizar = tester
        .getCenter(find.byKey(const ValueKey('mostrador-personalizar')))
        .dy;
    expect((dyAct - dyPersonalizar).abs(), lessThan(26),
        reason: 'frescura y personalizar en UNA fila: '
            'fuera la banda vacía');
    // Y la banda entera es UNA fila fina: la de antes
    // (línea + fila propia de 48 para el icono) medía
    // ~83-95 dp de prólogo casi vacío.
    expect(
        tester
            .getSize(find.byKey(const ValueKey('home-personalizar')))
            .height,
        lessThanOrEqualTo(64),
        reason: 'la banda de contexto+personalizar es '
            'una sola fila, no dos');
    // La fusión de la Zona 2: ningún título interno de
    // las dos tarjetas viejas sobrevive en la portada.
    expect(find.text('Atención hoy'), findsNothing);
    expect(find.text('Por Decidir'), findsNothing);
    // La fila fina de Turnos del dueño sigue.
    expect(find.byKey(const ValueKey('hoy-turnos')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Zona 3 ABIERTA: las mini-celdas se alcanzan sin
    // tocar cabecera alguna (el pliegue se jubiló).
    expect(find.byKey(const ValueKey('hoy-informe-cabecera')),
        findsNothing);
    final pulso = find.byKey(const ValueKey('hoy-pulso'));
    await tester.ensureVisible(pulso);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Pagaron el mes'), findsOneWidget);
    expect(find.text('Pago de entrenadores'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await _avanzarTiempo(tester);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  _testsTextoActCorto();
  _testsFilaCliente();
  _testsPastillaVencimientos();
  _testsBandejaEmbebida();
  _testsMostrador();
}
