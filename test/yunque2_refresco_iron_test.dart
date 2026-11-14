/// Yunque 2.34 (F-2) — pin de `RefrescoIron`: el «tirar para
/// refrescar» de la app va en la marca. RefreshIndicator no
/// es temable en este SDK (lee colorScheme.primary = cobalto
/// en producción); el envoltorio fija el color y deja el
/// resto del comportamiento intacto.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  testWidgets('RefrescoIron pinta el indicador en naranja '
      'de marca, no en el primary del esquema', (tester) async {
    var refrescos = 0;
    await tester.pumpWidget(MaterialApp(
      // El tema de producción pone el primary en cobalto:
      // sin el envoltorio, el indicador saldría azul.
      theme: AppTema.sol(),
      home: Scaffold(
        body: RefrescoIron(
          onRefresh: () async => refrescos++,
          child: ListView(children: const [Text('contenido')]),
        ),
      ),
    ));
    final ri = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator));
    expect(ri.color, AppColores.naranja);
    expect(ri.color, isNot(AppColores.cobalto));
    // El hijo y el gesto quedan intactos.
    expect(find.text('contenido'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Yunque 3 (K3-1): el default de triggerMode debe ser el
  // del SDK (onEdge), no anywhere — el contrato del
  // envoltorio es «sin cambiar ningún comportamiento».
  testWidgets('RefrescoIron sin triggerMode usa onEdge '
      '(default del SDK)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(
        body: RefrescoIron(
          onRefresh: () async {},
          child: ListView(children: const [Text('contenido')]),
        ),
      ),
    ));
    final ri = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator));
    expect(ri.triggerMode, RefreshIndicatorTriggerMode.onEdge);
  });

  testWidgets('RefrescoIron respeta un triggerMode explícito',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(
        body: RefrescoIron(
          triggerMode: RefreshIndicatorTriggerMode.anywhere,
          onRefresh: () async {},
          child: ListView(children: const [Text('contenido')]),
        ),
      ),
    ));
    final ri = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator));
    expect(ri.triggerMode, RefreshIndicatorTriggerMode.anywhere);
  });
}
