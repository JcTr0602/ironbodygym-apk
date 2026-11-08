/// Gestión 1.30 · Oleada 3 — retirar con la misma red que
/// guardar (ítem 3) + GEN-08 (retirar rutinas del gym).
///
/// Contrato que se fija:
/// · avisoReflejaRetiro: el retiro se refleja cuando el id
///   YA NO está en la lista recién cargada.
/// · retirarAvisoVerificado y ejecutarRetiroVerificado (el
///   motor ÚNICO que comparten avisos y rutinas): si la RPC
///   de retiro falla pero el elemento ya no está en la
///   lista → retirado (sin error falso); si sigue →
///   noRetirado (reintentar es seguro); si ni la
///   comprobación responde → sinConfirmar.
/// · En pantalla (las DOS superficies): el caso «el
///   servidor ya lo retiró pero la red dijo que no»
///   enseña el éxito, no un error; el noRetirado deja el
///   formulario abierto con su error; el sinConfirmar
///   vuelve a la lista con el aviso de revisar antes de
///   repetir.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/editor_avisos_clientes.dart';
import 'package:ironbody_gym/ui/editor_rutinas_gym.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés común (la pauta de las oleadas 1.29) ─────────

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(
    WidgetTester tester, String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {
        'telegram_id': telegramId,
        'provider': 'email'
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _sesionDueno(WidgetTester t) =>
    _fijarSesion(t, 'jc@ironbody.local', 735772141);

Future<Database> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Superficie alta de teléfono (1080×2400), como en D-22:
/// con la de defecto, el botón de retirar del formulario
/// puede quedar fuera del área visible.
void _pantallaAlta(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

AvisoCliente _aviso(int id, [String titulo = 'Aviso de prueba']) =>
    AvisoCliente(
        id: id,
        titulo: titulo,
        cuerpo: 'Cuerpo de prueba',
        nivel: 'info',
        creadoTs: '2026-11-07T10:00:00');

const _press = FichaCatalogo(
  id: 'banco-plano_press-banca-plano',
  titulo: 'Press banca plano',
  slug: 'press-banca-plano',
  equipoNombre: 'Banco plano',
  musculos: ['Pectoral mayor', 'Tríceps'],
  grupo: 'pecho',
  descansoSeg: 120,
);
const _sentadilla = FichaCatalogo(
  id: 'barra-recta_sentadilla',
  titulo: 'Sentadilla con barra',
  slug: 'sentadilla',
  equipoNombre: 'Barra recta',
  musculos: ['Cuádriceps', 'Glúteos'],
  grupo: 'piernas',
  descansoSeg: 180,
);
const _catalogo = [_press, _sentadilla];

RutinaGymAdmin _rutina() => RutinaGymAdmin(
      id: 7,
      nombre: 'Día A',
      fichaIds: [_press.id, _sentadilla.id],
      ejercicios: [
        EjercicioGymAdmin(fichaId: _press.id, series: const [
          SerieGymAdmin(repsMin: 10),
        ]),
        EjercicioGymAdmin(fichaId: _sentadilla.id, series: const [
          SerieGymAdmin(repsMin: 5),
        ]),
      ],
    );

void main() {
  tearDown(() => cargarCatalogoRutinasParaTest = null);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  // ── Puros · el reflejo del retiro ────────────────────
  group('Oleada 3 · avisoReflejaRetiro (puro)', () {
    test('id ausente en la lista recién cargada → reflejado', () {
      expect(
          avisoReflejaRetiro(lista: [_aviso(1), _aviso(3)], id: 5),
          isTrue);
      expect(avisoReflejaRetiro(lista: const [], id: 5), isTrue);
    });

    test('id presente → no reflejado', () {
      expect(
          avisoReflejaRetiro(lista: [_aviso(1), _aviso(5)], id: 5),
          isFalse);
    });
  });

  // ── Puros · retirarAvisoVerificado ───────────────────
  group('Oleada 3 · retirarAvisoVerificado (puro)', () {
    test('la RPC responde → retirado, sin comprobar', () async {
      var comprobaciones = 0;
      final r = await retirarAvisoVerificado(
        retirar: () async {},
        listar: () async {
          comprobaciones++;
          return [_aviso(5)];
        },
        id: 5,
      );
      expect(r, ResultadoRetiroAviso.retirado);
      expect(comprobaciones, 0,
          reason: 'con éxito directo no hace falta la lista');
    });

    test('la red dice que no pero ya no está → retirado '
        '(sin error falso)', () async {
      final r = await retirarAvisoVerificado(
        retirar: () async => throw TimeoutException('tarde'),
        listar: () async => [_aviso(1)],
        id: 5,
      );
      expect(r, ResultadoRetiroAviso.retirado);
    });

    test('falla y sigue en la lista → noRetirado', () async {
      final r = await retirarAvisoVerificado(
        retirar: () async => throw StateError('500'),
        listar: () async => [_aviso(5)],
        id: 5,
      );
      expect(r, ResultadoRetiroAviso.noRetirado);
    });

    test('ni retirar ni comprobar → sinConfirmar', () async {
      final r = await retirarAvisoVerificado(
        retirar: () async => throw TimeoutException('t'),
        listar: () async => throw TimeoutException('t'),
        id: 5,
      );
      expect(r, ResultadoRetiroAviso.sinConfirmar);
    });
  });

  // ── Puros · el motor que reusa rutinas (GEN-08) ──────
  group('Oleada 3 · ejecutarRetiroVerificado (motor común)', () {
    test('la RPC responde → retirado, sin comprobar', () async {
      var comprobaciones = 0;
      final r = await ejecutarRetiroVerificado(
        retirar: () async {},
        sigueEnLaLista: () async {
          comprobaciones++;
          return true;
        },
      );
      expect(r, ResultadoRetiroAviso.retirado);
      expect(comprobaciones, 0);
    });

    test('falla y ya no sigue → retirado', () async {
      final r = await ejecutarRetiroVerificado(
        retirar: () async => throw TimeoutException('tarde'),
        sigueEnLaLista: () async => false,
      );
      expect(r, ResultadoRetiroAviso.retirado);
    });

    test('falla y sigue → noRetirado', () async {
      final r = await ejecutarRetiroVerificado(
        retirar: () async => throw StateError('500'),
        sigueEnLaLista: () async => true,
      );
      expect(r, ResultadoRetiroAviso.noRetirado);
    });

    test('falla y la comprobación también → sinConfirmar',
        () async {
      final r = await ejecutarRetiroVerificado(
        retirar: () async => throw TimeoutException('t'),
        sigueEnLaLista: () async => throw TimeoutException('t'),
      );
      expect(r, ResultadoRetiroAviso.sinConfirmar);
    });
  });

  // ── Pantalla · avisos ────────────────────────────────
  group('Oleada 3 · la pantalla de avisos', () {
    Future<void> montarYAbrir(
      WidgetTester tester, {
      required Future<void> Function(int) retirar,
      required Future<List<AvisoCliente>> Function() listar,
    }) async {
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: EditorAvisosClientesScreen(
              guardarAvisoRpc: (
                      {int? id,
                      required String titulo,
                      required String cuerpo,
                      required String nivel,
                      String? fechaFin}) async {},
              listarAvisosRpc: listar,
              retirarAvisoRpc: retirar)));
      await _pumps(tester, 16);
      expect(find.text('Aviso de prueba'), findsOneWidget);
      await tester.tap(find.text('Aviso de prueba'));
      await _pumps(tester, 10);
      expect(find.text('Editar aviso'), findsOneWidget);
      final boton = find.text('Retirar aviso');
      await tester.ensureVisible(boton);
      await _pumps(tester, 4);
      await tester.tap(boton);
      await _pumps(tester, 10);
      // La escalera de confirmaciones sigue intacta.
      expect(find.text('Retirar'), findsOneWidget,
          reason: 'el diálogo en rojo pide confirmar antes');
      await tester.tap(find.text('Retirar'));
      await _pumps(tester, 20);
    }

    testWidgets('el servidor ya lo retiró pero la red dijo '
        'que no: éxito, sin error falso', (tester) async {
      _pantallaAlta(tester);
      final servidor = [_aviso(5)];
      var llamadasRetirar = 0;
      await montarYAbrir(
        tester,
        retirar: (id) async {
          llamadasRetirar++;
          // El retiro ATERRIZÓ en el servidor…
          servidor.removeWhere((a) => a.id == id);
          // …pero la respuesta se perdió (timeout).
          throw TimeoutException('la red llegó tarde');
        },
        listar: () async => List.of(servidor),
      );
      expect(llamadasRetirar, 1,
          reason: 'un solo intento de retiro: no se repite');
      expect(find.text('Aviso retirado'), findsOneWidget);
      expect(find.textContaining('No se pudo retirar'),
          findsNothing,
          reason: 'nada de error falso: sí se retiró');
      expect(find.text('Sin avisos publicados'), findsOneWidget,
          reason: 'de vuelta en la lista, recargada y vacía');
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('no aterrizó: error y formulario abierto '
        'para reintentar', (tester) async {
      _pantallaAlta(tester);
      final servidor = [_aviso(5)];
      await montarYAbrir(
        tester,
        retirar: (id) async => throw StateError('500'),
        listar: () async => List.of(servidor),
      );
      expect(
          find.text('No se pudo retirar el aviso. Revisa la '
              'conexión e inténtalo de nuevo.'),
          findsOneWidget);
      expect(find.text('Editar aviso'), findsOneWidget,
          reason: 'el formulario sigue abierto');
      expect(find.text('Retirar aviso'), findsOneWidget,
          reason: 'se puede volver a intentar');
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('sin confirmación posible: vuelve a la '
        'lista con el aviso de revisar', (tester) async {
      _pantallaAlta(tester);
      var llamadasListar = 0;
      await montarYAbrir(
        tester,
        retirar: (id) async => throw TimeoutException('t'),
        // La carga inicial de la lista SÍ responde; lo que
        // falla es la comprobación tras el retiro (y la
        // recarga posterior).
        listar: () async {
          llamadasListar++;
          if (llamadasListar == 1) return [_aviso(5)];
          throw TimeoutException('t');
        },
      );
      expect(
          find.text('No se pudo confirmar si el aviso se '
              'retiró. Revisa la lista antes de intentarlo '
              'de nuevo.'),
          findsOneWidget);
      expect(find.text('Editar aviso'), findsNothing,
          reason: 'el formulario se cerró');
      expect(find.text('Avisos a clientes'), findsOneWidget,
          reason: 'de vuelta en la pantalla de la lista');
      await tester.pump(const Duration(seconds: 6));
    });
  });

  // ── Pantalla · rutinas del gym (GEN-08) ──────────────
  group('Oleada 3 · el formulario de rutinas (GEN-08)', () {
    Future<void> montarYAbrir(
      WidgetTester tester, {
      required Future<void> Function(int) retirar,
      required Future<List<RutinaGymAdmin>> Function() listar,
    }) async {
      cargarCatalogoRutinasParaTest = () async => _catalogo;
      // Como en producción: el formulario va EMPUJADO sobre
      // la lista (no es la raíz) — al volver, la barra de
      // aviso se pinta sobre la pantalla que queda.
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (ctx) => Center(
                          child: ElevatedButton(
                        onPressed: () => Navigator.push(
                            ctx,
                            MaterialPageRoute<void>(
                                builder: (_) => FormularioRutinaScreen(
                                    rutina: _rutina(),
                                    retirarRutinaRpc: retirar,
                                    listarRutinasRpc: listar))),
                        child: const Text('Abrir rutina'),
                      ))))));
      await tester.tap(find.text('Abrir rutina'));
      await _pumps(tester, 10);
      final boton = find.text('Retirar rutina');
      expect(boton, findsOneWidget);
      await tester.ensureVisible(boton);
      await _pumps(tester, 4);
      await tester.tap(boton);
      await _pumps(tester, 10);
      expect(find.text('Retirar'), findsOneWidget,
          reason: 'el diálogo en rojo pide confirmar antes');
      await tester.tap(find.text('Retirar'));
      await _pumps(tester, 20);
    }

    testWidgets('el servidor ya la retiró pero la red dijo '
        'que no: éxito, sin error falso', (tester) async {
      _pantallaAlta(tester);
      final servidor = [_rutina()];
      var llamadasRetirar = 0;
      await montarYAbrir(
        tester,
        retirar: (id) async {
          llamadasRetirar++;
          servidor.removeWhere((r) => r.id == id);
          throw TimeoutException('la red llegó tarde');
        },
        listar: () async => List.of(servidor),
      );
      expect(llamadasRetirar, 1);
      expect(find.text('Rutina retirada'), findsOneWidget);
      expect(find.textContaining('No se pudo retirar'),
          findsNothing,
          reason: 'nada de error falso: sí se retiró');
      expect(find.byType(FormularioRutinaScreen), findsNothing,
          reason: 'el formulario se cerró como en un éxito');
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('no aterrizó: error y formulario abierto '
        'para reintentar', (tester) async {
      _pantallaAlta(tester);
      final servidor = [_rutina()];
      await montarYAbrir(
        tester,
        retirar: (id) async => throw StateError('500'),
        listar: () async => List.of(servidor),
      );
      expect(
          find.text('No se pudo retirar la rutina. Revisa '
              'la conexión e inténtalo de nuevo.'),
          findsOneWidget);
      expect(find.byType(FormularioRutinaScreen),
          findsOneWidget,
          reason: 'el formulario sigue abierto');
      expect(find.text('Retirar rutina'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('sin confirmación posible: sale del '
        'formulario con el aviso de revisar', (tester) async {
      _pantallaAlta(tester);
      await montarYAbrir(
        tester,
        retirar: (id) async => throw TimeoutException('t'),
        listar: () async => throw TimeoutException('t'),
      );
      expect(
          find.text('No se pudo confirmar si la rutina se '
              'retiró. Revisa la lista antes de intentarlo '
              'de nuevo.'),
          findsOneWidget);
      expect(find.byType(FormularioRutinaScreen), findsNothing,
          reason: 'el formulario se cerró');
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
