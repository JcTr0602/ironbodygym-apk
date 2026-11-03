/// 1.22 Diseño Bloque 1 (orden de Argón): T1 transición
/// global, base B10 (IronAppBar = AppBar estándar), T3
/// cascada acotada (ventana 400 ms, máx. 10 ítems) y T7
/// cruce de estados con key por tipo de estado.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  test('T1: RutaIron impone 220 ms en entrada y salida', () {
    // Panel Bloque 1: el builder da la forma, la RUTA manda
    // la duración — sin RutaIron seguiría el default de
    // MaterialPageRoute y la promesa de 220 ms sería falsa.
    final ruta = RutaIron<void>(builder: (_) => const SizedBox());
    expect(ruta.transitionDuration,
        const Duration(milliseconds: 220));
    expect(ruta.reverseTransitionDuration,
        const Duration(milliseconds: 220));
    expect(ruta, isA<MaterialPageRoute<void>>(),
        reason: 'compatibilidad con código que espera '
            'MaterialPageRoute');
  });

  test('T1: el tema usa la transición del sistema en Android', () {
    final tema = AppTema.claro();
    final b =
        tema.pageTransitionsTheme.builders[TargetPlatform.android];
    expect(b, isA<TransicionPaginaIron>());
  });

  testWidgets('B10: IronAppBar ES un AppBar estándar', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        appBar: IronAppBar(title: Text('Servicios')),
        body: SizedBox(),
      ),
    ));
    expect(find.byType(AppBar), findsOneWidget,
        reason: 'find.byType(AppBar) debe seguir funcionando');
    expect(find.text('Servicios'), findsOneWidget);
    const barra = IronAppBar(title: Text('X'));
    expect(barra.preferredSize.height, kToolbarHeight);
  });

  testWidgets('T3: ítem dentro del cupo anima; fuera, no', (t) async {
    FadeEntrada.reiniciarVentana();
    await t.pumpWidget(const MaterialApp(
      home: Column(
        children: [
          FadeEntrada(indice: 0, child: Text('primero')),
          FadeEntrada(indice: 15, child: Text('quince')),
        ],
      ),
    ));
    // El ítem 15 va directo, sin AnimatedOpacity.
    expect(
      find.ancestor(
          of: find.text('quince'), matching: find.byType(AnimatedOpacity)),
      findsNothing,
    );
    // El ítem 0 sí anima: existe su AnimatedOpacity y al
    // asentarse la opacidad llega a 1.
    expect(
      find.ancestor(
          of: find.text('primero'),
          matching: find.byType(AnimatedOpacity)),
      findsOneWidget,
    );
    await t.pump(const Duration(milliseconds: 600));
    final op = t.widget<AnimatedOpacity>(find.ancestor(
        of: find.text('primero'),
        matching: find.byType(AnimatedOpacity)));
    expect(op.opacity, 1.0);
  });

  testWidgets('T7: CruceEstados cambia por tipo de estado sin romper',
      (t) async {
    Widget app(String estado, String texto) => MaterialApp(
          home: CruceEstados(
            estado: estado,
            child: Text(texto, textDirection: TextDirection.ltr),
          ),
        );
    await t.pumpWidget(app('cargando', 'espera'));
    expect(find.text('espera'), findsOneWidget);
    await t.pumpWidget(app('contenido', 'datos'));
    await t.pumpAndSettle();
    expect(find.text('datos'), findsOneWidget);
    // Mismo estado, datos nuevos: no hay destrucción del hijo.
    await t.pumpWidget(app('contenido', 'datos frescos'));
    expect(find.text('datos frescos'), findsOneWidget);
  });
}
