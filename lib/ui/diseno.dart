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

  // --- Gradientes del banner de sync ---
  // Cola 1.20: los hex sueltos de widgets.dart pasan a ser
  // tokens con nombre, con los VALORES EXACTOS de siempre
  // (sin cambio visual). Los pares que ya coincidían con un
  // semántico (verde = exito/exitoOscuro, ámbar oscuro =
  // alertaOscuro) usan el semántico directamente.
  static const bannerGrisA = Color(0xFF9CA3AF);
  static const bannerGrisB = Color(0xFF6B7280);
  static const bannerAlertaA = Color(0xFFFBBF24);
  static const bannerInfoA = Color(0xFF60A5FA);
  static const bannerInfoB = Color(0xFF2563EB);

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

  /// Color de superficie según el tema actual.
  ///
  /// Delega en `colorScheme.surface` (Argón 1.20): en modo normal vale
  /// lo mismo que antes, y en alto contraste respeta el blanco/negro
  /// puro del tema en vez de quedarse en el gris del modo oscuro.
  static Color superficie(BuildContext context) =>
      Theme.of(context).colorScheme.surface;

  /// Color de fondo según el brillo actual.
  static Color fondo(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? fondoOscuro
          : fondoClaro;

  /// Color de borde según el tema actual.
  ///
  /// Delega en `colorScheme.outline` (fijado en [AppTema] al mismo
  /// valor que antes en modo normal, y a negro/blanco puro en alto
  /// contraste). Igual que [superficie], no ignora el alto contraste.
  static Color borde(BuildContext context) =>
      Theme.of(context).colorScheme.outline;

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

  /// Azul agua (botón Solo agua, 1.19): se lee al instante como agua.
  static const azulAgua = Color(0xFF1E88E5);

  /// Degradado dosis + agua (1.19): naranja a azul, mezcla de ambos.
  static const gradienteDosisAgua = LinearGradient(
    colors: [naranja, azulAgua],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // --- P0 (1.20, paquete de diseño Argón) ---
  // Superficies con jerarquía: elevada flota sobre la tarjeta, hundida
  // se hunde hacia el fondo. Valores por modo + helpers por brillo.
  static const superficieElevadaClaro = Colors.white;
  static const superficieHundidaClaro = Color(0xFFF0F0F0);
  static const superficieElevadaOscuro = Color(0xFF2A2A2A);
  static const superficieHundidaOscuro = Color(0xFF121212);

  /// Detecta el tema de alto contraste (Argón 1.20): [AppTema] fija
  /// `outline` a negro/blanco puro solo en alto contraste, así que el
  /// borde del tema lo delata en ambos brillos.
  static bool _altoContraste(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Theme.of(context).brightness == Brightness.dark
        ? esquema.outline == Colors.white
        : esquema.outline == Colors.black;
  }

  /// Superficie elevada según el brillo actual (plana en alto contraste).
  static Color superficieElevada(BuildContext context) {
    if (_altoContraste(context)) {
      return Theme.of(context).colorScheme.surface;
    }
    return Theme.of(context).brightness == Brightness.dark
        ? superficieElevadaOscuro
        : superficieElevadaClaro;
  }

  /// Superficie hundida según el brillo actual (plana en alto contraste).
  static Color superficieHundida(BuildContext context) {
    if (_altoContraste(context)) {
      return Theme.of(context).colorScheme.surface;
    }
    return Theme.of(context).brightness == Brightness.dark
        ? superficieHundidaOscuro
        : superficieHundidaClaro;
  }

  /// Borde todavía más sutil que [bordeClaro]/[bordeOscuro].
  static const bordeSutilClaro = Color(0xFFEDEDED);
  static const bordeSutilOscuro = Color(0xFF2E2E2E);

  /// Borde sutil según el brillo actual (puro en alto contraste).
  static Color bordeSutil(BuildContext context) {
    if (_altoContraste(context)) {
      return Theme.of(context).colorScheme.outline;
    }
    return Theme.of(context).brightness == Brightness.dark
        ? bordeSutilOscuro
        : bordeSutilClaro;
  }

  /// Naranja para texto (Argón 1.20, corrección matemática):
  /// #B45309 pasa AA sobre blanco (5.18:1) Y sobre grises claros
  /// (#F0F0F0: 4.64:1), donde el #C25E00 original se quedaba corto
  /// (4.01:1). Vale también como fondo de badge con texto blanco.
  static const naranjaTexto = Color(0xFFB45309);

  /// Naranja para texto en modo oscuro (el claro se apaga sobre negro).
  static const naranjaTextoOscuro = Color(0xFFFB923C);

  /// Naranja para texto según el brillo actual.
  static Color textoNaranja(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? naranjaTextoOscuro
          : naranjaTexto;

  /// Contenido (texto/icono) sobre fondo naranja.
  static const sobreNaranja = Colors.white;

  /// Superficie y borde tintados de alerta (avisos, no errores).
  static const alertaSuperficieClaro = Color(0xFFFEF3C7);
  static const alertaBordeClaro = Color(0xFFFDE68A);
  static const alertaSuperficieOscuro = Color(0xFF3D2A00);
  static const alertaBordeOscuro = Color(0xFF92600A);

  /// Superficie de alerta según el brillo actual.
  static Color alertaSuperficie(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? alertaSuperficieOscuro
          : alertaSuperficieClaro;

  /// Borde de alerta según el brillo actual.
  static Color alertaBorde(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? alertaBordeOscuro
          : alertaBordeClaro;
}

/// Tipografía del sistema (V1 1.20, escala contractual).
///
/// Roles y tamaños, sin excepciones en pantallas nuevas:
/// display 32 · metrica 22 · tituloPagina 20 · titulo 18 ·
/// subtitulo 15 · cuerpo 14 · secundario 13 · etiqueta 12 ·
/// metadato 12 · minuscula/microtexto 11.
/// Regla: ningún texto operativo importante por debajo de 12 px;
/// 11 px solo para microtexto no operativo.
class AppTexto {
  AppTexto._();

  /// Números grandes: dinero, conteos, vencimientos.
  /// 1.23 (Delta Argón 6ª, pulido): cifras tabulares — los
  /// dígitos ocupan el mismo ancho y las columnas de dinero
  /// dejan de «bailar» al cambiar un valor.
  static const display = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.5,
    height: 1.1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const displayPequeno = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.25,
    height: 1.15,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Título de página (P0 1.20).
  static const tituloPagina = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    height: 1.25,
  );

  /// Métrica destacada (P0 1.20): cifra única protagonista.
  static const metrica = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.25,
    height: 1.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Títulos de sección.
  static const titulo = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    height: 1.25,
  );

  static const subtitulo = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// Cuerpo normal.
  static const cuerpo = TextStyle(fontSize: 14, height: 1.5);

  /// Texto secundario / hints.
  static const secundario = TextStyle(fontSize: 13, height: 1.4);

  /// Etiquetas pequeñas (badges, captions).
  static const etiqueta = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
    height: 1.2,
  );

  /// Metadato: fecha, autor, detalle secundario en filas (12, regular).
  static const metadato = TextStyle(fontSize: 12, height: 1.4);

  static const minuscula = TextStyle(fontSize: 11, height: 1.4);
}

/// Espaciado consistente (V2 1.20, retícula 4/8 pt).
///
/// Todos los valores son múltiplos de 4; los escalones habituales
/// son 8/12/16/24/32. Márgenes laterales, separación entre
/// secciones, altura de filas y aire interno de tarjetas usan
/// solo estos escalones.
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
      // 1.22 Diseño Bloque 1 (T1): UNA transición del sistema
      // para las 95 rutas (desvanecido + desplazamiento corto,
      // duración y curva únicas), en vez del salto por defecto
      // de cada plataforma.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: TransicionPaginaIron(),
          TargetPlatform.iOS: TransicionPaginaIron(),
          TargetPlatform.windows: TransicionPaginaIron(),
          TargetPlatform.macOS: TransicionPaginaIron(),
          TargetPlatform.linux: TransicionPaginaIron(),
          TargetPlatform.fuchsia: TransicionPaginaIron(),
        },
      ),
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColores.naranja,
        brightness: b,
        primary: AppColores.naranja,
        onPrimary: Colors.white,
        surface: superficie,
        error: AppColores.error,
        // Borde del tema (Argón 1.20): igual que antes en modo normal,
        // negro/blanco puro en alto contraste, para que
        // AppColores.borde(context) lo respete.
      ).copyWith(outline: borde),
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
          // D-16 (1.21): el 16 literal no existe en la escala;
          // el botón primario usa el rol subtitulo (15).
          textStyle:
              AppTexto.subtitulo.copyWith(fontWeight: FontWeight.bold),
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
              AppTexto.subtitulo.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColores.naranja,
          minimumSize: const Size(48, 44),
          textStyle:
              AppTexto.cuerpo.copyWith(fontWeight: FontWeight.w600),
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
        displaySmall: AppTexto.metrica,
        headlineMedium: AppTexto.tituloPagina,
        titleLarge: AppTexto.titulo,
        titleMedium: AppTexto.subtitulo,
        bodyLarge: AppTexto.cuerpo,
        bodyMedium: AppTexto.secundario,
        bodySmall: AppTexto.metadato,
        labelLarge: AppTexto.etiqueta,
        labelSmall: AppTexto.minuscula,
      ).apply(bodyColor: texto, displayColor: texto),
    );
  }
}

/// 1.22 Diseño Bloque 1 (T1, corrección de panel): la ruta
/// del sistema. El PageTransitionsBuilder da la FORMA de la
/// transición pero NO su duración (la manda el PageRoute);
/// RutaIron fija 220 ms en entrada y salida para que la
/// promesa de T1 sea real en las 95 rutas, que la usan
/// todas tras la migración mecánica de MaterialPageRoute.
class RutaIron<T> extends MaterialPageRoute<T> {
  RutaIron({
    required super.builder,
    super.settings,
    super.maintainState = true,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
  });

  @override
  Duration get transitionDuration =>
      const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration =>
      const Duration(milliseconds: 220);
}

/// 1.22 Diseño Bloque 1 (T1): la transición de página del
/// sistema — desvanecido + desplazamiento vertical corto
/// (24 px), con curva easeOutCubic, idéntica en
/// entrada y salida. Sustituye el salto por defecto de
/// Material en todas las rutas.
class TransicionPaginaIron extends PageTransitionsBuilder {
  const TransicionPaginaIron();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curva = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curva,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(curva),
        child: child,
      ),
    );
  }
}
