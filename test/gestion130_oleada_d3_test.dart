// (1.30 D3, UI130-14/15) Kit de formularios y HojaAccion:
// formato por campo (moneda, teléfono, fecha, cantidad),
// el andamio FormularioIron, la hoja única de la casa y
// las guardas de fuente de la oleada (fuera el Campo
// legacy, bottomSheetTheme presente, menos TextField
// crudos que en la base 1.30).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';

void main() {
  group('parseMoneda (puro)', () {
    test('acepta punto y coma como separador decimal', () {
      expect(parseMoneda('1500'), 1500);
      expect(parseMoneda('1500.50'), 1500.5);
      expect(parseMoneda('1500,50'), 1500.5);
      expect(parseMoneda(' 250 '), 250);
    });

    test('rechaza vacío, basura y no finitos', () {
      expect(parseMoneda(''), isNull);
      expect(parseMoneda('abc'), isNull);
      expect(parseMoneda('1.2.3'), isNull);
    });
  });

  group('FormateadorMoneda', () {
    const f = FormateadorMoneda();
    TextEditingValue v(String t) => TextEditingValue(text: t);

    test('un solo separador y hasta 2 decimales', () {
      expect(f.formatEditUpdate(v('12'), v('12.345')).text, '12');
      expect(f.formatEditUpdate(v('12'), v('12,3')).text, '12,3');
      expect(f.formatEditUpdate(v('1.2'), v('1.2.3')).text, '1.2');
      expect(f.formatEditUpdate(v(''), v('abc')).text, '');
      expect(f.formatEditUpdate(v(''), v('99')).text, '99');
    });
  });

  group('limpiarDigitosTelefono (puro)', () {
    test('el internacional pegado colapsa a los 8 locales', () {
      expect(limpiarDigitosTelefono('5358191577'), '58191577');
      expect(limpiarDigitosTelefono('+53 5819 1577'), '58191577');
    });

    test('el local se recorta a 8 y sin letras', () {
      expect(limpiarDigitosTelefono('581915779'), '58191577');
      expect(limpiarDigitosTelefono('58-19-15'), '581915');
      expect(limpiarDigitosTelefono(''), '');
    });
  });

  testWidgets('CampoTelefono: el controlador nunca guarda el +53',
      (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CampoTelefono(controller: ctrl)),
    ));
    await tester.enterText(find.byType(TextFormField), '5358191577');
    expect(ctrl.text, '58191577',
        reason: 'pegar el internacional deja los 8 dígitos limpios');
    await tester.enterText(find.byType(TextFormField), '51234567');
    expect(ctrl.text, '51234567');
  });

  testWidgets('CampoMoneda: sufijo de moneda y texto parseable',
      (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CampoMoneda(controller: ctrl)),
    ));
    expect(find.text('CUP'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '1250,5');
    expect(ctrl.text, '1250,5');
    expect(parseMoneda(ctrl.text), 1250.5);
  });

  testWidgets('CampoFecha: texto dd/mm/aaaa y botón de limpiar',
      (tester) async {
    DateTime? valor = DateTime(2026, 11, 8);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setS) => CampoFecha(
            valor: valor,
            onCambio: (f) => setS(() => valor = f),
          ),
        ),
      ),
    ));
    expect(find.text('08/11/2026'), findsOneWidget);
    await tester.tap(find.byTooltip('Limpiar fecha'));
    await tester.pump();
    expect(valor, isNull);
    expect(find.text('08/11/2026'), findsNothing);
  });

  testWidgets('CampoCantidad con paso: botones −/+ con clamp',
      (tester) async {
    final ctrl = TextEditingController(text: '10');
    addTearDown(ctrl.dispose);
    String? ultimo;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CampoCantidad(
          controller: ctrl,
          paso: 5,
          onChanged: (v) => ultimo = v,
        ),
      ),
    ));
    await tester.tap(find.byTooltip('Más'));
    expect(ctrl.text, '15');
    expect(ultimo, '15');
    await tester.tap(find.byTooltip('Menos'));
    await tester.tap(find.byTooltip('Menos'));
    await tester.tap(find.byTooltip('Menos'));
    expect(ctrl.text, '0', reason: 'el mínimo por defecto es 0');
  });

  testWidgets('FormularioIron: secciones, errores en línea y CTA',
      (tester) async {
    var toques = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FormularioIron(
          secciones: const [
            SeccionFormulario(
              titulo: 'Datos',
              icono: Icons.person_rounded,
              campos: [CampoTexto(etiqueta: 'Nombre')],
            ),
          ],
          errores: const ['Falta el nombre'],
          textoCta: 'Guardar',
          onCta: () => toques++,
        ),
      ),
    ));
    expect(find.text('Datos'), findsOneWidget);
    expect(find.text('Falta el nombre'), findsOneWidget,
        reason: 'el error va en línea, nunca un SnackBar tras el velo');
    await tester.tap(find.text('Guardar'));
    expect(toques, 1);
  });

  testWidgets(
      'showHojaIron: abre con título y cuerpo y el pie devuelve '
      'el resultado cerrando la HOJA', (tester) async {
    bool? resultado;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              resultado = await showHojaIron<bool>(
                ctx,
                titulo: 'Confirmar cosa',
                cuerpo: const Text('El cuerpo de la hoja'),
                pie: Builder(
                  builder: (ctxHoja) => ElevatedButton(
                    onPressed: () => Navigator.pop(ctxHoja, true),
                    child: const Text('Aceptar hoja'),
                  ),
                ),
              );
            },
            child: const Text('Abrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Confirmar cosa'), findsOneWidget);
    expect(find.text('El cuerpo de la hoja'), findsOneWidget);
    await tester.tap(find.text('Aceptar hoja'));
    await tester.pumpAndSettle();
    expect(resultado, isTrue);
    expect(find.text('Confirmar cosa'), findsNothing);
  });

  testWidgets(
      'HojaAccion: el pie sube con el teclado y la X cierra la hoja',
      (tester) async {
    // Contrato medido en el entorno de test: el route de la
    // hoja compensa parte del viewInsets (dentro de la hoja
    // se ven 100 de los 300 simulados), así que la prueba es
    // DIFERENCIAL: con teclado, el pie queda claramente más
    // arriba que sin teclado (el pie suma el viewInsets que
    // la hoja ve, el patrón que HojaLiquidar ya usaba).
    Future<double> abrirYMedirPie() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showHojaIron<void>(
                ctx,
                titulo: 'Hoja con teclado',
                cuerpo: const CampoTexto(etiqueta: 'Algo'),
                pie: const ElevatedButton(
                  onPressed: null,
                  child: Text('Acción del pie'),
                ),
              ),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      final bottom =
          tester.getRect(find.text('Acción del pie')).bottom;
      // Cerrar antes de la siguiente fase.
      await tester.tap(find.byTooltip('Cerrar'));
      await tester.pumpAndSettle();
      expect(find.text('Hoja con teclado'), findsNothing);
      return bottom;
    }

    final sinTeclado = await abrirYMedirPie();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    final conTeclado = await abrirYMedirPie();
    expect(conTeclado, lessThan(sinTeclado - 80),
        reason: 'el pie sube al abrirse el teclado '
            '(sin: $sinTeclado, con: $conTeclado)');
    expect(conTeclado, lessThanOrEqualTo(600));
  });

  group('guardas de fuente de la oleada', () {
    String leer(String rel) => File(rel).readAsStringSync();

    test('el Campo legacy salió de widgets.dart', () {
      expect(leer('lib/ui/widgets.dart').contains('class Campo extends'),
          isFalse);
    });

    test('el tema trae bottomSheetTheme', () {
      expect(leer('lib/ui/diseno.dart').contains('bottomSheetTheme'),
          isTrue);
    });

    test('los TextField crudos bajan frente a la base (128)', () {
      var n = 0;
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        n += 'TextField('.allMatches(f.readAsStringSync()).length;
      }
      // D3 retira: 2 de HojaLiquidar, 1 del Centro de Precios,
      // 2 de «Salida sin venta» y 1 de «Revertir venta» (los
      // diálogos viejos de servicios.dart).
      expect(n, lessThanOrEqualTo(122));
      expect(n, lessThan(128));
    });
  });
}
