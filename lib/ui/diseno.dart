/// Sistema de diseño v1.1 — Iron Body Gym.
///
/// Tokens centralizados: colores (claro/oscuro), tipografía, espaciado,
/// radios y sombras. Toda la app debe usar estos tokens en vez de
/// colores hardcodeados.
///
/// Target: gama media — se permite diseño rico (sombras sutiles,
/// gradientes) manteniendo apertura rápida sin conexión.
library;

import 'package:flutter/material.dart';

/// Paleta de la marca.
class AppColores {
  AppColores._();

  /// Naranja vibrante (acento principal).
  static const naranja = Color(0xFFE8821A);

  /// Naranja más intenso para gradientes.
  static const naranjaOscuro = Color(0xFFD96A0B);

  /// Carbón / grafito.
  static const carbon = Color(0xFF232323);

  /// Carbón profundo (fondos oscuros).
  static const carbonProfundo = Color(0xFF141414);

  // --- Semánticos ---
  static const exito = Color(0xFF22C55E);
  static const exitoOscuro = Color(0xFF15803D);
  static const alerta = Color(0xFFF59E0B);
  static const alertaOscuro = Color(0xFFD97706);
  static const error = Color(0xFFEF4444);
  static const errorOscuro = Color(0xFFB91C1C);
  static const info = Color(0xFF3B82F6);
  static const infoOscuro = Color(0xFF1D4ED8);

  // --- Superficies modo claro ---
  static const fondoClaro = Color(0xFFF5F5F5);
  static const superficieClaro = Colors.white;
  static const bordeClaro = Color(0xFFE0E0E0);

  // --- Superficies modo oscuro ---
  static const fondoOscuro = Color(0xFF121212);
  static const superficieOscuro = Color(0xFF1E1E1E);
  static const bordeOscuro = Color(0xFF3A3A3A);

  // --- Textos ---
  static const textoClaro = Color(0xFF1A1A1A);
  static const textoSecundarioClaro = Color(0xFF757575);
  static const textoOscuro = Color(0xFFF5F5F5);
  static const textoSecundarioOscuro = Color(0xFFB0B0B0);

  /// Color de superficie según el brillo actual.
  static Color superficie(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? superficieOscuro
          : superficieClaro;

  /// Color de fondo según el brillo actual.
  static Color fondo(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? fondoOscuro
          : fondoClaro;

  /// Color de borde sutil según el brillo actual.
  static Color borde(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? bordeOscuro
          : bordeClaro;

  /// Color de texto principal según el brillo actual.
  static Color texto(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? textoOscuro
          : textoClaro;

  /// Color de texto secundario según el brillo actual.
  static Color textoSecundario(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? textoSecundarioOscuro
          : textoSecundarioClaro;

  /// Gradiente naranja (botones primarios, headers).
  static const gradienteNaranja = LinearGradient(
    colors: [Color(0xFFF59E0B), naranjaOscuro],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Gradiente carbón (headers oscuros, login).
  static const gradienteCarbon = LinearGradient(
    colors: [carbon, carbonProfundo],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

/// Tipografía del sistema.
class AppTexto {
  AppTexto._();

  /// Números grandes: dinero, conteos, vencimientos.
  static const display = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.5,
  );

  static const displayPequeno = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.25,
  );

  /// Títulos de sección.
  static const titulo = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
  );

  static const subtitulo = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  /// Cuerpo normal.
  static const cuerpo = TextStyle(fontSize: 14);

  /// Texto secundario / hints.
  static const secundario = TextStyle(fontSize: 13);

  /// Etiquetas pequeñas (badges, captions).
  static const etiqueta = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );

  static const minuscula = TextStyle(fontSize: 11);
}

/// Espaciado consistente.
class AppEspacio {
  AppEspacio._();

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Radios de borde.
class AppRadio {
  AppRadio._();

  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const circular = 999.0;
}

/// Sombras sutiles (gama media: permitidas, sin exagerar).
class AppSombra {
  AppSombra._();

  static List<BoxShadow> tarjeta(BuildContext context) {
    final oscuro =
        Theme.of(context).brightness == Brightness.dark;
    return [
      BoxShadow(
        color: (oscuro ? Colors.black : Colors.grey)
            .withValues(alpha: oscuro ? 0.4 : 0.12),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ];
  }

  static List<BoxShadow> botonPrimario = [
    BoxShadow(
      color: AppColores.naranja.withValues(alpha: 0.35),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];
}
