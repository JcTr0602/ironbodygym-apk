// JORNADA 1 · S12 — Dar un adelanto a un entrenador y
// verlo en su resumen.
//
// Flujo real del dueño en la pantalla de Nómina: sección
// «Adelantos de Gabriel» → Registrar → diálogo «Adelanto a
// Gabriel» (efectivo, caja del turno, su gaveta: los
// valores por defecto del gym) → op registrar_adelanto.
// Después: el resumen del mes lo descuenta (bruto 600 por
// 4 clientes que pagaron el mes × 150, la definición única
// de NominaCalc), la gaveta del entrenador lo refleja como
// adelanto (NO como gasto) y el borde: adelantos por encima
// de lo devengado no dan un neto negativo imposible — el
// excedente queda como deuda arrastrada al mes siguiente.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/nomina_foto.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/nomina.dart';

import 'jornada_ayudas.dart';

const _gabrielId = '00000000-0000-0000-0000-0000000000e7';

Future<void> _sembrarNomina(WidgetTester tester) async {
  await LocalDb.instance.setMeta(
      'usuarios_apk',
      jsonEncode([
        {
          'id': _gabrielId,
          'telegram_id': 1403501391,
          'nombre': 'Gabriel',
          'username': 'gabriel',
        },
      ]));
  final hoy = hoyHabanaIso();
  // 4 clientes pagaron el mes, cobrados por Gabriel:
  // su base del mes es 4 × 150 = 600 (definición única).
  for (var i = 0; i < 4; i++) {
    await LocalDb.instance.upsertMirror('pagos', 100 + i, {
      'id': 100 + i,
      'cliente_id': 20 + i,
      'fecha': hoy,
      'monto': 2000,
      'metodo': 'efectivo',
      'entrenador': 1403501391,
      'nombre_entrenador': 'Gabriel',
    }, 1);
  }
}

Widget _pantalla() {
  return MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: const NominaScreen(),
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

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S12 · adelanto a un entrenador', () {
    testWidgets(
        'el dueño registra 500 desde la pantalla de '
        'Nómina: la op nace con la gaveta de Gabriel',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarNomina(tester);
      jornadaViewport(tester);
      await tester.pumpWidget(_pantalla());
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      await jornadaEsperar(tester, find.text('Adelantos de Gabriel'));
      await toques.scrollHasta(tester, find.text('Registrar adelanto'),
          scrollable: find.byType(Scrollable).first);
      // Un arrastre más: el botón quedaba al filo inferior
      // y el toque caía fuera (aviso de hit-test). Es un
      // gesto del usuario y se cuenta como tal.
      toques.n++;
      await tester.drag(
          find.byType(Scrollable).first, const Offset(0, -140));
      await tester.pumpAndSettle();
      await toques.tap(tester, find.text('Registrar adelanto'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Adelanto a Gabriel'));

      // Monto con el pad (500): abrir + 3 dígitos + Aceptar.
      await toques.tap(tester, find.text('Monto (CUP entero)'));
      await jornadaDrenar(tester, vueltas: 4);
      await jornadaEsperar(tester, find.text('Aceptar'));
      await _teclaPad(tester, toques, '5');
      await _teclaPad(tester, toques, '0');
      await _teclaPad(tester, toques, '0');
      await toques.tap(tester, find.text('Aceptar'));
      await jornadaDrenar(tester, vueltas: 4);
      // Sin «le quedarían X» antes de confirmar: el diálogo
      // no anticipa el neto (fricción documentada).
      // El «Registrar» de confirmar vive en el diálogo (la
      // sección de atrás tiene otro con el mismo texto).
      await toques.tap(
          tester,
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Registrar')));
      await jornadaDrenar(tester, vueltas: 8);

      final ops = await jornadaOpsTodas('registrar_adelanto');
      expect(ops, hasLength(1));
      final p = jornadaPayloadDe(ops.single);
      expect(p['entrenador'], _gabrielId);
      expect(p['monto'], 500);
      expect(p['metodo'], 'efectivo');
      expect(p['origen'], 'caja_turno');
      expect(p['descuenta_a'], 1403501391,
          reason: 'sale de la gaveta de Gabriel');
      expect(p['fecha'], hoyHabanaIso());

      expect(toques.n, 9,
          reason: 'desplazar a su sección + Registrar '
              'adelanto + abrir pad + 3 dígitos + Aceptar + '
              'Registrar = 9 toques/gestos');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'el resumen del mes lo descuenta, la gaveta lo '
        'marca adelanto (no gasto)', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarNomina(tester);

      // El mismo registrar() que invoca el diálogo de la
      // pantalla (verificado arriba por UI). Se comprueba
      // enseguida: contra el servidor falso del arnés, un
      // ciclo de sync largo sella la op como rechazada y
      // purga el directorio — en producción el servidor la
      // acepta y el espejo la devuelve.
      await AdelantosService.instance.registrar(
        entrenadorId: _gabrielId,
        entrenadorNombre: 'Gabriel',
        entrenadorTelegramId: 1403501391,
        monto: 500,
        fecha: ahoraHabana(),
        metodo: 'efectivo',
        origen: 'caja_turno',
        descuentaA: 1403501391,
      );

      // El resumen del mes (la MISMA foto que pinta la
      // pantalla de Nómina) ya lo descuenta: 600 − 500.
      final pref = hoyHabanaIso().substring(0, 7);
      final foto = await fotoNominaMes(pref);
      final libro = foto.libroMes['gabriel']!;
      expect(libro.bruto, 600);
      expect(libro.adelantos, 500);
      expect(libro.neto, 100);
      expect(libro.items, hasLength(1),
          reason: 'el adelanto aparece en su libro con '
              'fecha y monto');

      // La caja del día: la gaveta de Gabriel bajó 500 por
      // ADELANTO; no es un gasto (no está en gastosTodos).
      expect(await adelantosEnPendiente(1403501391), 500);
      expect(
          (await gastosTodos())
              .where((g) => '${g['concepto']}'.contains('delanto')),
          isEmpty);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'BORDE: adelantos (1000) por encima de lo devengado '
        '(600): a pagar 0 y 400 de deuda arrastrada al mes '
        'siguiente, sin neto negativo', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarNomina(tester);

      final hoy = ahoraHabana();
      for (final monto in [500, 500]) {
        await AdelantosService.instance.registrar(
          entrenadorId: _gabrielId,
          entrenadorNombre: 'Gabriel',
          entrenadorTelegramId: 1403501391,
          monto: monto,
          fecha: hoy,
          metodo: 'efectivo',
          origen: 'bolsillo',
        );
      }

      final pref = hoyHabanaIso().substring(0, 7);
      final foto = await fotoNominaMes(pref);
      final libro = foto.libroMes['gabriel']!;
      expect(libro.adelantos, 1000);
      expect(libro.bruto, 600);
      expect(libro.aPagar, 0,
          reason: 'el neto no baja de cero: no existe un '
              '«a pagar» negativo imposible');
      expect(libro.deudaSaliente, 400,
          reason: 'el excedente queda como deuda, no se '
              'pierde ni se inventa');

      // La cadena: el mes siguiente abre con esa deuda
      // entrante (la misma foto corrida un mes adelante).
      final siguiente = mesSiguiente(pref);
      final fotoSig = await fotoNominaMes(siguiente);
      expect(fotoSig.libroMes['gabriel']?.deudaEntrante, 400,
          reason: 'la deuda arrastrada se ve al abrir el '
              'mes siguiente');
      await jornadaCerrarCascara(tester);
    });
  });
}
