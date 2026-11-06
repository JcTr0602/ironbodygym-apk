/// 1.25 T117 (Ficha): F1-31 la barra del período nombra el
/// período real por su duración (semana/quincena/mes/período);
/// F1-37 el fiado va fijado arriba con cualquier filtro;
/// F1-38 el historial pinta con tope y «Ver todo», y el vacío
/// de «Todo» no sugiere otro filtro.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _pago(int n, {String fecha = ''}) => {
      'tipo': 'pago',
      'fecha': fecha,
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

  // 1.25 T56: el tope de 8 con «Ver todo» (contrato de
  // T117/F1-38) lo sustituye el historial por meses
  // plegables: el mes reciente empieza abierto y los
  // demás solo enseñan su cabecera con conteo y suma.
  testWidgets(
      'Historial: meses plegables — el reciente abierto, '
      'el anterior solo con cabecera', (t) async {
    final hoy = ahoraHabana();
    final mesActual = _iso(hoy);
    final mesAnterior =
        _iso(DateTime(hoy.year, hoy.month - 1, 15));
    await t.pumpWidget(_historial([
      _pago(1, fecha: mesActual),
      _pago(2, fecha: mesActual),
      _pago(3, fecha: mesAnterior),
    ]));
    expect(find.text('Pago 1'), findsOneWidget);
    expect(find.text('Pago 2'), findsOneWidget);
    // El mes anterior está plegado: su pago no se ve,
    // pero su cabecera resume «1 pago · 2 000 CUP».
    expect(find.text('Pago 3'), findsNothing);
    expect(find.text('1 pago · ${fmtMonto(2000)} CUP'),
        findsOneWidget);
    // Al tocar la cabecera, el mes se despliega.
    await t.tap(find.text('1 pago · ${fmtMonto(2000)} CUP'));
    await t.pumpAndSettle();
    expect(find.text('Pago 3'), findsOneWidget);
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
