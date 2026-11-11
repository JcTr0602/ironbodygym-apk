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

  // 1.32 «Mostrador Táctico»: Modo Sol (claro de Papel Frío para
  // el sol directo del mostrador). SOLO manual, de 1 toque en la
  // cabecera — guarda del contraste de Argón: el encendido
  // automático por sensor de luz queda APAGADO por defecto y NO
  // se implementa (Jc trabaja bajo techo la mayor parte del día;
  // un parpadeo de tema a media venta es inaceptable). No hay
  // ningún código de sensor en la app.
  static final ValueNotifier<bool> modoSol = ValueNotifier(false);
  static const _kModoSol = 'modo_sol_v1';

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
    // 1.32: Modo Sol persistido (default apagado).
    modoSol.value = p.getBool(_kModoSol) ?? false;
  }

  /// 1.32: enciende/apaga el Modo Sol y lo persiste. Al apagarlo
  /// manda de nuevo el modo elegido (sistema/claro/oscuro).
  static Future<void> setModoSol(bool v) async {
    modoSol.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kModoSol, v);
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
