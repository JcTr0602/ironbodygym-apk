/// 1.32 «Mostrador Táctico» — el Marco Global Persistente.
///
/// La cáscara raíz de la app: cabecera compacta SIEMPRE visible
/// (rol, píldora de sync, lupa universal, Modo Sol y menú de
/// perfil), barra inferior de 4 Pilares simétricos y el Dock de
/// Mostrador del Pilar 1. Sustituye al selector de niveles
/// Hoy|Módulos y a las cuadrículas de módulos de la Home 1.31:
/// ningún destino se pierde, todos viven en un pilar.
///
/// Reglas del plano que este archivo hace cumplir:
/// - El estado de sync es UN icono junto a la lupa
///   ([IconoSyncCabecera], campo nº 4 + M-6 de la 1.35):
///   la frase completa vive en su descripción y el detalle,
///   a un toque. Al guardar algo nuevo, el icono pulsa; al
///   sincronizar, gira. Sin spinners centrales ni fila
///   entera de píldora robando pantalla.
/// - El Modo Sol es SOLO manual (1 toque en la cabecera); el
///   automático por sensor no existe (guarda del contraste).
/// - La cabecera vive en UNA fila fina (~56 dp): avatar con
///   el nombre dentro de su propio toque (el menú dice
///   nombre y rol), lupa, icono de sync y Modo Sol. El chip
///   de rol como pieza separada desapareció (M-6).
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'primitivas.dart';
import 'widgets.dart';

/// Los 4 pilares del marco, en su orden fijo de barra.
enum PilarGestion { mostrador, clientes, tienda, negocio }

/// Destino pedido dentro del Pilar 2 (Clientes): qué segmento
/// abrir y, según el segmento, la pestaña del directorio de
/// vencimientos o el filtro del buscador directo.
class DestinoClientes {
  /// directorio | vencimientos | invitados | avisos
  final String segmento;

  /// Pestaña inicial de ListasScreen (0 Hoy · 1 Por vencer ·
  /// 2 Atrasados −30d · 3 Atrasados +30d · 4 Al día).
  final int? tabListas;

  /// Filtro inicial de BuscarScreen (todos|aldia|vencidos|…).
  final String? filtro;

  const DestinoClientes(
      {this.segmento = 'directorio', this.tabListas, this.filtro});
}

/// Canal de navegación entre pilares (patrón de la casa: el
/// mismo de [ThemeController], ValueNotifiers estáticos). La
/// cáscara escucha [pilar]; las tarjetas del Mostrador piden
/// saltos con contexto (el «vencidos» del Pulso del Día abre
/// Clientes ya filtrado: el D-3 del inventario, absorbido por
/// el rediseño en vez de parchear el dashboard viejo).
class MarcoNav {
  MarcoNav._();

  /// Pilar visible (índice de [PilarGestion]).
  static final ValueNotifier<int> pilar = ValueNotifier<int>(0);

  /// Destino pendiente dentro de Clientes; el Pilar 2 lo
  /// consume y lo limpia al aplicarlo.
  static final ValueNotifier<DestinoClientes?> destinoClientes =
      ValueNotifier<DestinoClientes?>(null);

  /// Pestaña pendiente dentro de Negocio/Mi Caja (caja |
  /// nomina | equipo | reglas · entregar | minomina |
  /// misturnos); el Pilar 4 la consume y la limpia.
  static final ValueNotifier<String?> destinoNegocio =
      ValueNotifier<String?>(null);

  /// Salta a un pilar sin contexto extra.
  static void irAPilar(PilarGestion p) => pilar.value = p.index;

  /// Salta a Clientes con el segmento/filtro pedido.
  static void irAClientes(DestinoClientes destino) {
    destinoClientes.value = destino;
    pilar.value = PilarGestion.clientes.index;
  }

  /// Salta a Negocio/Mi Caja con la pestaña pedida.
  static void irANegocio(String pestana) {
    destinoNegocio.value = pestana;
    pilar.value = PilarGestion.negocio.index;
  }

  /// Vuelve al estado de arranque (tests y cierre de sesión).
  static void reiniciar() {
    pilar.value = 0;
    destinoClientes.value = null;
    destinoNegocio.value = null;
  }
}

