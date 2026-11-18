/// UI136-07 (adjudicación ARGON-136-UI, hallazgo H3 · pata
/// movimiento): 136-274 metió la guarda de «Reducir
/// movimiento» en las primitivas (AppMovimiento.resuelta),
/// pero estos sitios usan el token a pelo y animan igual con
/// la bandera activa. Todos pasan por resuelta.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  testWidgets('resuelta: cero con reducir movimiento, token sin él',
      (tester) async {
    late Duration conBandera, sinBandera;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Builder(builder: (ctx) {
        conBandera = AppMovimiento.resuelta(ctx, AppMovimiento.media);
        return const SizedBox();
      }),
    ));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: false),
      child: Builder(builder: (ctx) {
        sinBandera = AppMovimiento.resuelta(ctx, AppMovimiento.media);
        return const SizedBox();
      }),
    ));
    expect(conBandera, Duration.zero);
    expect(sinBandera, AppMovimiento.media);
  });

  group('UI136-07 · sitios nombrados por resuelta', () {
    test('servicios: switchers y opacidad', () {
      final s = _src('lib/ui/servicios.dart');
      for (final token in ['corta', 'media', 'larga']) {
        expect(s.contains('duration: AppMovimiento.$token,'), isFalse,
            reason: 'queda una duración $token sin la guarda');
      }
      final resuelta = RegExp(
          r'AppMovimiento\.resuelta\(\s*context, AppMovimiento\.(\w+)\)');
      final tokens =
          resuelta.allMatches(s).map((m) => m.group(1)).toSet();
      expect(tokens, containsAll(['corta', 'media']));
      expect(
          RegExp(r'AppMovimiento\.resuelta\(\s*ctx, AppMovimiento\.corta\)')
              .hasMatch(s),
          isTrue,
          reason: 'el frameBuilder de la foto resuelve con su ctx');
    });
    test('ranking_servicios: la barra animada', () {
      final s = _src('lib/ui/ranking_servicios.dart');
      expect(s.contains('duration: AppMovimiento.media,'), isFalse);
      expect(
          RegExp(r'AppMovimiento\.resuelta\(\s*context, '
                  r'AppMovimiento\.media\)')
              .hasMatch(s),
          isTrue);
    });
    test('editor_foto: switcher y controlador del reset', () {
      final s = _src('lib/ui/editor_foto.dart');
      expect(
          RegExp(r'AppMovimiento\.resuelta\(\s*context, '
                  r'AppMovimiento\.corta\)')
              .hasMatch(s),
          isTrue);
      expect(s.contains('_animReset.duration ='), isTrue,
          reason: 'el controlador nace sin contexto: su '
              'duración se resuelve al disparar el reset');
    });
    test('historial_ventas: animateTo y ensureVisible', () {
      final s = _src('lib/ui/historial_ventas.dart');
      expect(s.contains('duration: AppMovimiento.larga,'), isFalse);
      expect(
          RegExp(r'AppMovimiento\.resuelta\(\s*context, '
                  r'AppMovimiento\.larga\)')
              .allMatches(s)
              .length,
          2);
    });
    test('pago_diario: el switcher del check', () {
      final s = _src('lib/ui/pago_diario.dart');
      expect(s.contains('duration: AppMovimiento.larga,'), isFalse);
      expect(
          RegExp(r'AppMovimiento\.resuelta\(\s*context, '
                  r'AppMovimiento\.larga\)')
              .hasMatch(s),
          isTrue);
    });
  });
}
