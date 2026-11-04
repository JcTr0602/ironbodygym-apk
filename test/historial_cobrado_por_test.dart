/// 1.23 (backlog de campo): el historial de pagos de la ficha
/// muestra quién cobró cada pago («Cobró: Gabriel») cuando el
/// espejo trae `registrado_por`, y NO muestra nada cuando viene
/// vacío (las filas viejas quedan como siempre).
///
/// - El formateador `textoCobradoPor` (negocio.dart) es la
///   fuente única del texto: con dato devuelve la línea y sin
///   dato devuelve ''.
/// - La ficha compone el subtítulo añadiendo '\n' + línea solo
///   si el formateador devolvió algo; aquí se fija el render de
///   la fila (TarjetaHistorialFicha) con los dos subtítulos.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

void main() {
  group('textoCobradoPor', () {
    test('con nombre devuelve la línea «Cobró: …»', () {
      expect(textoCobradoPor('Gabriel'), 'Cobró: Gabriel');
      expect(textoCobradoPor('  Duany  '), 'Cobró: Duany');
    });

    test('sin dato devuelve vacío (no se muestra nada)', () {
      expect(textoCobradoPor(null), '');
      expect(textoCobradoPor(''), '');
      expect(textoCobradoPor('   '), '');
    });
  });

  testWidgets(
      'TarjetaHistorialFicha: la fila con cobrador lo muestra; '
      'la fila sin cobrador no muestra ninguna línea «Cobró»',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TarjetaHistorialFicha(
            entradas: [
              {
                'tipo': 'pago',
                'titulo': 'Efectivo',
                // Subtítulo tal como lo compone la ficha cuando
                // el espejo trae registrado_por = 'Gabriel'.
                'subtitulo': '04/11/2026 · mensual\nCobró: Gabriel',
                'trailing': '2000 CUP',
                'color': Colors.green,
                'icono': Icons.payments_rounded,
                'pago': {'metodo': 'efectivo', 'monto': 2000},
              },
              {
                'tipo': 'pago',
                'titulo': 'Efectivo',
                // Fila vieja sin registrado_por: una sola línea.
                'subtitulo': '05/10/2026 · mensual',
                'trailing': '2000 CUP',
                'color': Colors.green,
                'icono': Icons.payments_rounded,
                'pago': {'metodo': 'efectivo', 'monto': 2000},
              },
            ],
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
    ));
    expect(find.textContaining('Cobró: Gabriel'), findsOneWidget);
    // Ninguna otra fila inventa un cobrador ni deja la marca
    // «No registrado» de la versión anterior.
    expect(find.textContaining('Cobró:'), findsOneWidget);
    expect(find.textContaining('No registrado'), findsNothing);
  });
}
