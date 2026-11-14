/// 1.34 · G-1 (campo de Jc, 2026-11-13): el diálogo «Foto
/// del cliente» de la ficha se APILABA. `_cambiarFoto()` no
/// tenía guarda de reentrada y su espera previa
/// (`_tieneFoto()`, lectura de BD) no daba ninguna señal:
/// tras la primera subida esa lectura tarda (la cola de
/// fotos y la sync escriben la misma BD desde dos
/// isolates), el usuario tocaba de nuevo y cada toque
/// abría otra copia idéntica del diálogo — las opciones
/// «no respondían» porque cada toque solo cerraba la
/// copia superior.
///
/// Costura sobre la ficha ENSAMBLADA (FichaScreen real,
/// espejo real, sesión de dueño, viewport 420×800):
///   A · doble toque rápido ⇒ UN solo diálogo (en la base
///       salen dos apilados) y las tres opciones presentes;
///   B · señal de apertura: con el flujo en curso el botón
///       de la cabecera se pinta DESHABILITADO (en la base
///       queda habilitado, mudo) y se rehabilita al cerrar;
///   C · continuación de las opciones: «Eliminar foto»
///       confirma y encola la op (y al reabrir ya no se
///       ofrece eliminar); «Elegir de la galería» cierra
///       con el aviso del helper cuando el selector no
///       está (en test no hay plugin: el flujo termina en
///       el null anunciado, sin diálogo colgado);
///   D · la guarda global de foto_elegir se puede LEER
///       (elegirFotoEnCurso): tomada mientras un flujo
///       vive y libre al volver de él — el discriminador
///       con el que la ficha distingue el null de la
///       guarda del null de cancelación. En la base el
///       getter no existe (el archivo no compila).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';
import 'package:ironbody_gym/ui/foto_elegir.dart';
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

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_g1_foto.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// Cliente 501 CON foto en el servidor (foto_storage no
/// vacío): `_tieneFoto()` lo deriva del espejo y el
/// diálogo ofrece las tres opciones.
Future<void> _sembrar(WidgetTester tester) async {
  final hoy = DateTime.parse(hoyHabanaIso());
  final dentro20 =
      hoy.add(const Duration(days: 20)).toIso8601String().substring(0, 10);
  await tester.runAsync(() async {
    await LocalDb.instance.upsertMirror('clientes', 501, {
      'id': 501,
      'nombre': 'Elianis Gandara',
      'telefono': '58112233',
      'estado': 'activo',
      'pagado_hasta': dentro20,
      'fecha_inscripcion': '2026-01-01',
      'foto_storage': 'clientes/501/semilla_original.jpg',
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
  expect(find.byType(FichaScreen), findsOneWidget);
}

/// El botón de foto de la cabecera (el único TextButton
/// de CabeceraFicha).
Finder get _botonFoto => find.descendant(
    of: find.byType(CabeceraFicha), matching: find.byType(TextButton));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Roboto REAL del SDK (mismo arnés que la Fase 1).
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
    LocalDb.nombreArchivoDbForzado = 'test_g1_foto.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('g1_docs');
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
    await _bdVacia();
  });

  testWidgets('G-1 A · doble toque sobre la foto: UN solo '
      'diálogo, con sus tres opciones', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sembrar(tester);
    expect(_botonFoto, findsOneWidget);

    // Dos toques SIN drenar entre ellos: la primera
    // invocación queda esperando su lectura de BD (la
    // espera invisible del fallo de campo) cuando el
    // segundo toque llega.
    await tester.tap(_botonFoto);
    await tester.tap(_botonFoto, warnIfMissed: false);
    await _drenar(tester);

    expect(find.byType(DialogoApp), findsOneWidget,
        reason: 'G-1: un toque = un diálogo; el segundo '
            'toque no puede apilar una copia gemela');
    expect(find.text('Foto del cliente'), findsOneWidget);
    expect(find.text('Tomar foto'), findsOneWidget);
    expect(find.text('Elegir de la galería'), findsOneWidget);
    expect(find.text('Eliminar foto'), findsOneWidget,
        reason: 'con foto en el espejo, la tercera opción '
            'existe');
    // Cerrar por la barrera: si el segundo toque apiló
    // un diálogo gemelo (el fallo de campo), debajo
    // quedaría OTRO «Foto del cliente» abierto.
    await tester.tapAt(const Offset(20, 20));
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.byType(DialogoApp), findsNothing,
        reason: 'G-1: cerrado el único diálogo no queda '
            'un gemelo apilado debajo');
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('G-1 A2 · segunda invocación con el flujo '
      'en curso: la guarda la bloquea', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sembrar(tester);

    await tester.tap(_botonFoto);
    await tester.pump();
    // El primer flujo está en curso (espera invisible) y
    // llega la segunda activación del botón — el doble
    // toque de campo, reproducido sin depender de la
    // geometría del toque: si el botón sigue vivo, su
    // onPressed se invoca; con la guarda, esa segunda
    // invocación muere en la puerta.
    tester.widget<TextButton>(_botonFoto).onPressed?.call();
    await _drenar(tester);

    expect(find.byType(DialogoApp), findsOneWidget,
        reason: 'G-1: dos invocaciones concurrentes = un '
            'solo diálogo');
    await tester.tapAt(const Offset(20, 20));
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.byType(DialogoApp), findsNothing,
        reason: 'sin gemelo apilado debajo');
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('G-1 B · señal de apertura: el botón se '
      'deshabilita con el flujo en curso y revive al '
      'cerrar', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sembrar(tester);
    expect(tester.widget<TextButton>(_botonFoto).onPressed, isNotNull);

    await tester.tap(_botonFoto);
    await tester.pump();
    expect(tester.widget<TextButton>(_botonFoto).onPressed, isNull,
        reason: 'G-1: durante la espera de apertura el '
            'botón se pinta deshabilitado — el usuario VE '
            'que su toque entró');

    await _drenar(tester);
    expect(find.byType(DialogoApp), findsOneWidget);
    // Cierre por la barrera: la guarda se suelta y el
    // botón revive.
    await tester.tapAt(const Offset(20, 20));
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.byType(DialogoApp), findsNothing);
    expect(tester.widget<TextButton>(_botonFoto).onPressed, isNotNull,
        reason: 'al terminar el flujo la guarda se suelta');
    // Drenar temporizadores (bitácora/flush) antes de
    // cerrar: el arnés exige cero timers pendientes.
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('G-1 C · las opciones continúan: eliminar '
      'encola la op una vez; galería cierra sin diálogo '
      'colgado', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sembrar(tester);

    await tester.tap(_botonFoto);
    await _drenar(tester);
    expect(find.byType(DialogoApp), findsOneWidget);

    // «Eliminar foto» → confirmación → «Eliminar».
    await tester.tap(find.text('Eliminar foto'));
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.widgetWithText(ElevatedButton, 'Eliminar'),
        findsOneWidget,
        reason: 'la confirmación de eliminar se abre');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Eliminar'));
    await _drenar(tester);
    expect(find.byType(DialogoApp), findsNothing,
        reason: 'tras confirmar, ningún diálogo queda '
            'abierto ni apilado');
    var ops = <Map<String, Object?>>[];
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      ops = await db.query('ops_queue',
          columns: ['tipo', 'payload'],
          where: 'tipo = ?',
          whereArgs: ['eliminar_foto']);
    });
    expect(ops.length, 1,
        reason: 'la op eliminar_foto quedó encolada una '
            'sola vez');
    final payload =
        jsonDecode(ops.single['payload'] as String) as Map<String, dynamic>;
    expect(payload['cliente_id'], 501);

    // Reabrir: la guarda ya se soltó y el diálogo vuelve
    // a abrir con sus opciones (continuación del flujo).
    // NOTA de entorno: en este arnés el push de
    // SyncEngine consume la op durante los drenajes, así
    // que aquí NO se afirma si «Eliminar foto» se sigue
    // ofreciendo; la semántica de intención (eliminar
    // encolado ⇒ no se ofrece) la fija
    // intencion_foto_test.dart contra la cola quieta.
    await tester.tap(_botonFoto);
    await _drenar(tester);
    expect(find.byType(DialogoApp), findsOneWidget);
    expect(find.text('Elegir de la galería'), findsOneWidget);

    // Galería sin plugin (test): el helper devuelve su
    // null ANUNCIADO y la ficha sigue viva, sin diálogo.
    await tester.tap(find.text('Elegir de la galería'));
    await _drenar(tester);
    expect(find.byType(DialogoApp), findsNothing);
    expect(find.textContaining('No se pudo abrir la foto'),
        findsOneWidget,
        reason: 'el fallo del selector se anuncia, no se '
            'traga en silencio');
    expect(find.byType(FichaScreen), findsOneWidget);
    // Vaciado final paciente: el push que dispara el
    // eliminar programa temporizadores reales del motor
    // (sondeo de internet de 5 s) que nacen tarde; se da
    // una vuelta real para que nazcan en el reloj falso
    // y dos vueltas falsas para que expiren.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('G-1 D · la guarda global de foto_elegir '
      'se puede leer mientras un flujo vive', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const Scaffold(body: SizedBox.shrink()),
    ));
    final ctx = tester.element(find.byType(Scaffold));
    expect(elegirFotoEnCurso, isFalse);

    final bloqueo = Completer<XFile?>();
    var llamadasSelector = 0;
    final primera = elegirFotoEditada(
      ctx,
      ImageSource.gallery,
      selector: (_) {
        llamadasSelector++;
        return bloqueo.future;
      },
      recuperador: () async => LostDataResponse.empty(),
    );
    // El flujo queda vivo dentro del selector: la guarda
    // está tomada y se puede LEER.
    await tester.pump();
    expect(elegirFotoEnCurso, isTrue,
        reason: 'con un flujo en curso, la guarda se lee '
            'tomada');

    // Segunda petición con la guarda tomada: null al
    // instante, sin tocar el selector, y la guarda SIGUE
    // tomada al volver (el discriminador de la ficha).
    final segunda = await elegirFotoEditada(
      ctx,
      ImageSource.camera,
      selector: (_) async {
        llamadasSelector++;
        return null;
      },
      recuperador: () async => LostDataResponse.empty(),
    );
    expect(segunda, isNull);
    expect(llamadasSelector, 1,
        reason: 'la segunda petición ni siquiera llega '
            'al selector');
    expect(elegirFotoEnCurso, isTrue,
        reason: 'el null de la guarda se distingue del '
            'de cancelación: la guarda sigue tomada');

    // La primera se cancela (null del selector): al
    // volver, la guarda viene libre.
    bloqueo.complete(null);
    expect(await primera, isNull);
    expect(elegirFotoEnCurso, isFalse);
    // El aviso de la guarda escribe en la bitácora, que
    // programa su volcado con un temporizador de 3 s:
    // se deja correr el reloj falso antes de cerrar.
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}
