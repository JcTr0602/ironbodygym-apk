// Jornada 1 · Situaciones 8 y 9 — servicios (dosis y agua).
//
// S8 (entrenador, SU pomo): vender una dosis en efectivo a un
// cliente normal y otra a un cliente Casa identificado. Es la
// regresión del defecto de campo de la 1.32 (la dosis Casa
// desde el pomo del entrenador se bloqueaba): se valida la
// sesión del OPERADOR y el stock se atribuye al TITULAR del
// pomo. El entrenador NO ve el saldo de su pomo en ninguna
// superficie; el dueño sí (contraste en S9).
// S9 (dueño): el agua suelta es la ÚNICA venta con «A nombre
// de» libre (cualquier persona); en dosis el desplegable del
// dueño solo ofrece titular del pomo + Yo (diseño confirmado
// por Jc 2026-10-29, no error).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/servicios.dart';

import 'jornada_ayudas.dart';

const _tidGabriel = 1403501391;
const _tidDuany = 969869611;
const _tidDueno = 735772141;

Future<void> _sembrarBase(WidgetTester tester) async {
  await tester.runAsync(() async {
    final db = await LocalDb.instance.db;
    final ahora = ahoraHabana();
    for (final tid in [_tidGabriel, _tidDueno]) {
      await db.insert('turnos', {
        'turno_id': 'turno-jornada-$tid',
        'fecha_turno': hoyHabanaIso(),
        'turno': ahora.hour >= 12 ? 'tarde' : 'mañana',
        'hora_apertura': isoHabana(ahora),
        'hora_cierre': null,
        'telegram_id': tid,
        'estado': 'abierto_local',
        'cubre_a': null,
      });
    }
    await LocalDb.instance.upsertMirror('suplementos', 5, {
      'id': 5,
      'nombre': 'Pre-entreno Jornada',
      'precio': 2500,
      'stock': 4,
    }, 1);
    // Pomo de Gabriel: 10 dosis asignadas.
    await LocalDb.instance.upsertMirror('servicio_pomos', 7, {
      'id': 7,
      'activo': 1,
      'titular_telegram_id': _tidGabriel,
      'es_principal': 0,
      'dosis_asignadas': 10,
      'dosis_repartidas': 0,
      'suplemento_id': 5,
    }, 1);
    // Pomo principal del dueño: 20 dosis.
    await LocalDb.instance.upsertMirror('servicio_pomos', 8, {
      'id': 8,
      'activo': 1,
      'titular_telegram_id': _tidDueno,
      'es_principal': 1,
      'dosis_asignadas': 20,
      'dosis_repartidas': 0,
      'suplemento_id': 5,
    }, 1);
    // Agua común: 10 pomos.
    await LocalDb.instance.upsertMirror('servicio_agua_movimientos', 1, {
      'id': 1,
      'tipo': 'entrada',
      'cantidad': 10,
      'costo_unitario': 100,
    }, 1);
    await LocalDb.instance.upsertMirror('clientes', 20, {
      'id': 20,
      'nombre': 'Cliente Normal',
      'estado': 'activo',
      'cuenta_casa': 0,
    }, 1);
    await LocalDb.instance.upsertMirror('clientes', 21, {
      'id': 21,
      'nombre': 'Cliente Casa',
      'estado': 'activo',
      'cuenta_casa': 1,
    }, 1);
    await LocalDb.instance.setAjustes({'servicio_precio_agua': 300});
    await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {'telegram_id': _tidGabriel, 'nombre': 'Gabriel'},
          {'telegram_id': _tidDuany, 'nombre': 'Duany'},
          {'telegram_id': _tidDueno, 'nombre': 'Jc'},
        ]));
  });
}

/// Anfitrión mínimo: empuja Servicios (como desde Inicio)
/// para poder SALIR como un usuario (atrás) antes de desmontar
/// el árbol: la barra «Deshacer» de Servicios muere con su
/// pantalla cerrando su controlador, y hacerlo contra un
/// ScaffoldMessenger ya desmontado lanza StateError (artefacto
/// del arnés al desmontar todo de golpe; en la app el
/// messenger sobrevive a la pantalla).
Widget _hostServicios() {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const ServiciosScreen())),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _abrirServicios(
    WidgetTester tester, ContadorToques toques) async {
  await tester.pumpWidget(_hostServicios());
  await toques.tap(tester, find.text('abrir')); // entrada
  await jornadaDrenar(tester, vueltas: 6);
}

