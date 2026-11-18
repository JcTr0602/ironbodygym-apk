/// UI136-09 (adjudicación ARGON-136-UI, hallazgo H8): la
/// regla de Jc — las filas y reportes en CERO no aparecen.
/// Sitios: detalle por bote e inversión de Estadísticas de
/// servicios, columnas del cuadre de Servicios, el «· N con
/// pocas dosis» de Admin, las tarjetas-filtro en cero de
/// Control de acceso y el desglose por concepto de Ingresos
/// del período. Los totales protagonistas de cada tarjeta
/// se quedan (son el resumen, no ruido).
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
  group('UI136-09 · Estadísticas de servicios', () {
    final s = _src('lib/ui/servicios_estadisticas.dart');
    test('el detalle por bote oculta Casa/Mermas/Cortesías/Staff en 0',
        () {
      expect(s.contains('bool _esCero('), isTrue);
      for (final clave in ['casa', 'merma', 'cortesia', 'staff']) {
        expect(s.contains("if (!_esCero(e.value['$clave']))"), isTrue,
            reason: 'la fila $clave no está guardada');
      }
    });
    test('la inversión oculta el detalle en 0 con filaSi', () {
      final t = _tramo(s, 'Widget _tarjetaInversion()', 3400);
      expect(t.contains('filaSi('), isTrue);
      expect(t.contains("filaSi('Mermas (a costo)', 'mermas_costo')"),
          isTrue);
    });
  });

  test('UI136-09 · el cuadre oculta Pomos sueltos y Casa en 0', () {
    final s = _src('lib/ui/servicios.dart');
    final t = _tramo(s, 'Widget _tarjetaCuadre(', 6500);
    expect(t.contains('if (aguaSuelta > 0)'), isTrue);
    expect(t.contains('if (casaN > 0)'), isTrue);
    expect(t.contains("Text('Dosis hoy'"), isTrue,
        reason: 'la columna principal se queda siempre');
  });

  test('UI136-09 · «con pocas dosis» solo si hay bajos', () {
    final s = _src('lib/ui/servicios_admin.dart');
    expect(s.contains('final bajos = pomos'), isTrue);
    expect(s.contains('bajos > 0'), isTrue);
  });

  test('UI136-09 · tarjetas-filtro en cero no se construyen', () {
    final s = _src('lib/ui/control_acceso.dart');
    for (final vista in [
      'activos',
      'nunca',
      '7d',
      'bloqueados',
      'revocados',
      'sinacceso'
    ]) {
      expect(s.contains("_vista == '$vista'"), isTrue,
          reason: 'la tarjeta $vista no guarda su cero '
              '(se queda solo si es la vista activa)');
    }
  });

  test('UI136-09 · Ingresos del período filtra conceptos en 0', () {
    final s = _src('lib/ui/panel_resto_caja.dart');
    expect(s.contains('(r.porConcepto[c] ?? 0) != 0'), isTrue);
  });
}
