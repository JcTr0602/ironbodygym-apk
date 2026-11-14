// Etapa 4 · F3: widget tests de la tarjeta «Acciones» de la
// ficha (TarjetaAccionesCliente). Guardan la matriz de
// visibilidad acordada en el diseño v2: la fila de frío
// cambia de etiqueta según el estado; cada fila dispara SU
// callback; sin desbordes en pantalla estrecha con texto
// ampliado.
// 1.30 (Oleada 10, FICHA-12): la tarjeta YA NO trae
// «Progreso y Nutrición» ni «Renovación rápida». Progreso
// queda con UNA sola puerta en la ficha (la tarjeta de la
// última medida) y Renovar vive junto a la Membresía.
// Estos tests fijan el contrato nuevo: esas dos filas no
// vuelven a la tarjeta.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  Widget envolver(Widget w, {double escalaTexto = 1.0}) {
    return MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
              textScaler: TextScaler.linear(escalaTexto)),
          child: SingleChildScrollView(child: w),
        ),
      ),
    );
  }

  TarjetaAccionesCliente tarjeta({
    bool congelado = false,
    void Function()? onCongelar,
    void Function()? onPapelera,
    bool conCongelar = true,
    bool conPapelera = true,
  }) {
    return TarjetaAccionesCliente(
      congelado: congelado,
      onCongelar: conCongelar ? (onCongelar ?? () {}) : null,
      onPapelera: conPapelera ? (onPapelera ?? () {}) : null,
    );
  }

  testWidgets('solo Congelar y A papelera; FICHA-12: ni '
      'Progreso ni Renovación viven ya aquí', (tester) async {
    await tester.pumpWidget(envolver(tarjeta()));
    expect(find.text('Congelar'), findsOneWidget);
    expect(find.text('Descongelar'), findsNothing);
    expect(find.text('A papelera'), findsOneWidget);
    expect(find.text('Progreso y Nutrición'), findsNothing);
    expect(find.text('Renovación rápida (1 mes)'), findsNothing);
  });

  testWidgets('congelado: la fila dice Descongelar',
      (tester) async {
    await tester.pumpWidget(envolver(tarjeta(congelado: true)));
    expect(find.text('Descongelar'), findsOneWidget);
    expect(find.text('Congelar'), findsNothing);
  });

  testWidgets('Yunque 1.34 (C5-4): sin callback de congelar '
      '(sesión de entrenador) la fila NO existe; la papelera sí',
      (tester) async {
    await tester.pumpWidget(envolver(tarjeta(conCongelar: false)));
    expect(find.text('Congelar'), findsNothing);
    expect(find.text('Descongelar'), findsNothing);
    expect(find.text('A papelera'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Yunque 2.34 (D-1): sin callback de papelera '
      '(sesión de entrenador) la fila NO existe; congelar sí',
      (tester) async {
    await tester.pumpWidget(envolver(tarjeta(conPapelera: false)));
    expect(find.text('A papelera'), findsNothing);
    expect(find.text('Congelar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cada fila dispara su callback', (tester) async {
    var congelar = 0, papelera = 0;
    await tester.pumpWidget(envolver(tarjeta(
      onCongelar: () => congelar++,
      onPapelera: () => papelera++,
    )));
    await tester.tap(find.text('Congelar'));
    await tester.tap(find.text('A papelera'));
    expect(congelar, 1);
    expect(papelera, 1);
  });

  testWidgets('pantalla estrecha y texto 1.3x: sin desbordes',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(envolver(
      tarjeta(congelado: true),
      escalaTexto: 1.3,
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Descongelar'), findsOneWidget);
  });
}
