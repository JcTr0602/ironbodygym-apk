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

      // Yunque 2.34: el inventario crece a TODO control que
      // DIS-04 dejó fuera (F-1/F-3/F-4/F-5/F-6).
      test('F-1: pestañas — indicador y etiqueta activa en '
          'naranja', () {
        expect(t.tabBarTheme.indicatorColor, AppColores.naranja);
        expect(t.tabBarTheme.labelColor, AppColores.naranja);
      });

      test('F-3: selección de texto en la marca', () {
        expect(t.textSelectionTheme.cursorColor, AppColores.naranja);
        expect(t.textSelectionTheme.selectionHandleColor,
            AppColores.naranjaOscuro);
        expect(t.textSelectionTheme.selectionColor,
            AppColores.naranja.withValues(alpha: 0.35));
      });

      test('F-4: calendario — hoy y año seleccionado en la '
          'marca', () {
        expect(
            t.datePickerTheme.todayForegroundColor
                ?.resolve({WidgetState.selected}),
            AppColores.sobreMarca);
        expect(
            t.datePickerTheme.todayForegroundColor
                ?.resolve(<WidgetState>{}),
            AppColores.naranja);
        expect(
            t.datePickerTheme.yearBackgroundColor
                ?.resolve({WidgetState.selected}),
            AppColores.naranja);
        expect(
            t.datePickerTheme.yearForegroundColor
                ?.resolve({WidgetState.selected}),
            AppColores.sobreMarca);
      });

      test('F-5: reloj — AM/PM y hora/minuto por estado en '
          'la marca', () {
        // Los campos del tema son Color: el valor fijado es
        // un WidgetStateColor y se resuelve por estado.
        Color? res(Color? c, Set<WidgetState> e) =>
            c is WidgetStateColor ? c.resolve(e) : c;
        expect(res(t.timePickerTheme.dayPeriodColor,
            {WidgetState.selected}), AppColores.naranja);
        expect(res(t.timePickerTheme.dayPeriodTextColor,
            {WidgetState.selected}), AppColores.sobreMarca);
        expect(res(t.timePickerTheme.hourMinuteColor,
            {WidgetState.selected}),
            AppColores.naranja.withValues(alpha: 0.16));
        expect(res(t.timePickerTheme.hourMinuteTextColor,
            {WidgetState.selected}), AppColores.naranjaOscuro);
      });

      test('F-6: deslizador — la burbuja del valor en naranja',
          () {
        expect(t.sliderTheme.valueIndicatorColor,
            AppColores.naranja);
        expect(t.sliderTheme.valueIndicatorTextStyle?.color,
            AppColores.sobreMarca);
      });
    });
  }
}
