/// 1.35 DIS-05 · Fase 1 (editores de contenido) — la prueba
/// exacta del Y2 (clusterF_ui.md §3.3) sobre los selectores
/// migrados a `SelectorIronForm`:
///
/// · `gympedia_editor`: crear un artículo NUEVO desde cero
///   preselecciona EXACTAMENTE lo que hoy preselecciona el
///   FormField (categoría «entrenamiento», sello «verde»,
///   nivel «plus» — si el sustituto preseleccionara otra
///   cosa, la GymPedia guardaría artículos con el nivel
///   cambiado en silencio); editar, cambiar el nivel,
///   publicar y reabrir: el valor elegido persiste y el
///   campo cerrado muestra la etiqueta, no el id.
/// · `guia_editor`: editar una ficha, cambiar equipo y
///   silueta, guardar el borrador y reabrirlo: el borrador
///   lleva los valores nuevos y el cerrado muestra los
///   NOMBRES (el equipo por su nombre, nunca su id).
///
/// El arnés (BD ffi vacía, sesión de dueño falsa, asentar
/// mezclando tiempo real y falso) es el de la oleada 6.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/guia_editor.dart';
import 'package:ironbody_gym/ui/gympedia_editor.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _slugGym = 'articulo-dis05';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
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

/// Toca el selector cuyo campo cerrado enseña [etiquetaVisible]
/// y elige [opcion] en la hoja del panel.
Future<void> _elegirEnSelector(
    WidgetTester tester, String etiquetaVisible, String opcion) async {
  final campo = find.ancestor(
      of: find.text(etiquetaVisible),
      matching: find.byType(SelectorIronForm<String>));
  expect(campo, findsOneWidget,
      reason: 'no se encontró el selector que enseña «$etiquetaVisible»');
  await tester.ensureVisible(campo);
  await tester.pump();
  await tester.tap(campo);
  await _asentarHasta(
      tester, () => find.byType(HojaAccion).evaluate().isNotEmpty);
  expect(find.byType(HojaAccion), findsOneWidget);
  await tester.tap(find.descendant(
      of: find.byType(HojaAccion), matching: find.text(opcion)));
  await _asentarHasta(
      tester, () => find.byType(HojaAccion).evaluate().isEmpty);
  expect(find.byType(HojaAccion), findsNothing);
}

/// Lanzador del editor GymPedia como RUTA (así vive en la
/// app: se empuja desde la lista). Publicar desapila la ruta
/// y vuelve aquí; reabrir es empujar otra vez con la fila
/// nueva del espejo. (Montar el editor como `home` y dejar
/// que publicar desapile la ruta raíz corrompe el Navigator
/// del arnés: aserción `_history.isNotEmpty` al remontar.)
class _LanzadorGym extends StatelessWidget {
  final Map<String, dynamic>? Function() publicado;
  const _LanzadorGym({required this.publicado});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () {
            final p = publicado();
            if (p == null) return;
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => GympediaEditorScreen(
                  publicado: p, slugsPublicados: const {_slugGym}),
            ));
          },
          child: const Text('Abrir editor'),
        ),
      ),
    );
  }
}

