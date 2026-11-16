/// SL-3 · G02-1 — la barra de pasos de Inscribir no miente.
///
/// En la base (ead3d63): el paso «Membresía» se daba por
/// completo copiando el estado de «Datos» (ok: datosOk), con
/// reglas más flojas que las del guardado — con un período
/// personalizado sin días ni monto (que _guardarAhora
/// rechaza con «Indica días y monto válidos») la barra lo
/// pintaba completo. Y «Foto», siendo opcional, salía como
/// paso pendiente.
///
/// Camino real: pantalla de inscripción, nombre escrito,
/// período Personalizado elegido en su selector y días/monto
/// vacíos. La barra debe decir Membresía INCOMPLETA (sin el
/// check) y Foto marcada «opcional».
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/inscribir.dart';

import 'jornada_ayudas.dart';

/// La etiqueta de un paso EN LA BARRA (arriba de la
/// pantalla, y < 220): «Membresía» también es el título de
/// la sección de abajo y no debe confundirse con ella.
Finder _etiquetaEnBarra(WidgetTester tester, String texto) {
  for (final e in find.text(texto).evaluate()) {
    final f = find.byWidget(e.widget);
    if (tester.getTopLeft(f).dy < 220) return f;
  }
  return find.text(texto);
}

/// ¿El paso lleva el check de completo en su fila de la
/// barra? (La fila del paso: círculo + etiqueta.)
bool _pasoCompleto(WidgetTester tester, String etiqueta) {
  final row = find
      .ancestor(
          of: _etiquetaEnBarra(tester, etiqueta),
          matching: find.byType(Row))
      .first;
  return find
      .descendant(of: row, matching: find.byIcon(Icons.check_rounded))
      .evaluate()
      .isNotEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'personalizado sin días ni monto (el guardado lo '
      'rechaza): la barra NO da Membresía por completa y '
      'Foto se marca opcional', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: InscribirScreen()));
    await jornadaDrenar(tester);
    expect(tester.takeException(), isNull);

    // Nombre válido: «Datos» completo en cualquier versión.
    await tester.enterText(find.byType(TextField).first, 'Prueba Pasos Sl3');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_pasoCompleto(tester, 'Datos'), isTrue,
        reason: 'control: con nombre, Datos sí está completo');

    // Elegir «Personalizado…» en el selector de período:
    // se sube la lista hasta la tarjeta de Membresía.
    await tester.drag(find.byType(ListView).first, const Offset(0, -320));
    await tester.pump(const Duration(milliseconds: 300));
    // El selector muestra el valor actual (1 mes…); se toca
    // y se elige Personalizado en la hoja de la casa.
    await tester.tap(find.textContaining('mes (').first);
    await jornadaDrenar(tester, vueltas: 6, ms: 80);
    await tester.tap(find.text('Personalizado…'));
    await jornadaDrenar(tester, vueltas: 6, ms: 80);

    // Sin días ni monto, el guardado rechaza; la barra debe
    // coincidir: Membresía sin el check.
    expect(_pasoCompleto(tester, 'Membresía'), isFalse,
        reason: 'G02-1: barra y guardado nunca discrepan — '
            'personalizado vacío no es membresía completa');
    // Foto es opcional: se marca «opcional», no pendiente.
    expect(find.text('Foto · opcional'), findsOneWidget,
        reason: 'G02-1: el paso opcional se marca «opcional»');
    await jornadaCerrarCascara(tester);
  });
}
