/// 1.35 (UI-15): verificación de que la propuesta ya
/// vive en la base — todas las etiquetas del gráfico de
/// métrica (las del widget y las dos que pinta el
/// painter: rótulos de guía y valores) usan los roles de
/// texto de la casa; no existe ningún tamaño escrito a
/// mano en el archivo. El test fija la invariante.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('grafico_metrica: cero fontSize sueltos y roles '
      'de texto en el painter', () {
    final src =
        File('lib/ui/grafico_metrica.dart').readAsStringSync();
    expect('fontSize'.allMatches(src).length, 0,
        reason: 'ningún tamaño de fuente escrito a mano');
    expect(src, contains('AppTexto.metadato'));
    // Las etiquetas del painter nacen del rol metadato.
    final rotulo = src.substring(src.indexOf('void _rotuloGuia'));
    expect(rotulo.substring(0, 600), contains('AppTexto.metadato'));
    final etiqueta = src.substring(src.indexOf('void _etiqueta'));
    expect(etiqueta.substring(0, 600), contains('AppTexto.metadato'));
  });
}
