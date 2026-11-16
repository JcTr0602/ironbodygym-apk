/// 1.35 (UX-02) — barra de pilares propia «Grafito».
///
/// Contrato: ya no es la NavigationBar de Material; flota
/// sobre grafito con la pastilla naranja plena en el
/// destino activo (icono y etiqueta en grafito, peso
/// fuerte), los inactivos en gris cálido fantasma; las 4
/// claves de destino, la insignia de urgencias y el toque
/// que selecciona se conservan.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/marco.dart';

Widget _host({int activo = 0, int urgencias = 0, bool esDueno = true}) {
  return MaterialApp(
    theme: AppTema.tacticoOscuro(),
    home: Scaffold(
      bottomNavigationBar: BarraPilares(
        key: const ValueKey('marco-pilares'),
        activo: activo,
        esDueno: esDueno,
        urgencias: urgencias,
        onTap: (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets('la barra es propia: sin NavigationBar, con '
      'cuerpo grafito y pastilla naranja en el activo',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(activo: 1, urgencias: 3));
    await tester.pump();

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('marco-pilares')),
        findsOneWidget);

    // Cuerpo grafito: el contenedor de la barra lleva el
    // token grafitoTactico.
    final cuerpos = tester
        .widgetList<Container>(find.descendant(
          of: find.byKey(const ValueKey('marco-pilares')),
          matching: find.byType(Container),
        ))
        .where((c) =>
            (c.decoration as BoxDecoration?)?.color ==
            AppColores.grafitoTactico);
    expect(cuerpos, isNotEmpty);

    // Pastilla naranja plena en el activo (Clientes).
    final pastillas = tester
        .widgetList<AnimatedContainer>(find.descendant(
          of: find.byKey(const ValueKey('pilar-tab-clientes')),
          matching: find.byType(AnimatedContainer),
        ))
        .where((c) =>
            (c.decoration as BoxDecoration?)?.color ==
            AppColores.naranja);
    expect(pastillas, isNotEmpty);

    // El inactivo (Mostrador) NO lleva pastilla naranja.
    final sinPastilla = tester
        .widgetList<AnimatedContainer>(find.descendant(
          of: find.byKey(const ValueKey('pilar-tab-mostrador')),
          matching: find.byType(AnimatedContainer),
        ))
        .where((c) =>
            (c.decoration as BoxDecoration?)?.color ==
            AppColores.naranja);
    expect(sinPastilla, isEmpty);

    // Insignia de urgencias sobre Mostrador.
    expect(find.text('3'), findsOneWidget);
    // Etiquetas siempre visibles, las 4.
    for (final e in ['Mostrador', 'Clientes', 'Tienda', 'Negocio']) {
      expect(find.text(e), findsOneWidget);
    }
  });

  testWidgets('con la letra al 200 % la barra crece sin '
      'reventar', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: _host(activo: 0),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Mostrador'), findsOneWidget);
  });

  testWidgets('el toque selecciona el pilar tocado',
      (tester) async {
    var tocado = -1;
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
        bottomNavigationBar: BarraPilares(
          activo: 0,
          esDueno: false,
          urgencias: 0,
          onTap: (i) => tocado = i,
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pilar-tab-tienda')));
    expect(tocado, 2);
    // El cuarto pilar del entrenador se llama «Mi Caja».
    expect(find.text('Mi Caja'), findsOneWidget);
  });
}
