/// 1.35 (UI-09): las pantallas que cargaban con un spinner
/// centrado (Congelaciones, Categorías, Detalle de
/// entrenador, Avisos de entrenador) cargan con el
/// esqueleto de su forma; la regla queda escrita en
/// skeleton.dart.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/skeleton.dart';

void main() {
  testWidgets('SkeletonLista pinta tarjetas, no spinner',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: SkeletonLista(items: 4)),
    ));
    expect(find.byType(SkeletonTarjeta), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('SkeletonFicha pinta su forma de ficha',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: SkeletonFicha()),
    ));
    expect(find.byType(SkeletonLinea), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  test('contrato: las cuatro pantallas usan esqueleto '
      'y la regla está escrita', () {
    for (final f in [
      'lib/ui/congelaciones.dart',
      'lib/ui/categorias_suplemento.dart',
      'lib/ui/avisos_entrenador.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src, contains('SkeletonLista'),
          reason: '$f debe cargar con SkeletonLista');
    }
    final det =
        File('lib/ui/detalle_entrenador.dart').readAsStringSync();
    expect(det, contains('SkeletonFicha'));
    final sk = File('lib/ui/skeleton.dart').readAsStringSync();
    expect(sk, contains('REGLA DE LA CASA'));
    expect(sk, contains('pantalla COMPLETA'));
  });
}