Map<String, dynamic> _publicadoGym() => {
      'id': _slugGym,
      'titulo': 'Artículo DIS-05',
      'categoria': 'tecnica',
      'lo_esencial': 'Resumen corto y claro.',
      'explicacion_md': 'Texto de explicación del artículo.',
      'pasos': ['Paso uno', 'Paso dos'],
      'errores': ['Error frecuente'],
      'referencias': [
        {'titulo': 'Estudio A', 'fuente': 'Revista 2020', 'url': 'https://a.org/1'},
        {'titulo': 'Estudio B', 'fuente': 'Revista 2021', 'url': 'https://b.org/2'},
      ],
      'sello': 'verde',
      'nivel': 'esencial',
      'related_ids': <String>[],
      'tiene_imagen': false,
      'imagen_cambiada': false,
      'revision': 3,
      'imagen_rev': 0,
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  group('DIS-05 fase 1 · GympediaEditor', () {
    testWidgets(
        'artículo NUEVO: los 3 selectores preseleccionan lo de '
        'hoy (entrenamiento / verde / plus)', (tester) async {
      _mockAppLinks();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(_bdVacia);
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
          home: GympediaEditorScreen(slugsPublicados: {})));
      await _asentarHasta(
          tester, () => find.text('Plus (de pago)').evaluate().isNotEmpty);
      // Los tres selectores migrados, ninguno del SDK.
      expect(find.byType(SelectorIronForm<String>), findsNWidgets(3));
      expect(
          find.byType(DropdownButtonFormField<String>), findsNothing);
      // El defecto que manda el Y2: lo preseleccionado al crear.
      expect(find.text('Entrenamiento'), findsOneWidget);
      expect(find.text('🟢 Respaldo sólido'), findsOneWidget);
      expect(find.text('Plus (de pago)'), findsOneWidget);
    });

    testWidgets(
        'editar: cambiar el nivel, publicar y reabrir — el '
        'valor elegido persiste', (tester) async {
      _mockAppLinks();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.upsertMirrorTexto(
            'gympedia_articulos', _slugGym, _publicadoGym(), 0);
      });
      await _fijarSesionDueno(tester);
      Map<String, dynamic>? actual = _publicadoGym();
      await tester.pumpWidget(
          MaterialApp(home: _LanzadorGym(publicado: () => actual)));
      await tester.tap(find.text('Abrir editor'));
      await _asentarHasta(tester,
          () => find.text('Esencial (gratis)').evaluate().isNotEmpty);
      // El cerrado enseña las etiquetas de lo publicado.
      expect(find.text('Técnica de ejercicios'), findsOneWidget);
      expect(find.text('Esencial (gratis)'), findsOneWidget);
      // Cambiar el nivel desde el panel de la casa.
      await _elegirEnSelector(
          tester, 'Esencial (gratis)', 'Plus (de pago)');
      expect(find.text('Plus (de pago)'), findsOneWidget);
      // Publicar: la op encolada lleva el nivel NUEVO y la
      // categoría intacta.
      await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Publicar'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Publicar'));
      await _asentarHasta(tester,
          () => find.byType(GympediaEditorScreen).evaluate().isEmpty);
      expect(find.byType(GympediaEditorScreen), findsNothing,
          reason: 'el editor no cerró tras publicar');
      final ops = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        return db.rawQuery(
            "SELECT payload FROM ops_queue WHERE tipo = "
            "'gympedia_upsert_publicado'");
      });
      expect(ops, hasLength(1));
      final payload = jsonDecode('${ops!.single['payload']}');
      expect(payload['nivel'], 'plus');
      expect(payload['categoria'], 'tecnica');
      expect(payload['sello'], 'verde');
      // Reabrir desde el espejo (lo que la lista pasaría): el
      // cerrado enseña el nivel nuevo.
      final espejo = await tester.runAsync(
          () => LocalDb.instance.gympediaPublicados());
      actual = espejo!.firstWhere((f) => '${f['id']}' == _slugGym);
      await tester.tap(find.text('Abrir editor'));
      await _asentarHasta(tester,
          () => find.text('Plus (de pago)').evaluate().isNotEmpty);
      expect(find.text('Plus (de pago)'), findsOneWidget);
      expect(find.text('Técnica de ejercicios'), findsOneWidget);
    });
  });

  group('DIS-05 fase 1 · GuiaEditor', () {
    testWidgets(
        'editar: el cerrado enseña NOMBRES (no ids); cambiar '
        'equipo y silueta, guardar borrador y reabrir persiste',
        (tester) async {
      _mockAppLinks();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.guiaGuardarEquipo(const {
          'equipoId': 'eq1',
          'equipoNombre': 'Barra olímpica',
          'orden': 1,
          'activo': true,
        });
        await LocalDb.instance.guiaGuardarEquipo(const {
          'equipoId': 'eq2',
          'equipoNombre': 'Mancuernas',
          'orden': 2,
          'activo': true,
        });
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
          home: GuiaEditorScreen(publicado: {
        'id': 'press-banca',
        'titulo': 'Press de banca',
        'equipoId': 'eq2',
        'siluetaId': 'espalda',
        'musculosPrincipales': ['Pectoral'],
        'esencial': false,
        'revision': 1,
      })));
      await _asentarHasta(
          tester, () => find.text('Mancuernas').evaluate().isNotEmpty);
      // El cerrado enseña el NOMBRE del equipo y de la
      // silueta; los ids no aparecen como texto.
      expect(find.text('Mancuernas'), findsOneWidget);
      expect(find.text('Espalda'), findsOneWidget);
      expect(find.text('eq2'), findsNothing);
      expect(find.byType(SelectorIronForm<String>), findsNWidgets(2));
      expect(
          find.byType(DropdownButtonFormField<String>), findsNothing);
      // Cambiar ambos desde el panel.
      await _elegirEnSelector(tester, 'Mancuernas', 'Barra olímpica');
      await _elegirEnSelector(tester, 'Espalda', 'Pecho');
      expect(find.text('Barra olímpica'), findsOneWidget);
      expect(find.text('Pecho'), findsOneWidget);
      // Guardar el borrador: lleva los valores nuevos.
      final botonBorrador =
          find.widgetWithText(FilledButton, 'Guardar borrador');
      await tester.ensureVisible(botonBorrador);
      await tester.pump();
      await tester.tap(botonBorrador);
      Map<String, dynamic>? borrador;
      for (var i = 0; i < 60 && borrador == null; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
        borrador = await tester.runAsync<Map<String, dynamic>?>(
            () => LocalDb.instance.guiaBorrador('press-banca'));
      }
      expect(borrador, isNotNull,
          reason: 'el borrador no se guardó en la BD');
      final data =
          jsonDecode('${borrador!['data']}') as Map<String, dynamic>;
      expect(data['equipoId'], 'eq1');
      expect(data['siluetaId'], 'pecho');
      // Reabrir el borrador: el cerrado enseña lo nuevo.
      await tester.pumpWidget(
          MaterialApp(home: GuiaEditorScreen(borrador: borrador)));
      await _asentarHasta(tester,
          () => find.text('Barra olímpica').evaluate().isNotEmpty);
      expect(find.text('Barra olímpica'), findsOneWidget);
      expect(find.text('Pecho'), findsOneWidget);
    });
  });
}
