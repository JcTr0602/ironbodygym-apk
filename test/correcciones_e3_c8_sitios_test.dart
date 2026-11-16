/// 1.35 (corrección E3, C8-01 del Yunque de Cambios): la
/// migración DIS-05 a SelectorIron dejó sitios sin red:
/// ningún test fijaba la corrección de Invitados (el
/// selector de orden acotado a 184 dp junto al buscador)
/// ni montaba otros cuatro sitios migrados. Si el campo
/// cerrado vuelve a medirse por su contenido dentro de
/// un Row, o un sitio pierde su preselección, esto lo
/// caza antes que el campo.
///
/// Los cinco sitios, montados a 360×800 con el arnés de
/// dis05_fase3_operativa_test: preselección visible en
/// el cerrado, elegir en el panel y valor resultante en
/// el cerrado, sin excepción de layout.
///
/// Nota de alcance: esta red es NUEVA (el hallazgo es la
/// ausencia de red, no un defecto presente): sobre la
/// base de074a6 los sitios ya funcionan — lo que no
/// existía era la prueba.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// FontLoader vive en services (ya importado); se usa en
// setUpAll para pintar con la fuente real.
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/ui/campana_wa.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
import 'package:ironbody_gym/ui/incidencias/lista_incidencias.dart';
import 'package:ironbody_gym/ui/invitados.dart';
import 'package:ironbody_gym/ui/panel_premios_clientes.dart';
import 'package:ironbody_gym/ui/panel_resto_sistema.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

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

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
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

void _mockAppLinks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (args, events) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (call) async => null);
}

