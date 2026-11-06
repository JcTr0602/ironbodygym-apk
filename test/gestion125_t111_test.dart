// 1.25 T111: la agrupación por equipo de la Guía (la
// misma para la lista y para la portada de conteos).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/guia_lista.dart';

void main() {
  Map<String, dynamic> ficha(String equipo) =>
      {'equipoId': equipo, 'titulo': 'x'};

  test('agrupa en el orden canónico y manda lo no vigente a Otros', () {
    final m = agruparFichasPorEquipo(
      [ficha('mancuernas'), ficha('polea'), ficha('mancuernas'), ficha('viejo')],
      ['mancuernas', 'polea'],
    );
    expect(m['mancuernas']!.length, 2);
    expect(m['polea']!.length, 1);
    expect(m['Otros']!.length, 1);
  });
  test('sin fichas ajenas no aparece la clave Otros', () {
    final m = agruparFichasPorEquipo([ficha('polea')], ['polea']);
    expect(m.containsKey('Otros'), isFalse);
  });
  test('equipo vacío cae en Otros', () {
    final m = agruparFichasPorEquipo([
      {'titulo': 'sin equipo'}
    ], ['polea']);
    expect(m['Otros']!.length, 1);
  });
}
