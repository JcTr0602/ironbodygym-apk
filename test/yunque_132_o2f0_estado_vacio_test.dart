/// 1.32 (Oleada 2, Fase 0 — residuo 9b del veredicto
/// g132dis_): EstadoVacio ELÁSTICO.
///
/// El vacío compartido medía ~164 px + acolchado y se
/// recortaba en pantallas cortas (medido: 101 px a
/// 480×640 en el Pilar Clientes). Ahora: con < 200 px de
/// altura disponible compacta márgenes y figura — jamás
/// la tipografía — y con marco se envuelve en scroll
/// seguro: lo que no cabe scrollea, no se recorta.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

Widget _envolver(Widget w, {Size size = const Size(420, 800)}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => SizedBox(
          width: size.width,
          height: size.height,
          child: w,
        ),
      ),
    ),
  );
}

EstadoVacio _vacioCompleto() => EstadoVacio(
      icono: Icons.people_outline_rounded,
      titulo: 'Aún no hay clientes',
      subtitulo: 'Actualiza la lista o inscribe el primero.',
      textoAccion: 'Inscribir cliente',
      onAccion: () {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a 420×800 el vacío pleno se ve entero, sin excepción',
      (tester) async {
    await tester.pumpWidget(_envolver(_vacioCompleto()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Aún no hay clientes'), findsOneWidget);
    expect(find.text('Inscribir cliente'), findsOneWidget);
  });

  testWidgets('a 480×640 (el caso medido) no se recorta',
      (tester) async {
    await tester.pumpWidget(
        _envolver(_vacioCompleto(), size: const Size(480, 640)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Aún no hay clientes'), findsOneWidget);
    expect(
        find.text('Actualiza la lista o inscribe el primero.'),
        findsOneWidget);
  });

  testWidgets(
      'con < 200 px de alto compacta sin overflow y SIN encoger '
      'la tipografía', (tester) async {
    // La caja corta: 150 px para un vacío que pleno mide
    // más del doble.
    await tester.pumpWidget(_envolver(
      _vacioCompleto(),
      size: const Size(420, 150),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'el vacío compacto desborda en caja corta');
    expect(find.text('Aún no hay clientes'), findsOneWidget);

    // La tipografía es la misma que a altura plena.
    final fuenteCorta =
        tester.widget<Text>(find.text('Aún no hay clientes')).style;
    await tester.pumpWidget(_envolver(_vacioCompleto()));
    await tester.pump();
    final fuentePlena =
        tester.widget<Text>(find.text('Aún no hay clientes')).style;
    expect(fuenteCorta?.fontSize, fuentePlena?.fontSize);
    expect(fuenteCorta?.fontWeight, fuentePlena?.fontWeight);
  });

  testWidgets('sinMarco en caja corta tampoco desborda',
      (tester) async {
    await tester.pumpWidget(_envolver(
      const EstadoVacio(
        icono: Icons.filter_alt_off_rounded,
        titulo: 'Nadie cumple este filtro',
        subtitulo: 'Ningún cliente coincide.',
        sinMarco: true,
      ),
      size: const Size(420, 150),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Nadie cumple este filtro'), findsOneWidget);
  });
}