/// Sale de Servicios como un usuario (atrás) y desmonta.
Future<void> _salirServicios(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(ServiciosScreen))).pop();
  await jornadaDrenar(tester, vueltas: 4);
  await jornadaCerrarCascara(tester);
}

/// Toca un control asegurando primero que está en pantalla
/// (los diálogos de venta son altos: sus acciones pueden nacer
/// bajo el borde inferior a 420×800 y el toque se pierde).
Future<void> _tapVisible(
    WidgetTester tester, ContadorToques toques, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await toques.tap(tester, finder);
}

/// Elige un cliente en el diálogo de venta (campo → selector
/// con buscador → ficha de la lista).
Future<void> _elegirClienteVenta(
    WidgetTester tester, ContadorToques toques, String nombre) async {
  await toques.tap(
      tester, find.textContaining('Cliente: sin identificar'));
  // G06-9: el hint dice su verdad — también busca por carnet.
  await jornadaEsperar(
      tester, find.text('Buscar por nombre o carnet…'));
  await toques.tap(tester, find.text(nombre));
  await jornadaDrenar(tester, vueltas: 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S8 · dosis desde el pomo del entrenador', () {
    testWidgets(
        'venta normal en efectivo + dosis Casa identificada sin '
        'bloqueo; el entrenador no ve el saldo de su pomo',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await _sembrarBase(tester);
      jornadaViewport(tester);
      final toques = ContadorToques();

      await _abrirServicios(tester, toques);
      await jornadaEsperar(tester, find.text('Dosis'));

      // Paso 6 (antes de vender): el entrenador NO ve cuántas
      // dosis quedan en su pomo; sí ve el agua común.
      expect(find.text('10 dosis'), findsNothing,
          reason: 'el saldo del pomo es invisible al entrenador');
      expect(find.textContaining('Agua común: 10 pomos'),
          findsOneWidget);

      // ── Venta 1: dosis a cliente normal, efectivo ──
      await toques.tap(tester, find.text('Dosis'));
      await jornadaEsperar(tester, find.text('Cobrar'));
      // Sin «A nombre de» ni «Consumo Casa» para el entrenador.
      expect(find.text('A nombre de:'), findsNothing);
      expect(find.text('Consumo Casa (para el dueño)'),
          findsNothing);
      await _elegirClienteVenta(tester, toques, 'Cliente Normal');
      await toques.tap(tester, find.text('Cobrar'));
      await jornadaDrenar(tester, vueltas: 6);

      var ops = await jornadaOpsTodas('venta_servicio');
      expect(ops, hasLength(1));
      var payload = jornadaPayloadDe(ops.single);
      expect(payload['tipo'], 'dosis_sin_agua');
      expect(payload['pomo_id'], 7);
      expect(payload['cantidad'], 1);
      expect((payload['precio_unitario'] as num).toInt(), 600);
      expect((payload['comision_unitaria'] as num).toInt(), 50);
      expect(payload['metodo'], 'efectivo');
      expect(payload['cliente_id'], 20);
      expect(ops.single['telegram_id'], _tidGabriel,
          reason: 'la autoría de la op es el operador');
      // El stock cae: saldo del pomo con la op encolada = 9.
      final pomo = (await LocalDb.instance
              .allMirror('servicio_pomos'))
          .firstWhere((p) => p['id'] == 7);
      expect(
          saldoPomoDesde(
              pomo: pomo,
              ventasEspejo: const [],
              salidasEspejo: const [],
              opsPendientes: ops),
          9);
      // El efectivo de la venta es dinero a entregar (600).
      final precios = await preciosVigentes();
      expect(montoEfectivoOp(ops.single, precios), 600);

      // ── Venta 2: dosis a cliente Casa identificado ──
      // (la regresión de la 1.32: no debe bloquearse).
      await toques.tap(tester, find.text('Dosis'));
      await jornadaEsperar(tester, find.text('Cobrar'));
      await _elegirClienteVenta(tester, toques, 'Cliente Casa');
      // Con el Casa identificado, el diálogo pasa a «sin
      // cobro» y el botón a «Registrar».
      await jornadaEsperar(tester, find.text('Registrar'));
      await toques.tap(tester, find.text('Registrar'));
      await jornadaDrenar(tester, vueltas: 6);

      ops = await jornadaOpsTodas('venta_servicio');
      expect(ops, hasLength(2));
      final opCasa =
          ops.firstWhere((o) => jornadaPayloadDe(o)['casa'] == true);
      payload = jornadaPayloadDe(opCasa);
      expect(payload['tipo'], 'dosis_sin_agua');
      expect(payload['pomo_id'], 7,
          reason: 'el stock se atribuye al titular del pomo');
      expect(payload['cliente_id'], 21);
      expect(payload.containsKey('metodo'), isFalse,
          reason: 'la dosis Casa no cobra: sin método de pago');
      // La Casa no es dinero a entregar.
      expect(montoEfectivoOp(opCasa, precios), 0);
      // Y el pomo descuenta también la dosis Casa: 10 − 2 = 8.
      expect(
          saldoPomoDesde(
              pomo: pomo,
              ventasEspejo: const [],
              salidasEspejo: const [],
              opsPendientes: ops),
          8);

      expect(toques.n, 9,
          reason: 'entrada 1 + por venta (Dosis + elegir '
              'cliente + cliente + Cobrar/Registrar = 4) × 2 '
              'ventas = 9 toques');
      await _salirServicios(tester);
    });
  });

  group('Jornada S9 · agua suelta con «A nombre de» (dueño)', () {
    testWidgets(
        'el agua permite atribuir a otro entrenador; en dosis '
        'el desplegable solo ofrece titular + Yo', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarBase(tester);
      jornadaViewport(tester);
      final toques = ContadorToques();

      await _abrirServicios(tester, toques);
      await jornadaEsperar(tester, find.text('Agua'));
      // El dueño SÍ ve el saldo de su pomo principal.
      expect(find.text('20 dosis'), findsOneWidget);

      // Contraste en DOSIS: «A nombre de» solo trae al titular
      // del pomo (él mismo, principal) — nadie más.
      await toques.tap(tester, find.text('Dosis'));
      await jornadaEsperar(tester, find.text('Cobrar'));
      expect(find.text('A nombre de:'), findsOneWidget);
      await _tapVisible(
          tester,
          toques,
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(SelectorIron<int?>)));
      await tester.pumpAndSettle();
      expect(find.text('Duany'), findsNothing,
          reason: 'en dosis no se puede elegir a otro '
              'entrenador (diseño de Jc 2026-10-29)');
      await toques.tap(tester, find.text('Yo (dueño)').last);
      await tester.pumpAndSettle();
      // Se cancela la dosis: solo se vende el agua.
      await _tapVisible(tester, toques, find.text('Cancelar'));
      await jornadaDrenar(tester, vueltas: 4);

      // AGUA a nombre de Duany:
      await toques.tap(tester, find.text('Agua'));
      await jornadaEsperar(tester, find.text('Cobrar'));
      await _tapVisible(
          tester,
          toques,
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(SelectorIron<int?>)));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Duany'));
      await toques.tap(tester, find.text('Duany').last);
      await tester.pumpAndSettle();
      await toques.tap(tester, find.text('Cobrar'));
      await jornadaDrenar(tester, vueltas: 6);

      final ops = await jornadaOpsTodas('venta_servicio');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['tipo'], 'agua_suelta');
      expect(payload.containsKey('pomo_id'), isFalse,
          reason: 'el agua sale del stock común, sin pomo');
      expect((payload['precio_unitario'] as num).toInt(), 300);
      expect(payload['vendedor_id'], _tidDuany,
          reason: 'la venta queda a nombre de Duany');
      expect(ops.single['telegram_id'], _tidDueno,
          reason: 'el autor de la op es el dueño que la '
              'registró');
      // El stock común de agua baja a 9 pomos (con la op
      // encolada contada: en el arnés el push la sella al
      // instante y stockAguaLocal ya no la ve; en campo queda
      // pendiente y descuenta igual).
      final movsAgua = await LocalDb.instance
          .allMirror('servicio_agua_movimientos');
      expect(
          aguaDesde(movimientosEspejo: movsAgua, opsPendientes: ops)
              .saldo,
          9);

      expect(toques.n, 9,
          reason: 'entrada 1 + contraste dosis sin vender '
              '(Dosis + desplegable + Yo + Cancelar = 4) + agua '
              'vendida (Agua + desplegable + Duany + Cobrar = '
              '4) = 9 toques');
      await _salirServicios(tester);
    });
  });
}
