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
import 'package:ironbody_gym/ui/home.dart';

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
    await jornadaCerrarCascara(tester);
  });
}
