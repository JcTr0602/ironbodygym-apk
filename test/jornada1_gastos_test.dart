// JORNADA 1 · S11 — Registrar un gasto del día.
//
// El flujo ÚNICO agregarGastoFlow (dialogo_gasto.dart) con
// su guarda de permiso DENTRO: el dueño registra; Gabriel
// SIN la llave de gastos recibe la denegación en claro y
// ninguna op nace; Gabriel CON la llave registra (la guarda
// no es un veto a entrenadores, es la llave de Jc). El gasto
// se ve en el listado del día sin esperar a la sync (la op
// pendiente entra en gastosTodos, sin duplicar al bajar).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/dialogo_gasto.dart';

import 'jornada_ayudas.dart';

Widget _anfitrion() {
  return MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            onPressed: () => agregarGastoFlow(ctx),
            child: const Text('gasto'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _registrarGasto(
    WidgetTester tester, ContadorToques toques) async {
  await toques.tap(tester, find.text('gasto'));
  await tester.pumpAndSettle();
  await jornadaEsperar(tester, find.text('Agregar gasto'));
  await toques.campo(
      tester, find.byType(TextField).first, 'Pago de la luz jornada');
  // El monto va con el pad del mostrador: abrir + dígitos
  // + Aceptar (cada tecla es un toque real).
  await toques.tap(tester, find.text('Monto (CUP)'));
  await jornadaDrenar(tester, vueltas: 4);
  await jornadaEsperar(tester, find.text('Aceptar'));
  // Las teclas viven en la hoja inferior del pad y son el
  // texto GRANDE; la hoja también muestra el importe en
  // curso en pequeño con los mismos dígitos. Se elige el
  // candidato de mayor tamaño efectivo.
  Future<void> tecla(String d) async {
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
    if (objetivo == null) {
      throw StateError('sin tecla $d en el pad');
    }
    await toques.tap(
        tester, find.byWidgetPredicate((w) => identical(w, objetivo)));
    // La hoja se reconstruye con cada tecla: sin asentar el
    // frame, el toque siguiente cae en el vacío (avisos de
    // hit-test del arnés lo delataron).
    await tester.pumpAndSettle();
  }

  await tecla('3');
  await tecla('0');
  await tecla('0');
  await jornadaEsperar(tester, find.text('Aceptar'));
  await toques.tap(tester, find.text('Aceptar'));
  await jornadaDrenar(tester, vueltas: 4);
  await toques.tap(tester, find.text('Guardar'));
  // Pocos frames cortos: el flujo dispara el push al final
  // y contra el servidor falso del arnés la op se sella
  // «rechazada» en cuanto el motor completa su ciclo; la
  // lista del día se comprueba con la op aún pendiente,
  // que es como la ve el usuario al guardar sin conexión
  // real con el servidor.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S11 · gasto del día', () {
    testWidgets(
        'el DUEÑO registra: op gasto y el gasto se ve hoy',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await tester.pumpWidget(_anfitrion());
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      await _registrarGasto(tester, toques);

      // El dato cae donde debe: el listado del día lo
      // incluye desde la op pendiente, sin esperar al pull.
      // Se comprueba ANTES de que el motor de sync selle la
      // op contra el servidor falso del arnés.
      final hoy = await gastosTodos();
      expect(
          hoy.where((g) =>
              g['concepto'] == 'Pago de la luz jornada' &&
              (g['monto'] as num).toDouble() == 300),
          hasLength(1),
          reason: 'el gasto del día descuenta del cuadre '
              'desde ya (op pendiente fusionada en la lista)');

      expect(find.textContaining('Gasto guardado'), findsWidgets,
          reason: 'el flujo confirma el guardado');
      final ops = await jornadaOpsTodas('gasto');
      expect(ops, hasLength(1));
      final p = jornadaPayloadDe(ops.single);
      expect(p['concepto'], 'Pago de la luz jornada');
      expect((p['monto'] as num).toDouble(), 300);
      expect(p['fecha'], hoyHabanaIso());

      expect(toques.n, 8,
          reason: 'abrir + concepto + abrir pad + 3 dígitos '
              '+ Aceptar + Guardar = 8 toques (el pad cobra '
              'un toque por dígito)');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'entrenador SIN llave de gastos: la guarda deniega '
        'en la propia vía y no nace ninguna op',
        (tester) async {
      await jornadaPreparar(tester, gastos: false);
      await jornadaSesionEntrenador(tester, gastos: false);
      await tester.pumpWidget(_anfitrion());
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      await toques.tap(tester, find.text('gasto'));
      await jornadaDrenar(tester, vueltas: 6);

      expect(find.text('Agregar gasto'), findsNothing,
          reason: 'sin la llave el diálogo ni se abre: la '
              'guarda vive dentro del flujo compartido');
      expect(
          find.textContaining(
              'No tienes permiso para registrar gastos'),
          findsWidgets,
          reason: 'la denegación se dice en claro, no en '
              'silencio (y el servidor sería el cinturón '
              'final si la op llegara encolada)');
      expect(await jornadaOpsTodas('gasto'), isEmpty);
      expect(toques.n, 1);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'entrenador CON la llave: registra su gasto '
        '(la guarda es la llave, no el rol)', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.pumpWidget(_anfitrion());
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      await _registrarGasto(tester, toques);

      final ops = await jornadaOpsTodas('gasto');
      expect(ops, hasLength(1));
      expect(ops.single['telegram_id'], 1403501391,
          reason: 'la op nace firmada por Gabriel');
      expect(toques.n, 8);
      await jornadaCerrarCascara(tester);
    });
  });
}
