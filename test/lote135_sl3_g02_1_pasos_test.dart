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
  // F02-HD (z18_tests_sl3-5 r2): SIN fallback sin filtrar —
  // antes, si la etiqueta de la barra no se localizaba, se
  // devolvía el Text a pelo y _pasoCompleto leía el Row del
  // TÍTULO de la sección de abajo (sin check): una barra
  // completa se podía leer «incompleta» en verde. Ahora se
  // devuelve un finder vacío y _pasoCompleto exige la
  // etiqueta en la barra: el ámbito es el del paso, no el
  // de la sección vecina.
  return find.byElementPredicate((_) => false);
}

/// ¿El paso lleva el check de completo en su fila de la
/// barra? (La fila del paso: círculo + etiqueta.)
bool _pasoCompleto(WidgetTester tester, String etiqueta) {
  final enBarra = _etiquetaEnBarra(tester, etiqueta);
  expect(enBarra, findsOneWidget,
      reason: 'la etiqueta «$etiqueta» debe localizarse EN '
          'LA BARRA de pasos; leer el título de la sección '
          'de abajo no vale');
  final row = find
      .ancestor(of: enBarra, matching: find.byType(Row))
      .first;
  return find
      .descendant(of: row, matching: find.byIcon(Icons.check_rounded))
      .evaluate()
      .isNotEmpty;
}

/// El campo de texto cuya decoración lleva [etiqueta]
/// («Días», «Monto (CUP)» del personalizado).
Finder _campoPorEtiqueta(String etiqueta) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == etiqueta);

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

  // F02-HD (z18_tests_sl3-4/5 r2): el caso VÁLIDO completo —
  // el test de arriba solo ejerce el inválido y una barra
  // siempre incompleta pasaría. Con días y monto válidos la
  // barra SÍ llega a completo, y el check se lee en la fila
  // DE LA BARRA (etiquetas cortas: «Datos», «Membresía»),
  // no en el título homónimo de la sección de abajo.
  testWidgets(
      'personalizado VÁLIDO (días y monto): la barra SÍ da '
      'Membresía por completa, como el guardado', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: InscribirScreen()));
    await jornadaDrenar(tester);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField).first, 'Prueba Pasos Valida');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_pasoCompleto(tester, 'Datos'), isTrue,
        reason: 'control: con nombre, Datos sí está completo');

    await tester.drag(find.byType(ListView).first, const Offset(0, -320));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining('mes (').first);
    await jornadaDrenar(tester, vueltas: 6, ms: 80);
    await tester.tap(find.text('Personalizado…'));
    await jornadaDrenar(tester, vueltas: 6, ms: 80);

    // Control del inválido dentro del mismo montaje: recién
    // elegido el personalizado, aún sin días ni monto, la
    // barra NO lo da por completo.
    expect(_pasoCompleto(tester, 'Membresía'), isFalse,
        reason: 'control: personalizado recién elegido, sin '
            'días ni monto, sigue incompleto');

    // Los datos que el guardado exige.
    await tester.ensureVisible(_campoPorEtiqueta('Días'));
    await tester.enterText(_campoPorEtiqueta('Días'), '30');
    await tester.enterText(_campoPorEtiqueta('Monto (CUP)'), '2000');
    await tester.pump(const Duration(milliseconds: 300));

    // La ambigüedad existe de verdad (barra + título de la
    // sección) y aun así la lectura es la de la barra.
    expect(find.text('Membresía', skipOffstage: false), findsNWidgets(2),
        reason: 'control: «Membresía» vive en la barra Y en '
            'el título de la sección: hay que leer la barra');
    expect(_pasoCompleto(tester, 'Membresía'), isTrue,
        reason: 'G02-1: con días y monto válidos, barra y '
            'guardado coinciden también en positivo — el '
            'check está en la fila del paso en la barra, no '
            'se lee «incompleto» desde la sección vecina');
    await jornadaCerrarCascara(tester);
  });
}
