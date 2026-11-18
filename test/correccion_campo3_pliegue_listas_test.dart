/// 1.35 (CAMPO-3, corrección de la reconciliación §3.3):
/// la pila propia de Vencimientos (ListasScreen) se
/// pliega al bajar, como manda el campo nº 3.
///
/// Guion a 360×800, pantalla embebida (su forma en el
/// pilar de Clientes) y la pestaña de cobro «Atrasados
/// -30d» con 15 clientes:
/// - al abrir, la pila está entera: sub-pestañas,
///   buscador y fila de vistas («Guardar vista»), y el
///   botón «Avisar a los 15 sin avisar» sobre la lista;
/// - al bajar por la lista, la pila se recoge a cero Y
///   el botón se recoge con ella: la primera fila sube
///   lo que la pila medía;
/// - al subir de vuelta, todo reaparece y queda
///   alcanzable (ningún bloque se elimina).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/listas.dart';
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
    LocalDb.nombreArchivoDbForzado = 'test_correccion_campo3.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('campo3_docs');
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
        await File(p.join(dir, 'test_correccion_campo3.db$suf'))
            .delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('CAMPO-3 · la pila de Vencimientos se '
      'recoge al bajar y vuelve al subir', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = DateTime.parse(hoyHabanaIso());
    final vencioHace10 = hoy
        .subtract(const Duration(days: 10))
        .toIso8601String()
        .substring(0, 10);
    await tester.runAsync(() async {
      for (var i = 1; i <= 15; i++) {
        await LocalDb.instance.upsertMirror('clientes', 600 + i, {
          'id': 600 + i,
          'nombre':
              'Cliente Cobro ${i.toString().padLeft(2, '0')}',
          'telefono': '540000${i.toString().padLeft(2, '0')}',
          'estado': 'activo',
          'pagado_hasta': vencioHace10,
          'fecha_inscripcion': '2026-01-01',
        }, 20 + i);
      }
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
      home: const ListasScreen(inicial: 2, embebida: true),
    ));
    await _drenar(tester);

    // La pila entera, desplegada.
    expect(find.byType(TabBar), findsOneWidget,
        reason: 'las sub-pestañas están al abrir');
    // 1.36 (136-261): el hint declara que también busca
    // por teléfono (antes: «Buscar cliente…»).
    expect(find.text('Buscar cliente o teléfono…'), findsOneWidget);
    expect(find.text('Guardar vista'), findsOneWidget,
        reason: 'la fila de vistas está al abrir');
    final botonAvisar =
        find.textContaining('Avisar a los 15 sin avisar');
    expect(botonAvisar, findsOneWidget,
        reason: 'el botón de la pasada de avisos está '
            'sobre la lista al abrir');
    final fila1 = find.text('Cliente Cobro 01');
    expect(fila1, findsOneWidget);
    // La medida es el borde superior de la lista: al
    // plegarse la pila, la lista crece hacia arriba lo
    // que la pila medía (la fila 01 no sirve de testigo:
    // al desplazar, la lista la recicla fuera del árbol).
    final yAntes = tester.getTopLeft(find.byType(ListView)).dy;

    // Bajar por la lista: la pila se recoge.
    await tester.drag(fila1, const Offset(0, -500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _drenar(tester, vueltas: 4, ms: 50);
    expect(find.byType(TabBar), findsNothing,
        reason: 'CAMPO-3: al bajar, las sub-pestañas se '
            'recogen');
    expect(find.text('Guardar vista'), findsNothing,
        reason: 'CAMPO-3: la fila de vistas se recoge');
    expect(find.text('Buscar cliente o teléfono…'), findsNothing,
        reason: 'CAMPO-3: el buscador se recoge');
    expect(botonAvisar, findsNothing,
        reason: 'CAMPO-3: el botón de avisar se recoge '
            'con la pila');
    final yDespues = tester.getTopLeft(find.byType(ListView)).dy;
    expect(yAntes - yDespues, greaterThan(100),
        reason: 'la lista gana el alto de la pila '
            '(su borde superior sube más de 100 dp)');

    // Subir de vuelta: todo reaparece y queda alcanzable.
    await tester.drag(find.byType(ListView).first,
        const Offset(0, 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.drag(find.byType(ListView).first,
        const Offset(0, 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _drenar(tester, vueltas: 4, ms: 50);
    expect(find.byType(TabBar), findsOneWidget,
        reason: 'al subir, las sub-pestañas vuelven');
    expect(find.text('Guardar vista'), findsOneWidget);
    expect(find.text('Buscar cliente o teléfono…'), findsOneWidget);
    expect(botonAvisar, findsOneWidget,
        reason: 'el botón de avisar vuelve con la pila');
    expect(tester.takeException(), isNull);
    // Cierre limpio del arnés: (1) el motor de sync
    // corre en esta pantalla (emisión ligera de fotos) y
    // su corrida lleva temporizadores que se cancelan al
    // terminar — se espera a que vuelva a reposo; (2) las
    // filas que re-entran al desplegarse la pila arrancan
    // el temporizador de su cascada de entrada
    // (EntradaCascada) — se le deja morir en tiempo de
    // reloj. Sin temporizadores pendientes al desmontar.
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
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  });
}
