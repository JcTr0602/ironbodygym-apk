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
/// - La píldora de sync es el [SyncPill] de la casa envuelto en
///   el pulso elástico de la pieza premium 8: al guardar algo
///   nuevo, la píldora SUMA el pendiente con un pulso ámbar; al
///   subir, el propio SyncPill enseña el resumen en verde. Sin
///   spinners centrales.
/// - El Modo Sol es SOLO manual (1 toque en la cabecera); el
///   automático por sensor no existe (guarda del contraste).
/// - La cabecera vive SIEMPRE en dos filas (identidad y
///   acciones arriba, píldora a lo ancho debajo): a 420 dp
///   la fila única desborda, y al 200 % ni se acerca.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../sync.dart';
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

/// Píldora de sync con el pulso elástico de la pieza premium 8:
/// cuando el pendiente CRECE (algo se acaba de guardar), la
/// píldora pulsa en ámbar; el contenido y los estados honestos
/// son los del [SyncPill] de la casa, sin tocar.
class PildoraSyncPulso extends StatefulWidget {
  final VoidCallback onTap;
  final bool anchoCompleto;

  const PildoraSyncPulso(
      {super.key, required this.onTap, this.anchoCompleto = false});

  @override
  State<PildoraSyncPulso> createState() => _PildoraSyncPulsoState();
}

class _PildoraSyncPulsoState extends State<PildoraSyncPulso>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulso = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  late final Animation<double> _escala = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.18)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40),
    TweenSequenceItem(
        tween: Tween(begin: 1.18, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 60),
  ]).animate(_pulso);
  StreamSubscription<SyncStatus>? _sub;
  int _pendientesVistos = -1;

  @override
  void initState() {
    super.initState();
    _pendientesVistos = SyncEngine.instance.currentStatus.pending;
    _sub = SyncEngine.instance.statusStream.listen((s) {
      if (!mounted) return;
      if (_pendientesVistos >= 0 && s.pending > _pendientesVistos) {
        _pulso.forward(from: 0);
      }
      _pendientesVistos = s.pending;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulso.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _escala,
      child: SyncPill(onTap: widget.onTap, anchoCompleto: widget.anchoCompleto),
    );
  }
}

/// Cabecera persistente del marco: chip de rol + nombre, píldora
/// de sync, lupa universal, interruptor del Modo Sol y avatar
/// con el menú de perfil. Compacta (~56 dp) y sin alturas fijas:
/// con la fuente por encima del 130 % se apila en dos filas.
class CabeceraMarco extends StatelessWidget {
  /// «Dueño» | «Administrador» | «Entrenador».
  final String rol;
  final String nombre;
  final VoidCallback onSyncTap;
  final VoidCallback onLupa;

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
      // 1.33 (diseño): cada destino del menú lleva su
      // icono en el chip de marca de la casa, como el
      // resto de filas de la app — antes era texto pelado
      // sobre el rectángulo marrón sin tema («parece HTML
      // de hace 20 años»). La superficie, las esquinas y
      // la transición salen del popupMenuTheme de la casa;
      // «Cerrar sesión» se diferencia en rojo de error.
      itemBuilder: (ctx) => [
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
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: CircleAvatar(
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final identidad = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Chip(
          key: const ValueKey('marco-rol'),
          label: Text(rol,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          visualDensity: VisualDensity.compact,
          // 1.33 (diseño): el rol se lee en la marca
          // (borde y texto en el naranja accesible), no en
          // el cobalto plano que Jc rechazó en campo.
          side: BorderSide(color: AppColores.textoNaranja(context)),
          labelStyle: TextStyle(
              color: AppColores.textoNaranja(context),
              fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: AppEspacio.sm),
        Flexible(
          child: Text(
            nombre,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTexto.cuerpo.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    final acciones = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('marco-lupa'),
          tooltip: 'Buscar en el gym',
          icon: const Icon(Icons.search_rounded),
          onPressed: onLupa,
        ),
        _interruptorSol(context),
        _avatar(context),
      ],
    );
    // Dos filas SIEMPRE: identidad + acciones arriba y la
    // píldora de sync A LO ANCHO debajo (precedente de la
    // casa desde UI130-07). A 420 dp — y no digamos con la
    // letra al 200 % — la fila única no cabe: la costura de
    // la 1.32 lo cazó con 50 px de desborde.
    final pildora = PildoraSyncPulso(
      key: const ValueKey('marco-pildora'),
      onTap: onSyncTap,
      anchoCompleto: true,
    );
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: identidad),
              acciones,
            ]),
            const SizedBox(height: AppEspacio.xs),
            pildora,
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
    return NavigationBar(
      key: const ValueKey('marco-pilares'),
      selectedIndex: activo,
      // 1.35 (UI-02): cambiar de pilar se siente (selección).
      onDestinationSelected: (i) {
        Tacto.seleccion();
        onTap(i);
      },
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        NavigationDestination(
          key: const ValueKey('pilar-tab-mostrador'),
          // 1.32 (integración, RD-10): la cifra de la
          // insignia usa el token mínimo de la escala
          // (minuscula, 11) en vez del literal 10.
          icon: Badge(
            isLabelVisible: urgencias > 0,
            label: Text('$urgencias',
                style: AppTexto.conTabulares(AppTexto.minuscula)),
            child: const Icon(Icons.storefront_outlined),
          ),
          selectedIcon: Badge(
            isLabelVisible: urgencias > 0,
            label: Text('$urgencias',
                style: AppTexto.conTabulares(AppTexto.minuscula)),
            child: const Icon(Icons.storefront_rounded),
          ),
          label: 'Mostrador',
        ),
        const NavigationDestination(
          key: ValueKey('pilar-tab-clientes'),
          icon: Icon(Icons.people_outline_rounded),
          selectedIcon: Icon(Icons.people_rounded),
          label: 'Clientes',
        ),
        const NavigationDestination(
          key: ValueKey('pilar-tab-tienda'),
          icon: Icon(Icons.science_outlined),
          selectedIcon: Icon(Icons.science_rounded),
          label: 'Tienda',
        ),
        NavigationDestination(
          key: const ValueKey('pilar-tab-negocio'),
          icon: Icon(esDueno
              ? Icons.business_center_outlined
              : Icons.account_balance_wallet_outlined),
          selectedIcon: Icon(esDueno
              ? Icons.business_center_rounded
              : Icons.account_balance_wallet_rounded),
          label: esDueno ? 'Negocio' : 'Mi Caja',
        ),
      ],
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
