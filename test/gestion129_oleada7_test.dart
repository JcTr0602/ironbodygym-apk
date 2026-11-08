/// Gestión 1.29 · Oleada 7 (FB-22: avisos con fecha de fin).
///
/// Contrato que se fija, contra el plan §8 + S-3 + H-03:
/// · La fecha de fin viaja en el documento como fecha civil
///   de La Habana 'AAAA-MM-DD' (fechaFinIsoDe / textoFechaFin
///   por componentes, sin conversión de zona que corra el día).
/// · AvisoCliente.fromJson lee fecha_fin (ausente o vacía =
///   sin fecha, el comportamiento de siempre).
/// · etiquetaFechaFin: el editor sigue enseñando el aviso
///   vencido, dicho en pasado (el servidor ya no lo entrega).
/// · El guardado verificado (D-B3-05) compara TAMBIÉN la
///   fecha: un guardado que aterriza sin la fecha pedida NO
///   cuenta como reflejado (no se le miente al dueño con un
///   «caducará» falso).
/// · El formulario ofrece «Dejarse de mostrar el [fecha]»,
///   pre-llena la fecha al editar, permite quitarla y manda
///   'AAAA-MM-DD' (o null) a la RPC.
/// La pieza de servidor (firma única con default, filtro de
/// avisos_delta, batería del corte Habana) se verificó en
/// vivo con la simulación por roles de
/// cola-123/gestion/oleada7/03_simulacion.sql (22 aserciones).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/editor_avisos_clientes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés común (la pauta de las oleadas 4/5/6) ────────

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e7',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e7',
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

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Superficie de teléfono real (el formulario de aviso,
/// con la fila de fecha, no cabe entero en 800×600).
void _superficieTelefono(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  // ── FB-22 · los puros de la fecha ────────────────────
  group('FB-22 · fechaFinIsoDe / textoFechaFin (puros)', () {
    test('el día elegido se serializa AAAA-MM-DD con ceros',
        () {
      expect(fechaFinIsoDe(DateTime(2026, 3, 5)), '2026-03-05');
      expect(fechaFinIsoDe(DateTime(2026, 11, 10)), '2026-11-10');
      expect(fechaFinIsoDe(DateTime(2027, 1, 1)), '2027-01-01');
    });

    test('textoFechaFin lee la fecha civil tal cual '
        '(sin correr el día por zona)', () {
      expect(textoFechaFin('2026-11-10'), '10/11/2026');
      expect(textoFechaFin('2026-03-05'), '5/3/2026');
      expect(textoFechaFin('no-es-fecha'), 'no-es-fecha',
          reason: 'valor ilegible: se devuelve el texto, '
              'no se inventa una fecha');
    });

    test('ida y vuelta: día → ISO → texto', () {
      final iso = fechaFinIsoDe(DateTime(2026, 12, 24));
      expect(iso, '2026-12-24');
      expect(textoFechaFin(iso), '24/12/2026');
    });
  });

  group('FB-22 · etiquetaFechaFin', () {
    test('futura y de hoy se anuncian; pasada, en pasado',
        () {
      expect(etiquetaFechaFin('2026-11-10', hoyIso: '2026-11-08'),
          'Se deja de mostrar el 10/11/2026');
      expect(etiquetaFechaFin('2026-11-08', hoyIso: '2026-11-08'),
          'Se deja de mostrar el 8/11/2026',
          reason: 'hoy se sigue mostrando todo el día');
      expect(etiquetaFechaFin('2026-11-07', hoyIso: '2026-11-08'),
          'Dejó de mostrarse el 7/11/2026');
    });
  });

  group('FB-22 · AvisoCliente.fromJson', () {
    test('lee fecha_fin; ausente o vacía = sin fecha', () {
      final con = AvisoCliente.fromJson(const {
        'id': 5,
        'titulo': 'T',
        'cuerpo': 'C',
        'nivel': 'info',
        'creado_ts': '2026-11-08T09:00:00',
        'fecha_fin': '2026-12-24',
      });
      expect(con.fechaFin, '2026-12-24');
      final sin = AvisoCliente.fromJson(const {
        'id': 6,
        'titulo': 'T',
        'cuerpo': 'C',
        'nivel': 'info',
        'creado_ts': '2026-11-08T09:00:00',
      });
      expect(sin.fechaFin, isNull,
          reason: 'los avisos de antes de FB-22 no traen '
              'la clave: sin fecha, como siempre');
      final vacia = AvisoCliente.fromJson(const {
        'id': 7,
        'titulo': 'T',
        'cuerpo': 'C',
        'nivel': 'info',
        'fecha_fin': '',
      });
      expect(vacia.fechaFin, isNull);
    });
  });

  // ── FB-22 · el guardado verificado compara la fecha ──
  group('FB-22 · guardarAvisoVerificado con fecha', () {
    AvisoCliente aviso(int id, {String? fechaFin}) => AvisoCliente(
        id: id,
        titulo: 'T',
        cuerpo: 'C',
        nivel: 'info',
        creadoTs: '',
        fechaFin: fechaFin);

    test('edición que aterriza SIN la fecha pedida NO '
        'cuenta como guardada', () async {
      final r = await guardarAvisoVerificado(
        guardar: () async => throw TimeoutException('tarde'),
        listar: () async => [aviso(3)], // aterrizó sin fecha
        idsPrevios: const {3},
        idEditado: 3,
        titulo: 'T',
        cuerpo: 'C',
        nivel: 'info',
        fechaFin: '2026-12-24',
      );
      expect(r, ResultadoGuardadoAviso.noGuardado,
          reason: 'creer que caducará sin que la fecha '
              'aterrizara sería mentirle al dueño');
    });

    test('edición que aterriza CON la fecha pedida = '
        'guardada', () async {
      final r = await guardarAvisoVerificado(
        guardar: () async => throw TimeoutException('tarde'),
        listar: () async => [aviso(3, fechaFin: '2026-12-24')],
        idsPrevios: const {3},
        idEditado: 3,
        titulo: 'T',
        cuerpo: 'C',
        nivel: 'info',
        fechaFin: '2026-12-24',
      );
      expect(r, ResultadoGuardadoAviso.guardado);
    });

    test('creación: el gemelo viejo sin fecha no es '
        'prueba; el nuevo con fecha sí', () async {
      final r = await guardarAvisoVerificado(
        guardar: () async => throw TimeoutException('tarde'),
        listar: () async =>
            [aviso(1), aviso(9, fechaFin: '2026-12-24')],
        idsPrevios: const {1},
        idEditado: null,
        titulo: 'T',
        cuerpo: 'C',
        nivel: 'info',
        fechaFin: '2026-12-24',
      );
      expect(r, ResultadoGuardadoAviso.guardado);
    });
  });

  // ── FB-22 · la pantalla: elegir, pre-llenar, quitar ──
  group('FB-22 · la pantalla de avisos', () {
    testWidgets('publicar eligiendo fecha: la RPC recibe '
        'AAAA-MM-DD y la lista anuncia el fin', (tester) async {
      final servidor = <AvisoCliente>[];
      String? fechaRecibida;
      Future<void> guardarFalso(
          {int? id,
          required String titulo,
          required String cuerpo,
          required String nivel,
          String? fechaFin}) async {
        fechaRecibida = fechaFin;
        servidor.add(AvisoCliente(
            id: 99,
            titulo: titulo,
            cuerpo: cuerpo,
            nivel: nivel,
            creadoTs: '2026-11-08T09:00:00',
            fechaFin: fechaFin));
      }

      Future<List<AvisoCliente>> listarFalso() async =>
          List.of(servidor);

      _superficieTelefono(tester);
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: EditorAvisosClientesScreen(
              guardarAvisoRpc: guardarFalso,
              listarAvisosRpc: listarFalso)));
      await _pumps(tester, 16);

      await tester.tap(find.text('Nuevo aviso'));
      await _pumps(tester, 10);
      expect(find.text('Elegir fecha'), findsOneWidget);
      expect(
          find.textContaining('Sin fecha de fin'), findsOneWidget);

      await tester.enterText(
          find.byType(TextField).first, 'Horario especial');
      await tester.enterText(
          find.byType(TextField).at(1), 'El viernes abrimos '
              'hasta las 12.');
      await tester.tap(find.text('Elegir fecha'));
      await _pumps(tester, 10);
      // El selector abre en el mes en curso y no ofrece
      // días pasados: el día 28 siempre es elegible.
      final selector = find.byType(DatePickerDialog);
      expect(selector, findsOneWidget);
      await tester.tap(find.descendant(
          of: selector, matching: find.text('28')));
      await _pumps(tester, 6);
      await tester.tap(find.text('OK'));
      await _pumps(tester, 10);
      expect(
          find.textContaining('se muestra durante todo ese día'),
          findsOneWidget,
          reason: 'el formulario enseña la fecha elegida '
              'con su explicación');

      await tester.tap(find.text('Publicar aviso'));
      await _pumps(tester, 20);

      expect(fechaRecibida, isNotNull);
      expect(fechaRecibida, matches(r'^\d{4}-\d{2}-28$'),
          reason: 'viaja como fecha civil AAAA-MM-DD');
      // De vuelta en la lista, la tarjeta anuncia el fin.
      expect(find.text('Horario especial'), findsOneWidget);
      expect(find.textContaining('Se deja de mostrar el'),
          findsOneWidget);
    });

    testWidgets('editar pre-llena la fecha; quitarla la '
        'manda en null', (tester) async {
      final servidor = <AvisoCliente>[
        const AvisoCliente(
            id: 7,
            titulo: 'Aviso con fin',
            cuerpo: 'Cuerpo',
            nivel: 'info',
            creadoTs: '2026-11-01T09:00:00',
            fechaFin: '2027-06-24'),
      ];
      String? fechaRecibida = 'sin-llamar';
      Future<void> guardarFalso(
          {int? id,
          required String titulo,
          required String cuerpo,
          required String nivel,
          String? fechaFin}) async {
        fechaRecibida = fechaFin;
        servidor[0] = AvisoCliente(
            id: 7,
            titulo: titulo,
            cuerpo: cuerpo,
            nivel: nivel,
            creadoTs: '2026-11-01T09:00:00',
            fechaFin: fechaFin);
      }

      Future<List<AvisoCliente>> listarFalso() async =>
          List.of(servidor);

      _superficieTelefono(tester);
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: EditorAvisosClientesScreen(
              guardarAvisoRpc: guardarFalso,
              listarAvisosRpc: listarFalso)));
      await _pumps(tester, 16);

      // La tarjeta de la lista anuncia el fin futuro.
      expect(find.text('Se deja de mostrar el 24/6/2027'),
          findsOneWidget);

      await tester.tap(find.text('Aviso con fin'));
      await _pumps(tester, 10);
      expect(find.textContaining('24/6/2027'), findsWidgets,
          reason: 'el formulario pre-llena la fecha guardada');
      expect(find.text('Quitar'), findsOneWidget);

      await tester.tap(find.text('Quitar'));
      await _pumps(tester, 6);
      expect(
          find.textContaining('Sin fecha de fin'), findsOneWidget);

      await tester.tap(find.text('Guardar cambios'));
      await _pumps(tester, 20);
      expect(fechaRecibida, isNull,
          reason: 'quitar la fecha = guardar sin fecha '
              '(vuelve a retirarse a mano)');
    });
  });
}
