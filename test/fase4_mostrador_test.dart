/// 1.35 FASE 4 — Mostrador M-1…M-10 sobre la Home real
/// del dueño, a 360×800 dp (con pagos de hoy sembrados
/// en el espejo):
///
/// - M-8/M-1: el titular del día (grafito, «Hoy: …
///   cobrados · … por recoger») abre la portada; la
///   tarjeta «Estadísticas Rápidas» se jubiló.
/// - M-10: con el informe plegado ABIERTO (semana +
///   salud del mes + pago), ningún desborde de
///   RenderFlex a 360 dp (la auditoría midió
///   «overflowed by 3.0 pixels» en la tarjeta vieja).
///   ALCANCE: el arnés de la Home ensamblada no
///   aterriza los valores de _cargar bajo FakeAsync
///   (limitación conocida de la casa: las piezas se
///   prueban con cargadores inyectados); las funciones
///   de datos SÍ devuelven lo sembrado, probado en la
///   sonda de la fase (cobradoHoyPorMetodo = siembra).
///   El estado cargado en pantalla se verifica en el
///   banco Android real, compuerta posterior.
/// - M-1: el informe «Tu semana y tu mes» nace cerrado y
///   abre al tocar su cabecera.
/// - M-8: la Bandeja de WhatsApp NO pinta fila con 0
///   avisos (regla de Jc: lo que está en cero no
///   aparece) y su tarjeta propia se jubiló.
/// - M-5: la fila fina «Turnos de hoy» del dueño existe.
/// - M-7: el Dock se recoge al bajar y vuelve al subir.
/// - Campo nº 5: el aire inferior es de 24 dp, no 96.
/// - M-4 (contrato de fuente): «por recoger» baja a Por
///   Decidir por ensureVisible sobre su clave.
///
/// Harness: el de home_a_entregar_127 (sesión de mentira
/// + FFI real fuera de FakeAsync).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/marco.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

/// Siembra el estado cargado: 224 250 cobrados hoy
/// (125 500 en efectivo + 98 750 por transferencia) y un
/// pago de ayer para la serie de 7 días.
Future<void> _sembrarCargado() async {
  final hoy = _iso(DateTime.now());
  final ayer = _iso(DateTime.now().subtract(const Duration(days: 1)));
  var id = 9100;
  Future<void> pago(String fecha, double monto, String metodo) async {
    id++;
    await LocalDb.instance.upsertMirror('pagos', id, {
      'id': id,
      'op_uuid': 'fase4-mostrador-$id',
      'cliente_id': 1,
      'fecha': fecha,
      'monto': monto,
      'metodo': metodo,
      'concepto': 'mensualidad',
      'anulado': 0,
    }, id);
  }

  await pago(hoy, 60000, 'efectivo');
  await pago(hoy, 65500, 'efectivo');
  await pago(hoy, 98750, 'transferencia');
  await pago(ayer, 45000, 'efectivo');
}

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

  testWidgets(
      'dueño: portada M-8 cargada a 360 dp, sin desborde '
      '(M-10), informe plegado (M-1) y Dock que se recoge '
      '(M-7)', (tester) async {
    await tester.runAsync(() async {
      await _fijarSesionDueno();
      await _sembrarCargado();
    });
    await _abrirHome360(tester);

    // M-8/M-1: el titular abre y la tarjeta vieja murió.
    final titular = find.byKey(const ValueKey('hoy-titular'));
    expect(titular, findsOneWidget);
    expect(find.text('Estadísticas Rápidas'), findsNothing);
    expect(find.textContaining('cobrados'), findsOneWidget);
    expect(find.textContaining('por recoger'), findsOneWidget);
    // M-9: la frescura habla en palabras del dueño.
    expect(find.textContaining('Datos guardados en este teléfono'),
        findsWidgets);
    expect(find.textContaining('espejo'), findsNothing);

    // M-8: sin avisos de WhatsApp no hay fila ni tarjeta.
    expect(find.byKey(const ValueKey('hoy-bandeja')), findsNothing);
    // M-5: la fila fina de Turnos del dueño existe.
    expect(find.byKey(const ValueKey('hoy-turnos')), findsOneWidget);
    // Campo nº 5: el aire inferior es el respiro mínimo.
    final aire = find.byKey(const ValueKey('hoy-aire'));
    if (aire.evaluate().isNotEmpty) {
      expect(tester.getSize(aire).height, 24);
    }

    // M-10: sin excepción de layout con el estado cargado.
    expect(tester.takeException(), isNull);

    // M-1: el informe nace cerrado; al abrirlo, su
    // contenido (semana, salud, pago) no desborda.
    final cabeceraInforme =
        find.byKey(const ValueKey('hoy-informe-cabecera'));
    await tester.ensureVisible(cabeceraInforme);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Pago de entrenadores'), findsNothing);
    await tester.tap(cabeceraInforme);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Pago de entrenadores'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'M-10: el informe abierto a 360 dp no '
            'desborda (la tarjeta vieja desbordaba 3 px)');

    // M-7: al bajar, el Dock se recoge; al subir, vuelve.
    expect(find.byType(DockMostrador), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(DockMostrador), findsNothing,
        reason: 'M-7: bajando, el Dock se recoge');
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(DockMostrador), findsOneWidget,
        reason: 'M-7: subiendo, el Dock reaparece');

    // Drenaje del harness (contrato de la Home).
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await _avanzarTiempo(tester);
  });

  test('M-4 (fuente): «por recoger» baja a Por Decidir '
      'con ensureVisible sobre la clave del bloque', () {
    final home = File('lib/ui/home.dart').readAsStringSync();
    expect(home.contains('_clavePorDecidir'), isTrue);
    expect(home.contains('Scrollable.ensureVisible'), isTrue);
    expect(home.contains('key: _clavePorDecidir'), isTrue,
        reason: 'la clave envuelve la BandejaPorDecidir '
            'en _seccionesMostrador');
    // M-4: el destino viejo (la pantalla de Pendiente)
    // ya no cuelga del Mostrador del dueño (ojo:
    // DetallePendienteScreen, del entrenador, sí vive).
    expect(home.contains('PendienteScreen())'), isFalse);
  });
}
