import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/dialogo_confirmar_inscripcion.dart';

void main() {
  group('formatoTelefonoPresentacion', () {
    test('8 dígitos se formatean como 5 816 1619', () {
      expect(formatoTelefonoPresentacion('58161619'), '5 816 1619');
    });

    test('9 dígitos se devuelven tal cual (sin RangeError)', () {
      expect(formatoTelefonoPresentacion('581161619'), '581161619');
    });

    test('texto vacío se devuelve tal cual', () {
      expect(formatoTelefonoPresentacion(''), '');
    });

    test('con guiones se limpia y formatea', () {
      expect(formatoTelefonoPresentacion('5-816-1619'), '5 816 1619');
    });
  });

  group('DialogoConfirmarInscripcion', () {
    Future<void> pumpDialog(WidgetTester tester,
        {String? fotoPath, String telefono = '58161619'}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => DialogoConfirmarInscripcion.mostrar(
                ctx,
                nombre: 'Alberto Prueba',
                periodoEtiqueta: '1 mes',
                montoTxt: '1500 CUP',
                metodoPago: 'efectivo',
                validoHastaTxt: '15/11/2026',
                telefono: telefono,
                carnet: '150520',
                fotoPath: fotoPath,
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
    }

    testWidgets('muestra monto protagonista y datos con iconos',
        (tester) async {
      await pumpDialog(tester);
      expect(find.text('1500 CUP'), findsOneWidget);
      expect(find.text('Alberto Prueba'), findsOneWidget);
      expect(find.text('1 mes'), findsOneWidget);
      expect(find.text('150520'), findsOneWidget);
      expect(find.text('5 816 1619'), findsOneWidget);
      expect(find.text('Válido hasta 15/11/2026'), findsOneWidget);
      expect(find.text('Confirmar'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
    });

    testWidgets('sin foto muestra check naranja (fallback)',
        (tester) async {
      await pumpDialog(tester);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    // Nota: el errorBuilder con foto corrupta no se prueba aquí porque
    // el decoder de imágenes se cuelga en el entorno de tests.
    // La defensa (errorBuilder → check naranja) queda verificada por
    // revisión de código según directiva de Argón.

    testWidgets('Confirmar devuelve true', (tester) async {
      bool? resultado;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                resultado = await DialogoConfirmarInscripcion.mostrar(
                  ctx,
                  nombre: 'X',
                  periodoEtiqueta: '1 mes',
                  montoTxt: '1500 CUP',
                  metodoPago: 'efectivo',
                  validoHastaTxt: '15/11/2026',
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();
      expect(resultado, isTrue);
    });

    testWidgets('Cancelar devuelve false', (tester) async {
      bool? resultado;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                resultado = await DialogoConfirmarInscripcion.mostrar(
                  ctx,
                  nombre: 'X',
                  periodoEtiqueta: '1 mes',
                  montoTxt: '1500 CUP',
                  metodoPago: 'efectivo',
                  validoHastaTxt: '15/11/2026',
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(resultado, isFalse);
    });
  });
}
