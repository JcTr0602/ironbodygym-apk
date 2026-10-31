import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/gympedia.dart';

void main() {
  test('GY3: cada sello tiene su texto de respaldo', () {
    expect(textoSelloGympedia('verde'), 'Respaldo sólido');
    expect(textoSelloGympedia('amarillo'), 'Con matices');
    expect(textoSelloGympedia('gris'), 'Sin respaldo');
    expect(textoSelloGympedia('otro'), 'otro');
  });
}
