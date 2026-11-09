/// Sistema de diseño v1.1 — Iron Body Gym.
///
/// Tokens centralizados: colores (claro/oscuro), tipografía, espaciado,
/// radios y sombras. Toda la app debe usar estos tokens en vez de
/// colores hardcodeados.
///
/// Target: gama media — se permite diseño rico (sombras sutiles,
/// gradientes) manteniendo apertura rápida sin conexión.
///
/// NORMAS DE LA FUNDACIÓN (1.29 OG-0, escritas — no negociables):
/// 1. **Ningún estado solo por color** — dinero y sync incluidos:
///    todo estado lleva palabra; banners y diálogos, icono +
///    palabra. (Hereda la A.7.6 del DS V2 de Clientes.)
/// 2. **Blanco sobre naranja, prohibido**: sobre la marca va
///    [AppColores.sobreMarca] (grafito, 6,32:1; el blanco da 2,75).
/// 3. **Texto semántico = rol `*Texto`** resuelto por tema; el
///    color brillante (exito/alerta/error/info) es relleno o
///    gráfico, nunca texto directo en pantallas nuevas.
/// 4. **Ningún `Color(0x…)` nuevo fuera de este archivo**: todo
///    color nace como token con nombre aquí.
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
  // 1.30 D1 (COMP-A): los dos verdes de ICONO del badge
  // verde de módulos (IconoModuloBadge.verde), tokenizados
  // con su valor exacto — eran los últimos literales de las
  // fábricas de componentes.dart fuera de la excepción
  // colorSignificadoChip. Son color de gráfico, no de texto.
  static const exitoIconoOscuro = Color(0xFF4ADE80);
  static const exitoIconoClaro = Color(0xFF16A34A);
  static const alerta = Color(0xFFF59E0B);
  static const alertaOscuro = Color(0xFFD97706);
  static const error = Color(0xFFEF4444);
  static const errorOscuro = Color(0xFFB91C1C);
  static const info = Color(0xFF3B82F6);
  static const infoOscuro = Color(0xFF1D4ED8);

  // --- Roles de TEXTO de los semánticos (1.29 OG-0, D-02) ---
  // Los brillantes de arriba son color de RELLENO o gráfico:
  // como texto fallan AA sobre las superficies reales (GD-02:
  // error sobre la superficie elevada oscura 3,81; exito sobre
  // blanco 2,28). El texto de estado se pide SIEMPRE por estos
  // roles, resueltos por brillo con los helpers exitoTexto /
  // alertaTexto / errorTexto / infoTexto de abajo. Valores y
  // cuentas de la tabla normativa del estudio de diseño 1.29
  // (§4.1), verificados por test codificado:
  //   oscuro sobre fondo/superficie/elevada · claro sobre
  //   blanca/fondo/hundida, todo ≥ 4,5 salvo el límite declarado
  //   de exitoTextoClaro sobre hundida (4,40: la hundida no
  //   aloja texto de estado).
  static const exitoTextoClaro = Color(0xFF15803D);
  static const exitoTextoOscuro = Color(0xFF22C55E);
  static const alertaTextoClaro = Color(0xFF9C4A0C);
  static const alertaTextoOscuro = Color(0xFFF59E0B);
  static const errorTextoClaro = Color(0xFFB91C1C);
  static const errorTextoOscuro = Color(0xFFFF6B6B);
  static const infoTextoClaro = Color(0xFF1D4ED8);
  static const infoTextoOscuro = Color(0xFF38BDF8);

  // --- Fondos SÓLIDOS de estado (1.29 OG-0, D-03) ---
  // Invariantes por tema; encima va Colors.white literal
  // (7,68 / 7,09 / 6,54 / 7,56 : 1, verificado por test).
  // Para los avisos que no pueden fallar (AvisoEstado en
  // componentes.dart): fondo sólido + icono + palabra, nunca
  // un tinte translúcido.
  static const exitoFondo = Color(0xFF065F46);
  static const avisoFondo = Color(0xFF92400E);
  static const errorFondo = Color(0xFFB3261E);
  static const infoFondo = Color(0xFF075985);

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

  // 1.29 (Oleada 5, D-04): los dos pares del banner que
  // NO coincidían con ningún semántico completo dejan de
  // ser literales en widgets.dart. «Enviando» cabalga
  // ámbar→naranja quemado y «Fotos» el púrpura de las
  // subidas; «Descargando» usa info/infoOscuro y «Error»
  // error/errorOscuro directamente, como ya hacían el
  // verde (exito) y el ámbar de pendientes (bannerAlertaA
  // + alertaOscuro).
  static const bannerEnviandoA = Color(0xFFF59E0B);
  static const bannerEnviandoB = Color(0xFFEA580C);
  static const bannerFotosA = Color(0xFFA855F7);
  static const bannerFotosB = Color(0xFF7C3AED);

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
  // 1.30 D1 (UI130-04): #757575 daba 4,23 sobre fondoClaro
  // (bajo AA para texto pequeño); #6B6B6B da 4,89 sobre el
  // fondo y ≈5,48 sobre blanco — fijado por test con los
  // tres pares reales del rol (fondo, superficie y hundida).
  // El oscuro (#B0B0B0, 8,64) no se toca.
  static const textoSecundarioClaro = Color(0xFF6B6B6B);
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

  /// Gradiente RESERVADO del FAB del speed dial (v1.3.6; tokenizado
  /// en la 1.29 O9 con nombre propio, como mandó la pasada de
  /// diseño: NO es el gradiente de marca general — sus extremos
  /// (#FF8A00 → #EA580C) son los del dial y solo los usa él).
  static const gradienteDial = LinearGradient(
    colors: [Color(0xFFFF8A00), Color(0xFFEA580C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
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

  /// Contenido sobre la MARCA (1.29 OG-0, D-01 · GD-01): el
  /// blanco sobre #E8821A da 2,75:1 y falla AA incluso en
  /// texto grande; este grafito da 6,32:1 (y 4,98 sobre el
  /// extremo oscuro del gradiente primario, 8,09 sobre el
  /// ámbar). Lo fijan el tema (botón elevado, botón relleno,
  /// FAB, onPrimary) y por herencia [BotonPrimario]. Regla
  /// de la fundación: blanco sobre naranja, prohibido.
  static const sobreMarca = Color(0xFF1A1A1C);

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

  /// Texto de éxito según el brillo actual (rol D-02).
  static Color exitoTexto(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? exitoTextoOscuro
          : exitoTextoClaro;

  /// Texto de alerta según el brillo actual (rol D-02).
  /// OJO: en claro es #9C4A0C, NO alertaOscuro (#D97706 da
  /// 3,19 sobre blanco) ni #B45309 (ese ya es naranjaTexto:
  /// aviso y marca serían el mismo color).
  static Color alertaTexto(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? alertaTextoOscuro
          : alertaTextoClaro;

  /// Texto de error según el brillo actual (rol D-02).
  /// En oscuro es #FF6B6B y no #FF5252: sobre la superficie
  /// elevada de Gestión (#2A2A2A) el FF5252 queda en 4,50
  /// exactos, sin margen; el FF6B6B deja 5,17.
  static Color errorTexto(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? errorTextoOscuro
          : errorTextoClaro;

  /// Texto de información según el brillo actual (rol D-02).
  static Color infoTexto(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? infoTextoOscuro
          : infoTextoClaro;

  // --- Identidad de módulo del Panel (1.29 OG-0, D-05) ---
  // Los 6 tintes viven SOLO en la pastilla del icono del
  // módulo y en su cabecera, siempre junto al nombre del
  // módulo. «Caja y dinero» deja el verde de estado por el
  // dorado (P-07): el verde significa solo «al día»/éxito
  // en toda la app. Guarda: el dorado de módulo no se usa
  // como tinte dentro de las pantallas de caja — dentro
  // del dinero, dorado significa una sola cosa: efectivo.
  static const moduloCaja = Color(0xFFD9A441);
  static const moduloClientes = info;
  static const moduloEquipo = naranja;
  static const moduloSuplementos = Color(0xFFA855F7);
  static const moduloConfiguracion = Color(0xFF9AA3B2);
  static const moduloControl = Color(0xFF14B8A6);

  // --- Categórica de trabajo (1.29 OG-0, D-11) ---
  // Color con función, SIEMPRE junto a la palabra (nombre
  // del entrenador o del método): jamás como estado (un
  // entrenador «en rojo» no significa nada). En oscuro
  // mandan los valores base (6,06–8,67 sobre las
  // superficies); en claro, la variante oscurecida hasta
  // ≥ 3,0 sobre blanco (calculada, no a ojo; el test
  // codificado la verifica).
  static const entrenador2 = Color(0xFF38BDF8);
  static const entrenador2Claro = Color(0xFF2D97C6);
  static const entrenador3 = Color(0xFFA78BFA);
  static const entrenador3Claro = Color(0xFF967DE1);
  static const entrenador4 = Color(0xFF34D399);
  static const entrenador4Claro = Color(0xFF279E73);

  /// Color de la posición [indice] en la lista estable de
  /// entrenadores: 0 = dueño (la marca; en claro, su
  /// variante de texto legible), 1..3 = los siguientes por
  /// ORDEN de la lista — la asignación es por posición,
  /// nunca por nombre escrito en código. Si la lista crece
  /// más allá de 4 personas, los colores rotan: la
  /// categórica distingue de un vistazo hasta 4.
  static Color colorEntrenador(BuildContext context, int indice) {
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    switch (indice % 4) {
      case 0:
        return oscuro ? naranja : naranjaTexto;
      case 1:
        return oscuro ? entrenador2 : entrenador2Claro;
      case 2:
        return oscuro ? entrenador3 : entrenador3Claro;
      default:
        return oscuro ? entrenador4 : entrenador4Claro;
    }
  }

  /// Método de pago: efectivo = dorado, transferencia =
  /// azul. Solo junto a la palabra «efectivo» /
  /// «transferencia»: el color refuerza, no sustituye.
  static const metodoEfectivo = Color(0xFFD9A441);
  static const metodoEfectivoClaro = Color(0xFFB28635);
  static const metodoTransferencia = Color(0xFF60A5FA);
  static const metodoTransferenciaClaro = Color(0xFF538ED7);

  /// Dorado de «efectivo» según el brillo actual.
  static Color colorEfectivo(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? metodoEfectivo
          : metodoEfectivoClaro;

  /// Azul de «transferencia» según el brillo actual.
  static Color colorTransferencia(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? metodoTransferencia
          : metodoTransferenciaClaro;
  // --- Roles nacidos en la Oleada 8 de la 1.30 (§9.2) ---
  // Literales que ya eran un rol con nombre en las pantallas y
  // vivían sueltos: la oleada los centraliza con el VALOR
  // EXACTO que ya pintaban (sin cambio visual; un ajuste
  // futuro del rol se hace en un solo sitio).

  /// Verde de marca de WhatsApp (el icono de la acción).
  static const whatsapp = Color(0xFF25D366);

  /// Cuenta a la Casa: la pastilla dorada — fondo, icono y
  /// texto sobre ese fondo. Tinte claro fijo en ambos temas,
  /// como ya lo pintaban buscar, inscribir y acceso.
  static const casaFondo = Color(0xFFFFF3CD);
  static const casaIcono = Color(0xFFB8860B);
  static const casaTexto = Color(0xFF7A5A00);

  /// Dorado de la pastilla y la línea Plus de Invitados.
  static const doradoPlus = Color(0xFF9A7B0A);

  /// Fondo de la vista previa del comprobante, tal y como lo
  /// recibirá el cliente (venta y detalle de suplemento).
  static const comprobanteFondo = Color(0xFFE7F6EC);

  /// Bloque «por revisar» del Panel: superficie cálida propia
  /// con su par claro/oscuro (distinta de alertaSuperficie).
  static const avisoPanelFondoClaro = Color(0xFFFFF6E5);
  static const avisoPanelFondoOscuro = Color(0xFF1B150B);
  static const avisoPanelBordeOscuro = Color(0xFF6B4A12);

  /// Texto oscuro sobre el botón naranja (primario) de las
  /// acciones rápidas del Panel.
  static const sobreNaranjaOscuro = Color(0xFF171106);

  /// Rojo suave del icono de alerta sobre fondo oscuro (el
  /// mismo valor que colorSignificadoChip usa para el error
  /// en oscuro dentro de componentes).
  static const errorIconoOscuro = Color(0xFFF87171);

  /// Azul del badge de agua, par oscuro/claro (junto a
  /// azulAgua, el del gradiente de dosis de agua).
  static const azulAguaOscuro = Color(0xFF60A5FA);
  static const azulAguaClaro = Color(0xFF2563EB);

  /// Resaltado de coincidencias al buscar dentro de una lista
  /// (modo claro; en oscuro manda el naranja translúcido).
  static const resaltadoBusqueda = Color(0xFFFFF176);
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

  // 1.30 D1 (UI130-09): vocabulario cerrado de chips —
  // `chip` (circular) para estado, contador y filtro;
  // `tag` (md) SOLO para etiquetas de metadato no
  // interactivas. Antes ChipEstado usaba lg y las
  // insignias artesanales inventaban su radio (20): a la
  // altura real de un chip se parecían pero no coincidían.
  static const chip = circular;
  static const tag = md;
}

/// Tokens de movimiento (1.30 D1, UI130-32 — la fundación).
///
/// El movimiento es un sistema, como el color: duraciones y
/// curvas con nombre, únicos para toda la app. Ningún
/// componente nuevo escribe una duración literal: pide el
/// token. Valores = los que ya vivían repartidos (la ruta
/// respiraba a 220 ms desde la 1.22; el contador de montos,
/// a 300 ms): tokenizar no cambia el ritmo, lo fija.
/// Todo el sistema respeta `MediaQuery.disableAnimations`:
/// con «reducir movimiento» activo, las primitivas nacen
/// puestas, sin animar.
class AppMovimiento {
  AppMovimiento._();

  /// Micro-interacciones: chips, contadores cortos, sellos.
  static const corta = Duration(milliseconds: 150);

  /// La respiración estándar: transición de ruta, entradas.
  static const media = Duration(milliseconds: 220);

  /// Cifras protagonistas que cuentan hasta su valor.
  static const larga = Duration(milliseconds: 300);

  /// Curva de entrada del sistema (la de la ruta desde 1.22).
  static const curva = Curves.easeOutCubic;

  /// Curva de salida del sistema (la inversa de la ruta).
  static const curvaReversa = Curves.easeInCubic;

  /// Curva suave para contadores y fundidos cortos.
  static const curvaSuave = Curves.easeOut;

  /// Curva con rebote para celebraciones breves (el sello
  /// de un cobro, la confirmación de una inscripción).
  /// Nace en D6 (UI130-32) al tokenizar las dos superficies
  /// que ya compartían `Curves.easeOutBack` literal: el
  /// gesto es del sistema, no de cada pantalla.
  static const curvaPop = Curves.easeOutBack;
}

/// Sombras sutiles (gama media: permitidas, sin exagerar).
///
/// 1.29 OG-0 (D-18): queda UN solo lenguaje de elevación —
/// el del tema ([AppTema]: cardTheme y los botones). Esta
/// clase queda deprecada y sin llamadores; se conserva
/// solo como referencia histórica de los valores.
@Deprecated('La elevación manda del tema (AppTema), no de una '
    'clase paralela. No usar en código nuevo (1.29 D-18).')
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
/// no plano: tarjetas y botones con la elevación del tema (único
/// lenguaje de elevación desde la 1.29, D-18) y el gradiente naranja
/// en el botón primario (BotonPrimario).
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
        // 1.29 D-01 (GD-01): sobre la marca va el grafito
        // sobreMarca (6,32:1); el blanco daba 2,75:1.
        onPrimary: AppColores.sobreMarca,
        surface: superficie,
        error: AppColores.error,
        // Borde del tema (Argón 1.20): igual que antes en modo normal,
        // negro/blanco puro en alto contraste, para que
        // AppColores.borde(context) lo respete.
      ).copyWith(outline: borde),
      scaffoldBackgroundColor:
          oscuro ? AppColores.fondoOscuro : AppColores.fondoClaro,
      // 1.24.2 (reporte de campo de Jc): sin switchTheme, el
      // interruptor APAGADO por defecto de Material 3 casi no
      // contrasta sobre las superficies oscuras de la casa y se
      // veía como una mancha (Inscribir, Ajustes). OFF siempre
      // visible: pista gris clara y pulgar claro en oscuro;
      // ON sigue en el naranja de marca (el por defecto).
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.disabled)) {
            return oscuro
                ? const Color(0xFF333333)
                : const Color(0xFFE0E0E0);
          }
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return oscuro
              ? const Color(0xFF555555)
              : const Color(0xFFC9C9C9);
        }),
        thumbColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.disabled)) {
            return oscuro
                ? const Color(0xFF5A5A5A)
                : const Color(0xFFBDBDBD);
          }
          if (estados.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return oscuro
              ? const Color(0xFFD8D8D8)
              : const Color(0xFF757575);
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return oscuro
              ? const Color(0xFF7A7A7A)
              : const Color(0xFF9E9E9E);
        }),
      ),
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
        // Sombra sutil del tema: la elevación de las tarjetas
        // vive AQUÍ y solo aquí (1.29 D-18).
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
      // 1.30 D3 (UI130-15): superficie ÚNICA de las hojas:
      // fondo del tema, radio superior xl y SIN asa del
      // framework (la pinta HojaAccion, con su geometría).
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: superficie,
        modalBackgroundColor: superficie,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadio.xl)),
        ),
        showDragHandle: false,
      ),
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
          // 1.29 D-01: letra grafito sobre la marca.
          foregroundColor: AppColores.sobreMarca,
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
          // 1.29 D-01: letra grafito sobre la marca.
          foregroundColor: AppColores.sobreMarca,
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
        // 1.29 D-01: icono grafito sobre la marca.
        foregroundColor: AppColores.sobreMarca,
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

  // 1.30 D1 (UI130-32): la duración sale del token de
  // movimiento (AppMovimiento.media = los 220 ms de
  // siempre), no de un literal en la ruta.
  @override
  Duration get transitionDuration => AppMovimiento.media;

  @override
  Duration get reverseTransitionDuration => AppMovimiento.media;
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
    // 1.30 D1 (UI130-32): curvas del token de movimiento
    // (easeOutCubic/easeInCubic, las de siempre).
    final curva = CurvedAnimation(
      parent: animation,
      curve: AppMovimiento.curva,
      reverseCurve: AppMovimiento.curvaReversa,
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
