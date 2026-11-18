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

  /// 1.35 (UI-16): la escala de texto SOBRE superficie
  /// oscura (login y piezas de marca), como tokens: antes
  /// cada pantalla escribía sus blancos con alfa a mano.
  // 1.36 (136-290): cada peldaño declara su USO PERMITIDO
  // y su contraste sobre carbonProfundo (#141414):
  /// Texto pleno sobre oscuro — 15,4:1. Uso: texto funcional.
  static const textoSobreOscuro = Color(0xFFFFFFFF);
  /// 60 % — ≈7,1:1. Uso: texto funcional secundario.
  static const textoSobreOscuroSuave = Color(0x99FFFFFF);
  /// 54 % — ≈6,0:1. Uso: texto funcional grande o etiquetas.
  static const textoSobreOscuroMedio = Color(0x8AFFFFFF);
  /// 38 % — ≈3,6:1. Uso: SOLO decorativo o texto grande;
  /// PROHIBIDO para pistas de campo y texto funcional.
  static const textoSobreOscuroTenue = Color(0x61FFFFFF);
  /// 24 % — ≈2,2:1. Uso: SOLO decorativo (marca de agua,
  /// versión de la app); PROHIBIDO para texto que se lee.
  static const textoSobreOscuroMinimo = Color(0x3DFFFFFF);

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
  static const exitoTextoClaro = Color(0xFF166534); // 1.36 (136-278): #15803D daba 4,22 sobre grisTecnico instalado; #166534 da 6,00 y 6,26 sobre hundida
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

  // 1.29 (Oleada 5, D-04): los dos pares del banner que
  // NO coincidían con ningún semántico completo dejan de
  // ser literales en widgets.dart. «Enviando» cabalga
  // ámbar→naranja quemado y «Fotos» el púrpura de las
  // subidas; «Descargando» usa info/infoOscuro y «Error»
  // error/errorOscuro directamente, como ya hacían el
  // verde (exito) y el ámbar de pendientes (bannerAlertaA
  // + alertaOscuro).
  static const bannerEnviandoB = Color(0xFFEA580C);

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
  static const textoSecundarioClaro = Color(0xFF5F5F5F); // 1.36 (136-278): #6B6B6B daba 4,49 sobre grisTecnico instalado; #5F5F5F da 5,37
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
  /// 1.36 (136-287): el gradiente de marca nace y muere en
  /// la marca — antes arrancaba en #F59E0B (el ámbar de
  /// alerta) y el naranja de la casa no estaba en ningún
  /// extremo. Regla gradiente/plano: gradiente SOLO en el
  /// botón primario de la casa ([BotonPrimario]) y en las
  /// cabeceras de marca; el tema pinta los botones Material
  /// en plano con el mismo extremo inicial.
  static const gradienteNaranja = LinearGradient(
    colors: [naranja, naranjaOscuro],
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

  // --- 1.32 «Mostrador Táctico» (rediseño de Argón, inventario
  // §4.1) ---
  // Paleta táctica EXACTA del plano. Los tokens anteriores NO se
  // tocan (sus valores están fijados por tests de contraste); estos
  // son nombres NUEVOS que consumen el marco de 4 Pilares, el Dock
  // y los temas [AppTema.tacticoOscuro]/[AppTema.sol]. El naranja
  // de marca (#E8821A) queda RESERVADO al logo y al botón Cobrar;
  // la acción principal del sistema táctico es el cobalto.
  /// Fondo del tema táctico oscuro.
  static const pizarra = Color(0xFF0B0F14);

  /// Fondo del Modo Sol (claro táctico).
  static const papelFrio = Color(0xFFF4F6F8);

  /// Superficie 1 del tema táctico oscuro.
  static const grafitoTactico = Color(0xFF151C24);

  /// 1.35 (UX-02): gris cálido fantasma de los destinos
  /// inactivos de la barra «Grafito» (sobre el cuerpo
  /// grafito, en ambos temas: la barra es de marca).
  static const fantasmaBarra = Color(0xFFA79C8F);

  /// 1.35 (UX-02): sombra de la barra «Grafito» flotante
  /// y su línea de luz superior (blanco al 24 %).
  static const sombraBarra = Color(0x59000000);
  static const luzBarra = Color(0x3DFFFFFF);

  /// Superficie 2 del tema táctico oscuro.
  static const acero = Color(0xFF1E2936);

  /// Superficie 2 del Modo Sol.
  static const grisTecnico = Color(0xFFE8ECEF);

  /// Acción principal y navegación (tema oscuro).
  static const cobalto = Color(0xFF2563EB);

  /// Acción principal y navegación (Modo Sol).
  static const cobaltoOscuro = Color(0xFF1D4ED8);

  /// Éxito / Al día (tema oscuro).
  static const esmeralda = Color(0xFF10B981);

  /// Éxito / Al día (Modo Sol).
  static const verdeBosque = Color(0xFF047857);

  /// Urgencia media / Por vencer (tema oscuro).
  static const ambarTactico = Color(0xFFFACC15);

  /// Urgencia media / Por vencer (Modo Sol).
  static const ambarTierra = Color(0xFFCA8A04);

  /// Error / Atrasado (tema oscuro).
  static const coral = Color(0xFFEF4444);

  /// Error / Atrasado (Modo Sol).
  static const carmesi = Color(0xFFDC2626);

  /// Estado En Pausa (tema oscuro).
  static const cianHielo = Color(0xFF06B6D4);

  /// Estado En Pausa (Modo Sol).
  static const cianProfundo = Color(0xFF0E7490);

  /// Transferencia / App Plus (tema oscuro).
  static const violetaTactico = Color(0xFF8B5CF6);

  /// Transferencia / App Plus (Modo Sol).
  static const indigoTactico = Color(0xFF6D28D9);

  /// Cuenta a la Casa (tema oscuro; exclusivo, jamás genérico).
  static const doradoReal = Color(0xFFF59E0B);

  /// Cuenta a la Casa (Modo Sol).
  static const doradoRealOscuro = Color(0xFFB45309);

  /// Cobalto de acción según el brillo actual.
  static Color cobaltoDe(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? cobalto
          : cobaltoOscuro;

  /// 1.36 (136-268): verdeDe ES exitoTexto — un solo juego
  /// semántico; la familia táctica deja de ser vocabulario
  /// de estado y queda solo como superficies.
  static Color verdeDe(BuildContext context) => exitoTexto(context);

  /// 1.36 (136-268): ambarDe ES alertaTexto.
  static Color ambarDe(BuildContext context) => alertaTexto(context);

  /// 1.36 (136-268): rojoDe ES errorTexto.
  static Color rojoDe(BuildContext context) => errorTexto(context);




  // --- P0 (1.20, paquete de diseño Argón) ---
  // Superficies con jerarquía: elevada flota sobre la tarjeta, hundida
  // se hunde hacia el fondo. Valores por modo + helpers por brillo.
  static const superficieElevadaClaro = Colors.white;
  static const superficieHundidaClaro = Color(0xFFF0F0F0);
  static const superficieElevadaOscuro = Color(0xFF2A2A2A);
  static const superficieHundidaOscuro = Color(0xFF121212);

  /// 1.35 (UX-09): la detección de alto contraste, pública
  /// para los componentes que se eximen de los efectos de
  /// profundidad (la tarjeta y el fondo del marco).
  static bool esAltoContraste(BuildContext context) =>
      _altoContraste(context);

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

  // --- 1.36 (136-285): papeles que vivían como literales
  // locales dentro de _tema, ahora con nombre y par ---
  /// Fondo de control deshabilitado (sobre él va
  /// [deshabilitadoTexto]; par declarado: legible como
  /// estado, exento de AA por ser control inactivo pero
  /// VISIBLE por decisión del tema).
  static const deshabilitadoFondoClaro = Color(0xFFE6E6E6);
  static const deshabilitadoFondoOscuro = Color(0xFF2C2C2C);
  static const deshabilitadoTextoClaro = Color(0xFF757575);
  static const deshabilitadoTextoOscuro = Color(0xFF9E9E9E);
  /// Interruptor apagado: pista y pulgar por brillo.
  static const interruptorPistaClaro = Color(0xFFC9C9C9);
  static const interruptorPistaOscuro = Color(0xFF555555);
  static const interruptorPistaDeshabClaro = Color(0xFFE0E0E0);
  static const interruptorPistaDeshabOscuro = Color(0xFF333333);
  static const interruptorPulgarClaro = Color(0xFF757575);
  static const interruptorPulgarOscuro = Color(0xFFD8D8D8);
  static const interruptorPulgarDeshabClaro = Color(0xFFBDBDBD);
  static const interruptorPulgarDeshabOscuro = Color(0xFF5A5A5A);
  static const interruptorBordeClaro = Color(0xFF9E9E9E);
  static const interruptorBordeOscuro = Color(0xFF7A7A7A);
  /// Fondo del snack en oscuro (en claro manda carbon).
  static const snackFondoOscuro = Color(0xFF2E2E2E);

  // --- 1.36 (136-269): papeles de CHIP de estado ---
  // La tabla de chips vive aquí, no en componentes: texto
  // de chip por significado y brillo. Reutiliza *Texto
  // donde el valor coincide y tokeniza donde no.
  static const chipExitoOscuro = Color(0xFF4ADE80);
  static const chipInfoOscuro = Color(0xFF60A5FA);
  static const chipAlertaOscuro = Color(0xFFFBBF24);
  static const chipErrorOscuro = Color(0xFFF87171);
  static const chipNeutralClaro = Color(0xFF616161);
  static const chipAgotadoClaro = Color(0xFF4B5563);
  static const chipAgotadoOscuro = Color(0xFF9CA3AF);

  /// Color de texto/borde del chip para un significado
  /// (0=exito 1=info 2=alerta 3=error 4=neutral 5=agotado).
  /// La enum vive en componentes; aquí el índice es el
  /// contrato para no crear dependencia circular.
  static Color chipTexto(int significado, bool oscuro) {
    switch (significado) {
      case 0:
        return oscuro ? chipExitoOscuro : exitoTextoClaro;
      case 1:
        return oscuro ? chipInfoOscuro : infoOscuro;
      case 2:
        return oscuro ? chipAlertaOscuro : avisoFondo;
      case 3:
        return oscuro ? chipErrorOscuro : errorOscuro;
      case 4:
        return oscuro ? textoSecundarioOscuro : chipNeutralClaro;
      default:
        return oscuro ? chipAgotadoOscuro : chipAgotadoClaro;
    }
  }

  /// Naranja para texto (Argón 1.20, corrección matemática):
  /// #B45309 pasa AA sobre blanco (5.18:1) Y sobre grises claros
  /// (#F0F0F0: 4.64:1), donde el #C25E00 original se quedaba corto
  /// (4.01:1). Vale también como fondo de badge con texto blanco.
  static const naranjaTexto = Color(0xFF9A4A08); // 1.36 (136-278): #B45309 daba 4,23 sobre grisTecnico instalado; #9A4A08 da 5,27 (6,26 sobre blanco)

  /// Naranja para texto en modo oscuro (el claro se apaga sobre negro).
  static const naranjaTextoOscuro = Color(0xFFFB923C);

  /// Naranja para texto según el brillo actual.
  static Color textoNaranja(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? naranjaTextoOscuro
          : naranjaTexto;

  /// Contenido (texto/icono) sobre fondo naranja.
  static const contenidoClaro = Colors.white; // 1.36 (136-286): antes «sobreNaranja» — su valor es BLANCO y el nombre invitaba al par prohibido (blanco sobre naranja); se nombra por lo que es

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

  /// 1.32 «Mostrador Táctico»: aplica cifras tabulares a
  /// CUALQUIER estilo. El plano (§4.2) exige
  /// `FontFeature.tabularFigures()` en todo contador, importe y
  /// cronómetro del sistema táctico para que las columnas de
  /// dinero no «bailen» al cambiar un dígito; los estilos con
  /// nombre (display, metrica…) ya la traen, este helper cubre
  /// los estilos compuestos al vuelo.
  static TextStyle conTabulares(TextStyle estilo) {
    final previas = estilo.fontFeatures ?? const <FontFeature>[];
    if (previas.contains(const FontFeature.tabularFigures())) {
      return estilo;
    }
    return estilo.copyWith(
      fontFeatures: [...previas, const FontFeature.tabularFigures()],
    );
  }

  /// 1.35 (UI-25): la familia de marca de los roles
  /// grandes — Barlow Condensed, embebida en dos pesos
  /// (600/700, declarada en pubspec.yaml). SOLO los
  /// cuatro roles de abajo la llevan; el cuerpo sigue en
  /// la fuente del sistema, que rinde mejor en tamaños
  /// pequeños. El wordmark del login hereda la familia
  /// por salir de `display`.
  static const familiaDisplay = 'Barlow Condensed';

  /// 1.36 (136-316): RED DE RESCATE declarada de la familia
  /// de marca: si un glifo no está en el cmap de Barlow
  /// (→, ✓, ★…), el rescate por glifo cae en esta fuente
  /// ELEGIDA, no en la que el OEM decida. Frontera de
  /// familias: Barlow Condensed = titulares grandes, cifras
  /// protagonistas y el nombre del cliente en su ficha
  /// (dato «de marca», 136-303); el sistema = cuerpo.
  static const familiaRespaldo = 'Roboto';

  /// 1.36 (136-316): la familia mono del editor de
  /// GymPedia vive en la declaración, no en un literal
  /// suelto de pantalla (136-311).
  static const familiaCodigo = 'monospace';

  /// Números grandes: dinero, conteos, vencimientos.
  /// 1.23 (Delta Argón 6ª, pulido): cifras tabulares — los
  /// dígitos ocupan el mismo ancho y las columnas de dinero
  /// dejan de «bailar» al cambiar un valor. 1.35 (UI-25):
  /// con Barlow Condensed la feature es real (verificado
  /// en el archivo: los 10 dígitos a 475/498 ud. exactas
  /// con `tnum` activa).
  static const display = TextStyle(
    fontFamily: familiaDisplay,
    fontFamilyFallback: [familiaRespaldo],
    fontSize: 32,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.5,
    // 1.36 (136-312/318): la línea natural medida de
    // Barlow es 1,20; por debajo, la «g» desborda su caja.
    height: 1.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const displayPequeno = TextStyle(
    fontFamily: familiaDisplay,
    fontFamilyFallback: [familiaRespaldo],
    fontSize: 24,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.25,
    height: 1.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Título de página (P0 1.20).
  static const tituloPagina = TextStyle(
    fontFamily: familiaDisplay,
    fontFamilyFallback: [familiaRespaldo],
    fontSize: 20,
    fontWeight: FontWeight.bold,
    height: 1.25,
    // 1.36 (136-295/314): era el ÚNICO rol Barlow sin
    // tabulares y es el que pinta los totales en texto
    // plano (Pagos por método, pendiente, Mi Día).
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Métrica destacada (P0 1.20): cifra única protagonista.
  static const metrica = TextStyle(
    fontFamily: familiaDisplay,
    fontFamilyFallback: [familiaRespaldo],
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

  /// 1.36 (136-313/314): CIFRA DE FILA — el escalón que le
  /// faltaba a las filas de informe y de libro: cuerpo 14
  /// en negrita y SIEMPRE tabular. Todo importe de fila se
  /// pinta con este rol (o con [conTabulares]); un importe
  /// con el rol de su rótulo es el defecto 136-300.
  static const cifraFila = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.bold,
    height: 1.4,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 1.36 (136-313): cabecera de SECCIÓN como rol propio
  /// (15, negrita, tracking leve declarado): la escalera
  /// re-nivelada — pantalla 20 · tarjeta 18 · sección 15.
  static const cabeceraSeccion = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.bold,
    letterSpacing: 0.3,
    height: 1.3,
  );

  /// 1.36 (136-306/313): cabecera de PANEL como rol propio:
  /// su tracking 1.6 era un token practicado en 3 sitios y
  /// declarado en ninguno; aquí queda declarado UNA vez.
  /// Peso 700 (136-315: el 800 no existe en la fuente del
  /// sistema estática).
  static const cabeceraPanel = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.bold,
    letterSpacing: 1.6,
    height: 1.2,
  );

  /// 1.36 (136-315): uso DECLARADO del SemiBold 600
  /// empaquetado de Barlow — los dígitos del teclado del
  /// PIN (antes llegaban al 600 solo como destino
  /// involuntario de un `normal` sobre displayPequeno).
  static const pinDigitos = TextStyle(
    fontFamily: familiaDisplay,
    fontFamilyFallback: [familiaRespaldo],
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.25,
    height: 1.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 1.36 (136-311/316): el mono del editor de GymPedia,
  /// desde la declaración de familias.
  static const codigo = TextStyle(
    fontFamily: familiaCodigo,
    fontSize: 13,
    height: 1.4,
  );
}

/// 1.36 (136-280): escala de PESOS declarada. El desvío
/// real de la tipografía no era el tamaño sino el peso
/// (234 copyWith de fontWeight): todo peso nuevo se pide
/// aquí, no como FontWeight suelto.
class AppPesos {
  AppPesos._();
  static const regular = FontWeight.w400;
  static const medio = FontWeight.w500;
  static const semibold = FontWeight.w600;
  static const bold = FontWeight.w700;
}

/// 1.36 (136-277): tabla ÚNICA concepto → glifo y regla
/// de familia. Regla redondeado/contorno (el patrón real
/// de la app, ahora escrito): INACTIVO = contorno
/// (`*_outline_rounded` / `*_outlined`), ACTIVO o
/// protagonista = redondeado pleno (`*_rounded`). Un
/// concepto = un glifo en toda la app: «Tienda»,
/// «Suplementos» y «Servicio» ya no comparten
/// `Icons.science_rounded`.
class AppIconos {
  AppIconos._();
  static const exito = Icons.check_circle_rounded;
  static const aviso = Icons.warning_amber_rounded;
  static const error = Icons.error_outline_rounded;
  static const info = Icons.info_rounded;
  static const fecha = Icons.calendar_month_rounded;
  static const persona = Icons.person_rounded;
  static const personaInactiva = Icons.person_outline_rounded;
  static const tienda = Icons.storefront_rounded;
  static const suplementos = Icons.science_rounded;
  static const servicio = Icons.fitness_center_rounded;
  static const dinero = Icons.payments_rounded;
  static const sincronizar = Icons.sync_rounded;
  static const buscar = Icons.search_rounded;
  static const casa = Icons.home_rounded;
  static const casaInactiva = Icons.home_outlined;
}

/// Espaciado consistente (V2 1.20, retícula 4/8 pt).
///
/// Todos los valores son múltiplos de 4; los escalones habituales
/// son 8/12/16/24/32. Márgenes laterales, separación entre
/// secciones, altura de filas y aire interno de tarjetas usan
/// solo estos escalones.
class AppEspacio {
  AppEspacio._();

  /// 1.36 (136-284): REGLA de alturas con texto — toda
  /// altura que aloja texto es INTRÍNSECA o MÍNIMA
  /// (minimumSize / minHeight), nunca fija: con la escala
  /// conjunta máxima (1,45) una altura fija rompe. Los
  /// botones del tema y la barra de pilares ya la cumplen;
  /// una pantalla nueva no escribe `height:` sobre un
  /// contenedor con texto dentro.

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
  static const chip = circular; // 1.36 (136-281): «tag» se borra: 0 usos
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

  /// El desplazamiento deliberado hasta un bloque lejano
  /// (el «bajar a Por Decidir» del Mostrador, M-4): recorre
  /// media pantalla y por eso dura más que una transición
  /// ordinaria. Nace en la corrección de UI-13 (1.35): el
  /// gesto vivía como literal de 450 ms en home.dart.
  static const desplazamiento = Duration(milliseconds: 450);

  /// Curva de entrada del sistema (la de la ruta desde 1.22).
  static const curva = Curves.easeOutCubic;

  /// Curva de salida del sistema (la inversa de la ruta).
  static const curvaReversa = Curves.easeInCubic;

  /// Curva suave para contadores y fundidos cortos.
  static const curvaSuave = Curves.easeOut;

  /// 1.36 (136-273): familias que el vocabulario no
  /// cubría y cada archivo declaraba como literal.
  /// Feedback: cuánto vive un aviso en pantalla.
  static const avisoCorto = Duration(seconds: 3);
  static const aviso = Duration(seconds: 4);
  static const avisoLargo = Duration(seconds: 6);
  /// Cascada: UN escalón para FadeEntrada e ItemCascada
  /// (antes 35 y 45 ms para el mismo gesto).
  static const cascadaPaso = Duration(milliseconds: 40);
  /// Pulso de atención (píldora de sync, marcadores).
  static const pulso = Duration(milliseconds: 1200);
  /// Celebración (cobro, logro): el ciclo completo.
  static const celebracion = Duration(milliseconds: 950);
  /// Marca: entrada/salida del momento de marca.
  static const marcaEntrada = Duration(milliseconds: 450);
  static const marcaSalida = Duration(milliseconds: 250);
  /// Curvas que el vocabulario no tenía y dos pantallas
  /// escribían sueltas.
  static const curvaSuaveInOut = Curves.easeInOut;
  static const curvaElastica = Curves.elasticOut;

  /// 1.36 (136-274): la guarda de «Reducir movimiento»
  /// vive AQUÍ, no en cada llamador: con la bandera activa
  /// (sistema o ajuste de la app, ya sumadas en la raíz)
  /// toda duración resuelta es cero.
  static Duration resuelta(BuildContext context, Duration duracion) =>
      MediaQuery.of(context).disableAnimations ? Duration.zero : duracion;

  /// Curva con rebote para celebraciones breves (el sello
  /// de un cobro, la confirmación de una inscripción).
  /// Nace en D6 (UI130-32) al tokenizar las dos superficies
  /// que ya compartían `Curves.easeOutBack` literal: el
  /// gesto es del sistema, no de cada pantalla.
  static const curvaPop = Curves.easeOutBack;
}

/// 1.36 (136-271): opacidades con nombre. El «tinte suave»
/// de un color de estado vale UN paso según el papel:
/// fondo de chip/insignia, borde de ese tinte, selección.
class AppOpacidad {
  AppOpacidad._();
  /// Fondo tintado estándar (chip, insignia, pastilla).
  static const tinte = 0.14;
  /// Tinte suave (fondos grandes, filas).
  static const tinteSuave = 0.12;
  /// Tinte fuerte (selección marcada).
  static const tinteFuerte = 0.16;
  /// Borde sobre un tinte.
  static const bordeTinte = 0.35;
  /// Borde suave sobre un tinte.
  static const bordeTinteSuave = 0.22;
  /// Fondo de selección (segmentos, chips elegidos).
  static const seleccion = 0.20;
}

/// 1.36 (136-272): elevación con nombre y equivalente en
/// oscuro. Sustituye a la clase de sombras deprecada
/// que la 1.36 borró (136-281):
/// en claro la profundidad es sombra; en oscuro, borde
/// luminoso + sombra negra marcada (la sombra sola es
/// invisible sobre el fondo casi negro).
class AppElevacion {
  AppElevacion._();

  /// Sombra del nivel (0=plano, 1=tarjeta, 2=flotante).
  static List<BoxShadow> sombra(BuildContext context, int nivel) {
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    if (AppColores.esAltoContraste(context) || nivel == 0) return const [];
    if (oscuro) {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: nivel == 1 ? 0.4 : 0.55),
          blurRadius: nivel == 1 ? 8 : 16,
          offset: Offset(0, nivel == 1 ? 2 : 6),
        ),
      ];
    }
    return [
      BoxShadow(
        color: Colors.grey.withValues(alpha: nivel == 1 ? 0.18 : 0.28),
        blurRadius: nivel == 1 ? 14 : 22,
        offset: Offset(0, nivel == 1 ? 4 : 8),
      ),
    ];
  }

  /// Borde del nivel: en oscuro es la línea de luz que
  /// despega la superficie; en claro, el borde del tema.
  static Border borde(BuildContext context, int nivel) {
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    if (oscuro && !AppColores.esAltoContraste(context) && nivel > 0) {
      return Border.all(color: AppColores.luzBarra);
    }
    return Border.all(color: AppColores.borde(context));
  }
}

/// 1.33 (diseño): el estilo de aparición de los menús
/// desplegables de la casa — fundido de la duración media
/// con la curva suave de la casa (la ruta además escalona
/// la entrada de los ítems). En esta versión de Flutter el
/// estilo NO es tematizable (PopupMenuThemeData no lo
/// expone): se aplica con esta constante en cada
/// PopupMenuButton y showMenu de la app. Sin ella, la ruta
/// usa los 300 ms lineales del framework y el menú se lee
/// como aparición de golpe.
const estiloAparicionMenu = AnimationStyle(
  duration: AppMovimiento.media,
  curve: AppMovimiento.curvaSuave,
  reverseCurve: AppMovimiento.curvaReversa,
);

/// v1.2.4 (Hark): tema único (claro/oscuro) a partir de los tokens.
/// Antes estaba duplicado en main.dart. Unifica botones (alto mínimo 48,
/// estado deshabilitado visible), campos, diálogos y avisos. Diseño rico,
/// no plano: tarjetas y botones con la elevación del tema (único
/// lenguaje de elevación desde la 1.29, D-18) y el gradiente naranja
/// en el botón primario (BotonPrimario).
/// Yunque 2.34 (F-9): escala de texto EFECTIVA = la de la
/// app × la del sistema, con TECHO conjunto 1.45 (y suelo
/// 0.85). Sin techo, app 1.3 × sistema 1.3 = 1.69 dejaba
/// filas calculadas al píxel (la «Pagado el» del diálogo de
/// pago) a 0-6 px del desborde. El techo es conjunto a
/// propósito: cada escala por separado sigue mandando
/// mientras el producto no se dispare. PURO.
double escalaTextoEfectiva(double escalaApp, double escalaSistema) =>
    (escalaApp * escalaSistema).clamp(0.85, 1.45).toDouble();

/// Yunque 3 (K3-4): lo que el deslizador «Tamaño de letra»
/// de Ajustes ANUNCIA debe ser la escala EFECTIVA, no la de
/// la app a secas: con el sistema a 1,30, los pasos de app
/// 1,15–1,30 caen todos en el techo 1,45 — la etiqueta
/// cambiaba (115 % → 130 %) y la letra no se movía (zona
/// muerta; simétrica en el suelo con sistema a 0,85).
/// Devuelve el porcentaje efectivo y si el producto entró
/// en clamp, para avisar «limitado por la escala del
/// sistema». PURO.
({int porcentaje, bool limitado}) anuncioEscalaLetra(
    double escalaApp, double escalaSistema) {
  final efectiva = escalaTextoEfectiva(escalaApp, escalaSistema);
  final producto = escalaApp * escalaSistema;
  return (
    porcentaje: (efectiva * 100).round(),
    limitado: (producto - efectiva).abs() > 0.001,
  );
}

/// 1.36 (136-262): el esquema EXPLÍCITO y completo del
/// sistema. Ningún papel lo genera una semilla: cada rol
/// de ColorScheme se elige aquí, por brillo, variante
/// táctica y alto contraste, y el test de la fila fija
/// cada papel. (fromSeed dejaba contenedores, variantes
/// e inversos al algoritmo de Material: de ahí nacían
/// los frentes de «azul cobalto» de DIS-04/F-1…F-9.)
ColorScheme esquemaIron(
  Brightness b, {
  bool tactico = false,
  bool altoContraste = false,
}) {
  final oscuro = b == Brightness.dark;
  if (altoContraste) {
    return ColorScheme(
      brightness: b,
      primary: oscuro ? Colors.white : Colors.black,
      onPrimary: oscuro ? Colors.black : Colors.white,
      primaryContainer: oscuro ? Colors.white : Colors.black,
      onPrimaryContainer: oscuro ? Colors.black : Colors.white,
      secondary: oscuro ? Colors.white : Colors.black,
      onSecondary: oscuro ? Colors.black : Colors.white,
      secondaryContainer: oscuro ? const Color(0xFF2A2A2A) : const Color(0xFFE6E6E6),
      onSecondaryContainer: oscuro ? Colors.white : Colors.black,
      tertiary: AppColores.naranja,
      onTertiary: AppColores.sobreMarca,
      tertiaryContainer: AppColores.naranja,
      onTertiaryContainer: AppColores.sobreMarca,
      error: AppColores.error,
      onError: Colors.white,
      errorContainer: AppColores.errorFondo,
      onErrorContainer: Colors.white,
      surface: oscuro ? Colors.black : Colors.white,
      onSurface: oscuro ? Colors.white : Colors.black,
      surfaceDim: oscuro ? Colors.black : const Color(0xFFE6E6E6),
      surfaceBright: oscuro ? const Color(0xFF2A2A2A) : Colors.white,
      surfaceContainerLowest: oscuro ? Colors.black : Colors.white,
      surfaceContainerLow: oscuro ? const Color(0xFF111111) : const Color(0xFFF7F7F7),
      surfaceContainer: oscuro ? const Color(0xFF1A1A1A) : const Color(0xFFF0F0F0),
      surfaceContainerHigh: oscuro ? const Color(0xFF242424) : const Color(0xFFEAEAEA),
      surfaceContainerHighest: oscuro ? const Color(0xFF2E2E2E) : const Color(0xFFE2E2E2),
      onSurfaceVariant: oscuro ? Colors.white : Colors.black,
      outline: oscuro ? Colors.white : Colors.black,
      outlineVariant: oscuro ? const Color(0xFF8A8A8A) : const Color(0xFF6B6B6B),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: oscuro ? Colors.white : Colors.black,
      onInverseSurface: oscuro ? Colors.black : Colors.white,
      inversePrimary: oscuro ? Colors.black : Colors.white,
      surfaceTint: Colors.transparent,
    );
  }
  final superficie = tactico
      ? (oscuro ? AppColores.grafitoTactico : Colors.white)
      : (oscuro ? AppColores.superficieOscuro : AppColores.superficieClaro);
  final contenedorAlto = tactico
      ? (oscuro ? AppColores.acero : AppColores.grisTecnico)
      : (oscuro ? AppColores.superficieElevadaOscuro : AppColores.superficieHundidaClaro);
  return ColorScheme(
    brightness: b,
    primary: tactico
        ? (oscuro ? AppColores.cobalto : AppColores.cobaltoOscuro)
        : AppColores.naranja,
    onPrimary: tactico ? Colors.white : AppColores.sobreMarca,
    primaryContainer:
        oscuro ? const Color(0xFF7A3E08) : const Color(0xFFFFD9AE),
    onPrimaryContainer:
        oscuro ? const Color(0xFFFFE3C2) : AppColores.textoClaro,
    secondary: AppColores.carbon,
    onSecondary: Colors.white,
    secondaryContainer: contenedorAlto,
    onSecondaryContainer:
        oscuro ? AppColores.textoOscuro : AppColores.textoClaro,
    tertiary: AppColores.azulAgua,
    onTertiary: Colors.white,
    tertiaryContainer: contenedorAlto,
    onTertiaryContainer:
        oscuro ? AppColores.textoOscuro : AppColores.textoClaro,
    error: AppColores.error,
    onError: Colors.white,
    errorContainer: AppColores.errorFondo,
    onErrorContainer: Colors.white,
    surface: superficie,
    onSurface: oscuro ? AppColores.textoOscuro : AppColores.textoClaro,
    surfaceDim: oscuro ? AppColores.fondoOscuro : AppColores.fondoClaro,
    surfaceBright:
        oscuro ? AppColores.superficieElevadaOscuro : Colors.white,
    surfaceContainerLowest: superficie,
    surfaceContainerLow: contenedorAlto,
    surfaceContainer: contenedorAlto,
    surfaceContainerHigh: contenedorAlto,
    surfaceContainerHighest: contenedorAlto,
    onSurfaceVariant: oscuro
        ? AppColores.textoSecundarioOscuro
        : AppColores.textoSecundarioClaro,
    outline: oscuro ? AppColores.bordeOscuro : AppColores.bordeClaro,
    outlineVariant:
        oscuro ? AppColores.bordeSutilOscuro : AppColores.bordeSutilClaro,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface:
        oscuro ? AppColores.superficieClaro : AppColores.carbonProfundo,
    onInverseSurface:
        oscuro ? AppColores.textoClaro : AppColores.textoOscuro,
    inversePrimary: AppColores.naranja,
    surfaceTint: Colors.transparent,
  );
}

class AppTema {
  AppTema._();

  /// 1.36 (136-265): claro()/oscuro() dejaron de ser un
  /// par paralelo que nadie instalaba (los tests de la
  /// fundación certificaban temas que producción no
  /// montaba). Queda UN solo par de producción: sol() y
  /// tacticoOscuro(); estos nombres delegan en él.
  static ThemeData claro() => sol();
  static ThemeData oscuro() => tacticoOscuro();

  /// Alto contraste = variante DEL PAR de producción
  /// (conserva las superficies tácticas), no un tema
  /// aparte sin la capa táctica.
  static ThemeData claroAltoContraste() => sol(altoContraste: true);
  static ThemeData oscuroAltoContraste() =>
      tacticoOscuro(altoContraste: true);

  /// 1.32 «Mostrador Táctico» — tema OSCURO del rediseño: fondo
  /// Pizarra, superficies Grafito/Acero y acción principal en
  /// Cobalto (el naranja queda reservado a la marca y a Cobrar).
  /// Se construye SOBRE [_tema] para heredar transiciones,
  /// interruptores, formularios y demás fundación; solo cambian
  /// las superficies y el primario. Los temas claro()/oscuro()
  /// anteriores no se tocan (tests de contraste los fijan).
  ///
  /// 1.33 (pasada de diseño, veredicto de Jc en campo): el
  /// cobalto como acento VISIBLE de navegación queda
  /// retirado — segmentos, indicador de pilares, chips y
  /// filas de lista van en marca (naranja/grafito/blanco)
  /// desde [_tema] y los sitios sueltos. El primario del
  /// esquema se conserva SOLO como fondo de los controles
  /// Material sin tema propio; ya no pinta ninguna
  /// superficie de navegación ni de lista.
  /// 1.36 (136-262/265): el táctico oscuro ES _tema con
  /// la variante táctica del esquema explícito — ya no un
  /// copyWith de primario sobre una semilla naranja.
  static ThemeData tacticoOscuro({bool altoContraste = false}) =>
      _tema(Brightness.dark, tactico: true, altoContraste: altoContraste);

  /// 1.36 (136-262/265): Modo Sol = _tema claro táctico.
  static ThemeData sol({bool altoContraste = false}) =>
      _tema(Brightness.light, tactico: true, altoContraste: altoContraste);

  static ThemeData _tema(Brightness b, {bool altoContraste = false, bool tactico = false}) {
    final oscuro = b == Brightness.dark;
    final superficie = altoContraste
        ? (oscuro ? Colors.black : Colors.white)
        : tactico
            ? (oscuro ? AppColores.grafitoTactico : Colors.white)
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
    // 1.36 (136-285): los literales locales del tema son
    // ahora tokens con nombre de AppColores.
    final deshabilitadoFondo = oscuro
        ? AppColores.deshabilitadoFondoOscuro
        : AppColores.deshabilitadoFondoClaro;
    final deshabilitadoTexto = oscuro
        ? AppColores.deshabilitadoTextoOscuro
        : AppColores.deshabilitadoTextoClaro;
    final forma = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadio.md));
    const minimo = Size(64, 48);

    return ThemeData(
      useMaterial3: true,
      // 1.36 (136-316): frontera de familias declarada en
      // el tema — el cuerpo sigue en la fuente del sistema
      // y su red de rescate es la familia de marca y luego
      // la elegida, no la del OEM.
      fontFamilyFallback: const [
        AppTexto.familiaDisplay,
        AppTexto.familiaRespaldo,
      ],
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
      // 1.36 (136-262): esquema EXPLÍCITO completo; ningún
      // papel nace de una semilla.
      colorScheme: esquemaIron(b,
          tactico: tactico, altoContraste: altoContraste),
      // 1.36 H-B1 (136-348): el alto contraste también manda
      // sobre el fondo — blanco/negro puros como la superficie.
      scaffoldBackgroundColor: altoContraste
          ? (oscuro ? Colors.black : Colors.white)
          : tactico
              ? (oscuro ? AppColores.pizarra : AppColores.papelFrio)
              : (oscuro ? AppColores.fondoOscuro : AppColores.fondoClaro),
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
                ? AppColores.interruptorPistaDeshabOscuro
                : AppColores.interruptorPistaDeshabClaro;
          }
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return oscuro
              ? AppColores.interruptorPistaOscuro
              : AppColores.interruptorPistaClaro;
        }),
        thumbColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.disabled)) {
            return oscuro
                ? AppColores.interruptorPulgarDeshabOscuro
                : AppColores.interruptorPulgarDeshabClaro;
          }
          if (estados.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return oscuro
              ? AppColores.interruptorPulgarOscuro
              : AppColores.interruptorPulgarClaro;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return oscuro
              ? AppColores.interruptorBordeOscuro
              : AppColores.interruptorBordeClaro;
        }),
      ),
      // Yunque 1.34 (DIS-04, decisión con la delegación de
      // Jc): los controles de selección y los selectores de
      // fecha/hora NO tenían tema de componente y Material 3
      // los pinta con `colorScheme.primary` — que en los
      // temas de producción (sol/tacticoOscuro, que ponen el
      // primary en cobalto) salía AZUL COBALTO plano: casillas
      // (14), radios (24), deslizadores (4) y los diálogos de
      // fecha (16) y hora (3) de toda la app, el mismo azul
      // que Jc rechazó en la 1.32. Aquí quedan fijados a la
      // marca SIN tocar el primary del esquema (su radio de
      // impacto no es enumerable: navegación y superficies lo
      // comparten a propósito).
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(AppColores.sobreMarca),
        side: BorderSide(color: secundario, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return secundario;
        }),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColores.naranja,
        thumbColor: AppColores.naranja,
        overlayColor: AppColores.naranja.withValues(alpha: 0.12),
        inactiveTrackColor: secundario.withValues(alpha: 0.35),
        // Yunque 2.34 (F-6): la burbuja del valor salía
        // cobalto (primary del esquema de producción).
        valueIndicatorColor: AppColores.naranja,
        valueIndicatorTextStyle:
            const TextStyle(color: AppColores.sobreMarca),
      ),
      // Yunque 2.34 (F-1): sin tabBarTheme, el indicador y la
      // etiqueta activa de las pestañas salían cobalto en 9
      // de 10 sitios (primary de producción). La etiqueta NO
      // seleccionada no se fija aquí: depende de la
      // superficie (barra oscura o tarjeta clara) y el valor
      // del SDK la resuelve por contexto.
      // Yunque 3 (K3-2): la etiqueta activa se resuelve por
      // brillo — el naranja gráfico como TEXTO sobre el
      // AppBar claro queda a 2,5:1; en claro manda el rol de
      // texto (naranjaTexto, 4,57:1). El indicador (raya,
      // gráfico) sigue naranja en ambos.
      tabBarTheme: TabBarThemeData(
        indicatorColor: AppColores.naranja,
        labelColor:
            oscuro ? AppColores.naranja : AppColores.naranjaTexto,
      ),
      // Yunque 4 (L8-1): sin expansionTileTheme, el chevron
      // de los ExpansionTile EXPANDIDOS salía cobalto (el
      // iconColor por defecto de M3 es el primary del
      // esquema de producción) en los 12 plegables de la
      // app. Colapsado sigue el tono secundario del texto;
      // expandido, el naranja de marca.
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: AppColores.naranja,
        collapsedIconColor: secundario,
      ),
      // Yunque 2.34 (F-3): cursor, selección y manijas de los
      // campos de texto en la marca (salían cobalto por el
      // primary de producción, como los controles de DIS-04).
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppColores.naranja,
        selectionColor: AppColores.naranja.withValues(alpha: 0.35),
        selectionHandleColor: AppColores.naranjaOscuro,
      ),
      datePickerTheme: DatePickerThemeData(
        dayBackgroundColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return null;
        }),
        dayForegroundColor: WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.sobreMarca;
          }
          return null;
        }),
        todayBorder: const BorderSide(color: AppColores.naranja),
        // Yunque 2.34 (F-4): «hoy» y el selector de AÑO
        // también en la marca (salían cobalto). La celda
        // «hoy» del selector de RANGO la fuerza el SDK por su
        // cuenta y no es temable: residual aceptado.
        todayForegroundColor:
            WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.sobreMarca;
          }
          // 1.36 H-B1 (136-346): «hoy» es texto — por brillo.
          return oscuro ? AppColores.naranja : AppColores.naranjaTexto;
        }),
        yearBackgroundColor:
            WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return null;
        }),
        yearForegroundColor:
            WidgetStateProperty.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.sobreMarca;
          }
          return null;
        }),
      ),
      timePickerTheme: TimePickerThemeData(
        // La manecilla del reloj era cobalto por el primary
        // de producción.
        dialHandColor: AppColores.naranja,
        // Yunque 2.34 (F-5): el selector AM/PM y las cajas de
        // hora/minuto también en la marca. La nota de DIS-04
        // («dayPeriodColor no admite resolución por estado»)
        // era FALSA en este SDK: admite WidgetStateColor.
        dayPeriodColor: WidgetStateColor.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja;
          }
          return AppColores.naranja.withValues(alpha: 0.12);
        }),
        dayPeriodTextColor: WidgetStateColor.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.sobreMarca;
          }
          return AppColores.naranjaOscuro;
        }),
        hourMinuteColor: WidgetStateColor.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranja.withValues(alpha: 0.16);
          }
          return AppColores.naranja.withValues(alpha: 0.06);
        }),
        hourMinuteTextColor: WidgetStateColor.resolveWith((estados) {
          if (estados.contains(WidgetState.selected)) {
            return AppColores.naranjaOscuro;
          }
          return oscuro ? Colors.white : AppColores.carbon;
        }),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: tactico
            ? (oscuro ? AppColores.grafitoTactico : AppColores.papelFrio)
            : (oscuro ? AppColores.carbonProfundo : AppColores.carbon),
        foregroundColor:
            (tactico && !oscuro) ? AppColores.sobreMarca : Colors.white,
        elevation: 2,
        scrolledUnderElevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        centerTitle: false,
        // 1.36 (136-305/313): la AppBar titula con el rol
        // de PÁGINA (20), no con el de tarjeta (18).
        titleTextStyle: AppTexto.tituloPagina.copyWith(color: (tactico && !oscuro) ? AppColores.sobreMarca : Colors.white),
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
          borderRadius: BorderRadius.circular(
              (tactico && !oscuro) ? AppRadio.md : AppRadio.lg),
          // 1.36 (136-272): el oscuro táctico gana su borde
          // luminoso explícito (luzBarra) en vez de heredar
          // un borde a 1,51:1; el Sol conserva su 1,5 dp de
          // grafito del plano §4.1.
          side: tactico
              ? (oscuro
                  ? const BorderSide(color: AppColores.luzBarra, width: 1)
                  : const BorderSide(
                      color: AppColores.sobreMarca, width: 1.5))
              : BorderSide(color: borde),
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
        backgroundColor: oscuro ? AppColores.snackFondoOscuro : AppColores.carbon,
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
          // 1.36 H-B1 (136-346): el texto del botón se resuelve
          // por brillo — en claro manda el rol de texto.
          foregroundColor:
              oscuro ? AppColores.naranja : AppColores.naranjaTexto,
          minimumSize: const Size(48, 44),
          textStyle:
              AppTexto.cuerpo.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: superficie,
        labelStyle: TextStyle(color: secundario),
        // 1.36 H-B1 (136-346): etiqueta flotante = texto, por brillo.
        floatingLabelStyle: TextStyle(
            color: oscuro ? AppColores.naranja : AppColores.naranjaTexto),
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
        // 1.33 (diseño): el icono-avatar de un chip sin
        // color propio caía al primario del esquema —
        // cobalto en los temas tácticos (así salían azules
        // los chips de «Qué le falta» de la ficha y los
        // enlaces en chip del Pilar Negocio). La familia
        // de chips lleva el naranja de texto de la marca;
        // un icono con color explícito manda sobre esto.
        iconTheme: IconThemeData(
            color: oscuro
                ? AppColores.naranjaTextoOscuro
                : AppColores.naranjaTexto),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: AppColores.naranja.withValues(alpha: 0.2),
          selectedForegroundColor: texto,
          // 1.33 (diseño, cazado en captura): sin
          // foregroundColor, el segmento SIN seleccionar
          // resolvía a null y el botón caía al primario
          // del esquema — cobalto en los temas tácticos:
          // icono y texto de los segmentos inactivos se
          // pintaban de azul plano en los tres pilares.
          // Gris legible de la casa, explícito; el activo
          // sigue blanco sobre el tinte de marca.
          foregroundColor: secundario,
          // 1.32 (integración, RD-1 del inventario): el
          // SegmentedButton es la navegación principal de
          // los Pilares 2/3/4 y de Servicios: su objetivo
          // táctil es 48 dp de alto, no los 44 de antes
          // (Material 3 parte de 40). En el mostrador, con
          // las manos ocupadas, es el fallo táctil más
          // probable del rediseño.
          minimumSize: const Size(48, 48),
        ),
      ),
      // 1.33 (diseño): los menús desplegables no tenían
      // tema y heredaban los defectos del framework: el
      // color por defecto es el surfaceContainer del
      // esquema — sembrado en naranja, sale el rectángulo
      // MARRÓN/carmelita que Jc vio en el menú del avatar —
      // con esquinas casi rectas y la animación lineal de
      // 300 ms de serie, que se lee como aparición de
      // golpe. Aquí quedan la superficie de la casa, el
      // radio grande con borde y la sombra propia; el
      // ESTILO de aparición no es tematizable en esta
      // versión de Flutter (PopupMenuThemeData no lo
      // expone) y va en la constante compartida
      // [estiloAparicionMenu], aplicada en cada
      // PopupMenuButton/showMenu de la app. Lo demás lo
      // heredan los 12 PopupMenuButton y el showMenu;
      // los DropdownButton no pasan por esta ruta (su
      // menú es del propio control).
      popupMenuTheme: PopupMenuThemeData(
        color: superficie,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.lg),
          side: BorderSide(color: borde),
        ),
        textStyle: AppTexto.cuerpo.copyWith(color: texto),
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
      navigationBarTheme: tactico
          ? NavigationBarThemeData(
              backgroundColor: oscuro
                  ? AppColores.grafitoTactico
                  : AppColores.papelFrio,
              indicatorColor: AppColores.naranja
                  .withValues(alpha: oscuro ? 0.35 : 0.25),
            )
          : const NavigationBarThemeData(),
      // 1.36 (136-280): TextTheme COMPLETO (15 ranuras de
      // Material, todas desde AppTexto) y bodyMedium vuelve
      // al cuerpo (14), no al secundario (13). El solape
      // etiqueta/metadato (ambos 12) se resuelve por PESO y
      // tracking declarados: etiqueta = w600 + 0,3 de
      // tracking (rótulo); metadato = regular sin tracking
      // (dato). Los tamaños de rol los re-nivela S2.
      textTheme: const TextTheme(
        displayLarge: AppTexto.display,
        displayMedium: AppTexto.displayPequeno,
        displaySmall: AppTexto.metrica,
        headlineLarge: AppTexto.displayPequeno,
        headlineMedium: AppTexto.tituloPagina,
        headlineSmall: AppTexto.titulo,
        titleLarge: AppTexto.titulo,
        titleMedium: AppTexto.subtitulo,
        titleSmall: AppTexto.secundario,
        bodyLarge: AppTexto.cuerpo,
        bodyMedium: AppTexto.cuerpo,
        bodySmall: AppTexto.metadato,
        labelLarge: AppTexto.etiqueta,
        labelMedium: AppTexto.etiqueta,
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
    // 1.36 (136-274): la ruta respeta la guarda del
    // sistema — con «Reducir movimiento» no hay fundido
    // ni desplazamiento, sin tocar cada llamador.
    if (MediaQuery.of(context).disableAnimations) return child;
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
