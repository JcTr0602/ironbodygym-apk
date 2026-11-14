// JORNADA 1 · S20 — Corregir un error: anular un pago y
// recuperar un cliente de la papelera.
//
// NUNCA sobre los 11 clientes con días de más del C8: la
// batería usa clientes sintéticos propios (50/51/52).
//
// Anular (dueño, desde la ficha): historial → Corregir
// pago → Anular pago → hoja con MOTIVO obligatorio y
// confirmación DESLIZANDO. Dato: op anular_pago con
// pago_id y motivo; el pago queda MARCADO en el espejo
// (anulado=1, la fila no desaparece) y los lectores de
// dinero lo excluyen desde ese instante vía la cola viva
// (el pendiente a entregar de Gabriel cae de 4000 a 2000
// sin esperar al pull). El recálculo de «pagado hasta»
// apilando desde los pagos restantes es la cadena C8 del
// servidor y baja con el pull (verificado en su serie).
//
// Papelera: «Recuperar» encola cambiar_estado a activo y
// el espejo lo refleja; «Recuperar y renovar» cobra
// PRIMERO y encola las dos ops juntas o ninguna
// (atomicidad Lote 1): aquí se completa la renovación y
// se verifica la pareja de ops.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/papelera.dart';

import 'jornada_ayudas.dart';

String _iso(DateTime d) => isoHabana(d).substring(0, 10);

