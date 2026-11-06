/// Gestión 1.25 · T04 — Un cliente que nunca pagó no
/// puede salir «AL DÍA» en verde.
///
/// La ficha convertía el pagado_hasta nulo en 999999 días
/// (centinela) y la cabecera pintaba el badge verde. Ahora
/// dias es anulable de punta a punta: null = insignia
/// neutra «SIN PAGOS» y anillo gris.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

Widget _cabecera({required int? dias, bool esCasa = false}) {
  return MaterialApp(
    home: Scaffold(
      body: CabeceraFicha(
        nombre: 'Cliente Prueba',
        foto: null,
        colorMarco: Colors.grey,
        esCasa: esCasa,
        dias: dias,
        heroTag: null,
        onFotoTap: null,
        onCambiarFoto: () {},
      ),
    ),
  );
}

void main() {
  testWidgets('nunca pagó (dias null): «SIN PAGOS», jamás «AL DÍA»',
      (tester) async {
    await tester.pumpWidget(_cabecera(dias: null));
    await tester.pump();
    expect(find.text('SIN PAGOS'), findsOneWidget);
    expect(find.text('AL DÍA'), findsNothing);
  });

  testWidgets('al día de verdad (30 días): «AL DÍA»', (tester) async {
    await tester.pumpWidget(_cabecera(dias: 30));
    await tester.pump();
    expect(find.text('AL DÍA'), findsOneWidget);
    expect(find.text('SIN PAGOS'), findsNothing);
  });

  testWidgets('vencido sigue vencido (-3)', (tester) async {
    await tester.pumpWidget(_cabecera(dias: -3));
    await tester.pump();
    expect(find.text('VENCIDO 3 DÍAS'), findsOneWidget);
  });

  testWidgets('la Casa manda su chip dorado aunque dias sea null',
      (tester) async {
    await tester.pumpWidget(_cabecera(dias: null, esCasa: true));
    await tester.pump();
    expect(find.text('Cuenta a la Casa'), findsOneWidget);
    expect(find.text('SIN PAGOS'), findsNothing);
  });

  test('BadgeEstado.desdeDias no cambia su semántica', () {
    expect(BadgeEstado.desdeDias(0).texto, 'VENCE HOY');
    expect(BadgeEstado.desdeDias(5).texto, 'VENCE EN 5 DÍAS');
    expect(BadgeEstado.desdeDias(30).texto, 'AL DÍA');
    expect(BadgeEstado.desdeDias(30).estado, EstadoMembresia.alDia);
  });
}
