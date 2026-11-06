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
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    // 1.25 T117 (F1-77/79/80): método con nombre completo y
    // sin paréntesis en crudo; micro-etiquetas en las filas;
    // desglose y «Desde hoy» cuando vienen.
    testWidgets('T117: método con nombre, etiquetas y desglose',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => DialogoConfirmarInscripcion.mostrar(
                ctx,
                nombre: 'Alberto Prueba',
                periodoEtiqueta: '3 meses',
                montoTxt: '7 500 CUP',
                desgloseTxt: '3 × 2 500 CUP',
                metodoPago: 'transferencia',
                validoHastaTxt: '05/02/2027',
                desdeTxt: 'Desde hoy, 05/11/2026',
                telefono: '58161619',
                carnet: '150520',
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Transferencia'), findsOneWidget);
      expect(find.text('(transferencia)'), findsNothing);
      expect(find.text('3 × 2 500 CUP'), findsOneWidget);
      expect(find.text('Desde hoy, 05/11/2026'), findsOneWidget);
      expect(find.text('Nombre'), findsOneWidget);
      expect(find.text('Período'), findsOneWidget);
      expect(find.text('Carnet'), findsOneWidget);
      expect(find.text('Teléfono'), findsOneWidget);
      expect(find.text('Vigencia'), findsOneWidget);
    });

    // 1.25 T117 (F1-78): el modo Casa muestra la condición sin
    // cobro y los datos de la persona, sin bloque de pago.
    testWidgets('T117: modo Casa sin bloque de pago',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => DialogoConfirmarInscripcion.mostrar(
                ctx,
                nombre: 'Melany Prueba',
                esCasa: true,
                sexo: 'Femenino',
                telefono: '58161619',
                carnet: '150520',
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Confirmar Cuenta a la Casa'), findsOneWidget);
      expect(find.text('Sin cobro · Sin vencimiento'), findsOneWidget);
      expect(find.text('Melany Prueba'), findsOneWidget);
      expect(find.text('Femenino'), findsOneWidget);
      expect(find.text('Válido hasta'), findsNothing);
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