/// Cabecera persistente del marco: avatar con el nombre
/// (su toque abre el menú de perfil, que dice nombre y
/// rol), lupa universal, icono de estado de sync e
/// interruptor del Modo Sol. UNA fila fina (M-6 de la
/// 1.35): la fila entera de la píldora y el chip de rol
/// como pieza separada ya no existen.
class CabeceraMarco extends StatelessWidget {
  /// «Dueño» | «Administrador» | «Entrenador».
  final String rol;
  final String nombre;
  final VoidCallback onSyncTap;
  final VoidCallback onLupa;

  /// 1.35 (UI-22, re-contratada con M-6): con la lista
  /// bajada, el NOMBRE se recoge y quedan el avatar y los
  /// iconos — el icono de sync NUNCA se oculta; al volver
  /// arriba, el nombre regresa. El ahorro de alto de la
  /// pieza ya no viene del plegado: viene de la fila
  /// única (la píldora a lo ancho medía su propia fila
  /// de ~48 dp en cada pantalla, para siempre).
  final bool plegada;

  /// SL-X2 (G01-10): hay desplazamiento en el pilar activo
  /// (la Home lo rastrea con su sensor de scroll). Con
  /// scroll, la sombra de la cabecera CRECE para despegarla
  /// del contenido que pasa por debajo; sin scroll, la
  /// elevación base de siempre. Antes la elevación era una
  /// constante con o sin scroll.
  final bool conScroll;

  /// Acción del menú de perfil: perfil | auditoria | respaldo |
  /// diagnostico | ayuda | tema | salir.
  final void Function(String accion) onAccionPerfil;

  const CabeceraMarco({
    super.key,
    required this.rol,
    required this.nombre,
    required this.onSyncTap,
    required this.onLupa,
    required this.onAccionPerfil,
    this.plegada = false,
    this.conScroll = false,
  });

