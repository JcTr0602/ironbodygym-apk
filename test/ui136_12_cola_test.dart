/// UI136-12 (adjudicación ARGON-136-UI, hallazgo H12): el
/// héroe de la Cola suma operaciones + fotos + comprobantes,
/// pero la tarjeta «en sencillo» nunca nombraba los
/// comprobantes: con 0 operaciones y 1 comprobante por
/// subir, decía «No tienes operaciones por subir» mientras
/// el héroe anunciaba 1. La tarjeta nombra los comprobantes
/// con el mismo patrón que las fotos (SP-04).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI136-12 · la tarjeta en sencillo nombra los comprobantes',
      () {
    final s = File('lib/ui/cola.dart').readAsStringSync();
    final i = s.indexOf('Widget _tarjetaColaEnSencillo()');
    expect(i, greaterThanOrEqualTo(0));
    final tramo = s.substring(i, i + 4200);
    expect(tramo.contains('if (_compPendientes > 0)'), isTrue,
        reason: 'la rama de 0 operaciones nombra los '
            'comprobantes pendientes');
    expect(tramo.contains('de transferencia por subir.'), isTrue);
    expect(tramo.contains('comprobante'), isTrue);
    // El héroe sigue sumando las cuatro patas (no se toca).
    expect(s.contains('_compPendientes;'), isTrue);
  });
}
