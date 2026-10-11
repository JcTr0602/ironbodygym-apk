/// Modo claro/oscuro/sistema y tamaño de letra (se guardan en el teléfono).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'perfil.dart';

class ThemeController {
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier(ThemeMode.system);
  static final ValueNotifier<double> fontScale =
      ValueNotifier(1.0);
  // v1.2.5 (3.4): alto contraste (WCAG AA).
  static final ValueNotifier<bool> altoContraste =
      ValueNotifier(false);

  static ThemeMode _aMode(String tema) {
    switch (tema) {
      case 'claro':
        return ThemeMode.light;
      case 'oscuro':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    // Migración del formato anterior ('theme': 'dark'/'light').
    var tema = p.getString('tema');
    if (tema == null) {
      final viejo = p.getString('theme');
      if (viejo == 'dark') {
        tema = 'oscuro';
      } else if (viejo == 'light') {
        tema = 'claro';
      }
      if (tema != null) {
        await p.setString('tema', tema);
        await p.remove('theme');
      }
    }
    mode.value = _aMode(tema ?? 'sistema');
    fontScale.value =
        await PerfilService.instance.getTamanoLetra();
    // v1.2.5 (3.4): alto contraste.
    altoContraste.value =
        await PerfilService.instance.getAltoContraste();
  }

  static Future<void> setTema(String tema) async {
    await PerfilService.instance.setTema(tema);
    mode.value = _aMode(tema);
  }

  static Future<void> setFontScale(double v) async {
    final c = v.clamp(0.85, 1.3);
    await PerfilService.instance.setTamanoLetra(c);
    fontScale.value = c;
  }

  /// v1.2.5 (3.4): activa/desactiva el alto contraste.
  static Future<void> setAltoContraste(bool v) async {
    await PerfilService.instance.setAltoContraste(v);
    altoContraste.value = v;
  }

  /// Rota sistema → claro → oscuro → sistema (botón de la cabecera).
  static Future<void> ciclo() async {
    final actual = await PerfilService.instance.getTema();
    final sig = actual == 'sistema'
        ? 'claro'
        : actual == 'claro'
            ? 'oscuro'
            : 'sistema';
    await setTema(sig);
  }
}
