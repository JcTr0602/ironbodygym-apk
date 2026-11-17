/// SL-3 · G01-1 — «Personalizar mi día» existe también con
/// los bloques presentes.
///
/// En la base (ead3d63): los únicos botones que abren el
/// editor de la estación diaria viven dentro del bloque de
/// vacío de _VistaHoyDueno/_VistaHoyEntrenador («Tu día está
/// vacío: ocultaste todos los bloques») — con bloques
/// visibles no hay forma de abrir el editor.
///
/// Corregido: una entrada permanente y discreta (un solo
/// IconButton, key mostrador-personalizar) en la cabecera
/// del Mostrador abre el mismo editor, con bloques o sin
/// ellos. Camino real: cáscara montada con los bloques por
/// defecto (todos presentes).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'con bloques presentes, la entrada discreta existe y '
      'abre el editor «Personalizar mi día»', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await jornadaMontarHome(tester);
    expect(tester.takeException(), isNull);
    // Control: NO estamos en el vacío de la estación (hay
    // bloques: la tarjeta del turno del entrenador existe).
    expect(find.text('Tu día está vacío: ocultaste todos los bloques.'),
        findsNothing);
    // F02-HD (z18_tests_sl3-1 r1): el control aserta EN
    // POSITIVO que los bloques por defecto están montados —
    // la ausencia del texto de vacío también la daría una
    // cáscara sin cuerpo del día. El bloque de alertas es el
    // primero de la estación: ya está en el árbol.
    expect(
        find.byKey(const ValueKey('hoy-alertas'), skipOffstage: false),
        findsOneWidget,
        reason: 'G01-1: con bloques presentes, el bloque de '
            'alertas de la estación está montado (no solo '
            'falta el texto de vacío)');
    final entrada = find.byKey(const ValueKey('mostrador-personalizar'));
    expect(entrada, findsOneWidget,
        reason: 'G01-1: la entrada al editor debe existir '
            'también con bloques presentes, en un sitio '
            'permanente y discreto de la cabecera del Mostrador');
    await tester.tap(entrada);
    await jornadaDrenar(tester, vueltas: 6, ms: 80);
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'la entrada abre el editor de la estación');
    expect(find.text('Personalizar mi día'), findsWidgets);
    // F02-HD (z18_tests_sl3-1 r1): y el segundo bloque por
    // defecto (finanzas: su turno y su dinero) también está
    // montado — se cierra el editor y se baja hasta él.
    await tester.tap(find.text('Cancelar'));
    await jornadaDrenar(tester, vueltas: 4, ms: 80);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('hoy-finanzas')), 250,
        scrollable: find.byType(Scrollable).first);
    await jornadaDrenar(tester, vueltas: 3, ms: 80);
    expect(find.byKey(const ValueKey('hoy-finanzas')),
        findsOneWidget,
        reason: 'G01-1: el bloque de finanzas de la estación '
            'está montado con los bloques por defecto');
    await jornadaCerrarCascara(tester);
  });
}
