/// 1.35 (UI-21): verificación de que la propuesta ya
/// vive en la base (1.25 T113) — Ajustes tiene buscador
/// arriba que filtra secciones y opciones por el índice
/// titulosPorSeccionAjustes, con su estado «Ningún
/// ajuste coincide». Aquí se fijan las funciones puras
/// del filtro y el contrato de la pantalla.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/ajustes.dart';

void main() {
  test('coincideBusquedaAjuste: vacío enseña todo y la '
      'coincidencia no mira mayúsculas', () {
    expect(coincideBusquedaAjuste('Tema', ''), isTrue);
    expect(coincideBusquedaAjuste('Tema', 'tema'), isTrue);
    expect(coincideBusquedaAjuste('Tema', 'TEMA'), isTrue);
    expect(coincideBusquedaAjuste('Tamaño de letra', 'letra'),
        isTrue);
    expect(coincideBusquedaAjuste('Tema', 'respaldo'), isFalse);
  });

  test('seccionVisibleAjustes: una sección se enseña si '
      'alguno de sus títulos coincide', () {
    expect(seccionVisibleAjustes('Apariencia', 'vibración'),
        isTrue);
    expect(seccionVisibleAjustes('Apariencia', 'movimiento'),
        isTrue,
        reason: 'Reducir movimiento entró en el índice (UI-20)');
    expect(seccionVisibleAjustes('Apariencia', 'respaldo'),
        isFalse);
    expect(seccionVisibleAjustes('Datos', 'respaldo'), isTrue);
    expect(seccionVisibleAjustes('Perfil', ''), isTrue);
  });

  test('contrato: campo arriba, limpiar y vacío con '
      'salida', () {
    final src = File('lib/ui/ajustes.dart').readAsStringSync();
    expect(src, contains("hint: 'Buscar un ajuste…'"));
    expect(src, contains("'Limpiar búsqueda'"));
    expect(src, contains("'Ningún ajuste coincide'"));
    expect(src, contains('_busquedaAjustesCtrl'));
  });
}