  Widget _interruptorSol(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeController.modoSol,
      builder: (_, sol, __) => IconButton(
        key: const ValueKey('marco-sol'),
        tooltip: sol ? 'Apagar el Modo Sol' : 'Modo Sol (pantalla clara)',
        icon: Icon(
          sol ? Icons.wb_sunny_rounded : Icons.wb_sunny_outlined,
          color: sol ? AppColores.ambarTierra : null,
        ),
        onPressed: () => ThemeController.setModoSol(!sol),
      ),
    );
  }

  /// 1.33 (diseño): la fila de un destino del menú del
  /// avatar: icono en chip con tinte (marca; rojo de error
  /// al cerrar sesión) y la etiqueta al lado.
  Widget _filaMenu(BuildContext context, IconData icono, String texto,
      {bool salir = false}) {
    return Row(
      children: [
        if (salir)
          IconoModuloBadge(
            icono: icono,
            tinte: AppColores.error,
            iconoOscuro: AppColores.coral,
            iconoClaro: AppColores.carmesi,
            tamanoIcono: 19,
          )
        else
          IconoModuloBadge.naranja(icono, tamanoIcono: 19),
        const SizedBox(width: AppEspacio.md),
        // Flexible + elipsis: la etiqueta se adapta al
        // ancho que el menú le dé (con la escala de fuente
        // de accesibilidad crecida, una etiqueta larga
        // desbordaba la fila en vez de recortarse).
        Flexible(
          child: Text(
            texto,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: salir
                ? AppTexto.cuerpo.copyWith(
                    color: AppColores.rojoDe(context),
                    fontWeight: FontWeight.w600)
                : AppTexto.cuerpo,
          ),
        ),
      ],
    );
  }

  Widget _avatar(BuildContext context) {
    final inicial =
        nombre.trim().isEmpty ? '?' : nombre.trim()[0].toUpperCase();
    return PopupMenuButton<String>(
      popUpAnimationStyle: estiloAparicionMenu,
      key: const ValueKey('marco-perfil'),
      tooltip: 'Mi perfil',
      onSelected: onAccionPerfil,
      // 1.35 (M-6): el menú abre diciendo quién eres —
      // el rol vive aquí, no en un chip suelto de la
      // cabecera.
      // (La cabecera del menú es el primer ítem, inerte.)
      // 1.33 (diseño): cada destino del menú lleva su
      // icono en el chip de marca de la casa, como el
      // resto de filas de la app — antes era texto pelado
      // sobre el rectángulo marrón sin tema («parece HTML
      // de hace 20 años»). La superficie, las esquinas y
      // la transición salen del popupMenuTheme de la casa;
      // «Cerrar sesión» se diferencia en rojo de error.
      itemBuilder: (ctx) => [
        // 1.35 (M-6): cabecera inerte del menú — nombre
        // y rol, que salieron de la fila de la cabecera.
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(nombre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w700)),
              Text(rol, style: AppTexto.secundario),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
            value: 'perfil',
            child: _filaMenu(ctx, Icons.person_rounded,
                'Mi perfil y ajustes')),
        PopupMenuItem(
            value: 'auditoria',
            child:
                _filaMenu(ctx, Icons.fact_check_rounded, 'Auditoría')),
        PopupMenuItem(
            value: 'respaldo',
            child: _filaMenu(ctx, Icons.backup_rounded, 'Respaldo')),
        PopupMenuItem(
            value: 'diagnostico',
            child: _filaMenu(
                ctx, Icons.monitor_heart_rounded, 'Diagnóstico')),
        PopupMenuItem(
            value: 'ayuda',
            child: _filaMenu(ctx, Icons.help_rounded, 'Ayuda')),
        PopupMenuItem(
            value: 'tema',
            child: _filaMenu(
                ctx, Icons.brightness_6_rounded, 'Tema claro/oscuro')),
        const PopupMenuDivider(),
        PopupMenuItem(
            value: 'salir',
            child:
                _filaMenu(ctx, Icons.logout_rounded, 'Cerrar sesión',
                    salir: true)),
      ],
      // 1.32 (integración, RD-3): el avatar es la ÚNICA
      // puerta a Respaldo, Auditoría, Diagnóstico y Ayuda
      // y medía 34×34 dp: fallar el toque caía en la
      // cabecera sin acción. El círculo se queda en 34
      // (visual intacto) y un relleno transparente de 7 dp
      // lleva el área tocable a 48×48.
      // 1.35 (M-6): el nombre va DENTRO del toque del
      // avatar (una sola pieza de identidad); plegada la
      // cabecera, el nombre se recoge y queda el círculo.
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 17,
              // 1.33 (diseño): el avatar de identidad va en la
              // marca (naranja con la inicial en grafito, la
              // pareja del FAB y de onPrimary), no en cobalto.
              backgroundColor: AppColores.naranja,
              child: Text(inicial,
                  style: const TextStyle(
                      color: AppColores.sobreMarca,
                      fontWeight: FontWeight.w700)),
            ),
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : AppMovimiento.media,
              curve: AppMovimiento.curvaSuave,
              alignment: Alignment.centerLeft,
              child: plegada
                  ? const SizedBox.shrink(
                      key: ValueKey('cabecera-nombre-plegado'))
                  : Row(
                      key: const ValueKey('cabecera-nombre-pleno'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: AppEspacio.sm),
                        ConstrainedBox(
                          constraints:
                              const BoxConstraints(maxWidth: 130),
                          child: Text(
                            nombre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTexto.cuerpo.copyWith(
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: AppEspacio.xs),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1.35 (M-6 + CAMPO-4): UNA fila fina. A la izquierda,
    // la identidad como una sola pieza (avatar + nombre
    // dentro de su toque); a la derecha, lupa, el icono
    // de estado de sync (junto a la lupa, como pidió Jc)
    // y el Modo Sol. Sin chip de rol suelto y sin la fila
    // entera de la píldora: ~48 dp devueltos a cada
    // pantalla, para siempre. La fila única de la 1.32
    // desbordaba porque llevaba el chip Y el nombre Y la
    // píldora a lo ancho; sin esas dos piezas, cabe — y
    // el nombre se recorta con elipsis y se recoge al
    // bajar (plegada) antes de apretar a los iconos.
    return Material(
      color: Theme.of(context).colorScheme.surface,
      // SL-X2 (G01-10): la sombra crece con el scroll.
      elevation: conScroll ? 4 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.xs),
        child: Row(
          children: [
            Flexible(child: _avatar(context)),
            const Spacer(),
            IconButton(
              key: const ValueKey('marco-lupa'),
              tooltip: 'Buscar en el gym',
              icon: const Icon(Icons.search_rounded),
              onPressed: onLupa,
            ),
            IconoSyncCabecera(
              key: const ValueKey('marco-pildora'),
              onTap: onSyncTap,
            ),
            _interruptorSol(context),
          ],
        ),
      ),
    );
  }
}

