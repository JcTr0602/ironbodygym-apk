// 1.34 Campo 2 — B-3: en Suplementos, al scrollear manda
// el catálogo (orden de campo de Jc, 2026-11-14):
// - La cabecera (promo + buscador + categorías) se pliega
//   al bajar y reaparece al subir o al volver arriba.
// - «Más vendidos» ya no es una banda fija al pie: cierra
//   el catálogo DENTRO del scroll, tras el último
//   producto — la lista gana el alto que perdía.
// - Vender/buscar/filtrar/crear quedan a los mismos
//   toques (la cabecera vuelve con un gesto hacia arriba;
//   «Nuevo» vive en la barra, siempre visible).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/suplementos.dart';

import 'jornada_ayudas.dart';

Future<void> _sembrarCatalogo() async {
  for (var i = 1; i <= 14; i++) {
    await LocalDb.instance.upsertMirror('suplementos', i, {
      'id': i,
      'nombre': 'Producto Campo $i',
      'precio': 1000 + i * 100,
      'precio_oficial': 1000 + i * 100,
      'stock': 5,
      'moneda': 'CUP',
      'activo': 1,
    }, 1);
  }
  await LocalDb.instance.upsertMirror('categorias_suplemento', 1, {
    'id': 1,
    'nombre': 'Proteínas',
    'activa': 1,
  }, 1);
  // Ventas para que «Más vendidos» exista (top por SQL).
  for (var v = 0; v < 3; v++) {
    await LocalDb.instance.upsertMirror('ventas_suplementos', 100 + v, {
      'id': 100 + v,
      'suplemento_id': 1,
      'cantidad': 3,
      'anulada': 0,
      'activo': 1,
    }, 1);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'al bajar se pliega la cabecera y «Más vendidos» '
      'espera al final del catálogo; al subir, la cabecera '
      'vuelve', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(_sembrarCatalogo);
    jornadaViewport(tester);

    await tester.pumpWidget(const MaterialApp(
      home: SuplementosScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Producto Campo 1'));

    // Arriba: la cabecera está y «Más vendidos» NO compite
    // en el primer pantallazo (vive tras el catálogo).
    expect(find.text('Buscar suplemento…'), findsOneWidget);
    expect(find.text('Más vendidos'), findsNothing);

    // Bajar por el catálogo: la cabecera se pliega.
    await tester.fling(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
        1200);
    await tester.pumpAndSettle();
    expect(find.text('Buscar suplemento…'), findsNothing,
        reason: 'al scrollear, la cabecera cede su alto a '
            'la lista');

    // Seguir bajando hasta el final: ahí cierra «Más
    // vendidos», dentro del scroll.
    await tester.scrollUntilVisible(find.text('Más vendidos'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Más vendidos'), findsOneWidget);

    // Subir: la cabecera reaparece (buscar/filtrar a un
    // gesto, como antes a cero).
    await tester.fling(
        find.byType(CustomScrollView).first,
        const Offset(0, 600),
        1200);
    await tester.pumpAndSettle();
    expect(find.text('Buscar suplemento…'), findsOneWidget);
  });
}
