/// 1.22 Diseño Bloque 2 Paso 1: las secciones extraídas de
/// la Ficha (FilaInfoFicha, BarraMesFicha, Resumen360Ficha)
/// son vistas tontas — renderizan igual que los métodos
/// privados originales con los mismos datos.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  testWidgets('FilaInfoFicha: icono, etiqueta y valor', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: FilaInfoFicha(
          icono: Icons.badge_rounded,
          etiqueta: 'Carnet',
          valor: '950620',
        ),
      ),
    ));
    expect(find.text('Carnet'), findsOneWidget);
    expect(find.text('950620'), findsOneWidget);
    expect(find.byIcon(Icons.badge_rounded), findsOneWidget);
  });

  testWidgets('BarraMesFicha: sin pagos no pinta nada', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: BarraMesFicha()),
    ));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('BarraMesFicha: rango vigente muestra días restantes',
      (t) async {
    final hoy = ahoraHabana();
    final ini = hoy.subtract(const Duration(days: 10));
    final fin = hoy.add(const Duration(days: 20));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BarraMesFicha(
          fechaInicioRaw: _iso(ini),
          pagadoHastaRaw: _iso(fin),
        ),
      ),
    ));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Quedan 20 días del mes pagado'), findsOneWidget);
  });

  testWidgets('TarjetaHistorialFicha: vacío y con un pago',
      (t) async {
    Widget app(List<Map<String, dynamic>> entradas) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TarjetaHistorialFicha(
                entradas: entradas,
                filtro: 'todo',
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
    await t.pumpWidget(app(const []));
    expect(find.text('Historial'), findsOneWidget);
    expect(find.text('Sin movimientos en este filtro'),
        findsOneWidget);

    await t.pumpWidget(app([
      {
        'tipo': 'pago',
        'titulo': 'Pago de mensualidad',
        'subtitulo': 'Efectivo',
        'trailing': '2000',
        'color': Colors.green,
        'icono': Icons.payments_rounded,
        'pago': {'metodo': 'efectivo', 'monto': 2000},
      },
    ]));
    expect(find.text('Pago de mensualidad'), findsOneWidget);
    // Sin rol admin/dueño no hay botones de corregir ni
    // conciliar; el recibo sí (pago real en efectivo).
    expect(find.byIcon(Icons.tune_rounded), findsNothing);
    expect(find.byIcon(Icons.fact_check_rounded), findsNothing);
    expect(find.byIcon(Icons.share_rounded), findsOneWidget);
  });

  testWidgets('Resumen360Ficha: n, total y método preferido',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Resumen360Ficha(
          resumen: (n: 7, total: 14000.0, metodoTop: 'efectivo'),
        ),
      ),
    ));
    expect(find.text('7'), findsOneWidget);
    expect(find.text('14000'), findsOneWidget);
    expect(find.text('pagos'), findsOneWidget);
    expect(find.text('CUP total'), findsOneWidget);
    expect(find.byIcon(Icons.payments_rounded), findsOneWidget);
  });
}
