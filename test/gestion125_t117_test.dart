/// 1.25 T117 (Ficha): F1-31 la barra del período nombra el
/// período real por su duración (semana/quincena/mes/período);
/// F1-37 el fiado va fijado arriba con cualquier filtro;
/// F1-38 el historial pinta con tope y «Ver todo», y el vacío
/// de «Todo» no sugiere otro filtro.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _pago(int n) => {
      'tipo': 'pago',
      'titulo': 'Pago $n',
      'subtitulo': 'Efectivo',
      'trailing': '2000',
      'color': Colors.green,
      'icono': Icons.payments_rounded,
      'pago': {'metodo': 'efectivo', 'monto': 2000},
    };

Widget _historial(List<Map<String, dynamic>> entradas,
        {String filtro = 'todo'}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TarjetaHistorialFicha(
            entradas: entradas,
            filtro: filtro,
            onFiltro: (_) {},
            serviciosHist: const [],
            clienteId: 1,
            esAdmin: false,
            esOwner: false,
            onReenviarRecibo: (_) {},
            onVerComprobante: (_) {},
            onCorregirPago: (_) {},
            onConciliar: (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('BarraMesFicha: 7 días dice «la semana pagada»',
      (t) async {
    final hoy = ahoraHabana();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BarraMesFicha(
          fechaInicioRaw: _iso(hoy.subtract(const Duration(days: 2))),
          pagadoHastaRaw: _iso(hoy.add(const Duration(days: 5))),
        ),
      ),
    ));
    expect(find.text('Quedan 5 días de la semana pagada'),
        findsOneWidget);
  });

  testWidgets('BarraMesFicha: 15 días dice «la quincena pagada»',
      (t) async {
    final hoy = ahoraHabana();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BarraMesFicha(
          fechaInicioRaw: _iso(hoy.subtract(const Duration(days: 5))),
          pagadoHastaRaw: _iso(hoy.add(const Duration(days: 10))),
        ),
      ),
    ));
    expect(find.text('Quedan 10 días de la quincena pagada'),
        findsOneWidget);
  });

  testWidgets('BarraMesFicha: 60 días dice «el período pagado»',
      (t) async {
    final hoy = ahoraHabana();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BarraMesFicha(
          fechaInicioRaw: _iso(hoy.subtract(const Duration(days: 10))),
          pagadoHastaRaw: _iso(hoy.add(const Duration(days: 50))),
        ),
      ),
    ));
    expect(find.text('Quedan 50 días del período pagado'),
        findsOneWidget);
  });

  testWidgets(
      'Historial: tope de 8 y «Ver todo» despliega el resto',
      (t) async {
    await t.pumpWidget(
        _historial([for (var i = 1; i <= 10; i++) _pago(i)]));
    expect(find.text('Pago 1'), findsOneWidget);
    expect(find.text('Pago 8'), findsOneWidget);
    expect(find.text('Pago 9'), findsNothing);
    expect(find.text('Ver todo el historial (2 más)'),
        findsOneWidget);
    await t.ensureVisible(
        find.text('Ver todo el historial (2 más)'));
    await t.pumpAndSettle();
    await t.tap(find.text('Ver todo el historial (2 más)'));
    await t.pumpAndSettle();
    expect(find.text('Pago 9'), findsOneWidget);
    expect(find.text('Pago 10'), findsOneWidget);
    expect(find.text('Ver todo el historial (2 más)'), findsNothing);
  });

  testWidgets(
      'Historial: el fiado queda fijado arriba aun filtrando pagos',
      (t) async {
    final fiado = <String, dynamic>{
      'tipo': 'fiado',
      'titulo': 'Venta de suplemento · FIADO',
      'subtitulo': 'Hoy',
      'trailing': '600',
      'color': Colors.red,
      'icono': Icons.receipt_rounded,
    };
    await t.pumpWidget(
        _historial([_pago(1), fiado], filtro: 'pagos'));
    expect(find.text('Venta de suplemento · FIADO'), findsOneWidget);
    expect(find.text('Pago 1'), findsOneWidget);
  });

  testWidgets('Historial vacío: «Todo» y filtro dicen lo suyo',
      (t) async {
    await t.pumpWidget(_historial(const []));
    expect(find.text('Sin movimientos todavía'), findsOneWidget);
    await t.pumpWidget(_historial(const [], filtro: 'pagos'));
    expect(find.text('Sin movimientos en este filtro'),
        findsOneWidget);
  });
}
