/// 1.36 · S1: compuertas de censo del sistema de diseño.
/// Cada compuerta es un TECHO (ratchet): el número puede
/// bajar con las migraciones por pilares, nunca subir.
/// Un primitivo nuevo fuera del sistema rompe el test el
/// día que nace, no en la auditoría siguiente.
///
/// Techos al cerrar S1 (2026-11-17):
/// - AlertDialog( fuera de componentes.dart: 99
///   (136-264: migración por pilares = excepción nombrada
///   en el progreso S1; la compuerta ya impide el 100º).
/// - MaterialPageRoute( fuera de diseno.dart: 6
///   (136-288: la cola de sync ya migró a RutaIron).
/// - Card( crudo en lib/ui: 52 (136-267: Tarjeta ya
///   consume el cardTheme; la migración de los Card( de
///   pantalla queda enrutada con este techo).
/// - showModalBottomSheet( crudo: 3 (136-276).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

int _contar(String patron, {Set<String> excluir = const {}}) {
  var n = 0;
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    if (excluir.contains(e.path)) continue;
    n += patron.allMatches(e.readAsStringSync()).length;
  }
  return n;
}

void main() {
  test('136-264: ningún AlertDialog nuevo fuera de la primitiva', () {
    expect(
        _contar('AlertDialog(', excluir: {'lib/ui/componentes.dart'}),
        lessThanOrEqualTo(99));
  });

  test('136-288: ninguna ruta nueva fuera de RutaIron', () {
    expect(
        _contar('MaterialPageRoute(', excluir: {'lib/ui/diseno.dart'}),
        lessThanOrEqualTo(6));
  });

  test('136-267: ningún Card( crudo nuevo en pantallas', () {
    expect(_contar(' Card('), lessThanOrEqualTo(52));
  });

  test('136-276: ninguna hoja modal cruda nueva', () {
    expect(_contar('showModalBottomSheet('), lessThanOrEqualTo(3));
  });

  test('136-283: ChipEstado con color libre solo por .libre', () {
    // El constructor principal ya es el cerrado; un uso
    // nuevo con `color:` fuera de .libre no compila, y
    // este censo fija que nadie reabra el constructor.
    final fuente =
        File('lib/ui/componentes.dart').readAsStringSync();
    expect(fuente.contains('const ChipEstado.libre('), isTrue);
    expect(fuente.contains('required SignificadoChip this.significado'),
        isTrue);
  });
}
