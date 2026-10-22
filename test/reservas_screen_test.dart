// Reservas v2 — pantalla de la bandeja (panel Gestión
// 2026-10-21): puerta de permiso en la propia pantalla y
// bloqueo de la tarjeta con una op encolada. La tarjeta es un
// widget sin dependencias de BD/sync: se prueba directo.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/reservas.dart';

ReservaVista _vista({
  String estado = 'solicitada',
  String moneda = 'CUP',
  String monedaVigente = 'CUP',
  double precioUnitario = 3000,
  double precioVigente = 3000,
}) =>
    ReservaVista(
      id: 5,
      clienteId: 7,
      clienteNombre: 'Ana',
      suplementoId: 3,
      suplementoNombre: 'Creatina',
      cantidad: 1,
      precioUnitario: precioUnitario,
      precioVigente: precioVigente,
      moneda: moneda,
      monedaVigente: monedaVigente,
      estado: estado,
      creadaTs: '2026-10-21T10:00:00-04:00',
      expiraEn: '2026-10-22T10:00:00-04:00',
      notaResolucion: null,
    );

Widget _envolver(Widget hijo) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: hijo)),
    );

void main() {
  testWidgets('sin permiso no se ve la bandeja aunque se abra '
      'la pantalla directamente', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: ReservasScreen(accesoPermitido: false)));
    await tester.pumpAndSettle();
    expect(find.textContaining('No tienes permiso'), findsOneWidget);
    expect(find.text('Solicitadas (1)'), findsNothing);
  });

  testWidgets('tarjeta bloqueada: chip visible y sin botones '
      'de acción', (tester) async {
    await tester.pumpWidget(_envolver(TarjetaReserva(
      reserva: _vista(),
      bloqueada: true,
      onConfirmar: () {},
      onRechazar: () {},
      onCancelar: () {},
      onCobrar: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Ana'), findsOneWidget);
    expect(
        find.text('Acción encolada — sincronizando'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Confirmar'),
        findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Rechazar'),
        findsNothing);
  });

  testWidgets('tarjeta libre solicitada: Confirmar y Rechazar '
      'presentes y operativos', (tester) async {
    var confirmada = false;
    await tester.pumpWidget(_envolver(TarjetaReserva(
      reserva: _vista(),
      bloqueada: false,
      onConfirmar: () => confirmada = true,
      onRechazar: () {},
      onCancelar: () {},
      onCobrar: () {},
    )));
    await tester.pumpAndSettle();
    expect(
        find.text('Acción encolada — sincronizando'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
    expect(confirmada, isTrue);
  });

  testWidgets('tarjeta reservada bloqueada tampoco ofrece '
      'Cobrar ni Cancelar', (tester) async {
    await tester.pumpWidget(_envolver(TarjetaReserva(
      reserva: _vista(estado: 'reservada'),
      bloqueada: true,
      onConfirmar: () {},
      onRechazar: () {},
      onCancelar: () {},
      onCobrar: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Cobrar'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Cancelar'),
        findsNothing);
    expect(
        find.text('Acción encolada — sincronizando'), findsOneWidget);
  });

  testWidgets('tarjeta con moneda del catálogo distinta al '
      'snapshot: aviso de precio hoy sin diferencia numérica',
      (tester) async {
    await tester.pumpWidget(_envolver(TarjetaReserva(
      reserva: _vista(
        estado: 'reservada',
        moneda: 'CUP',
        monedaVigente: 'USD',
        precioUnitario: 3000,
        precioVigente: 45,
      ),
      bloqueada: false,
      onConfirmar: () {},
      onRechazar: () {},
      onCancelar: () {},
      onCobrar: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Precio hoy'), findsOneWidget);
    expect(find.textContaining('Se cobra el precio al reservar'),
        findsOneWidget);
    expect(find.textContaining('diferencia'), findsNothing);
  });

  testWidgets('tarjeta con monedas coincidentes: sin aviso de '
      'moneda distinta', (tester) async {
    await tester.pumpWidget(_envolver(TarjetaReserva(
      reserva: _vista(estado: 'reservada'),
      bloqueada: false,
      onConfirmar: () {},
      onRechazar: () {},
      onCancelar: () {},
      onCobrar: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Precio hoy'), findsNothing);
  });
}
