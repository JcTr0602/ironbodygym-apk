// JORNADA 1 · S13 — Arqueo del pendiente a entregar.
//
// El pendiente de Gabriel son dos cobros en efectivo YA
// confirmados (espejo: el arqueo solo liquida sobre datos
// confirmados por el servidor) más una transferencia que
// JAMÁS entra en el pendiente. El dueño revisa el desglose,
// liquida PARCIAL (2000 de 2900) y el resto queda como
// arrastre exacto, sin diferencia fantasma; en la segunda
// batería, la entrega total deja el pendiente en cero.
// La confirmación es DESLIZAR, no tocar: el dinero no se
// liquida con un toque accidental.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/arqueo.dart';
import 'package:ironbody_gym/ui/detalle_pendiente.dart';
import 'package:ironbody_gym/ui/primitivas.dart';

import 'jornada_ayudas.dart';

Future<void> _sembrarPendiente() async {
  final hoy = hoyHabanaIso();
  await LocalDb.instance.upsertMirror('pagos', 301, {
    'id': 301,
    'cliente_id': 20,
    'fecha': hoy,
    'monto': 2000,
    'metodo': 'efectivo',
    'telegram_user_id': 1403501391,
    'registrado_por': 'Gabriel',
  }, 1);
  await LocalDb.instance.upsertMirror('pagos', 302, {
    'id': 302,
    'cliente_id': 21,
    'fecha': hoy,
    'monto': 900,
    'metodo': 'efectivo',
    'telegram_user_id': 1403501391,
    'registrado_por': 'Gabriel',
  }, 1);
  // La transferencia va directa a la cuenta de Jc: nunca
  // compone el pendiente a entregar.
  await LocalDb.instance.upsertMirror('pagos', 303, {
    'id': 303,
    'cliente_id': 22,
    'fecha': hoy,
    'monto': 2500,
    'metodo': 'transferencia',
    'telegram_user_id': 1403501391,
  }, 1);
}

Widget _anfitrion(Widget destino, String etiqueta) {
  return MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(builder: (_) => destino)),
            child: Text(etiqueta),
          ),
        ),
      ),
    ),
  );
}

Future<void> _teclaPad(
    WidgetTester tester, ContadorToques toques, String d) async {
  final candidatos = find.descendant(
      of: find.byType(BottomSheet), matching: find.text(d));
  Widget? mejor;
  var mejorTam = -1.0;
  for (final e in candidatos.evaluate()) {
    final tam = DefaultTextStyle.of(e).style.fontSize ?? 0;
    if (tam > mejorTam) {
      mejorTam = tam;
      mejor = e.widget;
    }
  }
  final objetivo = mejor;
  if (objetivo == null) throw StateError('sin tecla $d');
  await toques.tap(
      tester, find.byWidgetPredicate((w) => identical(w, objetivo)));
  await tester.pumpAndSettle();
}

