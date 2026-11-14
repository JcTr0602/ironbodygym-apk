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
  test('F-9: escala conjunta con techo 1.45 y suelo 0.85', () {
    // El caso del hallazgo: 1.3 × 1.3 ya no da 1.69.
    expect(escalaTextoEfectiva(1.3, 1.3), 1.45);
    // Dentro del rango, el producto manda tal cual.
    expect(escalaTextoEfectiva(1.0, 1.0), 1.0);
    expect(escalaTextoEfectiva(1.2, 1.1), closeTo(1.32, 1e-9));
    expect(escalaTextoEfectiva(0.9, 1.0), 0.9);
    // Suelo: dos escalas pequeñas no hunden el texto.
    expect(escalaTextoEfectiva(0.8, 0.9), 0.85);
  });

  test('K3-4: el deslizador anuncia el % EFECTIVO y marca '
      'la zona de clamp', () {
    // Sin clamp: anuncia el producto y no avisa.
    var a = anuncioEscalaLetra(1.0, 1.0);
    expect(a.porcentaje, 100);
    expect(a.limitado, isFalse);
    a = anuncioEscalaLetra(1.2, 1.1);
    expect(a.porcentaje, 132);
    expect(a.limitado, isFalse);
    // Techo: con sistema a 1,30, los pasos altos de la app
    // anuncian TODOS 145 % (la zona muerta, nombrada).
    for (final app in [1.15, 1.20, 1.25, 1.30]) {
      a = anuncioEscalaLetra(app, 1.3);
      expect(a.porcentaje, 145, reason: 'app=$app');
      expect(a.limitado, isTrue, reason: 'app=$app');
    }
    // El primer paso que aún no toca el techo no avisa.
    a = anuncioEscalaLetra(1.1, 1.3);
    expect(a.porcentaje, 143);
    expect(a.limitado, isFalse);
    // Suelo simétrico: sistema a 0,85 hunde los pasos bajos.
    a = anuncioEscalaLetra(0.85, 0.85);
    expect(a.porcentaje, 85);
    expect(a.limitado, isTrue);
  });

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
      test('F-1 + K3-2: pestañas — indicador naranja en ambos '
          'brillos; etiqueta activa por brillo', () {
        expect(t.tabBarTheme.indicatorColor, AppColores.naranja);
        // Yunque 3 (K3-2): en claro la etiqueta usa el rol de
        // texto (el naranja gráfico queda a 2,5:1 sobre el
        // AppBar claro); en oscuro sigue el naranja gráfico.
        expect(
            t.tabBarTheme.labelColor,
            t.brightness == Brightness.dark
                ? AppColores.naranja
                : AppColores.naranjaTexto);
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
