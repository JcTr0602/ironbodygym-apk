/// Lote 1.35 · SL-10 — Guía / GymPedia.
///
/// G13-8: el editor se titula con el TÍTULO de la ficha,
/// no con su slug técnico.
/// G13-4: publicar y fallar avisa amable (sin la
/// excepción cruda) y el lote nombra los borradores que
/// se quedan por su título, no por su slug.
/// G13-10 (mitad GymPedia): la fila de borrador pinta el
/// nombre de la silueta, no su id crudo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/guia_editor.dart';
import 'package:ironbody_gym/ui/guia_lista.dart';
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
    await File(p.join(dir, 'test_lote135_sl10_guia.db')).delete();
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

Map<String, dynamic> _fichaValida() => {
      'id': 'press-banca-plano',
      'titulo': 'Press de banca plano',
      'sinonimos': ['press plano'],
      'equipoId': 'banca-plana',
      'musculosPrincipales': ['pecho'],
      'musculosSecundarios': ['tríceps'],
      'siluetaId': 'pecho',
      'esencial': true,
      'vistaRapida': {
        'ajusteMaquina': 'Banco plano, barra a la altura del pecho',
        'claves': ['Escápulas juntas'],
        'advertenciaClave': 'No rebotar la barra en el pecho',
      },
      'dosificacion': {
        'series': 3,
        'repeticiones': '8-12',
        'descanso': '90 s',
        'pesoInicial': 'Barra sola',
      },
      'ejecutar': ['Acuéstate y toma la barra.'],
      'errores': ['Arquear la espalda.'],
      'seguridad': {
        'senalParada': 'Dolor en el hombro',
        'autoVerificacion': 'La barra toca el pecho sin rebote',
      },
      'regresion': 'Flexiones',
      'revision': 1,
    };

Future<void> _sembrarEquipo(WidgetTester tester) async {
  await tester.runAsync(() async {
    await _bdVacia();
    await LocalDb.instance.guiaGuardarEquipo(const {
      'equipoId': 'banca-plana',
      'equipoNombre': 'Banca plana',
      'orden': 1,
      'activo': true,
    });
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocalDb.nombreArchivoDbForzado = 'test_lote135_sl10_guia.db';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _mockAppLinks();
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  testWidgets('G13-8 · el editor se titula con el título de la '
      'ficha, no con el slug', (tester) async {
    await _sembrarEquipo(tester);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: GuiaEditorScreen(publicado: _fichaValida()),
    ));
    await _asentarHasta(
        tester, () => find.text('Banca plana').evaluate().isNotEmpty);
    final barra = tester.widget<AppBar>(find.byType(AppBar));
    final titulo = barra.title;
    expect(titulo, isA<Text>());
    expect((titulo as Text).data, 'Press de banca plano');
    // El slug sigue viviendo en su campo «Identificador
    // (slug)» del formulario; lo que no puede es titular
    // la pantalla (en la base, el título ERA el slug).
  });

  testWidgets('G13-4 · publicar con la BD rota avisa amable, '
      'sin la excepción cruda', (tester) async {
    await _sembrarEquipo(tester);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: GuiaEditorScreen(publicado: _fichaValida()),
    ));
    await _asentarHasta(
        tester, () => find.text('Banca plana').evaluate().isNotEmpty);
    // Fallo real de escritura local a mitad de publicar:
    // la cola de ops deja de existir.
    await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      await d.execute('DROP TABLE ops_queue');
    });
    final boton =
        find.widgetWithText(FilledButton, 'Publicar (con vista previa)');
    // El formulario es largo y la lista construye perezosa:
    // se arrastra hasta que el botón existe.
    await tester.dragUntilVisible(
        boton, find.byType(ListView).first, const Offset(0, -300));
    await tester.pump();
    await tester.tap(boton);
    await _asentarHasta(tester,
        () => find.text('Confirmar y publicar').evaluate().isNotEmpty);
    await tester.tap(find.text('Confirmar y publicar'));
    await _asentarHasta(
        tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    final textos = find
        .byType(SnackBar)
        .evaluate()
        .map((e) => e.widget.toString())
        .join(' ');
    expect(find.textContaining('No se pudo publicar'), findsWidgets);
    expect(textos, isNot(contains('DatabaseException')));
    expect(textos, isNot(contains('no such table')));
    expect(find.textContaining('DatabaseException'), findsNothing);
    expect(find.textContaining('no such table'), findsNothing);
  });

  testWidgets('G13-4 + G13-10 · la lista nombra los borradores '
      'por título y la silueta por su nombre', (tester) async {
    await _sembrarEquipo(tester);
    await tester.runAsync(() async {
      final doc = _fichaValida()
        ..['id'] = 'press-banca'
        ..['titulo'] = 'Press de banca';
      await LocalDb.instance.guiaGuardarBorrador({
        'slug': 'press-banca',
        'data': jsonEncode(doc),
        'equipoId': 'banca-plana',
        'esencial': 1,
        'tiene_imagen': 0,
        'imagen_cambiada': 0,
        'imagen_local': '',
        'base_revision': 0,
        'actualizado_ts': '2026-11-16T10:00:00',
      });
      // Una esencial ya publicada: sin ella, el lote se
      // detiene antes en la regla D7 y nunca enseña la
      // lista de los que se quedan.
      await LocalDb.instance.upsertMirrorTexto(
        'guia_fichas',
        'sentadilla',
        {
          'id': 'sentadilla',
          'titulo': 'Sentadilla',
          'equipoId': 'banca-plana',
          'esencial': true,
        },
        1,
      );
      // El borrador ya está en cola de publicación (op
      // real pendiente + su marca): el lote lo deja
      // fuera y debe NOMBRARLO por título.
      await LocalDb.instance.queueOp(
        opUuid: 'op-sl10-lote',
        tipo: 'guia_upsert_publicado',
        payload: {'id': 'press-banca'},
      );
      await LocalDb.instance.setMeta('guia_en_cola_press-banca', '1');
    });
    await _fijarSesionDueno(tester);
    // GuiaScreen es un cuerpo embebible: la envuelve el
    // Scaffold de la pantalla madre.
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: GuiaScreen())));
    await _asentarHasta(tester,
        () => find.textContaining('Publicar borradores').evaluate().isNotEmpty);

    // G13-4: el lote lo nombra por título (el botón del
    // lote vive en la cabecera: se usa antes de bajar).
    final botonLote = find.textContaining('Publicar borradores');
    await tester.tap(botonLote);
    await _asentarHasta(tester,
        () => find.text('Ningún borrador pasa la validación')
            .evaluate()
            .isNotEmpty);
    expect(
        find.textContaining(
            'Press de banca: ya está en cola de publicación.'),
        findsOneWidget);
    expect(find.textContaining('press-banca:'), findsNothing);
    await tester.tap(find.text('Entendido'));
    await tester.pump();

    // La lista construye perezosa: se arrastra hasta la
    // tarjeta del borrador.
    await tester.dragUntilVisible(find.text('Press de banca'),
        find.byType(ListView).first, const Offset(0, -300));
    await tester.pump();

    // G13-10: la fila del borrador nombra la silueta
    // («Pecho»), no su id crudo («pecho»).
    expect(find.textContaining('Banca plana · Pecho'), findsOneWidget);
    expect(find.textContaining('Banca plana · pecho'), findsNothing);
  });
}
