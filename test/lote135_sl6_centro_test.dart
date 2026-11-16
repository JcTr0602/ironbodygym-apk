/// SL-6 · Extracto de compras (centro_compras.dart):
/// - G05-6: las fechas de las filas (y el detalle) salen
///   con fmtFecha, nunca ISO crudo.
/// - G05-3: la cabecera del Extracto NO queda fija sobre
///   la lista: vive dentro del mismo scroll y la lista
///   manda (al desplazar, la cabecera se mueve con ella).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/centro_compras.dart';

import 'jornada_ayudas.dart';

Future<void> _sembrarVenta() async {
  await LocalDb.instance.upsertMirror('suplementos', 1, {
    'id': 1,
    'nombre': 'Creatina Centro',
    'precio_oficial': 500,
    'stock': 9,
    'moneda': 'CUP',
    'activo': 1,
  }, 1);
  for (var i = 1; i <= 12; i++) {
    await LocalDb.instance.upsertMirror('ventas_suplementos', i, {
      'id': i,
      'suplemento_id': 1,
      'cantidad': 1,
      'precio': 500,
      'total': 500,
      'moneda': 'CUP',
      'fecha': '2026-11-03',
      'anulada': 0,
    }, i);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G05-6: la fila del Extracto pinta la fecha habanera, '
      'no la ISO', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(_sembrarVenta);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: CentroComprasScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(
        tester, find.textContaining('Creatina Centro'));
    expect(find.textContaining('03/11/2026'), findsWidgets,
        reason: 'fmtFecha: 2026-11-03 → 03/11/2026');
    expect(find.textContaining('2026-11-03'), findsNothing,
        reason: 'G05-6: nada de ISO crudo en las filas');
  });

  testWidgets(
      'G05-3: al desplazar la lista, la cabecera del '
      'Extracto se mueve con el scroll (no queda fija)',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(_sembrarVenta);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: CentroComprasScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    final cabecera = find.textContaining('Total general:');
    await jornadaEsperar(tester, cabecera);
    final antes = tester.getTopLeft(cabecera).dy;
    await tester.drag(
        find.byType(ListView).first, const Offset(0, -320));
    await tester.pump(const Duration(milliseconds: 300));
    await jornadaDrenar(tester, vueltas: 3);
    final despues = cabecera.evaluate().isEmpty
        ? -10000.0 // salió por arriba: también vale (se movió)
        : tester.getTopLeft(cabecera).dy;
    expect(despues, lessThan(antes - 40),
        reason: 'G05-3: la cabecera forma parte del scroll; '
            'antes quedaba fija en dy=$antes');
  });
}
