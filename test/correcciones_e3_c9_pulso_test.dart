/// 1.35 (corrección E3, C9-01 del Yunque de Cambios): el
/// pulso del icono de sync de la cabecera ignoraba el
/// movimiento reducido: el listener disparaba
/// `_pulso.forward()` sin consultar `disableAnimations`
/// y el build aplicaba el `ScaleTransition`
/// incondicionalmente (el giro SÍ estaba guardado). Con
/// el ajuste de movimiento reducido activo, el icono
/// seguía latiendo.
///
/// Discriminante: sobre la base de074a6, con
/// disableAnimations activo el árbol contiene el
/// ScaleTransition igual (rojo); con la corrección no
/// hay ScaleTransition y el botón se pinta tal cual.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/widgets.dart';

void main() {
  group('E3 · C9-01: IconoSyncCabecera y el movimiento '
      'reducido', () {
    Future<void> montar(WidgetTester tester,
        {required bool reducido}) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(disableAnimations: reducido),
          child: Scaffold(
            body: IconoSyncCabecera(onTap: () {}),
          ),
        ),
      ));
      await tester.pump();
    }

    // El buscador se acota al icono: el MaterialApp trae
    // su propio ScaleTransition (transición de página).
    Finder pulsoDelIcono() => find.descendant(
        of: find.byType(IconoSyncCabecera),
        matching: find.byType(ScaleTransition));
    Finder botonDelIcono() => find.descendant(
        of: find.byType(IconoSyncCabecera),
        matching: find.byType(IconButton));

    testWidgets('con movimiento reducido: sin '
        'ScaleTransition, el botón sigue ahí',
        (tester) async {
      await montar(tester, reducido: true);
      expect(pulsoDelIcono(), findsNothing);
      expect(botonDelIcono(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('con movimiento normal: el pulso envuelve '
        'el botón como siempre', (tester) async {
      await montar(tester, reducido: false);
      expect(pulsoDelIcono(), findsOneWidget);
      expect(botonDelIcono(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