Future<void> _asentarHasta(
    WidgetTester tester, bool Function() condicion) async {
  for (var i = 0; i < 60 && !condicion(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

/// Trae [f] al viewport arrastrando SU scroll ancestro:
/// a 360×800 los campos y opciones bajos de una hoja
/// nacen fuera (y>800) y ni ensureVisible ni el toque
/// directo los alcanzan — el gesto real del usuario es
/// este arrastre.
Future<void> _traer(WidgetTester tester, Finder f) async {
  final alto = tester.view.physicalSize.height /
      tester.view.devicePixelRatio;
  for (var i = 0; i < 6; i++) {
    final c = tester.getCenter(f);
    if (c.dy > 10 && c.dy < alto - 10) return;
    final scroll = find
        .ancestor(of: f, matching: find.byType(Scrollable))
        .first;
    await tester.drag(
        scroll, Offset(0, c.dy >= alto ? -240 : 240));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Toca el campo cerrado [cerrado] y elige [opcion] en
/// el panel. El panel puede abrirse SOBRE otra hoja (la
/// de Filtros de Incidencias): la apertura y el cierre
/// se miden por el conteo de hojas, no por su ausencia.
Future<void> _elegir(
    WidgetTester tester, Finder cerrado, String opcion) async {
  final hojasAntes = find.byType(HojaAccion).evaluate().length;
  await _traer(tester, cerrado);
  await tester.tap(cerrado);
  await _asentarHasta(tester,
      () => find.byType(HojaAccion).evaluate().length > hojasAntes);
  final opcionFinder = find.descendant(
      of: find.byType(HojaAccion).last, matching: find.text(opcion));
  await _traer(tester, opcionFinder);
  await tester.tap(opcionFinder);
  await _asentarHasta(tester,
      () => find.byType(HojaAccion).evaluate().length == hojasAntes);
}

void _vista360(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // La fuente real (como el arnés de campo 1): con la
    // fuente de test, los textos miden de más y aparecen
    // desbordes fantasma que el teléfono no tiene.
    const dirFuentes =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ]) {
      final bytes = await File('$dirFuentes/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() {
    _mockAppLinks();
  });

  testWidgets('Invitados: el orden nace «Orden del '
      'servidor» en sus 184 dp y cambia a «Nombre A–Z»',
      (tester) async {
    _vista360(tester);
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InvitadosScreen(embebido: true))));
    await _asentarHasta(tester,
        () => find.text('Orden del servidor').evaluate().isNotEmpty);
    expect(find.text('Orden del servidor'), findsOneWidget);
    await _elegir(tester, find.text('Orden del servidor'), 'Nombre A–Z');
    expect(find.text('Nombre A–Z'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Incidencias: la hoja de Filtros enseña '
      'las dos pistas y la prioridad elegida queda',
      (tester) async {
    _vista360(tester);
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: ListaIncidenciasScreen()));
    await _asentarHasta(tester,
        () => find.byTooltip('Filtros').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Filtros'));
    await _asentarHasta(tester,
        () => find.text('Todos los tipos').evaluate().isNotEmpty);
    expect(find.text('Todos los tipos'), findsOneWidget);
    expect(find.text('Todas las prioridades'), findsOneWidget);
    await _elegir(
        tester, find.text('Todas las prioridades'), 'Alta');
    expect(find.text('Alta'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Premios: el diálogo de concesión '
      'preselecciona «manual» y el logro elegido queda',
      (tester) async {
    _vista360(tester);
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PremiosClientesTab(
          buscarClientes: () async => [
            (id: 7, nombre: 'Cliente Siete', telefono: '58112233')
          ],
          // La costura devuelve el JSON crudo de la RPC
          // (la pantalla lo parsea con
          // parseDetallePremiosCliente; ok:true basta).
          cargarDetalle: (id) async => {'ok': true},
          cargarCatalogo: () async => const [
            EntradaCatalogoPremio(
              logroId: 'manual',
              nombre: 'Manual',
              metaDias: 0,
              premioDias: 5,
              activo: true,
              ultimoCambioTexto: null,
            ),
            EntradaCatalogoPremio(
              logroId: 'constancia_real',
              nombre: 'Constancia real',
              metaDias: 15,
              premioDias: 10,
              activo: true,
              ultimoCambioTexto: null,
            ),
          ],
          concederVale: (id, logroId, dias, nota) async =>
              {'ok': true},
        ),
      ),
    ));
    await _asentarHasta(tester,
        () => find.text('Cliente Siete').evaluate().isNotEmpty);
    await tester.tap(find.text('Cliente Siete'));
    await _asentarHasta(tester,
        () => find.text('Conceder vale').evaluate().isNotEmpty);
    await tester.tap(find.text('Conceder vale'));
    await _asentarHasta(tester,
        () => find.text('Manual · 5 días').evaluate().isNotEmpty);
    expect(find.text('Manual · 5 días'), findsOneWidget,
        reason: 'con «manual» en el catálogo, el selector '
            'nace en él');
    await _elegir(tester, find.text('Manual · 5 días'),
        'Constancia real · 10 días');
    expect(find.text('Constancia real · 10 días'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mantenimiento: la tabla espejo nace en '
      '«Clientes» y la elegida queda en el cerrado',
      (tester) async {
    _vista360(tester);
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: MantenimientoScreen()));
    await _asentarHasta(tester,
        () => find.text('Re-descargar tabla espejo')
            .evaluate()
            .isNotEmpty);
    await _elegir(tester, find.text('Clientes'), 'Pagos');
    expect(find.text('Pagos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Campaña WA: con una plantilla sembrada, '
      'el selector nace en «Texto libre» y la plantilla '
      'elegida queda', (tester) async {
    _vista360(tester);
    await tester.runAsync(() async {
      await _bdVacia();
      await LocalDb.instance.setAjustes({
        'plantillas_wa': [
          {'nombre': 'Promo noviembre', 'texto': 'Hola {nombre}'}
        ],
      });
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: CampanaWaScreen()));
    await _asentarHasta(tester,
        () => find.text('Texto libre (abajo)').evaluate().isNotEmpty);
    await _elegir(
        tester, find.text('Texto libre (abajo)'), 'Promo noviembre');
    expect(find.text('Promo noviembre'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
