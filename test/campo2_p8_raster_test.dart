// 1.34 Campo 2 — P-8: pulido de raster.
// - Toda imagen de red se decodifica ACOTADA: ningún
//   NetworkImage( crudo en lib/ — todos cuelgan de
//   providerFotoAcotada (que envuelve en ResizeImage).
//   Los 5 sitios que el informe §B señalaba ya cumplían al
//   llegar la pieza (verificado en el código, no en el
//   resumen): este guardián lo deja fijado.
// - La fila de Listas es su propia capa (RepaintBoundary):
//   la sombra blur 12 del botón de cobro es el valor de
//   diseño de la casa (D-18) y NO se abarata; lo que se
//   evita es repintarla al desplazar.
// - Cada pilar de Home vive en su RepaintBoundary.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('guardián P-8: imágenes de red siempre acotadas', () {
    test('ningún NetworkImage( sin providerFotoAcotada delante',
        () {
      final ofensas = <String>[];
      for (final ent in Directory('lib').listSync(recursive: true)) {
        if (ent is! File || !ent.path.endsWith('.dart')) continue;
        final src = ent.readAsStringSync();
        var idx = 0;
        while (true) {
          final m = src.indexOf('NetworkImage(', idx);
          if (m < 0) break;
          final desde = m - 160 < 0 ? 0 : m - 160;
          final ventana = src.substring(desde, m);
          if (!ventana.contains('providerFotoAcotada(')) {
            ofensas.add('${ent.path} (offset $m)');
          }
          idx = m + 1;
        }
      }
      expect(ofensas, isEmpty,
          reason: 'Toda imagen de red debe pedirse acotada: '
              'providerFotoAcotada(NetworkImage(...), ancho: …)');
    });
  });

  group('capas de raster (contrato de fuente)', () {
    test('la fila de Listas nace dentro de un RepaintBoundary', () {
      final listas = File('lib/ui/listas.dart').readAsStringSync();
      expect(
          listas,
          contains('final filaPintada = RepaintBoundary('));
      // Y la sombra de la casa sigue intacta (no se abarató).
      expect(listas, contains('blurRadius: 12'));
    });

    test('cada pilar de Home va envuelto en RepaintBoundary', () {
      final home = File('lib/ui/home.dart').readAsStringSync();
      final idxStack = home.indexOf('child: IndexedStack(');
      expect(idxStack, greaterThan(0));
      final ventana = home.substring(idxStack, idxStack + 1200);
      expect(ventana, contains('child: RepaintBoundary('));
      expect(ventana, contains('_pilarParaMostrar(i, esDueno)'));
    });
  });
}