/// Barra inferior de los 4 Pilares: simétrica, etiquetas
/// siempre visibles, insignia de urgencias sobre Mostrador.
/// El cuarto pilar se llama «Negocio» para el dueño y
/// «Mi Caja» para el entrenador.
///
/// 1.35 (UX-02): barra PROPIA «Grafito» (antes
/// `NavigationBar` de Material tal cual): flota con margen
/// sobre el fondo, cuerpo grafito con sombra real y línea
/// de luz superior de 1 dp; el destino activo va en
/// pastilla naranja plena con icono y etiqueta en grafito
/// (norma 2: sobre la marca, grafito) y peso fuerte; los
/// inactivos, en gris cálido fantasma. Mismo patrón que la
/// barra V1 «Grafito» de Clientes. No cambian los 4
/// destinos, sus claves, la insignia ni el hueco que la
/// barra reserva (el Dock del Pilar 1 vive en el cuerpo,
/// no aquí).
class BarraPilares extends StatelessWidget {
  final int activo;
  final bool esDueno;
  final int urgencias;
  final void Function(int indice) onTap;

  const BarraPilares({
    super.key,
    required this.activo,
    required this.esDueno,
    required this.urgencias,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reducido = MediaQuery.disableAnimationsOf(context);
    final destinos = <({
      Key key,
      IconData icono,
      IconData iconoActivo,
      String etiqueta,
      bool conInsignia,
    })>[
      (
        key: const ValueKey('pilar-tab-mostrador'),
        icono: Icons.storefront_outlined,
        iconoActivo: Icons.storefront_rounded,
        etiqueta: 'Mostrador',
        conInsignia: true,
      ),
      (
        key: const ValueKey('pilar-tab-clientes'),
        icono: Icons.people_outline_rounded,
        iconoActivo: Icons.people_rounded,
        etiqueta: 'Clientes',
        conInsignia: false,
      ),
      (
        key: const ValueKey('pilar-tab-tienda'),
        icono: Icons.science_outlined,
        iconoActivo: Icons.science_rounded,
        etiqueta: 'Tienda',
        conInsignia: false,
      ),
      (
        key: const ValueKey('pilar-tab-negocio'),
        icono: esDueno
            ? Icons.business_center_outlined
            : Icons.account_balance_wallet_outlined,
        iconoActivo: esDueno
            ? Icons.business_center_rounded
            : Icons.account_balance_wallet_rounded,
        etiqueta: esDueno ? 'Negocio' : 'Mi Caja',
        conInsignia: false,
      ),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.md, AppEspacio.xs, AppEspacio.md, AppEspacio.sm),
        child: Container(
          // Altura mínima, no fija: con la letra al 200 %
          // la barra CRECE (como hacía NavigationBar) en
          // vez de reventar el destino.
          constraints: const BoxConstraints(minHeight: 64),
          decoration: BoxDecoration(
            color: AppColores.grafitoTactico,
            borderRadius: BorderRadius.circular(AppRadio.xl),
            boxShadow: const [
              BoxShadow(
                color: AppColores.sombraBarra,
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Línea de luz superior (1 dp): el borde de
              // arriba de la barra coge la luz.
              Positioned(
                top: 0,
                left: AppRadio.xl,
                right: AppRadio.xl,
                child: Container(
                  height: 1,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [
                      Colors.transparent,
                      AppColores.luzBarra,
                      Colors.transparent,
                    ]),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < destinos.length; i++)
                    Expanded(
                      child: _DestinoGrafito(
                        key: destinos[i].key,
                        icono: destinos[i].icono,
                        iconoActivo: destinos[i].iconoActivo,
                        etiqueta: destinos[i].etiqueta,
                        activo: activo == i,
                        reducido: reducido,
                        insignia: destinos[i].conInsignia
                            ? urgencias
                            : 0,
                        // 1.35 (UI-02): cambiar de pilar se
                        // siente (selección).
                        onTap: () {
                          Tacto.seleccion();
                          onTap(i);
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Un destino de la barra «Grafito»: pastilla naranja
/// plena si está activo; fantasma cálido si no.
class _DestinoGrafito extends StatelessWidget {
  final IconData icono;
  final IconData iconoActivo;
  final String etiqueta;
  final bool activo;
  final bool reducido;
  final int insignia;
  final VoidCallback onTap;

  const _DestinoGrafito({
    super.key,
    required this.icono,
    required this.iconoActivo,
    required this.etiqueta,
    required this.activo,
    required this.reducido,
    required this.insignia,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = activo
        ? AppColores.sobreMarca
        : AppColores.fantasmaBarra;
    Widget iconoW = Icon(activo ? iconoActivo : icono,
        color: color, size: 24);
    if (insignia > 0) {
      iconoW = Badge(
        isLabelVisible: true,
        // 1.32 (integración, RD-10): la cifra de la
        // insignia usa el token mínimo de la escala
        // (minuscula, 11) en vez del literal 10.
        label: Text('$insignia',
            style: AppTexto.conTabulares(AppTexto.minuscula)),
        child: iconoW,
      );
    }
    return Semantics(
      button: true,
      selected: activo,
      label: etiqueta,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadio.xl),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.xs, vertical: AppEspacio.sm),
          child: AnimatedContainer(
            duration:
                reducido ? Duration.zero : AppMovimiento.corta,
            curve: AppMovimiento.curvaSuave,
            decoration: BoxDecoration(
              color: activo
                  ? AppColores.naranja
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadio.lg),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                iconoW,
                const SizedBox(height: 2),
                Text(
                  etiqueta,
                  style: AppTexto.etiqueta.copyWith(
                    color: color,
                    fontWeight: activo
                        ? FontWeight.w800
                        : FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dock de Mostrador anclado al pie del Pilar 1: las acciones
/// de mostrador a 1 toque (hoja/pantalla según la tarea, como
/// manda la pieza premium 4). «Cobrar» es EL botón de marca
/// (naranja reservado); el resto va en superficie. Para el
/// dueño suma Suplemento y Gasto (G-05).
class DockMostrador extends StatelessWidget {
  final bool esDueno;
  final VoidCallback onCobrar;
  final VoidCallback onServicio;
  final VoidCallback onPase;
  final VoidCallback onInscribir;
  final VoidCallback? onSuplemento;
  final VoidCallback? onGasto;

  const DockMostrador({
    super.key,
    required this.esDueno,
    required this.onCobrar,
    required this.onServicio,
    required this.onPase,
    required this.onInscribir,
    this.onSuplemento,
    this.onGasto,
  });

  @override
  Widget build(BuildContext context) {
    Widget accion(
      String clave,
      IconData icono,
      String texto,
      VoidCallback? onTap, {
      bool esCobrar = false,
    }) {
      return Expanded(
        child: Material(
          key: ValueKey(clave),
          color: esCobrar
              ? AppColores.naranja
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadio.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadio.md),
            // 1.35 (UI-02): cada acción del Dock responde
            // con un toque ligero.
            onTap: onTap == null
                ? null
                : () {
                    Tacto.ligero();
                    onTap();
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: AppEspacio.sm, horizontal: AppEspacio.xs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icono,
                      size: 22,
                      color: esCobrar ? AppColores.sobreMarca : null),
                  const SizedBox(height: 2),
                  // 1.32 (integración, RD-4): a 360 dp el
                  // Dock del dueño reparte ≈48 dp por acción
                  // y «Suplemento» (≈62 dp a 12) se partía en
                  // dos líneas o se elidía, dejando además
                  // las pastillas a alturas distintas. Una
                  // sola línea que se encoge lo justo
                  // (scaleDown) conserva la palabra entera;
                  // la caja de alto FIJO (la línea natural
                  // de AppTexto.etiqueta a la escala de
                  // texto vigente) hace que el encogido no
                  // arrastre el alto de la pastilla y la fila
                  // quede uniforme.
                  SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(
                        AppTexto.etiqueta.fontSize! *
                            (AppTexto.etiqueta.height ?? 1)),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        texto,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: AppTexto.etiqueta.copyWith(
                          color:
                              esCobrar ? AppColores.sobreMarca : null,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppEspacio.md, AppEspacio.sm,
            AppEspacio.md, AppEspacio.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            accion('dock-cobrar', Icons.payments_rounded, 'Cobrar', onCobrar,
                esCobrar: true),
            const SizedBox(width: AppEspacio.sm),
            accion('dock-servicio', Icons.science_rounded, 'Servicio',
                onServicio),
            const SizedBox(width: AppEspacio.sm),
            accion('dock-pase', Icons.today_rounded, 'Pase', onPase),
            const SizedBox(width: AppEspacio.sm),
            accion('dock-inscribir', Icons.person_add_rounded, 'Inscribir',
                onInscribir),
            if (esDueno && onSuplemento != null) ...[
              const SizedBox(width: AppEspacio.sm),
              accion('dock-suplemento', Icons.medication_rounded,
                  'Suplemento', onSuplemento),
            ],
            if (esDueno && onGasto != null) ...[
              const SizedBox(width: AppEspacio.sm),
              accion('dock-gasto', Icons.money_off_rounded, 'Gasto', onGasto),
            ],
          ],
        ),
      ),
    );
  }
}
