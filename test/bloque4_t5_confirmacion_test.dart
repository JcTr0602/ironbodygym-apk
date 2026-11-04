/// Bloque 4 (T5/T6, 1.23): UNA sola gramática de confirmación
/// de éxito para cobrar y vender.
///
/// - [ConfirmacionOperacionScreen] es la pantalla compartida:
///   título configurable, marca animada, monto destacado (con
///   [MontoAnimado] si viene el valor numérico), filas de
///   detalle, comprobante y acción extra opcionales, y SIN
///   «Deshacer» cuando no hay opUuid.
/// - [ConfirmacionCobroScreen] sigue funcionando como
///   envoltorio fino del recibo de cobro (compatibilidad con
///   preview_cobro.dart): mismo título, mismas filas, mismo
///   monto; con montoValor pinta el monto con MontoAnimado.
///
/// El Deshacer con opUuid real (ventana de 15 s contra
/// ops_queue) lo cubre bloque1_deshacer_test.dart a nivel de BD.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/confirmacion_cobro.dart';

Widget _arnes(Widget pantalla) => MaterialApp(home: pantalla);

/// Empuja [pantalla] sobre una ruta raíz con un botón «abrir»,
/// para poder verificar la salida (pop) de «Entendido».
Widget _arnesConPush(Widget pantalla) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(
              MaterialPageRoute<void>(builder: (_) => pantalla),
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'T5 venta: título, marca, monto, detalles, comprobante y '
      'acción extra; sin Deshacer sin opUuid', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    var whatsappPulsado = false;
    await t.pumpWidget(_arnesConPush(ConfirmacionOperacionScreen(
      titulo: '¡Venta registrada!',
      etiquetaMonto: 'Total',
      monto: '1500 CUP',
      montoValor: 1500,
      montoFormato: (v) => '${v.toStringAsFixed(0)} CUP',
      detalles: const [
        (etiqueta: 'Producto', valor: 'Creatina ×2'),
        (etiqueta: 'Comprador', valor: 'Cliente externo'),
      ],
      comprobanteTitulo: 'Comprobante',
      comprobanteTexto: 'Comprobante de compra de prueba',
      accionExtra: AccionExtraConfirmacion(
        texto: 'Enviar por WhatsApp',
        icono: Icons.send_rounded,
        alPulsar: () => whatsappPulsado = true,
      ),
    )));
    await t.tap(find.text('abrir'));
    await t.pump();
    // Marca animada (350 ms) y conteo del monto (300 ms).
    await t.pump(const Duration(milliseconds: 400));

    expect(find.text('¡Venta registrada!'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget,
        reason: 'la marca de éxito animada es la del cobro');
    expect(find.byType(MontoAnimado), findsOneWidget,
        reason: 'T6: con montoValor el monto cuenta (MontoAnimado)');
    expect(find.text('1500 CUP'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('Producto'), findsOneWidget);
    expect(find.text('Creatina ×2'), findsOneWidget);
    expect(find.text('Comprador'), findsOneWidget);
    expect(find.text('Comprobante'), findsOneWidget);
    expect(find.text('Comprobante de compra de prueba'),
        findsOneWidget);
    expect(find.text('Enviar por WhatsApp'), findsOneWidget);
    expect(find.textContaining('Deshacer'), findsNothing,
        reason: 'sin opUuid no hay Deshacer (solo aplica al cobro)');

    // La acción extra se ejecuta (el comprobante no se pierde).
    await t.ensureVisible(find.text('Enviar por WhatsApp'));
    await t.tap(find.text('Enviar por WhatsApp'));
    await t.pump();
    expect(whatsappPulsado, isTrue);

    // Misma salida que el cobro: «Entendido» cierra la pantalla.
    await t.ensureVisible(find.text('Entendido'));
    await t.tap(find.text('Entendido'));
    await t.pumpAndSettle();
    expect(find.text('abrir'), findsOneWidget,
        reason: 'al cerrar se vuelve a la pantalla anterior');
    expect(find.text('¡Venta registrada!'), findsNothing);
  });

  testWidgets(
      'T5 cobro: la pantalla compartida sin extras no muestra '
      'ni WhatsApp ni comprobante', (t) async {
    await t.pumpWidget(_arnes(const ConfirmacionOperacionScreen(
      titulo: '¡Cobro registrado!',
      monto: '2000 CUP',
      detalles: [
        (etiqueta: 'Cliente', valor: 'María Pérez'),
        (etiqueta: 'Nuevo vencimiento', valor: '2026-12-03'),
      ],
    )));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('¡Cobro registrado!'), findsOneWidget);
    expect(find.text('2000 CUP'), findsOneWidget,
        reason: 'sin montoValor el monto queda fijo, como antes');
    expect(find.byType(MontoAnimado), findsNothing);
    expect(find.text('Enviar por WhatsApp'), findsNothing);
    expect(find.text('Comprobante'), findsNothing);
  });

  testWidgets(
      'compatibilidad: ConfirmacionCobroScreen conserva título, '
      'filas y monto del recibo de cobro', (t) async {
    await t.pumpWidget(_arnes(const ConfirmacionCobroScreen(
      nombreCliente: 'María Pérez',
      monto: '2000 CUP',
      nuevoVencimiento: '2026-12-03',
    )));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('¡Cobro registrado!'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.text('Monto'), findsOneWidget);
    expect(find.text('2000 CUP'), findsOneWidget);
    expect(find.text('Cliente'), findsOneWidget);
    expect(find.text('María Pérez'), findsOneWidget);
    expect(find.text('Nuevo vencimiento'), findsOneWidget);
    expect(find.text('2026-12-03'), findsOneWidget);
    expect(find.text('Entendido'), findsOneWidget);
    expect(find.textContaining('Deshacer'), findsNothing,
        reason: 'sin opUuid (llamadas viejas) no hay Deshacer');
  });

  testWidgets(
      'compatibilidad T6: ConfirmacionCobroScreen con montoValor '
      'pinta el monto con MontoAnimado', (t) async {
    await t.pumpWidget(_arnes(ConfirmacionCobroScreen(
      nombreCliente: 'María Pérez',
      monto: '2500 CUP',
      nuevoVencimiento: '2026-12-03',
      montoValor: 2500,
      montoFormato: (v) => '${v.toStringAsFixed(0)} CUP',
    )));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(MontoAnimado), findsOneWidget);
    expect(find.text('2500 CUP'), findsOneWidget);
  });
}
