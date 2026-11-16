/// 1.35 (CAMPO-2, corrección de la reconciliación §3.2):
/// el diálogo «Editar cliente» rehecho con el patrón de
/// la casa, sin perder un campo ni una validación.
///
/// Se afirma contra el diálogo ABIERTO desde la ficha:
/// - los 3 campos nacen con los valores de siempre;
/// - el teléfono ocupa el MISMO ancho que el nombre (el
///   defecto de campo: era más estrecho) y el botón de
///   contactos vive DENTRO de su rectángulo (antes
///   flotaba fuera);
/// - el aviso de fecha de carnet imposible aparece al
///   teclear una fecha que no existe y no bloquea;
/// - editar y guardar devuelve EXACTAMENTE los datos de
///   siempre: el espejo queda con los valores nuevos y la
///   op `editar_cliente` encolada con su payload;
/// - a 360 dp el diálogo no desborda.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma';
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 12, int ms = 100}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
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
    LocalDb.nombreArchivoDbForzado = 'test_correccion_campo2.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('campo2b_docs');
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
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_correccion_campo2.db$suf'))
            .delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('CAMPO-2 · el diálogo rehecho conserva '
      'campos, validaciones y resultado', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = DateTime.parse(hoyHabanaIso());
    final venceEn30 = hoy
        .add(const Duration(days: 30))
        .toIso8601String()
        .substring(0, 10);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 501, {
        'id': 501,
        'nombre': 'Ada Aragon Herrera',
        'telefono': '58112233',
        'carnet': '950312',
        'sexo': 'F',
        'estado': 'activo',
        'pagado_hasta': venceEn30,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
    });
    final sesion = jsonEncode({
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-x',
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
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const FichaScreen(clienteId: 501),
    ));
    await _drenar(tester);
    await tester.tap(find.text('Editar'));
    await _drenar(tester, vueltas: 8, ms: 60);
    expect(find.byType(DialogoApp), findsOneWidget);
    expect(find.text('Editar cliente'), findsOneWidget);

    final dialogo = find.byType(DialogoApp);
    Finder campo(int i) => find
        .descendant(of: dialogo, matching: find.byType(TextField))
        .at(i);
    // Los valores iniciales, los de siempre.
    expect(tester.widget<TextField>(campo(0)).controller!.text,
        'Ada Aragon Herrera');
    expect(tester.widget<TextField>(campo(1)).controller!.text,
        '58112233');
    expect(tester.widget<TextField>(campo(2)).controller!.text,
        '950312');
    // El sexo nace en Femenino (chip seleccionado).
    final chipF = tester.widget<ChoiceChip>(find.descendant(
        of: dialogo, matching: find.widgetWithText(ChoiceChip, 'Femenino')));
    expect(chipF.selected, isTrue);
    final chipM = tester.widget<ChoiceChip>(find.descendant(
        of: dialogo, matching: find.widgetWithText(ChoiceChip, 'Masculino')));
    expect(chipM.selected, isFalse);

    // El teléfono ya no es más estrecho que el nombre…
    final anchoNombre = tester.getSize(campo(0)).width;
    final anchoTelefono = tester.getSize(campo(1)).width;
    expect(anchoTelefono, anchoNombre,
        reason: 'CAMPO-2: el teléfono ocupa el ancho '
            'completo, como los demás campos');
    // …y el botón de contactos vive DENTRO de su rectángulo.
    final rectTelefono = tester.getRect(campo(1));
    final botonContactos = find.descendant(
        of: dialogo,
        matching: find.byWidgetPredicate((w) =>
            w is IconButton &&
            w.tooltip == 'Elegir de contactos'));
    expect(botonContactos, findsOneWidget);
    final rectBoton = tester.getRect(botonContactos);
    expect(rectTelefono.contains(rectBoton.center), isTrue,
        reason: 'CAMPO-2: «Elegir de contactos» es una '
            'acción del campo, no un icono flotante fuera');

    // El aviso de fecha imposible sigue vivo y no bloquea.
    await tester.enterText(campo(2), '122303');
    await tester.pump();
    expect(
        find.descendant(
            of: dialogo,
            matching: find.textContaining('Esa fecha no existe')),
        findsOneWidget,
        reason: 'el AvisoFechaCarnet sigue apareciendo en '
            'el momento, como manda la regla del carnet');
    await tester.enterText(campo(2), '950313');
    await tester.pump();
    expect(
        find.descendant(
            of: dialogo,
            matching: find.textContaining('Esa fecha no existe')),
        findsNothing);

    // Editar y guardar: el resultado es el de siempre.
    await tester.enterText(campo(0), 'Ada Nueva Herrera');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Masculino'));
    await tester.pump();
    await tester.tap(find.text('Guardar'));
    await _drenar(tester, vueltas: 8, ms: 60);
    expect(find.byType(DialogoApp), findsNothing,
        reason: 'el diálogo se cierra al guardar');
    expect(find.text('Cambios guardados (se sincronizarán)'),
        findsOneWidget);
    await tester.runAsync(() async {
      final espejo = await LocalDb.instance.allMirror('clientes');
      final fila = espejo.singleWhere((c) => c['id'] == 501);
      expect(fila['nombre'], 'Ada Nueva Herrera');
      expect(fila['telefono'], '58112233');
      expect(fila['carnet'], '950313');
      expect(fila['sexo'], 'M');
      final d = await LocalDb.instance.db;
      final ops = await d.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['editar_cliente']);
      expect(ops, hasLength(1));
      final payload =
          jsonDecode(ops.first['payload'] as String) as Map;
      expect(payload['nombre'], 'Ada Nueva Herrera');
      expect(payload['telefono'], '58112233');
      expect(payload['carnet'], '950313');
      expect(payload['sexo'], 'M');
    });
    expect(tester.takeException(), isNull,
        reason: 'a 360 dp el diálogo rehecho no desborda');
    // Cierre limpio del arnés: guardar disparó el push y
    // la corrida lleva un latido (Timer.periodic) que se
    // cancela al terminar; se le da tiempo real y de
    // reloj hasta que el motor vuelve a reposo para no
    // dejar temporizadores pendientes al desmontar.
    for (var i = 0; i < 40; i++) {
      if (SyncEngine.instance.currentStatus.phase ==
          SyncPhase.idle) {
        break;
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(
            const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(seconds: 2));
    }
  });
}
