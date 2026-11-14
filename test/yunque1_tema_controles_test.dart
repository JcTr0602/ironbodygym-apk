/// Yunque 1.34 · DIS-04: los controles de selección y los
/// selectores de fecha/hora van en la MARCA en los cuatro
/// temas (los de producción — sol y tacticoOscuro — ponen el
/// `primary` del esquema en cobalto y Material 3 pintaba
/// casillas, radios, deslizadores y calendarios en ese azul
/// plano que Jc rechazó en la 1.32).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  final temas = <String, ThemeData Function()>{
    'claro': AppTema.claro,
    'oscuro': AppTema.oscuro,
    'sol (producción)': AppTema.sol,
    'tacticoOscuro (producción)': AppTema.tacticoOscuro,
  };

  for (final e in temas.entries) {
    group('DIS-04 · tema ${e.key}', () {
      late ThemeData t;
      setUp(() => t = e.value());

      test('casilla seleccionada en naranja, no en cobalto', () {
        final c = t.checkboxTheme.fillColor
            ?.resolve({WidgetState.selected});
        expect(c, AppColores.naranja);
        expect(c, isNot(AppColores.cobalto));
        expect(c, isNot(AppColores.cobaltoOscuro));
      });

      test('radio seleccionado en naranja', () {
        final c =
            t.radioTheme.fillColor?.resolve({WidgetState.selected});
        expect(c, AppColores.naranja);
      });

      test('deslizador activo en naranja', () {
        expect(t.sliderTheme.activeTrackColor, AppColores.naranja);
        expect(t.sliderTheme.thumbColor, AppColores.naranja);
      });

      test('calendario: el día seleccionado en naranja', () {
        final c = t.datePickerTheme.dayBackgroundColor
            ?.resolve({WidgetState.selected});
        expect(c, AppColores.naranja);
      });

      test('reloj: la manecilla en naranja', () {
        expect(t.timePickerTheme.dialHandColor, AppColores.naranja);
      });
    });
  }
}
