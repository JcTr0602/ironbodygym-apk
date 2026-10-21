// Candado anti-abandono de «Lo Nuevo» (rescate de Ayuda,
// panel 2026-10-21): las novedades se quedaron en la 1.3.2
// durante 7 releases porque nada gritaba al subir la versión.
// Este test falla si la primera entrada de `novedades` no es
// la versión ACTUAL del pubspec.
//
// La comparación es contra la parte SEMÁNTICA (sin '+build'):
// novedades guarda '1.4.1' y el pubspec '1.4.1+59'. Comparar el
// literal completo nacería roto (panel, Luna/Terra).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/novedades.dart';

File? _buscarPubspec() {
  var dir = Directory.current;
  while (true) {
    final f = File('${dir.path}/pubspec.yaml');
    if (f.existsSync()) return f;
    final padre = dir.parent;
    if (padre.path == dir.path) return null;
    dir = padre;
  }
}

void main() {
  test('«Lo Nuevo» abre con la versión actual del pubspec', () {
    expect(novedades, isNotEmpty,
        reason: 'novedades no puede quedar vacía');
    final pubspec = _buscarPubspec();
    expect(pubspec, isNotNull,
        reason: 'No se encontró pubspec.yaml sobre el directorio actual');
    final contenido = pubspec!.readAsStringSync();
    final m = RegExp(r'''^version:\s*["']?([^"'\s]+)["']?\s*$''',
            multiLine: true)
        .firstMatch(contenido);
    expect(m, isNotNull, reason: 'pubspec.yaml sin línea version:');
    final semantica = m!.group(1)!.split('+').first;
    expect(novedades.first.version, semantica,
        reason:
            'Al subir la versión hay que añadir su entrada a «Lo Nuevo» '
            'en lib/novedades.dart (primera de la lista)');
    expect(novedades.first.cambios, isNotEmpty,
        reason: 'la versión actual debe traer cambios que contar');
  });

  test('las novedades no repiten versión y van en orden descendente',
      () {
    final versiones = novedades.map((n) => n.version).toList();
    expect(versiones.toSet().length, versiones.length,
        reason: 'versiones duplicadas en novedades');
    for (var i = 1; i < versiones.length; i++) {
      expect(compararVersiones(versiones[i - 1], versiones[i]),
          greaterThan(0),
          reason:
              '${versiones[i - 1]} debe ir antes que ${versiones[i]}');
    }
  });
}
