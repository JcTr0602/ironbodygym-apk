/// Modo claro/oscuro a gusto del entrenador (se guarda en el teléfono).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeController {
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier(ThemeMode.light);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    mode.value =
        p.getString('theme') == 'dark' ? ThemeMode.dark : ThemeMode.light;
  }

  static Future<void> toggle() async {
    mode.value =
        mode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'theme', mode.value == ThemeMode.dark ? 'dark' : 'light');
  }
}
