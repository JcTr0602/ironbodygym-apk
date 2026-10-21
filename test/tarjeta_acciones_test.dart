// Etapa 4 · F3: widget tests de la tarjeta «Acciones» de la
// ficha (TarjetaAccionesCliente). Guardan la matriz de
// visibilidad acordada en el diseño v2: Renovación solo si está
// vencido; la fila de frío cambia de etiqueta según el estado;
// cada fila dispara SU callback; sin desbordes en pantalla
// estrecha con texto ampliado.
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
    bool vencido = false,
    bool congelado = false,
    void Function()? onProgreso,
    void Function()? onRenovar,
    void Function()? onCongelar,
    void Function()? onPapelera,
  }) {
    return TarjetaAccionesCliente(
      vencido: vencido,
      congelado: congelado,
      onProgreso: onProgreso ?? () {},
      onRenovar: onRenovar ?? () {},
      onCongelar: onCongelar ?? () {},
      onPapelera: onPapelera ?? () {},
    );
  }

  testWidgets('sin vencimiento: no hay Renovación; Congelar sí',
      (tester) async {
    await tester.pumpWidget(envolver(tarjeta()));
    expect(find.text('Progreso y Nutrición'), findsOneWidget);
    expect(find.text('Renovación rápida (1 mes)'), findsNothing);
    expect(find.text('Congelar'), findsOneWidget);
    expect(find.text('Descongelar'), findsNothing);
    expect(find.text('A papelera'), findsOneWidget);
  });

  testWidgets('vencido: aparece Renovación', (tester) async {
    await tester.pumpWidget(envolver(tarjeta(vencido: true)));
    expect(find.text('Renovación rápida (1 mes)'), findsOneWidget);
  });

  testWidgets('congelado: la fila dice Descongelar',
      (tester) async {
    await tester.pumpWidget(envolver(tarjeta(congelado: true)));
    expect(find.text('Descongelar'), findsOneWidget);
    expect(find.text('Congelar'), findsNothing);
  });

  testWidgets('cada fila dispara su callback', (tester) async {
    var progreso = 0, renovar = 0, congelar = 0, papelera = 0;
    await tester.pumpWidget(envolver(tarjeta(
      vencido: true,
      onProgreso: () => progreso++,
      onRenovar: () => renovar++,
      onCongelar: () => congelar++,
      onPapelera: () => papelera++,
    )));
    await tester.tap(find.text('Progreso y Nutrición'));
    await tester.tap(find.text('Renovación rápida (1 mes)'));
    await tester.tap(find.text('Congelar'));
    await tester.tap(find.text('A papelera'));
    expect(progreso, 1);
    expect(renovar, 1);
    expect(congelar, 1);
    expect(papelera, 1);
  });

  testWidgets('pantalla estrecha y texto 1.3x: sin desbordes',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(envolver(
      tarjeta(vencido: true, congelado: true),
      escalaTexto: 1.3,
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Descongelar'), findsOneWidget);
  });
}
