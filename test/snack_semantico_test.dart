import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

Widget _app(SignificadoChip significado, String mensaje) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () =>
                mostrarSnack(context, mensaje, significado: significado),
            child: const Text('mostrar'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('mostrarSnack exito: icono de check y texto visibles',
      (tester) async {
    await tester.pumpWidget(_app(SignificadoChip.exito, 'Pago registrado'));
    await tester.tap(find.text('mostrar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Pago registrado'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
  });

  testWidgets('mostrarSnack error: icono de error y texto visibles',
      (tester) async {
    await tester.pumpWidget(_app(SignificadoChip.error, 'No se pudo guardar'));
    await tester.tap(find.text('mostrar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No se pudo guardar'), findsOneWidget);
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
  });
}
