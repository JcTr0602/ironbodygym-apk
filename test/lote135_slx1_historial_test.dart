/// LOTE SIGUIENTE 1.35 · SL-X1 · G05-4 y G05-6 (Historial de
/// ventas).
///
/// - G05-4: la fila `_fila` desbordaba 110 px a la derecha a
///   360 dp con nombre largo + 3 chips + 2 botones de dueño.
///   Discriminante: a 360 dp, con esa fila sembrada, no debe
///   haber excepción de layout (en la base salta el overflow).
/// - G05-6: el diálogo de filtros pintaba «Desde 2026-11-01»
///   en ISO crudo. Discriminante: con un rango aplicado, al
///   reabrir la hoja de filtros ningún texto contiene el ISO;
///   la fecha va con fmtFecha (01/11/2026).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';

import 'jornada_ayudas.dart';

const _nombreLargo =
    'Proteína Whey Gold Standard Edición Especial Chocolate Extremo 2 kg';

Future<void> _sembrarVenta(WidgetTester tester) async {
  await tester.runAsync(() async {
    await LocalDb.instance.upsertMirror('suplementos', 1, {
      'id': 1,
      'nombre': _nombreLargo,
      'precio_oficial': 1000.0,
    }, 1);
    await LocalDb.instance.upsertMirror('ventas_suplementos', 1, {
      'id': 1,
      'suplemento_id': 1,
      'precio': 2000.0,
      'cantidad': 1,
      'moneda': 'CUP',
      'total': 2000.0,
      'comprador_nombre': 'Comprador De Nombre También Muy Largo',
      'registrado_por_nombre': 'Gabriel',
      'fecha': '2026-11-01',
      'via_inscripcion': 1,
      'es_fiado': 1,
      'promo_mes': 0,
    }, 1);
  });
}

Future<void> _montar(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: const HistorialVentasScreen(),
  ));
  await jornadaDrenar(tester, vueltas: 10);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    // Roboto REAL (la del teléfono): con la fuente de test por
    // defecto (Ahem, más ancha) hasta filas sanas desbordan y
    // el discriminante no aislaría la fila de la ficha.
    await jornadaCargarRoboto();
  });

  testWidgets('G05-4 · fila con nombre largo, 3 chips y botones '
      'de dueño no desborda a 360 dp', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await _sembrarVenta(tester);
    await _montar(tester);
    // La fila está pintada con su información completa.
    expect(find.textContaining('Inscripción + venta'), findsWidgets);
    expect(find.textContaining('Precio diferente'), findsWidgets);
    expect(find.textContaining('Fiado'), findsWidgets);
    expect(tester.takeException(), isNull,
        reason: 'sin overflow de layout a 360 dp');
  });

  testWidgets('G05-6 · la hoja de filtros no pinta la fecha en '
      'ISO crudo', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await _sembrarVenta(tester);
    await _montar(tester);
    // Abrir filtros y fijar «Desde» eligiendo una fecha en el
    // selector (día 1 del mes mostrado por defecto no sirve:
    // se navega al 2026-11-01 vía el selector de año/mes del
    // propio DatePicker es frágil; en su lugar se aplica el
    // rango tocando el botón de fecha y aceptando la fecha
    // inicial que proponga, y se verifica el FORMATO).
    await tester.tap(find.textContaining('Filtrar'));
    await tester.pumpAndSettle();
    expect(find.text('Filtros'), findsOneWidget);
    await tester.tap(find.textContaining('Desde…'));
    await tester.pumpAndSettle();
    // El DatePicker propone hoy; se acepta con OK.
    // F02-HF (z30_slx1-1): el OK no es opcional — si el
    // selector no abrió, no hay rango aplicado y la
    // negativa de abajo pasaría de vacío.
    final ok = find.text('OK');
    expect(ok.evaluate().isNotEmpty, isTrue,
        reason: 'el selector de fecha debe abrir con su '
            'OK: sin él no se aplica rango alguno');
    await tester.tap(ok);
    await tester.pumpAndSettle();
    // Ningún texto de la hoja contiene una fecha ISO
    // (YYYY-MM-DD): «Desde» debe ir formateado.
    final textos = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    expect(RegExp(r'Desde \d{4}-\d{2}-\d{2}').hasMatch(textos), isFalse,
        reason: 'la fecha del filtro no va en ISO crudo');
    expect(textos, contains('Desde '));
    // El valor que la hoja muestra ya aplicado (formateado
    // por la propia pantalla) es el que debe PERSISTIR al
    // reabrir: se captura antes de «Aplicar».
    final desdeAntes = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((t) => t.startsWith('Desde ') && t != 'Desde…')
        .toList();
    expect(desdeAntes, hasLength(1),
        reason: 'tras el OK, la hoja muestra el «Desde» '
            'aplicado');
    expect(
        RegExp(r'^Desde \d{2}/\d{2}/\d{4}$')
            .hasMatch(desdeAntes.single),
        isTrue,
        reason: 'el «Desde» aplicado va formateado '
            '(dd/mm/aaaa), no en ISO: ${desdeAntes.single}');
    await tester.tap(find.text('Aplicar'));
    await tester.pumpAndSettle();
    // F02-HF: la medición manda DESPUÉS de aplicar — se
    // cierra la hoja, se REABRE y se afirman los valores
    // persistidos en la hoja reabierta.
    await tester.tap(find.textContaining('Filtrar'));
    await tester.pumpAndSettle();
    expect(find.text('Filtros'), findsOneWidget,
        reason: 'la hoja de filtros se reabre tras aplicar');
    final textosReabierta = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    for (final t in textosReabierta) {
      if (t.startsWith('Desde') || t.startsWith('Hasta')) {
        expect(RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(t), isFalse,
            reason: 'en la hoja reabierta ninguna fecha va '
                'en ISO crudo (ni «Desde: aaaa-mm-dd» ni '
                'variantes): «$t»');
      }
    }
    expect(textosReabierta, contains(desdeAntes.single),
        reason: 'al reabrir, el «Desde» persistido es el '
            'mismo que se aplicó: ${desdeAntes.single}');
  });
}
