/// UI136-08 (adjudicación ARGON-136-UI, hallazgo H7; compañera
/// de la fila abierta 136-126, sin duplicarla): con la escala
/// de letra a 1,45× estos sitios cortaban texto o dejaban los
/// números tocando los bordes. La pata del KPI de Estadísticas
/// se cerró en UI136-06 (FittedBox + tabulares).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

String _tramo(String s, String marca, int chars) {
  final i = s.indexOf(marca);
  expect(i, greaterThanOrEqualTo(0), reason: 'no aparece $marca');
  return s.substring(i, i + chars);
}

void main() {
  group('UI136-08 · Hub de turnos', () {
    final s = _src('lib/ui/hub_turnos.dart');
    test('la línea de tiempo crece con la escala de letra', () {
      final t = _tramo(s, 'Widget _lineaDeTiempo()', 4200);
      expect(t.contains('textScalerOf'), isTrue);
      expect(t.contains('height: 34,'), isFalse,
          reason: 'la altura fija de 34 no vuelve');
    });
    test('la caja del día encoge su cifra con FittedBox', () {
      final t = _tramo(s, 'Widget _celdaDia(', 900);
      expect(t.contains('FittedBox'), isTrue);
      expect(t.contains('width: 36'), isTrue,
          reason: 'la rejilla semanal conserva sus 36 dp');
    });
  });

  group('UI136-08 · Control de acceso', () {
    final s = _src('lib/ui/control_acceso.dart');
    test('la tarjeta-filtro respira y su valor no se corta', () {
      final t = _tramo(s, 'Widget _tarjetaFiltro(', 2400);
      expect(t.contains('width: 120'), isTrue);
      expect(t.contains('FittedBox'), isTrue);
    });
    test('la fila deja el chip en el subtítulo, no en el trailing',
        () {
      final t = _tramo(s, 'Widget _filaAcceso(', 2600);
      final iSub = t.indexOf('subtitle:');
      final iChip = t.indexOf('ChipEstado.semantico');
      final iTrail = t.indexOf('trailing:');
      expect(iSub, greaterThanOrEqualTo(0));
      expect(iChip, greaterThan(iSub));
      expect(iChip, lessThan(iTrail),
          reason: 'el chip vive en el subtítulo; el trailing '
              'queda para los botones icono');
    });
  });

  group('UI136-08 · Estadísticas de servicios', () {
    test('_barra sin ancho fijo y valor a dos líneas', () {
      final s = _src('lib/ui/servicios_estadisticas.dart');
      final t = _tramo(s, 'Widget _barra(', 1600);
      expect(t.contains('width: 92'), isFalse);
      expect(t.contains('maxLines: 2'), isTrue);
    });
  });

  group('UI136-08 · Nómina y Ficha', () {
    test('la fila de tarifa se envuelve en Wrap', () {
      final s = _src('lib/ui/nomina.dart');
      // La tarjeta de ajustes es la ÚLTIMA aparición del
      // rótulo (la primera es un concepto contable).
      final i = s.lastIndexOf("'Tarifa por cliente'");
      expect(i, greaterThanOrEqualTo(0));
      final t = s.substring(i, i + 900);
      expect(t.contains('Wrap('), isTrue);
      expect(t.contains('CUP por cada cliente que pagó:'), isTrue);
    });
    test('el «Pagado hasta» editable lleva Expanded', () {
      final s = _src('lib/ui/ficha.dart');
      final i = s.indexOf("'Pagado hasta: —'");
      expect(i, greaterThanOrEqualTo(0));
      final antes = s.substring(i - 600, i);
      expect(antes.contains('Expanded('), isTrue);
    });
  });
}