Future<void> _deslizarLiquidar(
    WidgetTester tester, ContadorToques toques) async {
  toques.n++; // el deslizamiento ES la confirmación: 1 gesto
  // El detector de arrastre vive SOLO en el pulgar (el
  // círculo a la izquierda de la pista): hay que agarrarlo
  // ahí y recorrer ≥92% de la pista, como el dedo real.
  await tester.drag(
      find.byKey(const ValueKey('deslizar-pulgar')),
      const Offset(340, 0));
  await jornadaDrenar(tester, vueltas: 3);
}

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S13 · arqueo del pendiente', () {
    testWidgets(
        'desglose sin transferencias y liquidación PARCIAL: '
        'arrastre exacto de 900', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarPendiente();
      jornadaViewport(tester);
      expect(await pendienteEntrega(1403501391), 2900,
          reason: 'solo el efectivo confirmado compone el '
              'pendiente (la transferencia de 2500 no está)');

      // 1) El desglose del pendiente: qué lo compone.
      await tester.pumpWidget(_anfitrion(
          const DetallePendienteScreen(
              trainerId: 1403501391, nombre: 'Gabriel'),
          'detalle'));
      await tester.pumpAndSettle();
      final toques = ContadorToques();
      await toques.tap(tester, find.text('detalle'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Mensualidades'));
      expect(find.text('2900 CUP'), findsWidgets,
          reason: 'el desglose suma los dos efectivos');
      expect(find.text('2000 CUP'), findsWidgets);
      expect(find.text('900 CUP'), findsWidgets,
          reason: 'el desglose es por cobro, no una cifra '
              'pelada: Cliente 20 (2000) y Cliente 21 (900)');
      expect(find.textContaining('2500'), findsNothing,
          reason: 'la transferencia no se cuela ni en el '
              'total ni en los movimientos');
      toques.n++; // el gesto de volver también es del usuario
      await tester.pageBack();
      await tester.pumpAndSettle();

      // 2) El arqueo: lista → su detalle → monto parcial.
      await tester.pumpWidget(_anfitrion(const ArqueoScreen(), 'arqueo'));
      await tester.pumpAndSettle();
      await toques.tap(tester, find.text('arqueo'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Gabriel'));
      await toques.tap(tester, find.text('Gabriel'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Nueva liquidación'));
      // El entregado nace precargado con el esperado (2900):
      // se corrige a 2000 con el pad (limpiar + 4 dígitos).
      await toques.tap(tester, find.text('Monto entregado (CUP)'));
      await jornadaDrenar(tester, vueltas: 4);
      await jornadaEsperar(tester, find.text('Aceptar'));
      await _teclaPad(tester, toques, 'C');
      await _teclaPad(tester, toques, '2');
      await _teclaPad(tester, toques, '0');
      await _teclaPad(tester, toques, '0');
      await _teclaPad(tester, toques, '0');
      await toques.tap(tester, find.text('Aceptar'));
      await jornadaDrenar(tester, vueltas: 4);
      await toques.tap(tester, find.text('Liquidar'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Confirmar liquidación'));
      expect(
          find.textContaining('quedan como saldo de arrastre'),
          findsOneWidget,
          reason: 'la parcial se anuncia como arrastre, no '
              'como diferencia');
      expect(find.text('2 operación(es) incluida(s).'),
          findsOneWidget);
      await _deslizarLiquidar(tester, toques);

      final ops = await jornadaOpsTodas('liquidar_caja');
      expect(ops, hasLength(1));
      final p = jornadaPayloadDe(ops.single);
      expect(p['entrenador_telegram_id'], 1403501391);
      expect((p['monto_esperado'] as num).toDouble(), 2900);
      expect((p['monto_entregado'] as num).toDouble(), 2000);

      // Mientras la liquidación está EN COLA, el contador
      // NO baja: el pendiente se calcula solo sobre datos
      // confirmados (la propia pantalla lo dice: «Cuando
      // sincronice, el pendiente bajará»). La guarda que
      // impide la segunda liquidación en esa ventana se
      // verifica en su propio test de este archivo.
      expect(await pendienteEntrega(1403501391), 2900,
          reason: 'en cola aún no baja: manda lo confirmado');
      // Cuando la sync la confirma y baja el espejo de la
      // liquidación (fila parcial con su arrastre), el
      // contador cae al arrastre EXACTO: 900.
      await LocalDb.instance.upsertMirror('liquidaciones_caja', 901, {
        'id': 901,
        'entrenador_telegram_id': 1403501391,
        'estado': 'parcial',
        'saldo_arrastre': 900,
        'moneda': 'CUP',
        'monto_esperado': 2900,
        'monto_entregado': 2000,
        'op_ids': {
          'pagos': [301, 302],
          'pagos_diarios': <int>[],
          'ventas_suplementos': <int>[],
          'servicio_ventas': <int>[],
        },
      }, 2);
      expect(await pendienteEntrega(1403501391), 900,
          reason: 'ni cero fantasma ni diferencia perdida: '
              'el arrastre de la parcial');

      expect(toques.n, 13,
          reason: 'detalle (abrir + volver) 2 + arqueo '
              '(abrir + tarjeta) 2 + pad (abrir + limpiar + '
              '4 dígitos + Aceptar) 7 + Liquidar 1 + deslizar '
              '1 = 13 interacciones');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'la guarda: con una liquidación EN COLA sin '
        'confirmar, la segunda no nace', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarPendiente();
      // Una liquidación encolada en este teléfono, aún sin
      // confirmar por el servidor (el estado que la guarda
      // protege: en el arnés, el ciclo contra el servidor
      // falso sella las ops al instante y la ventana no se
      // puede observar tras la UI; aquí se siembra la cola
      // tal cual queda en el teléfono real sin conexión).
      await LocalDb.instance.queueOp(
        opUuid: 'liq-en-cola-s13',
        tipo: 'liquidar_caja',
        payload: {
          'liquidacion_id': 'liq-en-cola-s13',
          'entrenador_telegram_id': 1403501391,
          'entrenador_nombre': 'Gabriel',
          'monto_esperado': 2900,
          'monto_entregado': 2900,
          'moneda': 'CUP',
          'op_ids': {
            'pagos': [301, 302]
          },
        },
      );
      await expectLater(
          crearLiquidacion(
            entrenadorTelegramId: 1403501391,
            entrenadorNombre: 'Gabriel',
            montoEsperado: 2900,
            montoEntregado: 2900,
            opIds: const {
              'pagos': [301]
            },
          ),
          throwsA(predicate((e) =>
              '$e'.contains('en cola de sincronización'))),
          reason: 'no se puede liquidar dos veces lo mismo '
              'mientras la primera sigue en el teléfono');
      expect(await jornadaOpsTodas('liquidar_caja'), hasLength(1),
          reason: 'la segunda liquidación nunca nació');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'entrega TOTAL: el diálogo dice «Cuadra exacto» y '
        'el pendiente queda en cero', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarPendiente();
      jornadaViewport(tester);
      await tester.pumpWidget(_anfitrion(const ArqueoScreen(), 'arqueo'));
      await tester.pumpAndSettle();
      final toques = ContadorToques();
      await toques.tap(tester, find.text('arqueo'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Gabriel'));
      await toques.tap(tester, find.text('Gabriel'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Nueva liquidación'));
      // Sin tocar el monto: nace precargado con el esperado.
      await toques.tap(tester, find.text('Liquidar'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Confirmar liquidación'));
      expect(find.text('Cuadra exacto.'), findsOneWidget);
      await _deslizarLiquidar(tester, toques);

      final ops = await jornadaOpsTodas('liquidar_caja');
      expect(ops, hasLength(1));
      final p = jornadaPayloadDe(ops.single);
      expect((p['monto_entregado'] as num).toDouble(), 2900);
      // En cola aún no baja (solo manda lo confirmado); al
      // bajar el espejo de la liquidación completa, cero.
      expect(await pendienteEntrega(1403501391), 2900);
      await LocalDb.instance.upsertMirror('liquidaciones_caja', 902, {
        'id': 902,
        'entrenador_telegram_id': 1403501391,
        'estado': 'completa',
        'saldo_arrastre': 0,
        'moneda': 'CUP',
        'monto_esperado': 2900,
        'monto_entregado': 2900,
        'op_ids': {
          'pagos': [301, 302],
          'pagos_diarios': <int>[],
          'ventas_suplementos': <int>[],
          'servicio_ventas': <int>[],
        },
      }, 2);
      expect(await pendienteEntrega(1403501391), 0);
      expect(toques.n, 4,
          reason: 'abrir arqueo + tarjeta + Liquidar + '
              'deslizar = 4 interacciones');
      await jornadaCerrarCascara(tester);
    });
  });
}
