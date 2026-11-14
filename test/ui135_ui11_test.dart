/// 1.35 (UI-11): los dos avisos del diálogo de pago
/// (precio de menor y días vigentes) se pintan con
/// AvisoEstado; los contenedores a mano con alfa ya no
/// existen en dialogo_pago.dart.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  testWidgets('AvisoEstado info con el texto de menor',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AvisoEstado(
          tipo: TipoAviso.info,
          icono: Icons.child_care_rounded,
          texto: 'Menor de 18: precio especial 1.500 CUP/mes.',
        ),
      ),
    ));
    expect(find.text('Menor de 18: precio especial 1.500 CUP/mes.'),
        findsOneWidget);
    expect(find.byIcon(Icons.child_care_rounded), findsOneWidget);
  });

  testWidgets('AvisoEstado éxito con el texto de vigentes',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AvisoEstado(
          tipo: TipoAviso.exito,
          icono: Icons.check_circle_rounded,
          texto: 'Tiene 5 día(s) vigentes. No se pierden: '
              'el nuevo período empieza al vencer.',
        ),
      ),
    ));
    expect(find.textContaining('día(s) vigentes'), findsOneWidget);
  });

  test('contrato: dialogo_pago usa AvisoEstado y no '
      'quedan contenedores con alfa', () {
    final src = File('lib/ui/dialogo_pago.dart').readAsStringSync();
    expect(src, contains('AvisoEstado('));
    expect(src, contains('TipoAviso.info'));
    expect(src, contains('TipoAviso.exito'));
    expect(src, isNot(contains('withValues(alpha:')));
    expect(src, contains('Menor de 18: precio especial'));
    expect(src, contains('día(s) vigentes'));
  });
}
