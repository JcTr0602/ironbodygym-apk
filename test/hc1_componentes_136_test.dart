/// H-C1 (1.36): componentes — 136-409, 136-410, 136-411,
/// 136-414, 136-415, 136-419 (parte confirmada de cada
/// fila PARCIAL).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

Widget _envolver(Widget w, {double ancho = 320}) => MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(
        body: SizedBox(width: ancho, child: w),
      ),
    );

void main() {
  testWidgets('136-410 · PuntoMetodo nombra el método y FilaLibro no desborda con monto extremo',
      (t) async {
    await t.pumpWidget(_envolver(const FilaLibro(
      concepto: 'Pago de mensualidad de un cliente con nombre largo',
      detalle: 'Detalle que también envuelve en dos líneas seguro',
      monto: '999.999.999,99 CUP + 888.888,88 USD',
      metodo: 'transferencia',
    )));
    expect(find.bySemanticsLabel('Método: transferencia'),
        findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      '136-411/419 · TarjetaDecision: cabecera sin desborde y selección marcada',
      (t) async {
    await t.pumpWidget(_envolver(const TarjetaDecision(
      icono: Icons.warning_amber_rounded,
      titulo: 'Incidencia de prueba',
      chipEstado: ChipEstado(
          texto: 'Pendiente de revisión larga',
          significado: SignificadoChip.alerta),
      contexto:
          'Contexto muy largo que antes desbordaba la cabecera entera',
      seleccionada: true,
    )));
    expect(t.takeException(), isNull);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.selected == true),
        findsWidgets);
  });

  testWidgets('136-409 · FormularioIron acota muchos errores sin romper',
      (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(
        body: FormularioIron(
          secciones: const [Text('Campo único')],
          errores: [for (var i = 0; i < 12; i++) 'Error número $i'],
          textoCta: 'Guardar',
          onCta: () {},
        ),
      ),
    ));
    expect(t.takeException(), isNull);
    expect(find.text('Guardar'), findsOneWidget);
    expect(find.text('Error número 0'), findsOneWidget);
  });

  testWidgets('136-415 · CampoTexto declara sus bordes de error', (t) async {
    await t.pumpWidget(_envolver(CampoTexto(
      etiqueta: 'Nombre',
      errorText: 'Obligatorio',
      controller: TextEditingController(),
    )));
    final campo = t.widget<TextField>(find.byType(TextField));
    expect(campo.decoration?.errorBorder, isNotNull);
    expect(campo.decoration?.focusedErrorBorder, isNotNull);
  });

  testWidgets('136-414 · el aviso de carnet usa el alerta del tema',
      (t) async {
    await t.pumpWidget(_envolver(const AvisoCarnetTelefono()));
    final texto = t.widget<Text>(find.textContaining('parece un número'));
    expect(
        texto.style?.color, AppColores.alertaTextoClaro);
  });
}