Future<void> _sembrarAnular() async {
  final hoy = ahoraHabana();
  await LocalDb.instance.upsertMirror('clientes', 50, {
    'id': 50,
    'nombre': 'Anular Jornada',
    'estado': 'activo',
    'pagado_hasta': _iso(hoy.add(const Duration(days: 20))),
    'telefono': '58112233',
    'carnet': '900115',
    'sexo': 'M',
  }, 1);
  await LocalDb.instance.upsertMirror('pagos', 501, {
    'id': 501,
    'cliente_id': 50,
    'fecha': _iso(hoy.subtract(const Duration(days: 40))),
    'monto': 2000,
    'metodo': 'efectivo',
    'telegram_user_id': 1403501391,
  }, 1);
  await LocalDb.instance.upsertMirror('pagos', 502, {
    'id': 502,
    'cliente_id': 50,
    'fecha': _iso(hoy.subtract(const Duration(days: 10))),
    'monto': 2000,
    'metodo': 'efectivo',
    'telegram_user_id': 1403501391,
  }, 1);
}

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S20 · anular pago y papelera', () {
    testWidgets(
        'anular el último pago desde la ficha: motivo, '
        'deslizar, op y el dinero lo excluye al momento',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarAnular();
      expect(await pendienteEntrega(1403501391), 4000,
          reason: 'antes de anular, los dos pagos cuentan');
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const FichaScreen(clienteId: 50),
      ));
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      // Historial (pestaña Pagos y Notas): el pago reciente
      // es la primera entrada; su botón «Más acciones»
      // abre «Corregir pago».
      // Desplazar por pasos hasta que el ⋮ del pago entre
      // de verdad en pantalla (scrollUntilVisible lo daba
      // por visible estando aún bajo el pliegue).
      for (var i = 0; i < 8; i++) {
        if (find.byTooltip('Más acciones').evaluate().isNotEmpty &&
            tester
                    .getRect(find.byTooltip('Más acciones').first)
                    .bottom <
                780) {
          break;
        }
        await tester.drag(
            find.byType(Scrollable).first, const Offset(0, -350));
        await tester.pumpAndSettle();
      }
      toques.n++;
      await toques.tap(tester, find.byTooltip('Más acciones').first);
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Corregir pago'));
      await toques.tap(tester, find.text('Corregir pago'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Anular pago'));
      await toques.tap(tester, find.text('Anular pago'));
      await tester.pumpAndSettle();
      await jornadaEsperar(
          tester, find.text('Motivo (obligatorio)'));
      await toques.campo(
          tester,
          find.widgetWithText(TextField, 'Motivo (obligatorio)'),
          'Cobro duplicado');
      await tester.pumpAndSettle();
      // Confirmación deslizando (como en el Arqueo).
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(340, 0));
      toques.n++;
      await tester.pump();
      await tester.pump();
      // Las lecturas locales se hacen ENSEGUIDA: la marca
      // optimista es atómica con el encolado, y si el
      // servidor rechazara la op más tarde, el diseño la
      // revierte (en el arnés el respondedor la sella
      // rechazada en cuanto la red «responde»).
      final espejo = await LocalDb.instance.allMirror('pagos');
      final filaB =
          espejo.firstWhere((f) => f['id'] == 502, orElse: () => {});
      expect(filaB, isNotEmpty,
          reason: 'el pago anulado queda MARCADO, no '
              'desaparece del espejo');
      expect(filaB['anulado'], 1);
      expect(await LocalDb.instance.pagosAnuladosEnCola(),
          contains(502));
      expect(await pendienteEntrega(1403501391), 2000,
          reason: 'la caja lo refleja al momento: solo '
              'queda el pago bueno, sin esperar al pull');
      await jornadaDrenar(tester, vueltas: 8);
      final ops = await jornadaOpsTodas('anular_pago');
      expect(ops, hasLength(1));
      final p = jornadaPayloadDe(ops.single);
      expect(p['pago_id'], 502);
      expect(p['motivo'], 'Cobro duplicado');
      expect(toques.n, 6,
          reason: 'desplazar al historial + «Más acciones» '
              'del pago + «Corregir pago» del menú + Anular '
              'pago + campo del motivo + deslizar para '
              'confirmar = 6');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'papelera: recuperar reactiva; recuperar y renovar '
        'encola la pareja (estado + pago)', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final hoy = ahoraHabana();
      for (final (id, nombre) in [
        (51, 'Papelera Jornada'),
        (52, 'Renovar Jornada'),
      ]) {
        await LocalDb.instance.upsertMirror('clientes', id, {
          'id': id,
          'nombre': nombre,
          // La papelera de la app = estado 'inactivo' (el
          // vocabulario es activo/inactivo/eliminado).
          'estado': 'inactivo',
          'pagado_hasta':
              _iso(hoy.subtract(const Duration(days: 30))),
          'carnet': '900115',
          'sexo': 'F',
        }, 1);
      }
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const PapeleraScreen(),
      ));
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      // Recuperar (la primera fila: Papelera va antes que
      // Renovar por nombre).
      await jornadaEsperar(tester, find.text('Papelera Jornada'));
      await toques.tap(tester, find.text('Recuperar').first);
      await tester.pumpAndSettle();
      await jornadaEsperar(
          tester, find.text('Recuperar cliente'));
      await toques.tap(tester,
          find.descendant(
              of: find.byType(Dialog),
              matching: find.text('Recuperar')));
      await jornadaDrenar(tester, vueltas: 8);
      var ops = await jornadaOpsTodas('cambiar_estado');
      expect(ops, hasLength(1));
      expect(jornadaPayloadDe(ops.single)['cliente_id'], 51);
      expect(jornadaPayloadDe(ops.single)['estado'], 'activo');
      final c51 = (await LocalDb.instance.allMirror('clientes'))
          .firstWhere((c) => c['id'] == 51);
      expect(c51['estado'], 'activo',
          reason: 'el espejo refleja la recuperación sin '
              'esperar al pull: el tombstone se revierte '
              'localmente y la op lo lleva al servidor');

      // Recuperar y renovar al segundo: confirmar → el
      // diálogo de cobro → completar → la pareja de ops.
      await jornadaEsperar(tester, find.text('Renovar Jornada'));
      await toques.tap(tester, find.text('Renovar'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Continuar'));
      await toques.tap(tester, find.text('Continuar'));
      await tester.pumpAndSettle();
      // pagoDialogo abre preguntando por el vencido: un
      // recuperado de la papelera NO siguió viniendo (la
      // cadena arranca hoy, sin regalar ni cobrar el hueco).
      await jornadaEsperar(tester, find.text('No, dejó de venir'));
      await toques.tap(tester, find.text('No, dejó de venir'));
      await tester.pumpAndSettle();
      // pagoDialogo es un solo diálogo y su «Continuar» es
      // la aceptación (la papelera no pasa por el preview:
      // decisión documentada en el propio flujo).
      await jornadaEsperar(tester, find.text('Continuar'));
      await toques.tap(tester,
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Continuar')));
      await jornadaDrenar(tester, vueltas: 10);

      ops = await jornadaOpsTodas('cambiar_estado');
      expect(ops, hasLength(2));
      expect(
          ops.map((o) => jornadaPayloadDe(o)['cliente_id']).toSet(),
          {51, 52},
          reason: 'una recuperación simple y la de la '
              'renovación, sin duplicar ninguna');
      final pagos = await jornadaOpsTodas('pago_mensual');
      expect(pagos, hasLength(1),
          reason: 'la renovación encola el pago JUNTO al '
              'cambio de estado (atomicidad Lote 1)');
      expect(jornadaPayloadDe(pagos.single)['cliente_id'], 52);
      final c52 = (await LocalDb.instance.allMirror('clientes'))
          .firstWhere((c) => c['id'] == 52);
      expect(c52['estado'], 'activo');
      await jornadaCerrarCascara(tester);
    });
  });
}
