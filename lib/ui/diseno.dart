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


/// v1.2.4 (Hark): tema único (claro/oscuro) a partir de los tokens.
/// Antes estaba duplicado en main.dart. Unifica botones (alto mínimo 48,
/// estado deshabilitado visible), campos, diálogos y avisos. Diseño rico,
/// no plano: tarjetas y botones con sombra sutil (AppSombra) y el
/// gradiente naranja en el botón primario (BotonPrimario).
class AppTema {
  AppTema._();

  static ThemeData claro() => _tema(Brightness.light);
  static ThemeData oscuro() => _tema(Brightness.dark);

  /// v1.2.5 (3.4): variantes de alto contraste (WCAG AA).
  static ThemeData claroAltoContraste() =>
      _tema(Brightness.light, altoContraste: true);
  static ThemeData oscuroAltoContraste() =>
      _tema(Brightness.dark, altoContraste: true);

  static ThemeData _tema(Brightness b, {bool altoContraste = false}) {
    final oscuro = b == Brightness.dark;
    final superficie = altoContraste
        ? (oscuro ? Colors.black : Colors.white)
        : (oscuro
            ? AppColores.superficieOscuro
            : AppColores.superficieClaro);
    final borde = altoContraste
        ? (oscuro ? Colors.white : Colors.black)
        : (oscuro ? AppColores.bordeOscuro : AppColores.bordeClaro);
    final texto = altoContraste
        ? (oscuro ? Colors.white : Colors.black)
        : (oscuro ? AppColores.textoOscuro : AppColores.textoClaro);
    final secundario = oscuro
        ? AppColores.textoSecundarioOscuro
        : AppColores.textoSecundarioClaro;
    final deshabilitadoFondo = oscuro ? const Color(0xFF2C2C2C) : const Color(0xFFE6E6E6);
    final deshabilitadoTexto = oscuro ? const Color(0xFF7A7A7A) : const Color(0xFF9E9E9E);
    final forma = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadio.md));
    const minimo = Size(64, 48);

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColores.naranja,
        brightness: b,
        primary: AppColores.naranja,
        onPrimary: Colors.white,
        surface: superficie,
        error: AppColores.error,
      ),
      scaffoldBackgroundColor:
          oscuro ? AppColores.fondoOscuro : AppColores.fondoClaro,
      appBarTheme: AppBarTheme(
        backgroundColor:
            oscuro ? AppColores.carbonProfundo : AppColores.carbon,
        foregroundColor: Colors.white,
        elevation: 2,
        scrolledUnderElevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        centerTitle: false,
        titleTextStyle: AppTexto.titulo.copyWith(color: Colors.white),
      ),
      cardTheme: CardThemeData(
        color: superficie,
        // Sombra sutil (misma gama que AppSombra.tarjeta).
        elevation: 2,
        shadowColor: oscuro
            ? Colors.black.withValues(alpha: 0.6)
            : Colors.black.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.only(bottom: AppEspacio.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.lg),
          side: BorderSide(color: borde),
        ),
      ),
      dividerTheme: DividerThemeData(color: borde, thickness: 1, space: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: superficie,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadio.xl)),
        titleTextStyle: AppTexto.titulo.copyWith(color: texto),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: oscuro ? const Color(0xFF2E2E2E) : AppColores.carbon,
        contentTextStyle: AppTexto.cuerpo.copyWith(color: Colors.white),
        actionTextColor: AppColores.naranja,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadio.md)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColores.naranja,
          foregroundColor: Colors.white,
          disabledBackgroundColor: deshabilitadoFondo,
          disabledForegroundColor: deshabilitadoTexto,
          elevation: 2,
          shadowColor: AppColores.naranja.withValues(alpha: 0.45),
          minimumSize: minimo,
          shape: forma,
          textStyle:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColores.naranja,
          foregroundColor: Colors.white,
          disabledBackgroundColor: deshabilitadoFondo,
          disabledForegroundColor: deshabilitadoTexto,
          minimumSize: minimo,
          shape: forma,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: texto,
          side: BorderSide(color: borde, width: 1.5),
          minimumSize: minimo,
          shape: forma,
          textStyle:
              const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColores.naranja,
          minimumSize: const Size(48, 44),
          textStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: superficie,
        labelStyle: TextStyle(color: secundario),
        floatingLabelStyle: const TextStyle(color: AppColores.naranja),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.md),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadio.md),
            borderSide: BorderSide(color: borde)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadio.md),
            borderSide: BorderSide(color: borde)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadio.md),
            borderSide:
                const BorderSide(color: AppColores.naranja, width: 2)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadio.md),
            borderSide: const BorderSide(color: AppColores.error)),
        errorMaxLines: 3,
      ),
      chipTheme: ChipThemeData(
        selectedColor: AppColores.naranja.withValues(alpha: 0.2),
        side: BorderSide(color: borde),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadio.circular)),
        labelStyle: AppTexto.etiqueta.copyWith(color: texto),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: AppColores.naranja.withValues(alpha: 0.2),
          selectedForegroundColor: texto,
          minimumSize: const Size(48, 44),
        ),
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: AppColores.naranja),
      listTileTheme: ListTileThemeData(
        iconColor: secundario,
        minVerticalPadding: AppEspacio.sm,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColores.naranja,
        foregroundColor: Colors.white,
      ),
      textTheme: const TextTheme(
        displayLarge: AppTexto.display,
        displayMedium: AppTexto.displayPequeno,
        titleLarge: AppTexto.titulo,
        titleMedium: AppTexto.subtitulo,
        bodyLarge: AppTexto.cuerpo,
        bodyMedium: AppTexto.secundario,
        labelLarge: AppTexto.etiqueta,
      ).apply(bodyColor: texto, displayColor: texto),
    );
  }
}
