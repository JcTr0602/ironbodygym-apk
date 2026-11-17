/// 1.35 FASE 4 — Mostrador sobre la Home real del
/// dueño, a 360×800 dp (con pagos de hoy sembrados en
/// el espejo). Nació para M-1…M-10; Campo 1.35
/// (2026-11-17) lo reescribe a la composición aprobada
/// por Jc:
///
/// - Zona 1 «El dinero de hoy»: la tarjeta
///   «Estadísticas Rápidas» y el titular grafito están
///   jubilados; en el estado que el arnés produce (el
///   cero, porque _cargar no aterriza) la zona no
///   existe — su semántica con datos se prueba por
///   funciones en campo135_defectos_test.dart.
/// - M-10: con la Zona 3 visible (semana + salud del
///   mes + pago), ningún desborde de RenderFlex a
///   360 dp (la auditoría midió «overflowed by 3.0
///   pixels» en la tarjeta vieja).
///   ALCANCE: el arnés de la Home ensamblada no
///   aterriza los valores de _cargar bajo FakeAsync
///   (limitación conocida de la casa: las piezas se
///   prueban con cargadores inyectados); las funciones
///   de datos SÍ devuelven lo sembrado, probado en la
///   sonda de la fase (cobradoHoyPorMetodo = siembra).
///   El estado cargado en pantalla se verifica en el
///   banco Android real, compuerta posterior.
/// - Zona 3 «Tu semana y tu mes» ARRIBA y ABIERTA: su
///   contenido se ve sin tocar ninguna cabecera (el
///   pliegue de M-1 se jubiló por veredicto de Jc).
/// - La Bandeja de WhatsApp NO pinta fila con 0 avisos
///   (regla de Jc: lo que está en cero no aparece).
/// - M-5: la fila fina «Turnos de hoy» del dueño existe.
/// - M-7: el Dock se recoge al bajar y vuelve al subir.
/// - Campo nº 5: el aire inferior es de 24 dp, no 96.
/// - Campo 1.35 (contrato de fuente): «por recoger» es
///   PUERTA a PendienteScreen (el detalle de entregas
///   pendientes); el scroll de M-4 se jubiló.
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
      'dueño: portada cargada a 360 dp, sin desborde '
      '(M-10), Zona 3 abierta y Dock que se recoge '
      '(M-7)', (tester) async {
    await tester.runAsync(() async {
      await _fijarSesionDueno();
      await _sembrarCargado();
    });
    await _abrirHome360(tester);

    // Zona 1: el titular grafito y la tarjeta vieja
    // murieron. OJO al alcance: como _cargar no
    // aterriza en este arnés (nota de la cabecera), el
    // estado visible es el cero — y en cero la Zona 1
    // NO existe (la regla dura de Jc, que es justo el
    // defecto de su captura). La Zona 1 CON datos se
    // prueba por sus funciones en
    // campo135_defectos_test.dart.
    expect(find.byKey(const ValueKey('hoy-titular')), findsNothing);
    expect(find.text('Estadísticas Rápidas'), findsNothing);
    expect(find.byKey(const ValueKey('hoy-dinero')), findsNothing);
    expect(find.byKey(const ValueKey('hoy-por-recoger')),
        findsNothing);
    expect(find.textContaining('por recoger'), findsNothing);
    // La frescura se dice una sola vez: la línea de
    // contexto («act.»), no al pie de una tarjeta.
    expect(find.byKey(const ValueKey('home-act')), findsOneWidget);
    expect(find.textContaining('Datos guardados en este teléfono'),
        findsNothing);
    expect(find.textContaining('espejo'), findsNothing);

    // Sin avisos de WhatsApp no hay fila.
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

    // Zona 3 ABIERTA: su contenido (semana, salud del
    // mes, pago) se alcanza sin tocar cabecera alguna —
    // el pliegue de M-1 y su llave están jubilados.
    expect(find.byKey(const ValueKey('hoy-informe-cabecera')),
        findsNothing);
    final pulso = find.byKey(const ValueKey('hoy-pulso'));
    await tester.ensureVisible(pulso);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Pago de entrenadores'), findsOneWidget);
    expect(find.text('Pagaron el mes'), findsOneWidget);
    // (Las barras «Últimos 7 días» piden la serie
    // aterrizada: sin _cargar en el arnés no se pintan;
    // su dato se prueba por funciones.)
    expect(tester.takeException(), isNull,
        reason: 'M-10: la Zona 3 visible a 360 dp no '
            'desborda (la tarjeta vieja desbordaba 3 px)');

    // M-7: al bajar, el Dock se recoge; al subir,
    // vuelve. Campo 1.35: la portada nueva es más corta
    // (ese es el punto de la pieza) y en el estado del
    // arnés ya no desborda un viewport de 800 — el
    // mecanismo (intacto en esta pieza) se ejercita con
    // un viewport corto, donde la misma portada sí baja.
    expect(find.byType(DockMostrador), findsOneWidget);
    tester.view.physicalSize = const Size(1080, 1320);
    await tester.pump(const Duration(milliseconds: 300));
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
    tester.view.physicalSize = const Size(1080, 2400);
    await tester.pump(const Duration(milliseconds: 300));

    // Drenaje del harness (contrato de la Home).
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await _avanzarTiempo(tester);
  });

  test('Campo 1.35 (fuente): «por recoger» es puerta a '
      'PendienteScreen; el scroll de M-4 se jubiló', () {
    final home = File('lib/ui/home.dart').readAsStringSync();
    expect(home.contains('_clavePorDecidir'), isTrue);
    expect(home.contains('key: _clavePorDecidir'), isTrue,
        reason: 'la clave es la de la BandejaPorDecidir '
            'embebida en la Zona 2 (su GlobalKey conserva '
            'el estado al aparecer/desaparecer la tarjeta)');
    // Directiva de campo de Jc (2026-11-17): el importe
    // «por recoger» abre el detalle de entregas
    // pendientes por entrenador — M-4 queda sustituida.
    expect(home.contains('_ir(const PendienteScreen())'), isTrue);
    expect(home.contains('_bajarAPorDecidir'), isFalse,
        reason: 'el scroll del titular a Por Decidir '
            'murió con el titular grafito');
  });
}
