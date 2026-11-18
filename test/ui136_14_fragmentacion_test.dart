/// UI136-14 (adjudicación ARGON-136-UI, hallazgo H9 · resto
/// no-diálogo): fragmentación del kit — Card crudos
/// conviviendo con la Tarjeta de la casa en las pantallas
/// nombradas, y la capa de candado con literales de blanco
/// en vez de la familia textoSobreOscuro.
/// BotonPeligro (0 usos) queda DECLARADO en la corrección:
/// su forma (ancho completo, con borde) no es la de los
/// botones destructivos de diálogo (rellenos, en la fila de
/// acciones) — adoptarlo ahí forzaría el layout.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('UI136-14 · fuera Card crudos en las pantallas nombradas', () {
    final patron = RegExp(r'(^|[^A-Za-z])Card\(', multiLine: true);
    for (final f in [
      'lib/ui/centro_sync.dart',
      'lib/ui/control_acceso.dart',
      'lib/ui/nomina.dart',
      'lib/ui/servicios.dart',
      'lib/ui/actividad.dart',
    ]) {
      test('$f sin Card(', () {
        expect(patron.hasMatch(_src(f)), isFalse,
            reason: 'queda un Card crudo; la tarjeta es Tarjeta');
      });
    }
  });

  test('UI136-14 · capa_candado con la familia textoSobreOscuro', () {
    final s = _src('lib/ui/capa_candado.dart');
    expect(s.contains('Colors.white'), isFalse,
        reason: 'ningún literal de blanco: manda la familia');
    expect(s.contains('AppColores.textoSobreOscuro'), isTrue);
    expect(s.contains('AppColores.textoSobreOscuroSuave'), isTrue);
    expect(s.contains('AppColores.textoSobreOscuroMedio'), isTrue);
    // La sombra black54 se queda: es sombra, no texto sobre
    // oscuro, y la familia no tiene peldaño para ella.
    expect('Colors.black54'.allMatches(s).length, 1);
  });
}
