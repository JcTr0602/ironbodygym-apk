/// 1.32 «Mostrador Táctico» — Pieza 1: tokens visuales y Modo Sol.
///
/// Fija la paleta EXACTA del plano de Argón (inventario §4.1), el
/// helper de cifras tabulares y el Modo Sol MANUAL persistido
/// (guarda del contraste: sin sensor, default apagado).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/theme.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Paleta táctica (valores exactos del plano)', () {
    test('superficies y acción', () {
      expect(AppColores.pizarra, const Color(0xFF0B0F14));
      expect(AppColores.papelFrio, const Color(0xFFF4F6F8));
      expect(AppColores.grafitoTactico, const Color(0xFF151C24));
      expect(AppColores.acero, const Color(0xFF1E2936));
      expect(AppColores.grisTecnico, const Color(0xFFE8ECEF));
      expect(AppColores.cobalto, const Color(0xFF2563EB));
      expect(AppColores.cobaltoOscuro, const Color(0xFF1D4ED8));
    });

    test('semánticos por brillo', () {
      expect(AppColores.esmeralda, const Color(0xFF10B981));
      expect(AppColores.verdeBosque, const Color(0xFF047857));
      expect(AppColores.ambarTactico, const Color(0xFFFACC15));
      expect(AppColores.ambarTierra, const Color(0xFFCA8A04));
      expect(AppColores.coral, const Color(0xFFEF4444));
      expect(AppColores.carmesi, const Color(0xFFDC2626));
      expect(AppColores.cianHielo, const Color(0xFF06B6D4));
      expect(AppColores.cianProfundo, const Color(0xFF0E7490));
      expect(AppColores.violetaTactico, const Color(0xFF8B5CF6));
      expect(AppColores.indigoTactico, const Color(0xFF6D28D9));
      expect(AppColores.doradoReal, const Color(0xFFF59E0B));
      expect(AppColores.doradoRealOscuro, const Color(0xFFB45309));
    });

    test('los tokens viejos NO se tocaron', () {
      // Fijados por la fundación 1.29 y sus tests de contraste.
      expect(AppColores.naranja, const Color(0xFFE8821A));
      expect(AppColores.sobreMarca, const Color(0xFF1A1A1C));
    });
  });

  group('AppTexto.conTabulares', () {
    test('añade tabularFigures y conserva el resto', () {
      const base = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);
      final r = AppTexto.conTabulares(base);
      expect(r.fontSize, 17);
      expect(r.fontWeight, FontWeight.w700);
      expect(r.fontFeatures,
          contains(const FontFeature.tabularFigures()));
    });

    test('es idempotente', () {
      const base = TextStyle(
          fontFeatures: [FontFeature.tabularFigures()]);
      final r = AppTexto.conTabulares(base);
      expect(r.fontFeatures!.length, 1);
    });
  });

  group('Temas tácticos', () {
    test('tacticoOscuro: Pizarra + Grafito + Cobalto', () {
      final t = AppTema.tacticoOscuro();
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, AppColores.pizarra);
      expect(t.colorScheme.primary, AppColores.cobalto);
      expect(t.colorScheme.surface, AppColores.grafitoTactico);
      expect(t.colorScheme.surfaceContainerHighest, AppColores.acero);
      expect(t.cardTheme.color, AppColores.grafitoTactico);
    });

    test('sol: Papel Frío + Cobalto oscuro + borde 1,5 dp', () {
      final t = AppTema.sol();
      expect(t.brightness, Brightness.light);
      expect(t.scaffoldBackgroundColor, AppColores.papelFrio);
      expect(t.colorScheme.primary, AppColores.cobaltoOscuro);
      expect(t.colorScheme.surface, Colors.white);
      final forma = t.cardTheme.shape as RoundedRectangleBorder;
      expect(forma.side.width, 1.5);
      expect(forma.side.color, AppColores.sobreMarca);
    });
  });

  group('ThemeController.modoSol (solo manual)', () {
    setUp(() {
      ThemeController.modoSol.value = false;
    });

    test('default apagado', () {
      expect(ThemeController.modoSol.value, isFalse);
    });

    test('setModoSol persiste y load() lo restaura', () async {
      SharedPreferences.setMockInitialValues({});
      await ThemeController.setModoSol(true);
      expect(ThemeController.modoSol.value, isTrue);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('modo_sol_v1'), isTrue);
      // Simula un arranque en frío con el valor guardado.
      ThemeController.modoSol.value = false;
      await ThemeController.load();
      expect(ThemeController.modoSol.value, isTrue);
    });
  });
}
