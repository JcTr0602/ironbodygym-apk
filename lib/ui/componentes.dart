/// Componentes reutilizables v1.1 — Iron Body Gym.
///
/// Construidos sobre los tokens de [diseno.dart]. Toda pantalla nueva
/// o rediseñada debe usar estos componentes en vez de armar
/// sus propios botones/tarjetas/diálogos.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../fotos.dart';
import '../sync.dart';
import '../tiempo.dart';

import 'diseno.dart';

// ---------------------------------------------------------------------------
// Scroll global (1.23 T8 — física de gama alta)
// ---------------------------------------------------------------------------

/// Comportamiento de scroll de TODA la app (lo aplica el
/// MaterialApp de main.dart): inercia natural con rebote suave
/// en los bordes — [BouncingScrollPhysics] con
/// [AlwaysScrollableScrollPhysics] de padre, para que las
/// listas cortas también puedan tirar y el gesto se sienta
/// igual en todas las pantallas.
///
/// Pull-to-refresh: los RefreshIndicator de la app escuchan el
/// overscroll del borde superior; con la física de rebote el
/// contenido se desplaza en el borde en vez de encenderse el
/// «glow» de ClampingScrollPhysics, pero la notificación de
/// overscroll sigue llegando y el refresco dispara igual.
///
/// 90/120 Hz: la app VOTA una vez al arranque por la tasa
/// más alta del panel (`pedirAltaTasaDeRefresco` en
/// lib/refresco.dart, llamada única en main); la plataforma
/// decide si la concede, y en paneles LTPO manda el sistema.
/// Nada limita la tasa por pantalla ni por ruta.
class ComportamientoScrollSuave extends MaterialScrollBehavior {
  const ComportamientoScrollSuave();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
  }

  /// Panel Bloque 5 (ajuste 2): la física sola NO decide el
  /// indicador visual de overscroll — lo decide este método, y
  /// MaterialScrollBehavior aplicaría el «glow» (o el stretch)
  /// de Android pese al rebote. Se devuelve el hijo sin
  /// envolver: en los bordes se ve el rebote del contenido y
  /// nada más, que es el acabado T8 buscado. La notificación
  /// de overscroll no pasa por aquí: RefreshIndicator sigue
  /// recibiéndola y disparando igual.
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

// ---------------------------------------------------------------------------
// Botones
// ---------------------------------------------------------------------------

/// Botón primario: gradiente naranja con sombra sutil; gris y sin
/// gradiente cuando está deshabilitado. Con [cargando] muestra un
/// indicador y bloquea pulsaciones repetidas.
class BotonPrimario extends StatelessWidget {
  final String texto;
  final VoidCallback? onPressed;
  final IconData? icono;
  final bool expandido;

  /// v1.2.4: muestra un indicador y bloquea pulsaciones repetidas
  /// mientras la operación está en curso.
  final bool cargando;

  const BotonPrimario({
    super.key,
    required this.texto,
    this.onPressed,
    this.icono,
    this.expandido = true,
    this.cargando = false,
  });

  @override
  Widget build(BuildContext context) {
    final activo = onPressed != null && !cargando;
    final radio = BorderRadius.circular(AppRadio.md);
    // Gradiente naranja + sombra cuando está activo; gris del tema
    // (sin gradiente) cuando está deshabilitado o cargando.
    // 1.29 D-18: la sombra conserva EXACTO el valor que daba la
    // clase deprecada de sombras (naranja 35 %, desenfoque 12,
    // desplazamiento 0/4), ahora escrito en el propio componente.
    final boton = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radio,
        gradient: activo ? AppColores.gradienteNaranja : null,
        boxShadow: activo
            ? [
                BoxShadow(
                  color: AppColores.naranja.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: ElevatedButton(
        onPressed: cargando ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: activo ? Colors.transparent : null,
          shadowColor: Colors.transparent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.md, horizontal: AppEspacio.xl),
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: radio),
        ),
        child:
            _ContenidoBoton(texto: texto, icono: icono, cargando: cargando),
      ),
    );
    if (!expandido) return boton;
    return SizedBox(width: double.infinity, child: boton);
  }
}

class _ContenidoBoton extends StatelessWidget {
  final String texto;
  final IconData? icono;
  final bool cargando;
  const _ContenidoBoton(
      {required this.texto, this.icono, this.cargando = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (cargando) ...[
          const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2)),
          const SizedBox(width: AppEspacio.sm),
        ] else if (icono != null) ...[
          Icon(icono, size: 20),
          const SizedBox(width: AppEspacio.sm),
        ],
        Flexible(
          child: Text(cargando ? 'Procesando…' : texto,
              overflow: TextOverflow.ellipsis, maxLines: 1),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tarjeta de acciones de la ficha del cliente (etapa 4 · F3)
// ---------------------------------------------------------------------------

/// Tarjeta «Acciones» de la ficha: agrupa como filas lo que
/// antes eran botones sueltos al final (Congelar/Descongelar
/// y A papelera en rojo). Widget presentacional sin
/// dependencias (flags + callbacks): la ficha conserva las
/// condiciones y los destinos; aquí solo se pinta y se hacen
/// widget tests.
/// 1.30 (Oleada 10, FICHA-12): la tarjeta ya NO trae
/// «Progreso y Nutrición» ni «Renovación rápida». Progreso
/// queda con UNA sola puerta en la ficha (la tarjeta de la
/// última medida) y Renovar vive junto a la Membresía,
/// donde se mira el estado que lo justifica.
class TarjetaAccionesCliente extends StatelessWidget {
  final bool congelado;

  /// Yunque 1.34 (C5-4): nullable — sin callback NO hay fila
  /// de congelar. La congelación LEGADA de esta tarjeta
  /// (op cambiar_estado, sin aprobación ni devolución de
  /// días) es solo del dueño; el entrenador congela por el
  /// sistema nuevo de solicitud/aprobación. La ficha pasa
  /// null cuando la sesión no es del dueño.
  final VoidCallback? onCongelar;

  /// Yunque 2.34 (D-1): nullable con la misma regla que
  /// onCongelar. La op `cambiar_estado` es SOLO del dueño en
  /// el servidor (modo estricto): ofrecer «A papelera» al
  /// entrenador encolaba una op que el servidor rechazaba en
  /// silencio y el cliente volvía a las listas al bajar.
  final VoidCallback? onPapelera;

  const TarjetaAccionesCliente({
    super.key,
    required this.congelado,
    required this.onCongelar,
    required this.onPapelera,
  });

  Widget _fila({
    required IconData icono,
    required Color color,
    required String texto,
    required VoidCallback onTap,
    bool chevron = false,
    bool peligro = false,
  }) {
    // Material transparente propio: dentro de Tarjeta (fondo con
    // DecoratedBox), el ListTile pintaria su efecto de toque en el
    // Material del Scaffold, debajo de la tarjeta (invisible).
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadio.sm),
        ),
        child: Icon(icono, size: 20, color: color),
      ),
      title: Text(
        texto,
        style: peligro
            ? const TextStyle(color: AppColores.error)
            : null,
      ),
      trailing: chevron
          ? const Icon(Icons.chevron_right_rounded, size: 20)
          : null,
      onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tarjeta(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color:
                      AppColores.naranja.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(AppRadio.sm),
                ),
                child: Icon(Icons.bolt_rounded,
                    size: 18, color: AppColores.textoSecundario(context)),
              ),
              const SizedBox(width: AppEspacio.sm),
              const Text('Acciones', style: AppTexto.titulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          if (onCongelar != null)
            _fila(
              icono: congelado ? Icons.wb_sunny_rounded : Icons.ac_unit_rounded,
              color: AppColores.naranja,
              texto: congelado ? 'Descongelar' : 'Congelar',
              onTap: onCongelar!,
            ),
          if (onCongelar != null && onPapelera != null)
            const Divider(height: 1),
          if (onPapelera != null)
            _fila(
              icono: Icons.delete_outline_rounded,
              color: AppColores.error,
              texto: 'A papelera',
              onTap: onPapelera!,
              peligro: true,
            ),
        ],
      ),
    );
  }
}

/// Yunque 2.34 (F-7): gramática corta de los resúmenes de
/// filtros plegados — la primera palabra de un nombre
/// («Gabriel Pérez» → «Gabriel») para que el resumen quepa
/// en las 2 líneas de C2-5 sin elidir la cola.
String primeraPalabraResumen(String nombre) {
  final t = nombre.trim();
  if (t.isEmpty) return t;
  return t.split(RegExp(r'\s+')).first;
}

/// Yunque 2.34 (F-7): truncado con elipsis para los
/// resúmenes plegados (un producto de 30 caracteres no puede
/// comerse el rango de fechas del mismo botón).
String truncarResumen(String texto, int max) {
  if (texto.length <= max) return texto;
  return '${texto.substring(0, max - 1).trimRight()}…';
}

/// Yunque 2.34 (F-2): RefreshIndicator en la marca.
/// RefreshIndicator NO es temable en este SDK (lee
/// `colorScheme.primary` directo, sin pasar por ningún tema
/// de componente) y el primary de producción es cobalto:
/// los 57 «tirar para refrescar» de la app salían azules,
/// fuera del alcance de DIS-04. Este envoltorio es el
/// RefreshIndicator de siempre con el color fijado a la
/// marca; el resto de parámetros se pasan tal cual (null =
/// el defecto del SDK, sin cambiar ningún comportamiento).
class RefrescoIron extends StatelessWidget {
  final Future<void> Function() onRefresh;
  final Widget child;
  final double? displacement;
  final double? edgeOffset;
  final Color? backgroundColor;
  final double? strokeWidth;
  final String? semanticsLabel;
  final String? semanticsValue;
  final ScrollNotificationPredicate? notificationPredicate;
  final RefreshIndicatorTriggerMode? triggerMode;

  const RefrescoIron({
    super.key,
    required this.onRefresh,
    required this.child,
    this.displacement,
    this.edgeOffset,
    this.backgroundColor,
    this.strokeWidth,
    this.semanticsLabel,
    this.semanticsValue,
    this.notificationPredicate,
    this.triggerMode,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColores.naranja,
      backgroundColor: backgroundColor,
      displacement: displacement ?? 40.0,
      edgeOffset: edgeOffset ?? 0.0,
      strokeWidth: strokeWidth ?? RefreshProgressIndicator.defaultStrokeWidth,
      semanticsLabel: semanticsLabel,
      semanticsValue: semanticsValue,
      notificationPredicate:
          notificationPredicate ?? defaultScrollNotificationPredicate,
      triggerMode: triggerMode ?? RefreshIndicatorTriggerMode.onEdge,
      onRefresh: onRefresh,
      child: child,
    );
  }
}

/// 1.34 Campo 2 (P-7): el gesto de bajar-para-actualizar
/// de una pantalla de ALCANCE, con la regla de Jc
/// (2026-11-14): «que sincronice en muchos casos con los
/// datos reales que ya están descargados; pero si llevan
/// mucho tiempo sin actualizar, que aparte de verificar
/// en local actualice la BD en tiempo real».
/// Operativización: última bajada buena ≤10 min → NO se
/// toca la red y se devuelve null (la pantalla solo
/// relee lo local); más vieja (o nunca) → se baja el
/// alcance primero y se devuelve su resultado detallado
/// para que la pantalla anuncie el desenlace veraz.
Future<ResultadoScopeDetallado?> refrescoScopeIron(String scope) async {
  if (await SyncEngine.instance.datosFrescos()) return null;
  return SyncEngine.instance.sincronizarScopeDetallado(scope);
}

/// 1.34 Campo 2 (P-7): el gesto de una pantalla SIN
/// alcance propio (su dato cruza varias tablas), con la
/// misma regla de Jc: fresco → solo [releer]; viejo → un
/// ciclo completo del motor y después [releer]. Sin
/// avisos: estas pantallas nunca los han dado al tirar
/// (Listas, Home, Papelera, Cola, secciones de Admin).
Future<void> refrescoGeneralIron(
    {required Future<void> Function() releer}) async {
  if (!await SyncEngine.instance.datosFrescos()) {
    try {
      await SyncEngine.instance.run();
    } catch (_) {
      // Sin conexión o ciclo en curso: se relee lo local
      // igualmente (offline-first); el banner de sync de
      // la cáscara cuenta el estado real del motor.
    }
  }
  await releer();
}

/// Botón secundario: contorno neutro, fondo transparente
/// (cancelar, volver, acciones complementarias).
class BotonSecundario extends StatelessWidget {
  final String texto;
  final VoidCallback? onPressed;
  final IconData? icono;

  const BotonSecundario({
    super.key,
    required this.texto,
    this.onPressed,
    this.icono,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.md, horizontal: AppEspacio.xl),
          minimumSize: const Size(64, 52),
        ),
        child: _ContenidoBoton(texto: texto, icono: icono),
      ),
    );
  }
}

/// v1.2.4: acción destructiva (eliminar, anular, borrar). Rojo, para que
/// nunca se confunda con la acción principal. Pedir confirmación antes.
class BotonPeligro extends StatelessWidget {
  final String texto;
  final VoidCallback? onPressed;
  final IconData? icono;
  final bool cargando;

  const BotonPeligro({
    super.key,
    required this.texto,
    this.onPressed,
    this.icono = Icons.delete_outline_rounded,
    this.cargando = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: cargando ? null : onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColores.error,
          side: const BorderSide(color: AppColores.error, width: 1.5),
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.md, horizontal: AppEspacio.xl),
          minimumSize: const Size(64, 52),
        ),
        child: _ContenidoBoton(
            texto: texto, icono: icono, cargando: cargando),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tarjeta
// ---------------------------------------------------------------------------

/// Tarjeta estándar del sistema: radio grande, sombra sutil, padding 16.
/// Bloque 1: fundido suave de entrada (250 ms). Solo anima al
/// montar: con el mismo tween no se repite en cada setState ni
/// retrasa las tarjetas al hacer scroll.
///
/// 1.22 Diseño Bloque 1 (T3, ajustes de Argón): la cascada
/// está ACOTADA — solo anima dentro de la ventana de 400 ms
/// desde que la pantalla se monta (las pantallas llaman a
/// [reiniciarVentana] en su initState) y solo los primeros
/// 10 ítems ([indice] 0-9, con 35 ms de escalón). Fuera de
/// la ventana o del cupo, el hijo se renderiza directo en
/// opacidad 1, sin crear maquinaria de animación: al hacer
/// scroll rápido no hay tirones ni latencia artificial en
/// pantallas de gama alta a 120 Hz.
class FadeEntrada extends StatefulWidget {
  final Widget child;

  /// Posición en la lista para la cascada; null = sin
  /// escalón (fundido simple de bloque, el uso histórico).
  final int? indice;

  const FadeEntrada({super.key, required this.child, this.indice});

  static DateTime? _inicioVentana;

  /// Abre la ventana de cascada (400 ms). Las pantallas con
  /// listas la llaman en initState.
  static void reiniciarVentana() => _inicioVentana = DateTime.now();

  static bool get ventanaActiva {
    final ahora = DateTime.now();
    _inicioVentana ??= ahora;
    return ahora.difference(_inicioVentana!) <
        const Duration(milliseconds: 400);
  }

  @override
  State<FadeEntrada> createState() => _FadeEntradaState();
}

class _FadeEntradaState extends State<FadeEntrada> {
  late final bool _animar;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    final i = widget.indice;
    _animar =
        FadeEntrada.ventanaActiva && (i == null || i < 10);
    if (!_animar) {
      _visible = true;
      return;
    }
    final retraso = i == null
        ? Duration.zero
        : Duration(milliseconds: i * 35);
    if (retraso == Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _visible = true);
      });
    } else {
      Future.delayed(retraso, () {
        if (mounted) setState(() => _visible = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_animar) return widget.child;
    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.0,
      // 1.30 D6 (UI130-32): duración y curva del token.
      duration: AppMovimiento.media,
      curve: AppMovimiento.curvaSuave,
      child: widget.child,
    );
  }
}

/// 1.22 Diseño Bloque 1 (T7, ajustes de Argón): cruce
/// desvanecido entre los estados de una pantalla (carga →
/// contenido → vacío/error) sin parpadeo. La key del hijo es
/// SOLO el tipo de estado ([estado]), NUNCA los datos: si la
/// key cambiara con los datos, el switcher destruiría el
/// contenido (y su ScrollController) en cada refresco.
/// PROHIBIDO poner GlobalKey dentro del hijo directo:
/// durante el crossfade conviven el árbol saliente y el
/// entrante y una GlobalKey duplicada revienta en runtime.
/// Un refresco con datos debe MANTENER el estado
/// 'contenido' (no volver a 'cargando') para no perder el
/// scroll: 'cargando' es solo para la carga inicial.
class CruceEstados extends StatelessWidget {
  /// 'cargando' | 'contenido' | 'vacio' | 'error'.
  final String estado;
  final Widget child;

  const CruceEstados({super.key, required this.estado, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      // 1.30 D6 (UI130-32): los valores de siempre, por el
      // token (220 ms = AppMovimiento.media).
      duration: AppMovimiento.media,
      switchInCurve: AppMovimiento.curva,
      switchOutCurve: AppMovimiento.curvaReversa,
      child: KeyedSubtree(key: ValueKey<String>(estado), child: child),
    );
  }
}

/// 1.22 Diseño Bloque 1 (base B10 adelantada por Argón): la
/// AppBar del sistema. Devuelve un AppBar ESTÁNDAR (no una
/// jerarquía nueva): find.byType(AppBar) y el tema siguen
/// funcionando igual en toda la app y en la suite. Las
/// pantallas nuevas la usan desde el nacimiento; la
/// migración de las existentes es progresiva (Boy Scout).
class IronAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final PreferredSizeWidget? bottom;

  const IronAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: title,
      actions: actions,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      bottom: bottom,
    );
  }
}

class Tarjeta extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onTap;

  const Tarjeta({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppEspacio.lg),
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 1.29 D-18: la sombra conserva EXACTO el valor que daba la
    // clase deprecada de sombras (negro/gris según el brillo),
    // escrito en el propio componente.
    // 1.35 (UX-09): profundidad sin cambiar un solo color —
    // en Modo Sol la sombra de papel se marca más (la
    // tarjeta se despega del fondo claro) y en oscuro cada
    // tarjeta lleva la línea de luz de 1 dp en su borde
    // superior, como una pieza apoyada. El alto contraste
    // queda exento y plano, como siempre.
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    final altoContraste = AppColores.esAltoContraste(context);
    final sombra = altoContraste || oscuro
        ? BoxShadow(
            color: (oscuro ? Colors.black : Colors.grey)
                .withValues(alpha: oscuro ? 0.4 : 0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        : BoxShadow(
            color: Colors.grey.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          );
    final lineaLuz = oscuro && !altoContraste
        ? Positioned(
            top: 0,
            left: AppRadio.lg,
            right: AppRadio.lg,
            child: Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.07),
            ),
          )
        : null;
    final radio = BorderRadius.circular(AppRadio.lg);
    if (onTap == null) {
      return Container(
        decoration: BoxDecoration(
          color: color ?? AppColores.superficie(context),
          borderRadius: radio,
          border: Border.all(color: AppColores.borde(context)),
          boxShadow: [sombra],
        ),
        // Cierre §17 (×30): el contenido va sobre un Material
        // transparente PROPIO. Sin él, cualquier ListTile o
        // ExpansionTile dentro de una Tarjeta (p. ej. las
        // secciones de Ayuda) dispara la aserción «ListTile
        // background color» porque su fondo y su tinta caían
        // tras esta caja decorada; y un InkWell descendiente
        // pintaba su onda sobre el Material de la pantalla en
        // vez de dentro de la tarjeta. Transparente: ni un
        // píxel del diseño cambia.
        child: Stack(
          children: [
            Material(
              type: MaterialType.transparency,
              child: Padding(padding: padding, child: child),
            ),
            if (lineaLuz != null) lineaLuz,
          ],
        ),
      );
    }
    // 1.30 D1 (UI130-08): el ripple cae POR FIN sobre la
    // tarjeta. Antes un InkWell envolvía por fuera un
    // Container opaco y la tinta se pintaba detrás, en el
    // Material del fondo: el toque no se veía en las 28
    // tarjetas tocables. Ahora la sombra vive en un
    // contenedor transparente exterior y el color, en un
    // Material propio con el InkWell DENTRO (el mismo
    // patrón que la Cola resolvió a mano en la 1.29).
    // Color, borde, sombra y acolchado: los de siempre.
    return Container(
      decoration: BoxDecoration(
        borderRadius: radio,
        boxShadow: [sombra],
      ),
      child: Material(
        color: color ?? AppColores.superficie(context),
        borderRadius: radio,
        child: InkWell(
          borderRadius: radio,
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radio,
              border: Border.all(color: AppColores.borde(context)),
            ),
            // 1.35 (UX-09): la misma línea de luz de la
            // rama sin toque, bajo la onda del InkWell.
            child: Stack(
              children: [
                Padding(padding: padding, child: child),
                if (lineaLuz != null) lineaLuz,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 1.35 (UX-09): el fondo con profundidad del marco —
/// en oscuro, un degradado grafito suave con el
/// resplandor de marca (un radial naranja casi
/// invisible) tras la zona superior; en Modo Sol, el
/// papel frío plano de siempre (la profundidad la dan
/// las sombras de las tarjetas). Degradado FIJO, sin
/// movimiento ni efectos en vivo. El alto contraste
/// queda exento: fondo plano del tema.
class FondoProfundidad extends StatelessWidget {
  const FondoProfundidad({super.key});

  @override
  Widget build(BuildContext context) {
    if (AppColores.esAltoContraste(context)) {
      return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor);
    }
    if (Theme.of(context).brightness == Brightness.light) {
      return const ColoredBox(color: AppColores.papelFrio);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF10161E), AppColores.pizarra],
              stops: [0, 0.55],
            ),
          ),
        ),
        Positioned(
          top: -140,
          left: -60,
          right: -60,
          height: 300,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  AppColores.naranja.withValues(alpha: 0.055),
                  AppColores.naranja.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Badge de estado (membresía)
// ---------------------------------------------------------------------------

/// Estado de membresía para badges.
enum EstadoMembresia { alDia, porVencer, vencido, sinPagos, congelado }

/// Badge con icono + texto. Nunca solo color.
class BadgeEstado extends StatelessWidget {
  final EstadoMembresia estado;
  final String texto;

  const BadgeEstado({
    super.key,
    required this.estado,
    required this.texto,
  });

  @override
  Widget build(BuildContext context) {
    late final Color fondo;
    late final Color frente;
    late final IconData icono;
    // 1.29 D-06: el frente es el ROL de texto del estado
    // (D-02), ya resuelto por tema — se acabó el parche de
    // aclarar con lerp sin medir. Los brillantes quedan
    // solo como tinte de fondo. GD-03: porVencer deja el
    // #D97706 que daba 3,19 en claro y congelado deja el
    // azul brillante que daba 3,68/3,90.
    switch (estado) {
      case EstadoMembresia.alDia:
        fondo = AppColores.exito.withValues(alpha: 0.15);
        frente = AppColores.exitoTexto(context);
        icono = Icons.check_circle_rounded;
        break;
      case EstadoMembresia.porVencer:
        fondo = AppColores.alerta.withValues(alpha: 0.15);
        frente = AppColores.alertaTexto(context);
        icono = Icons.schedule_rounded;
        break;
      case EstadoMembresia.vencido:
        fondo = AppColores.error.withValues(alpha: 0.15);
        frente = AppColores.errorTexto(context);
        icono = Icons.warning_amber_rounded;
        break;
      // 1.25 T04: nunca pagó — neutro, jamás el verde
      // de «al día». 1.29: el frente pasa al rol de texto
      // secundario (el gris anterior daba 2,50 en oscuro
      // sobre su propio tinte).
      case EstadoMembresia.sinPagos:
        fondo = AppColores.bannerGrisA.withValues(alpha: 0.18);
        frente = AppColores.textoSecundario(context);
        icono = Icons.receipt_long_rounded;
        break;
      // 1.25 T13: membresía congelada — el estado manda
      // sobre los días (su vencimiento no está corriendo).
      case EstadoMembresia.congelado:
        fondo = AppColores.info.withValues(alpha: 0.15);
        frente = AppColores.infoTexto(context);
        icono = Icons.ac_unit_rounded;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(AppRadio.circular),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 16, color: frente),
          const SizedBox(width: 4),
          // Jornada 1 de la 1.34: un texto largo del badge
          // («VENCIDO … DÍAS» en filas estrechas con
          // trailing ancho, p. ej. la Papelera) desbordaba
          // la columna en seco (158 px medidos); flexible
          // con elipsis, como el chip de la Casa.
          Flexible(
            child: Text(texto,
                overflow: TextOverflow.ellipsis,
                style: AppTexto.etiqueta.copyWith(color: frente)),
          ),
        ],
      ),
    );
  }

  /// Construye el badge desde días restantes (helper común).
  static BadgeEstado desdeDias(int dias, {int umbral = 7}) {
    if (dias < 0) {
      return BadgeEstado(
          estado: EstadoMembresia.vencido,
          texto: 'VENCIDO ${dias.abs()} DÍAS');
    }
    // v1.2.1: "Vence hoy" sin redundancia (antes "VENCE EN 0 DÍAS").
    if (dias == 0) {
      return const BadgeEstado(
          estado: EstadoMembresia.porVencer, texto: 'VENCE HOY');
    }
    if (dias <= umbral) {
      return BadgeEstado(
          estado: EstadoMembresia.porVencer,
          texto: 'VENCE EN $dias DÍAS');
    }
    return const BadgeEstado(
        estado: EstadoMembresia.alDia, texto: 'AL DÍA');
  }
}

// ---------------------------------------------------------------------------
// Diálogo estándar
// ---------------------------------------------------------------------------

/// Diálogo con el estilo único de la app.
class DialogoApp extends StatelessWidget {
  final String titulo;
  final IconData? iconoTitulo;
  final Widget contenido;
  final List<Widget> acciones;

  const DialogoApp({
    super.key,
    required this.titulo,
    this.iconoTitulo,
    required this.contenido,
    this.acciones = const [],
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadio.xl),
      ),
      title: Row(
        children: [
          if (iconoTitulo != null) ...[
            Icon(iconoTitulo, color: AppColores.textoSecundario(context)),
            const SizedBox(width: AppEspacio.sm),
          ],
          Expanded(child: Text(titulo, style: AppTexto.titulo)),
        ],
      ),
      content: contenido,
      actions: acciones,
      actionsPadding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, 0, AppEspacio.lg, AppEspacio.lg),
    );
  }

  /// Muestra un diálogo de confirmación simple. Devuelve true si aceptó.
  static Future<bool> confirmar(
    BuildContext context, {
    required String titulo,
    required String mensaje,
    String aceptar = 'Aceptar',
    String cancelar = 'Cancelar',
    IconData icono = Icons.help_outline_rounded,
    bool peligro = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: titulo,
        iconoTitulo: icono,
        contenido: Text(mensaje, style: AppTexto.cuerpo),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelar),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: peligro
                  ? AppColores.error
                  : AppColores.naranja,
              // 1.29 (ajuste de Argón al código, H-05): sobre
              // el naranja manda sobreMarca (D-01: grafito,
              // 6,32 de contraste; el blanco da 2,75 y no
              // pasa). El blanco queda solo para el peligro,
              // sobre el rojo de error.
              foregroundColor: peligro
                  ? Colors.white
                  : AppColores.sobreMarca,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.md),
              ),
            ),
            child: Text(aceptar),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

/// v1.8.0: selector de modo para eliminar cliente definitivamente
/// (ficha y papelera comparten este diálogo). Devuelve 'todo',
/// 'conservar' o null si se cancela. Ambos modos son irreversibles
/// y el diálogo lo dice; cada modo trae su explicación de una
/// línea. [avisoFiado] (si el cliente debe un fiado) se muestra
/// junto a la opción de conservar: al conservar, la deuda se da
/// por incobrable (candado 3 de Argón).
Future<String?> elegirModoEliminacion(
  BuildContext context, {
  required String titulo,
  String? avisoFiado,
}) async {
  var modo = 'conservar';
  Widget opcion(String valor, String tituloOp, String descripcion,
      void Function(void Function()) setState) {
    final sel = modo == valor;
    return InkWell(
      onTap: () => setState(() => modo = valor),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              sel
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: sel ? AppColores.naranja : null,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tituloOp,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600)),
                  Text(descripcion,
                      style: AppTexto.secundario),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  final elegido = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => DialogoApp(
        titulo: titulo,
        iconoTitulo: Icons.warning_amber_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hay dos formas de eliminar. Ambas son IRREVERSIBLES: '
              'no se puede deshacer ni recuperar a la persona.',
            ),
            const SizedBox(height: 12),
            opcion(
                'conservar',
                'Eliminar conservando estadísticas',
                'La persona desaparece; sus pagos y ventas quedan '
                    'anónimos y las estadísticas y la nómina no cambian.',
                setState),
            if (avisoFiado != null && modo == 'conservar')
              Padding(
                padding: const EdgeInsets.only(left: AppEspacio.xxl, bottom: AppEspacio.xs),
                child: Text(
                  avisoFiado,
                  style: const TextStyle(
                      color: AppColores.error, fontWeight: FontWeight.w600),
                ),
              ),
            opcion(
                'todo',
                'Eliminar todo',
                'Borra también sus pagos y ventas; las estadísticas '
                    'de meses pasados bajan.',
                setState),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, modo),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Continuar')),
        ],
      ),
    ),
  );
  return elegido;
}

// ---------------------------------------------------------------------------
// Estado vacío
// ---------------------------------------------------------------------------

/// Estado vacío útil: icono, título, subtítulo y acción opcional.
class EstadoVacio extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String? subtitulo;
  final String? textoAccion;
  final VoidCallback? onAccion;

  /// 1.30 D6 (UI130-22): el vacío vive DENTRO de una
  /// sección (una zona con su propio fondo): sin el
  /// medallón ni el acolchado de pantalla completa — el
  /// doble fondo que la auditoría señala en Servicios.
  final bool sinMarco;

  /// 1.30 D6 (UI130-22, ALTA-02): ilustración de la
  /// lámina de vacíos (`assets/vacio_*`) que sustituye
  /// a la figura de icono cuando el estado tiene una
  /// asignada. Sin asignar, el icono de siempre.
  ///
  /// 1.34 (carril arte + regeneración): las DOCE
  /// ilustraciones de vacío son spots WebP con ALFA real
  /// (sin el fondo horneado de la lámina) y se pintan con
  /// `BoxFit.contain` para que floten sobre la superficie
  /// — pomo, pastel y megafono incluidas, regeneradas como
  /// ilustraciones sueltas en la integración. (Yunque 1.34,
  /// C2-7: este comentario decía que esas tres quedaban en
  /// JPG con cover; la decisión de regenerarlas lo dejó
  /// falso. El `cover` queda solo como respaldo para una
  /// ruta que no termine en .webp.)
  final String? ilustracion;

  const EstadoVacio({
    super.key,
    required this.icono,
    required this.titulo,
    this.subtitulo,
    this.textoAccion,
    this.onAccion,
    this.sinMarco = false,
    this.ilustracion,
  });

  @override
  Widget build(BuildContext context) {
    // 1.32 (Oleada 2, Fase 0 — residuo 9b del veredicto
    // g132dis_): el vacío es ELÁSTICO. Con poca altura
    // disponible (< 200 px) compacta márgenes y figura —
    // jamás la tipografía — y con marco se envuelve en un
    // scroll seguro: lo que no cabe SCROLLEA en vez de
    // recortarse (el recorte medido: 101 px a 480×640 en
    // los vacíos envueltos del Pilar Clientes, agravado
    // por la cabecera marco de dos filas permanentes).
    return LayoutBuilder(
      builder: (context, limites) {
        final compacto =
            limites.maxHeight.isFinite && limites.maxHeight < 200;
        return _contenido(context, compacto: compacto, limites: limites);
      },
    );
  }

  Widget _contenido(BuildContext context,
      {required bool compacto, required BoxConstraints limites}) {
    final secundario = AppColores.textoSecundario(context);
    // La figura: la ilustración asignada si la hay; si
    // no, el icono — con su medallón en el vacío de
    // pantalla y suelto en el sin marco (la sección que
    // lo aloja ya trae su propio fondo). En compacto la
    // figura se reduce; la tipografía, nunca.
    final Widget figura;
    if (ilustracion != null) {
      final lado = sinMarco ? 96.0 : (compacto ? 72.0 : 128.0);
      // 1.34 (carril arte): el spot con alfa (WebP) va
      // en contain — recortarlo con cover amputaría el
      // motivo y su sombra; la escena opaca (JPG) sigue
      // en cover, llenando el cuadrado como hasta hoy.
      final esSpot = ilustracion!.endsWith('.webp');
      figura = ClipRRect(
        borderRadius: BorderRadius.circular(AppRadio.lg),
        child: Image.asset(ilustracion!,
            width: lado,
            height: lado,
            fit: esSpot ? BoxFit.contain : BoxFit.cover),
      );
    } else if (sinMarco) {
      figura = Icon(icono,
          size: compacto ? 24 : 30,
          color: AppColores.textoSecundario(context));
    } else {
      final diametro = compacto ? 48.0 : 72.0;
      figura = Container(
        width: diametro,
        height: diametro,
        decoration: BoxDecoration(
          color:
              AppColores.textoSecundario(context).withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icono,
            size: compacto ? 24 : 36,
            color: AppColores.textoSecundario(context)),
      );
    }
    final columna = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        figura,
        SizedBox(
            height: sinMarco
                ? AppEspacio.md
                : (compacto ? AppEspacio.sm : AppEspacio.lg)),
        Text(titulo,
            style: AppTexto.subtitulo,
            textAlign: TextAlign.center),
        if (subtitulo != null) ...[
          const SizedBox(height: AppEspacio.sm),
          Text(subtitulo!,
              style: AppTexto.secundario.copyWith(
                  color: secundario),
              textAlign: TextAlign.center),
        ],
        if (textoAccion != null &&
            onAccion != null) ...[
          SizedBox(height: compacto ? AppEspacio.md : AppEspacio.lg),
          BotonSecundario(
              texto: textoAccion!, onPressed: onAccion),
        ],
      ],
    );
    // Sin marco: ni el Center de pantalla completa ni su
    // acolchado xxl — solo el aire de la sección (en
    // compacto, reducido). La sección anfitriona ya trae
    // su propio scroll si lo necesita.
    if (sinMarco) {
      return Padding(
        padding: EdgeInsets.symmetric(
            horizontal: AppEspacio.lg,
            vertical: compacto ? AppEspacio.sm : AppEspacio.md),
        child: columna,
      );
    }
    final acolchado = Padding(
      padding:
          EdgeInsets.all(compacto ? AppEspacio.md : AppEspacio.xxl),
      child: columna,
    );
    // Alto sin cota (dentro de una lista): el Center de
    // siempre — la lista anfitriona ya scrollea.
    if (!limites.maxHeight.isFinite) {
      return Center(child: acolchado);
    }
    // Alto finito: centrado si sobra, scroll si falta —
    // nunca recorte ni overflow.
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: limites.maxHeight),
        child: Center(child: acolchado),
      ),
    );
  }
}

/// v1.2.4: estado de error con explicación y botón Reintentar.
///
/// 1.23 B6: con [claseError] el widget NACE clasificado: la
/// acción visible es la de su clase (ver
/// [configErrorClasificado]) — C1 ofrece «Reintentar», C3
/// «Verificar» (JAMÁS «Reintentar»: repetir la escritura podría
/// duplicarla) y C2/C4 no ofrecen botón aunque haya callback.
/// Sin clase se conserva el comportamiento histórico.
class EstadoError extends StatelessWidget {
  final String titulo;
  final String? detalle;
  final VoidCallback? onReintentar;
  final ClaseError? claseError;

  const EstadoError({
    super.key,
    this.titulo = 'No se pudo cargar',
    this.detalle,
    this.onReintentar,
    this.claseError,
  });

  @override
  Widget build(BuildContext context) {
    final cfg =
        claseError == null ? null : configErrorClasificado(claseError!);
    final esErrorDuro =
        cfg == null || cfg.significado == SignificadoChip.error;
    // La etiqueta sale de la clase, nunca del llamador: sin
    // clase es «Reintentar»; con clase, la suya (null en C2/C4
    // = sin botón, aunque haya callback).
    final etiqueta = onReintentar == null
        ? null
        : (cfg == null ? 'Reintentar' : cfg.etiquetaAccion);
    final iconoAccion = switch (etiqueta) {
      'Verificar' => Icons.fact_check_outlined,
      'Ver cola' => Icons.list_alt_rounded,
      _ => Icons.refresh_rounded,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                esErrorDuro
                    ? Icons.error_outline_rounded
                    : Icons.warning_amber_rounded,
                size: 48,
                color: esErrorDuro
                    ? AppColores.error
                    : AppColores.alerta),
            const SizedBox(height: AppEspacio.md),
            Text(titulo,
                style: AppTexto.subtitulo, textAlign: TextAlign.center),
            if (detalle != null) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(detalle!,
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context)),
                  textAlign: TextAlign.center),
            ],
            if (etiqueta != null) ...[
              const SizedBox(height: AppEspacio.lg),
              BotonSecundario(
                  texto: etiqueta,
                  icono: iconoAccion,
                  onPressed: onReintentar),
            ],
          ],
        ),
      ),
    );
  }
}

/// 1.23 B6 (H-03 de Argón): error de validación INLINE para
/// formularios dentro de Dialog/BottomSheet. REGLA de la
/// gramática: una validación que nace dentro de un modal se
/// muestra DENTRO del modal con este widget, nunca como
/// SnackBar del Scaffold de fondo (la barra se pinta detrás
/// del velo, choca con el FAB y el usuario no la asocia al
/// campo). El SnackBar queda para el feedback de la pantalla
/// tras cerrar el modal.
class ErrorInline extends StatelessWidget {
  final String mensaje;

  const ErrorInline(this.mensaje, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline_rounded,
            size: 16, color: AppColores.error),
        const SizedBox(width: AppEspacio.xs),
        Expanded(
          child: Text(
            mensaje,
            style: AppTexto.metadato.copyWith(
                color: AppColores.error, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// v1.2.4: indicador de carga con texto (para esperas no inmediatas).
class EstadoCargando extends StatelessWidget {
  final String texto;
  const EstadoCargando({super.key, this.texto = 'Cargando…'});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppEspacio.md),
          Text(texto,
              style: AppTexto.secundario.copyWith(
                  color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Campo de texto
// ---------------------------------------------------------------------------
// Kit de formularios (1.30 D3, UI130-14)
// ---------------------------------------------------------------------------

/// Decoración ÚNICA de los campos del kit: la misma piel de
/// [CampoTexto] para que ningún campo nuevo invente la suya.
InputDecoration _decoracionCampo(
  BuildContext context, {
  String? etiqueta,
  String? hint,
  String? errorText,
  IconData? icono,
  String? prefixText,
  String? suffixText,
  Widget? suffixIcon,
}) {
  return InputDecoration(
    labelText: etiqueta,
    hintText: hint,
    errorText: errorText,
    prefixIcon: icono != null ? Icon(icono) : null,
    prefixText: prefixText,
    suffixText: suffixText,
    suffixIcon: suffixIcon,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadio.md),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadio.md),
      borderSide: BorderSide(color: AppColores.borde(context)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadio.md),
      borderSide:
          const BorderSide(color: AppColores.naranja, width: 2),
    ),
    filled: true,
    fillColor: AppColores.superficie(context),
    contentPadding: const EdgeInsets.symmetric(
        horizontal: AppEspacio.lg, vertical: AppEspacio.md),
  );
}

/// PURO (1.30 D3): parseo de un campo de moneda de la casa.
/// Acepta '.' y ',' como separador decimal (el teclado
/// cubano teclea la coma; [HojaLiquidar] ya parseaba así).
/// null si no es un número finito.
double? parseMoneda(String texto) {
  final t = texto.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  return v;
}

/// Formateador de moneda: solo dígitos con UN separador
/// decimal ('.' o ',') y hasta 2 decimales. No agrupa
/// miles: el texto del controlador sigue siendo parseable
/// por los parseos vigentes de cada pantalla (la validación
/// de negocio NO cambia; esto es solo formato de tecleo).
class FormateadorMoneda extends TextInputFormatter {
  const FormateadorMoneda();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final texto = newValue.text;
    if (texto.isEmpty) return newValue;
    if (!RegExp(r'^[0-9.,]+$').hasMatch(texto)) return oldValue;
    final sep = texto.indexOf(RegExp(r'[.,]'));
    if (sep >= 0) {
      final resto = texto.substring(sep + 1);
      if (resto.contains(RegExp(r'[.,]'))) return oldValue;
      if (resto.length > 2) return oldValue;
    }
    return newValue;
  }
}

/// Campo de dinero del sistema: sufijo de moneda (CUP/USD),
/// formato de tecleo de [FormateadorMoneda] y selección
/// total al enfocar (sobreescribir el monto sin borrar).
class CampoMoneda extends StatefulWidget {
  final TextEditingController controller;
  final String? etiqueta;
  final String moneda;
  final IconData? icono;
  final FocusNode? focusNode;
  final void Function(String)? onChanged;
  final void Function(String)? onSubmitted;
  final String? errorText;

  /// Icono de estado a la derecha (p. ej. el ✓ de guardado
  /// del Centro de Precios), tras el sufijo de moneda.
  final Widget? sufijo;

  const CampoMoneda({
    super.key,
    required this.controller,
    this.etiqueta,
    this.moneda = 'CUP',
    this.icono,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.sufijo,
  });

  @override
  State<CampoMoneda> createState() => _CampoMonedaState();
}

class _CampoMonedaState extends State<CampoMoneda> {
  late final FocusNode _foco;
  late final bool _focoPropio;

  @override
  void initState() {
    super.initState();
    _focoPropio = widget.focusNode == null;
    _foco = widget.focusNode ?? FocusNode();
    _foco.addListener(_alCambiarFoco);
  }

  void _alCambiarFoco() {
    if (!_foco.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_foco.hasFocus) return;
      widget.controller.selection = TextSelection(
          baseOffset: 0, extentOffset: widget.controller.text.length);
    });
  }

  @override
  void dispose() {
    _foco.removeListener(_alCambiarFoco);
    if (_focoPropio) _foco.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: _foco,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: const [FormateadorMoneda()],
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      style: AppTexto.cuerpo,
      decoration: _decoracionCampo(context,
        etiqueta: widget.etiqueta,
        errorText: widget.errorText,
        icono: widget.icono,
        suffixText: widget.moneda,
        suffixIcon: widget.sufijo,
      ),
    );
  }
}

/// PURO (1.30 D3): limpieza de dígitos de teléfono al
/// teclear, espejo de la limpieza de `sanitizarTelefono`
/// (negocio.dart) SIN su validación: quita lo que no sea
/// dígito; el internacional pegado (10 dígitos empezando
/// en 53) colapsa a los 8 locales; un número local no
/// admite más de 8. El controlador NUNCA guarda el prefijo:
/// el dato guardado son los 8 dígitos limpios y el +53 es
/// solo el prefijo visual del campo.
String limpiarDigitosTelefono(String crudo) {
  var d = crudo.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length > 8) {
    if (d.startsWith('53')) {
      if (d.length > 10) d = d.substring(0, 10);
      if (d.length == 10) d = d.substring(2);
    } else {
      d = d.substring(0, 8);
    }
  }
  return d;
}

/// Formateador de teléfono: aplica [limpiarDigitosTelefono]
/// a cada tecleo o pegado.
class FormateadorTelefono extends TextInputFormatter {
  const FormateadorTelefono();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final limpio = limpiarDigitosTelefono(newValue.text);
    if (limpio == newValue.text) return newValue;
    return TextEditingValue(
      text: limpio,
      selection: TextSelection.collapsed(offset: limpio.length),
    );
  }
}

/// Campo de teléfono del sistema: prefijo visual «+53»
/// (nunca entra al controlador) y limpieza de dígitos al
/// teclear con [FormateadorTelefono].
class CampoTelefono extends StatelessWidget {
  final TextEditingController controller;
  final String? etiqueta;
  final IconData? icono;
  final FocusNode? focusNode;
  final void Function(String)? onChanged;
  final String? errorText;

  const CampoTelefono({
    super.key,
    required this.controller,
    this.etiqueta,
    this.icono,
    this.focusNode,
    this.onChanged,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.phone,
      inputFormatters: const [FormateadorTelefono()],
      onChanged: onChanged,
      style: AppTexto.cuerpo,
      decoration: _decoracionCampo(context,
        etiqueta: etiqueta,
        hint: '58123456',
        errorText: errorText,
        icono: icono,
        prefixText: '+53 ',
      ),
    );
  }
}

/// Campo de cantidad entera: solo dígitos y, si [paso] no
/// es nulo, botones −/+ que suman ese paso sin bajar de
/// [minimo] ni pasar de [maximo].
class CampoCantidad extends StatelessWidget {
  final TextEditingController controller;
  final String? etiqueta;
  final IconData? icono;
  final int? paso;
  final int minimo;
  final int? maximo;
  final void Function(String)? onChanged;
  final String? errorText;

  const CampoCantidad({
    super.key,
    required this.controller,
    this.etiqueta,
    this.icono,
    this.paso,
    this.minimo = 0,
    this.maximo,
    this.onChanged,
    this.errorText,
  });

  void _sumar(int delta) {
    final actual = int.tryParse(controller.text.trim()) ?? minimo;
    var nuevo = actual + delta;
    if (nuevo < minimo) nuevo = minimo;
    final max = maximo;
    if (max != null && nuevo > max) nuevo = max;
    controller.text = '$nuevo';
    onChanged?.call('$nuevo');
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: onChanged,
      style: AppTexto.cuerpo,
      decoration: _decoracionCampo(context,
        etiqueta: etiqueta,
        errorText: errorText,
        icono: icono,
        suffixIcon: paso == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_rounded),
                    tooltip: 'Menos',
                    onPressed: () => _sumar(-paso!),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded),
                    tooltip: 'Más',
                    onPressed: () => _sumar(paso!),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Campo de fecha del sistema: solo lectura (tocar abre el
/// selector del sistema), texto en el formato de la casa
/// dd/mm/aaaa (el de `fmtFecha`) y botón de limpiar cuando
/// hay valor y [limpiable] es true. El controlador es
/// propio y se libera en dispose (regla de la casa).
class CampoFecha extends StatefulWidget {
  final DateTime? valor;
  final ValueChanged<DateTime?> onCambio;
  final String? etiqueta;
  final bool limpiable;
  final DateTime? primera;
  final DateTime? ultima;
  final IconData? icono;

  const CampoFecha({
    super.key,
    required this.valor,
    required this.onCambio,
    this.etiqueta,
    this.limpiable = true,
    this.primera,
    this.ultima,
    this.icono,
  });

  @override
  State<CampoFecha> createState() => _CampoFechaState();
}

class _CampoFechaState extends State<CampoFecha> {
  final _ctrl = TextEditingController();

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  void initState() {
    super.initState();
    _sincronizar();
  }

  @override
  void didUpdateWidget(CampoFecha oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valor != widget.valor) _sincronizar();
  }

  void _sincronizar() {
    _ctrl.text = widget.valor == null ? '' : _fmt(widget.valor!);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _elegir() async {
    final f = await showDatePicker(
      context: context,
      initialDate: widget.valor ?? ahoraHabana(),
      firstDate: widget.primera ?? DateTime(1930),
      lastDate: widget.ultima ?? DateTime(2100),
    );
    if (f != null) widget.onCambio(f);
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _ctrl,
      readOnly: true,
      onTap: _elegir,
      style: AppTexto.cuerpo,
      decoration: _decoracionCampo(context,
        etiqueta: widget.etiqueta,
        hint: 'dd/mm/aaaa',
        icono: widget.icono,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.limpiable && widget.valor != null)
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Limpiar fecha',
                onPressed: () => widget.onCambio(null),
              ),
            IconButton(
              icon: const Icon(Icons.calendar_month_rounded),
              tooltip: 'Elegir fecha',
              onPressed: _elegir,
            ),
          ],
        ),
      ),
    );
  }
}

/// Sección de un [FormularioIron]: encabezado con icono y
/// título y sus campos separados por el espacio del sistema.
class SeccionFormulario extends StatelessWidget {
  final String titulo;
  final IconData? icono;
  final List<Widget> campos;

  const SeccionFormulario({
    super.key,
    required this.titulo,
    this.icono,
    required this.campos,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icono != null) ...[
              Icon(icono,
                  size: 18, color: AppColores.textoNaranja(context)),
              const SizedBox(width: AppEspacio.xs),
            ],
            Text(titulo,
                style: AppTexto.etiqueta
                    .copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: AppEspacio.md),
        for (var i = 0; i < campos.length; i++) ...[
          if (i > 0) const SizedBox(height: AppEspacio.md),
          campos[i],
        ],
      ],
    );
  }
}

/// Andamio de formulario de pantalla completa (patrón de
/// Inscribir): secciones desplazables y, fijos abajo, el
/// resumen de errores EN LÍNEA (nunca un SnackBar tras el
/// velo), un resumen opcional y la CTA — segura con el
/// teclado abierto porque el cuerpo sigue desplazable y la
/// barra sube con SafeArea.
class FormularioIron extends StatelessWidget {
  final List<Widget> secciones;
  final List<String> errores;
  final String textoCta;
  final VoidCallback? onCta;
  final bool cargandoCta;
  final IconData? iconoCta;
  final Widget? resumen;

  const FormularioIron({
    super.key,
    required this.secciones,
    this.errores = const [],
    required this.textoCta,
    required this.onCta,
    this.cargandoCta = false,
    this.iconoCta,
    this.resumen,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppEspacio.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < secciones.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppEspacio.lg),
                  secciones[i],
                ],
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.sm, AppEspacio.lg, AppEspacio.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final e in errores) ...[
                  ErrorInline(e),
                  const SizedBox(height: AppEspacio.xs),
                ],
                if (resumen != null) ...[
                  resumen!,
                  const SizedBox(height: AppEspacio.sm),
                ],
                BotonPrimario(
                  texto: textoCta,
                  icono: iconoCta,
                  cargando: cargandoCta,
                  onPressed: onCta,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Campo de texto con el estilo del sistema.
class CampoTexto extends StatelessWidget {
  final TextEditingController? controller;
  final String? etiqueta;
  final String? hint;
  final IconData? icono;
  final bool obscure;
  final TextInputType? teclado;
  final String? Function(String?)? validador;
  final void Function(String)? onChanged;
  final int? maxLineas;
  // 1.25 T19: error visible bajo el campo y nodo de foco
  // (validación en vivo que señala el campo culpable).
  final String? errorText;
  final FocusNode? focusNode;

  const CampoTexto({
    super.key,
    this.controller,
    this.etiqueta,
    this.hint,
    this.icono,
    this.obscure = false,
    this.teclado,
    this.validador,
    this.onChanged,
    this.maxLineas = 1,
    this.errorText,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      keyboardType: teclado,
      validator: validador,
      onChanged: onChanged,
      maxLines: maxLineas,
      style: AppTexto.cuerpo,
      decoration: InputDecoration(
        labelText: etiqueta,
        hintText: hint,
        errorText: errorText,
        prefixIcon:
            icono != null ? Icon(icono) : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadio.md),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadio.md),
          borderSide:
              BorderSide(color: AppColores.borde(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadio.md),
          borderSide: const BorderSide(
              color: AppColores.naranja, width: 2),
        ),
        filled: true,
        fillColor: AppColores.superficie(context),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.lg,
            vertical: AppEspacio.md),
      ),
    );
  }
}

/// v1.5.0 (Bloque G, decisión de Jc): aviso de que los dígitos del
/// carnet no forman una fecha AAMMDD real («122303» = mes 23: día y
/// mes invertidos al teclear). Es SOLO un aviso en el momento: no
/// bloquea el guardado ni exige longitud alguna. La condición la
/// decide `carnetFechaInvalida` (negocio.dart), única fuente.
/// Q5 (cola 1.20): aviso de que el carnet parece un teléfono
/// (mismo lenguaje visual que [AvisoFechaCarnet]; no bloquea).
class AvisoCarnetTelefono extends StatelessWidget {
  const AvisoCarnetTelefono({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 16, color: AppColores.alerta),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Esto parece un número de teléfono, no un '
              'carnet. Revísalo: del carnet solo hacen falta '
              'los 6 dígitos de la fecha de nacimiento. '
              'Puedes guardar igual.',
              style: AppTexto.metadato
                  .copyWith(color: AppColores.alertaOscuro),
            ),
          ),
        ],
      ),
    );
  }
}

class AvisoFechaCarnet extends StatelessWidget {
  const AvisoFechaCarnet({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 16, color: AppColores.alerta),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Esa fecha no existe, revísala: el día y el mes '
              'pueden estar invertidos. Puedes guardar igual.',
              style: AppTexto.metadato
                  .copyWith(color: AppColores.alertaOscuro),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Encabezado de sección (título + acción opcional "ver todo")
// ---------------------------------------------------------------------------

/// Franja de resumen de una línea del patrón de lista de
/// trabajo (1.30 D6, UI130-20): el total a la izquierda y
/// la frescura a la derecha, en registro de metadato —
/// sustituye a los héroes que repetían el total en grande.
/// Los conteos por estado viven en los chips de filtro,
/// no aquí.
class FranjaResumenLista extends StatelessWidget {
  final String principal;
  final String? secundario;

  const FranjaResumenLista(
      {super.key, required this.principal, this.secundario});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
          AppEspacio.sm, AppEspacio.lg, AppEspacio.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(principal,
                style: AppTexto.etiqueta
                    .copyWith(fontWeight: FontWeight.w700)),
          ),
          if (secundario != null)
            Flexible(
              child: Text(secundario!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
            ),
        ],
      ),
    );
  }
}

/// Variante del [EncabezadoSeccion] (1.30 D6, UI130-10):
/// un solo encabezado para toda la app; lo que cambia es
/// quién pone el acolchado horizontal y el registro
/// tipográfico.
enum VarianteEncabezado {
  /// Dentro de un contenedor que ya acolcha (ListView con
  /// padding): sin acolchado horizontal propio — el
  /// titular nace alineado con sus tarjetas.
  seccion,

  /// Vive fuera de un contenedor acolchado: trae su lg.
  pagina,

  /// El registro del Panel: mayúsculas (etiqueta w800 con
  /// tracking), metadato a la derecha y variante de aviso
  /// en naranja. Absorbe el `_tituloSeccion` privado que
  /// vivía en admin.dart.
  panel,
}

class EncabezadoSeccion extends StatelessWidget {
  final String titulo;
  final VarianteEncabezado variante;
  final String? accionTexto;
  final VoidCallback? onAccion;
  final IconData? accionIcono;
  final String? accionTooltip;

  /// Solo variante panel: metadato alineado a la derecha.
  final String? derecha;

  /// Solo variante panel: registro de aviso (icono de
  /// advertencia + título en naranja), el «NECESITA TU
  /// ATENCIÓN» del Panel.
  final bool aviso;

  const EncabezadoSeccion(
      {super.key,
      required this.titulo,
      this.variante = VarianteEncabezado.seccion,
      this.accionTexto,
      this.onAccion,
      this.accionIcono,
      this.accionTooltip,
      this.derecha,
      this.aviso = false});

  @override
  Widget build(BuildContext context) {
    // Ritmo único (UI130-10): 24 dp antes / 8 dp después
    // en las tres variantes. El acolchado horizontal lo
    // pone el contenedor, salvo la variante de página
    // (lg) y la de panel (xs, el aire histórico de admin).
    final horizontal = switch (variante) {
      VarianteEncabezado.seccion => 0.0,
      VarianteEncabezado.pagina => AppEspacio.lg,
      VarianteEncabezado.panel => AppEspacio.xs,
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
          horizontal, AppEspacio.xl, horizontal, AppEspacio.sm),
      child: variante == VarianteEncabezado.panel
          ? _filaPanel(context)
          : _filaSeccion(context),
    );
  }

  Widget _filaSeccion(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(titulo, style: AppTexto.subtitulo),
        ),
        if (accionTexto != null && onAccion != null)
          TextButton(
            onPressed: onAccion,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.sm),
              minimumSize: const Size(48, 44),
            ),
            child: Text(accionTexto!,
                style: AppTexto.etiqueta.copyWith(
                    color: AppColores.naranja)),
          ),
        if (accionIcono != null && onAccion != null)
          IconButton(
            tooltip: accionTooltip,
            iconSize: 20,
            padding: const EdgeInsets.all(AppEspacio.md),
            constraints: const BoxConstraints(
                minWidth: 44, minHeight: 44),
            color: Colors.grey,
            icon: Icon(accionIcono),
            onPressed: onAccion,
          ),
      ],
    );
  }

  Widget _filaPanel(BuildContext context) {
    return Row(
      children: [
        if (aviso) ...[
          const Icon(Icons.warning_amber_rounded,
              size: 15, color: AppColores.naranja),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            titulo,
            style: AppTexto.etiqueta.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
              color: aviso
                  ? AppColores.naranja
                  : AppColores.textoSecundario(context),
            ),
          ),
        ),
        if (derecha != null)
          Text(derecha!,
              style: AppTexto.metadato.copyWith(
                  color: AppColores.textoSecundario(context))),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Chip de estado (reemplaza chips armados a mano con fondos fijos)
// ---------------------------------------------------------------------------

/// Vocabulario semántico único (V6 1.20): un significado = un color,
/// en ambos brillos. Los llamadores ya no eligen el color a mano:
/// usan [ChipEstado.semantico] y el color lo decide el significado.
/// Regla V6: estado → chip; cantidad → [ContadorBadge], nunca chip.
enum SignificadoChip { exito, info, alerta, error, neutral, agotado }

/// Color de texto/borde del chip para un significado y un brillo.
/// En claro se usan las variantes oscuras (legibles sobre fondo
/// tintado); en oscuro, las variantes claras.
Color colorSignificadoChip(SignificadoChip s, bool oscuro) {
  switch (s) {
    case SignificadoChip.exito:
      return oscuro ? const Color(0xFF4ADE80) : const Color(0xFF166534);
    case SignificadoChip.info:
      return oscuro ? const Color(0xFF60A5FA) : AppColores.infoOscuro;
    case SignificadoChip.alerta:
      return oscuro ? const Color(0xFFFBBF24) : const Color(0xFF92400E);
    case SignificadoChip.error:
      return oscuro ? const Color(0xFFF87171) : AppColores.errorOscuro;
    case SignificadoChip.neutral:
      return oscuro
          ? AppColores.textoSecundarioOscuro
          : const Color(0xFF616161);
    case SignificadoChip.agotado:
      return oscuro ? const Color(0xFF9CA3AF) : const Color(0xFF4B5563);
  }
}

/// Chip de estado (V6, Argón 1.20): acepta color directo o significado.
/// Como constructor nombrado real (const), devuelve [ChipEstado] de
/// verdad: se puede tipar `List<ChipEstado>`, usar en `const` y buscar
/// por key con `tester.widget<ChipEstado>` sin el agujero que dejaba
/// el método estático con `_ChipSemantico` privado (eliminado).
class ChipEstado extends StatelessWidget {
  final String texto;
  final Color? color;
  final SignificadoChip? significado;
  final IconData? icono;
  const ChipEstado(
      {super.key,
      required this.texto,
      required Color this.color,
      this.icono})
      : significado = null;

  /// Chip por significado: el color lo decide [significado] según el
  /// brillo al construir. `icono` opcional; si no se pasa, sin icono.
  const ChipEstado.semantico({
    super.key,
    required this.texto,
    required SignificadoChip this.significado,
    this.icono,
  }) : color = null;

  @override
  Widget build(BuildContext context) {
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    final c = color ?? colorSignificadoChip(significado!, oscuro);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        // 1.30 D1 (UI130-09): geometría del vocabulario de
        // chips — circular (AppRadio.chip), no lg: a la
        // altura real del chip, 16 y circular se parecían
        // pero no coincidían en filas mixtas.
        borderRadius: BorderRadius.circular(AppRadio.chip),
        border: Border.all(
            color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icono != null) ...[
            Icon(icono, size: 16, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(texto,
                style: AppTexto.etiqueta
                    .copyWith(color: c),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// Significado de un [AvisoEstado] (1.29 OG-0, D-03).
enum TipoAviso { exito, aviso, error, info }

/// Aviso de estado sobre fondo SÓLIDO (1.29 OG-0, D-03):
/// para los mensajes que no pueden pasar desapercibidos
/// (error de sync, aviso importante, confirmación). Fondo
/// de la familia `*Fondo` de [AppColores] — invariante por
/// tema — con icono canónico y texto en Colors.white
/// literal (6,54–7,68:1 verificado por test): icono +
/// palabra siempre, ningún estado solo por color.
///
/// Iconos canónicos de estado, fijados en la fundación y
/// sin vuelta a discutir (tabla del estudio 1.29 §4.2):
/// aviso = warning_amber_rounded · error =
/// error_outline_rounded · info = info_rounded ·
/// éxito = check_circle_rounded.
class AvisoEstado extends StatelessWidget {
  final TipoAviso tipo;
  final String texto;
  final IconData? icono;

  /// 1.30 (Oleada D2, UI130-07): segunda línea opcional
  /// bajo el texto (el mensaje del error en el banner
  /// de sync), en metadato sobre el mismo fondo.
  final String? detalle;

  /// 1.30 (Oleada D2, UI130-07): acciones opcionales
  /// bajo el texto (Reintentar / Ver qué quedó / Ver
  /// detalle en el error de sync). El llamador les da el
  /// frente (sobre los fondos *Fondo, blanco).
  final List<Widget>? acciones;

  /// 1.30 (Oleada D2, UI130-07): contenido extra al
  /// final del aviso (el detalle desplegado del error).
  final Widget? pie;

  const AvisoEstado({
    super.key,
    required this.tipo,
    required this.texto,
    this.icono,
    this.detalle,
    this.acciones,
    this.pie,
  });

  Color get _fondo {
    switch (tipo) {
      case TipoAviso.exito:
        return AppColores.exitoFondo;
      case TipoAviso.aviso:
        return AppColores.avisoFondo;
      case TipoAviso.error:
        return AppColores.errorFondo;
      case TipoAviso.info:
        return AppColores.infoFondo;
    }
  }

  IconData get _iconoCanonico {
    switch (tipo) {
      case TipoAviso.exito:
        return Icons.check_circle_rounded;
      case TipoAviso.aviso:
        return Icons.warning_amber_rounded;
      case TipoAviso.error:
        return Icons.error_outline_rounded;
      case TipoAviso.info:
        return Icons.info_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.lg, vertical: AppEspacio.md),
      decoration: BoxDecoration(
        color: _fondo,
        borderRadius: BorderRadius.circular(AppRadio.lg),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icono ?? _iconoCanonico,
                  size: 20, color: Colors.white),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      texto,
                      style: AppTexto.cuerpo.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600),
                    ),
                    if (detalle != null && detalle!.isNotEmpty) ...[
                      const SizedBox(height: AppEspacio.xs),
                      Text(
                        detalle!,
                        style: AppTexto.metadato
                            .copyWith(color: Colors.white),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (acciones != null && acciones!.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.sm),
            Wrap(
              spacing: AppEspacio.sm,
              runSpacing: AppEspacio.xs,
              children: acciones!,
            ),
          ],
          if (pie != null) ...[
            const SizedBox(height: AppEspacio.sm),
            pie!,
          ],
        ],
      ),
    );
  }
}

/// 1.35 (UI-14): EL placeholder de la foto de suplemento
/// sin foto: un solo componente con el fondo del tema
/// para lista, detalle y reservas (antes había tres
/// copias a mano, una con un gris distinto del tema).
/// [alto] null = rellena el hueco que le dé el padre.
class PlaceholderSuplemento extends StatelessWidget {
  final double? alto;
  final double radio;
  final double tamanoIcono;

  const PlaceholderSuplemento({
    super.key,
    this.alto = 64,
    this.radio = AppRadio.md,
    this.tamanoIcono = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: alto,
      width: alto == null ? null : double.infinity,
      decoration: BoxDecoration(
        color: AppColores.fondo(context),
        borderRadius: BorderRadius.circular(radio),
      ),
      child: Icon(
        Icons.medication_rounded,
        size: tamanoIcono,
        color: AppColores.textoSecundario(context),
      ),
    );
  }
}

/// Badge numérico discreto (V6): solo para cantidades (contadores),
/// nunca para estados. Recorta a "99+" por encima de 99.
///
/// Fondo [AppColores.naranjaTexto] (Argón 1.20): blanco sobre el
/// naranja brillante daba 2.59:1 (falla AA); sobre naranjaTexto da
/// 4.57:1 o más. Geometría 20×20 (múltiplo de 4, retícula V2): con
/// etiqueta a 12 px el contenido mide 18.4 px y el mínimo 18 lo
/// dejaba ovalado.
class ContadorBadge extends StatelessWidget {
  final int numero;
  const ContadorBadge({super.key, required this.numero});

  @override
  Widget build(BuildContext context) {
    final texto = numero > 99 ? '99+' : '$numero';
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColores.naranjaTexto,
        borderRadius: BorderRadius.circular(AppRadio.circular),
      ),
      child: Center(
        child: Text(
          texto,
          style: AppTexto.etiqueta.copyWith(
            fontWeight: FontWeight.bold,
            color: AppColores.sobreNaranja,
          ),
        ),
      ),
    );
  }
}

/// Contador de URGENCIA (1.30 D1, UI130-02): el que avisa de
/// algo por hacer (pendientes en un segmento, la campana).
/// Componente ÚNICO sobre `errorFondo` — blanco da 6,54:1;
/// el par viejo (blanco sobre `error` brillante #EF4444) daba
/// 3,76 y queda prohibido para contadores. Mínimo 20×20, como
/// [ContadorBadge]. Con [conBorde], lleva el borde de
/// separación para cuando vive sobre la cabecera carbón.
/// Para cantidades neutras (sin urgencia) manda
/// [ContadorBadge], no este.
class ContadorUrgente extends StatelessWidget {
  final int numero;
  final bool conBorde;

  const ContadorUrgente({
    super.key,
    required this.numero,
    this.conBorde = false,
  });

  @override
  Widget build(BuildContext context) {
    final texto = numero > 99 ? '99+' : '$numero';
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColores.errorFondo,
        borderRadius: BorderRadius.circular(AppRadio.circular),
        border: conBorde
            ? Border.all(
                color: Colors.white.withValues(alpha: 0.55), width: 1)
            : null,
      ),
      child: Center(
        child: Text(
          texto,
          style: AppTexto.etiqueta.copyWith(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Tamaños del avatar de cliente (V19): una sola identidad visual
/// de la foto en todo el ecosistema (listas, fichas, reservas…).
/// [perfil] es la foto grande de la cabecera de la ficha (120 con
/// su marco de estado de 3 px, el que ya usaba la ficha).
enum TamanoAvatar { s, m, l, xl, perfil }

/// Avatar de cliente consistente (V19): foto circular con borde
/// sutil, o iniciales sobre naranja suave cuando no hay foto (o el
/// [iconoFallback] que pida la pantalla). Con [heroTag], la foto
/// vuela entre la lista y la ficha (V17). La foto llega ya resuelta
/// por la pantalla (archivo local); este componente no hace E/S.
/// El borde es fino y neutro por defecto; la ficha pasa su marco
/// de estado con [colorBorde] y [grosorBorde].
/// Decodificación acotada SIN deformar (reporte de campo
/// de Jc, 1.22): cuando a Image.file/Image.network se le
/// dan cacheWidth Y cacheHeight a la vez, Flutter decodifica
/// con ResizeImagePolicy.exact y ESTIRA el bitmap al
/// rectángulo destino ANTES de que BoxFit.cover recorte —
/// las fotos salían aplastadas/estiradas en miniaturas y en
/// la ficha.
///
/// La acotación es por UN SOLO eje (el ancho): el bitmap
/// conserva su aspecto exacto y, pasando ~2× el ancho de
/// la caja de destino, el eje libre queda siempre por
/// encima de lo que BoxFit.cover necesita recortar (vale
/// para retratos y paisajes hasta 2:1; el panel descartó
/// acotar por los dos ejes con policy fit porque el eje
/// corto quedaba por debajo de la caja y perdía nitidez).
/// [ancho] va en píxeles de dispositivo.
ImageProvider providerFotoAcotada(ImageProvider base,
        {required int ancho}) =>
    ResizeImage(base, width: ancho);

/// 1.22 Diseño Bloque 2 (T2, ajustes de Argón): el tag del
/// Hero de la foto de un cliente SIEMPRE lleva el origen
/// (`hero_<origen>_cliente_<id>`) para que dos superficies
/// con el mismo cliente no colisionen y el vuelo sepa de
/// dónde viene. La ficha usa el tag del origen que la abrió.
String tagHeroCliente(String origen, Object id) =>
    'hero_${origen}_cliente_$id';

/// T2: tag del Hero de la foto de un suplemento (lista →
/// detalle).
String tagHeroSuplemento(Object id) => 'hero_suplemento_$id';

/// Shuttle del Hero rectangular (fotos de suplemento): el
/// hijo destino se estira al rectángulo interpolado, con
/// las esquinas recortadas al radio del sistema.
///
/// Panel delta (Media): el hijo que se anima es SIEMPRE el
/// de la lista (imagen ya resuelta): en la ida es el
/// origen y en la vuelta es el destino. El hijo del
/// detalle es un FutureBuilder (rama FotoCache) y clonarlo
/// en el shuttle lo reinicia en espera — el vuelo animaba
/// el marcador en vez de la foto.
Widget shuttleHeroFoto(
    BuildContext context,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext) {
  final lista = flightDirection == HeroFlightDirection.push
      ? (fromHeroContext.widget as Hero).child
      : (toHeroContext.widget as Hero).child;
  return Material(
    color: Colors.transparent,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(AppRadio.lg),
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: lista,
        ),
      ),
    ),
  );
}

class AvatarCliente extends StatelessWidget {
  final String nombre;
  final File? foto;
  final TamanoAvatar tamano;
  final IconData? iconoFallback;
  final String? heroTag;
  final Color? colorBorde;
  final double grosorBorde;

  const AvatarCliente({
    super.key,
    required this.nombre,
    this.foto,
    this.tamano = TamanoAvatar.m,
    this.iconoFallback,
    this.heroTag,
    this.colorBorde,
    this.grosorBorde = 1,
  });

  double get _diametro => switch (tamano) {
        TamanoAvatar.s => 32,
        TamanoAvatar.m => 44,
        TamanoAvatar.l => 56,
        TamanoAvatar.xl => 160,
        TamanoAvatar.perfil => 120,
      };

  String get _iniciales {
    final partes =
        nombre.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (partes.isEmpty) return '?';
    var ini = partes.first[0].toUpperCase();
    if (partes.length > 1) ini += partes.last[0].toUpperCase();
    return ini;
  }

  TextStyle get _estiloIniciales => switch (tamano) {
        TamanoAvatar.s => AppTexto.etiqueta,
        TamanoAvatar.m => AppTexto.subtitulo,
        TamanoAvatar.l => AppTexto.tituloPagina,
        TamanoAvatar.xl => AppTexto.display,
        TamanoAvatar.perfil => AppTexto.display,
      };

  @override
  Widget build(BuildContext context) {
    final d = _diametro;
    // El interior respira dentro del borde (como el marco de la
    // ficha: borde + padding del mismo grosor).
    final di = d - 2 * grosorBorde;
    // T2 (Bloque 2): con Hero, AMBOS extremos decodifican
    // al mismo ancho fijo (720) para que el ImageProvider
    // sea el MISMO en la lista y en la ficha — si cada
    // extremo decodifica a su tamaño, el vuelo re-decodifica
    // y la foto parpadea. Sin Hero, 2x el tamaño mostrado
    // (D-02 con el margen anti-nitidez del panel delta).
    final cacheHero = heroTag != null
        ? 720
        : (2 * di * MediaQuery.devicePixelRatioOf(context)).round();
    final Widget interior = foto != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(di / 2),
            // D-02 (1.21): decodificar al tamaño mostrado × DPR,
            // no la foto entera (las listas pintan decenas de
            // avatares de 44-56 px con fotos de varios MB).
            child: Image(
                image: providerFotoAcotada(FileImage(foto!),
                    ancho: cacheHero),
                width: di,
                height: di,
                fit: BoxFit.cover),
          )
        : CircleAvatar(
            radius: di / 2,
            backgroundColor:
                AppColores.naranja.withValues(alpha: 0.15),
            child: iconoFallback != null
                ? Icon(iconoFallback,
                    size: di / 2, color: AppColores.naranja)
                : Text(_iniciales,
                    style: _estiloIniciales.copyWith(
                        color: AppColores.naranja,
                        fontWeight: FontWeight.bold)),
          );
    final Widget conBorde = Container(
      width: d,
      height: d,
      padding: EdgeInsets.all(grosorBorde),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
            color: colorBorde ?? AppColores.borde(context),
            width: grosorBorde),
      ),
      child: interior,
    );
    if (heroTag == null) return conBorde;
    // T2 (Bloque 2, ajustes de Argón): placeholder mientras
    // el destino no está listo y shuttle circular que
    // estira el avatar destino al rectángulo interpolado
    // (sin esto, el avatar salta de tamaño a mitad de vuelo).
    return Hero(
      tag: heroTag!,
      placeholderBuilder: (ctx, size, child) =>
          Opacity(opacity: 0.35, child: child),
      flightShuttleBuilder:
          (ctx, animation, direction, fromCtx, toCtx) {
        final destino = (toCtx.widget as Hero).child;
        return Material(
          color: Colors.transparent,
          child: ClipOval(
            child: SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: destino,
              ),
            ),
          ),
        );
      },
      child: conBorde,
    );
  }
}

/// Avatar que resuelve SOLO la miniatura del cliente
/// desde la caché de fotos (1.30 D6, UI130-28): el mismo
/// patrón de la fila de Buscar — primero la caché; si hay
/// referencia sin caché, la descarga corre en segundo
/// plano y la miniatura aparece cuando aterriza. Sin
/// referencia, sin caché o con la descarga en curso se
/// pintan las iniciales de [AvatarCliente]: quien lo usa
/// nunca espera red para pintarse (offline-first).
class AvatarClienteConFoto extends StatefulWidget {
  final String nombre;
  final String? fotoStorage;

  /// 1.31 (campo 2026-11-09): la foto recién tomada en este
  /// teléfono (clientes.foto_local), si el llamador la tiene:
  /// es la fase disco 1 del resolvedor, como en la ficha y en
  /// la fila de Buscar.
  final String? fotoLocal;
  final TamanoAvatar tamano;

  const AvatarClienteConFoto({
    super.key,
    required this.nombre,
    required this.fotoStorage,
    this.fotoLocal,
    this.tamano = TamanoAvatar.m,
  });

  @override
  State<AvatarClienteConFoto> createState() =>
      _AvatarClienteConFotoState();
}

class _AvatarClienteConFotoState extends State<AvatarClienteConFoto> {
  File? _foto;
  String? _resueltoPara;

  // 1.31: escucha de aterrizajes de la cola de precarga,
  // como la fila de Buscar.
  StreamSubscription<String>? _subFoto;

  @override
  void initState() {
    super.initState();
    _subFoto = FotoCache.instance.aterrizajes.listen((ruta) {
      if (ruta == _resueltoPara && _foto == null) _resolverFoto();
    });
    _resolverFoto();
  }

  @override
  void dispose() {
    _subFoto?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(AvatarClienteConFoto old) {
    super.didUpdateWidget(old);
    // 1.34 Campo 2 (P-4): como la fila de Buscar, solo se
    // re-resuelve si cambió la ruta; los aterrizajes de la
    // cola avisan por su stream cuando la foto llega a la
    // caché (la miniatura aparece al volver de la ficha
    // sin re-chequear disco en cada rebuild).
    if (old.fotoStorage != widget.fotoStorage ||
        old.fotoLocal != widget.fotoLocal) {
      _resolverFoto();
    }
  }

  /// Dos fases (1.31, campo 2026-11-09), como la fila de
  /// Buscar: el widget solo espera DISCO (foto_local →
  /// caché); la red va por la cola de precarga y la
  /// miniatura entra por la escucha de aterrizajes.
  Future<void> _resolverFoto() async {
    final sp = widget.fotoStorage;
    // Si ESTA foto ya está resuelta y mostrada, la
    // re-comprobación por reconstrucción no aporta nada.
    if (sp == _resueltoPara && _foto != null) return;
    if (sp != _resueltoPara && _foto != null && mounted) {
      setState(() => _foto = null);
    }
    _resueltoPara = sp;
    final local = widget.fotoLocal;
    if (local != null && local.isNotEmpty) {
      final f = File(local);
      if (await f.exists()) {
        if (!mounted || _resueltoPara != sp) return;
        setState(() => _foto = f);
        return;
      }
    }
    if (sp == null || sp.isEmpty) return;
    final enCache = await FotoCache.instance.enCache(sp);
    if (!mounted || _resueltoPara != sp) return;
    if (enCache != null) {
      setState(() => _foto = enCache);
      return;
    }
    FotoCache.instance.precargar([sp]);
  }

  @override
  Widget build(BuildContext context) {
    return AvatarCliente(
      nombre: widget.nombre,
      foto: _foto,
      tamano: widget.tamano,
    );
  }
}

/// Monto con animación funcional breve (V14): cuando el valor
/// cambia con el widget ya montado (una recarga, un pull-to-refresh),
/// la cifra cuenta hacia el nuevo valor en 300 ms, sin rebotes. En
/// el primer montaje muestra el valor directamente (sin animación),
/// así ningún lector de pantalla ni test ve una cifra a medias.
/// El formato lo decide quien llama ([formato]); las cifras son
/// tabulares para que el ancho no baile durante la animación (M7).
class MontoAnimado extends StatelessWidget {
  final double valor;
  final String Function(double) formato;
  final TextStyle? style;

  const MontoAnimado({
    super.key,
    required this.valor,
    required this.formato,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final base = (style ?? AppTexto.metrica).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // 1.30 D1 (UI130-32): la duración sale del token
    // (AppMovimiento.larga = los 300 ms de siempre) y con
    // «reducir movimiento» la cifra nace puesta (duración
    // cero), como manda la fundación de movimiento.
    final reducir = MediaQuery.of(context).disableAnimations;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: valor),
      duration: reducir ? Duration.zero : AppMovimiento.larga,
      curve: AppMovimiento.curvaSuave,
      builder: (_, v, __) => Text(formato(v), style: base),
    );
  }
}

/// Primitiva de aparición en cascada (1.30 D1, UI130-32):
/// envuelve la lista o rejilla de una pantalla y sus
/// [ItemCascada] aparecen escalonados SOLO al abrir la
/// ruta. La bandera de ciclo de vida vive en el State de
/// este ámbito (ajuste BAJA-02 de Argón): pasados la
/// ventana de entrada, la cascada se cierra y las celdas
/// que el scroll recicla después nacen puestas, sin
/// re-animar jamás — animar en cada build de celda
/// produce tirones y marea en listas largas. Con
/// «reducir movimiento» del teléfono, nada anima.
/// Las oleadas D2–D6 la adoptan pantalla a pantalla;
/// D6 cierra el barrido.
class EntradaCascada extends StatefulWidget {
  final Widget child;

  const EntradaCascada({super.key, required this.child});

  @override
  State<EntradaCascada> createState() => _EntradaCascadaState();
}

class _EntradaCascadaState extends State<EntradaCascada> {
  bool _ventanaAbierta = true;
  Timer? _cierre;

  @override
  void initState() {
    super.initState();
    // La ventana cubre el escalonado entero del último
    // ítem admitido (tope de ItemCascada) + su duración.
    _cierre = Timer(
      AppMovimiento.larga +
          const Duration(
              milliseconds: ItemCascada.pasoMs * ItemCascada.topeIndice),
      () {
        if (mounted) setState(() => _ventanaAbierta = false);
      },
    );
  }

  @override
  void dispose() {
    _cierre?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AmbitoCascada(
      ventanaAbierta: _ventanaAbierta,
      child: widget.child,
    );
  }
}

class _AmbitoCascada extends InheritedWidget {
  final bool ventanaAbierta;

  const _AmbitoCascada({
    required this.ventanaAbierta,
    required super.child,
  });

  static _AmbitoCascada? de(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AmbitoCascada>();

  @override
  bool updateShouldNotify(_AmbitoCascada oldWidget) =>
      ventanaAbierta != oldWidget.ventanaAbierta;
}

/// Un ítem de la cascada de [EntradaCascada]: entra con
/// fundido + subida corta, escalonado por [indice]
/// (acotado a [topeIndice] para que una lista larga no
/// desfile). Sin ámbito, con la ventana ya cerrada o con
/// «reducir movimiento», nace puesto, sin animar.
class ItemCascada extends StatefulWidget {
  final int indice;
  final Widget child;

  const ItemCascada({
    super.key,
    required this.indice,
    required this.child,
  });

  /// Milisegundos de escalón entre ítems consecutivos.
  static const pasoMs = 45;

  /// Último índice que aún se escalona; el resto entra
  /// con el último.
  static const topeIndice = 8;

  @override
  State<ItemCascada> createState() => _ItemCascadaState();
}

class _ItemCascadaState extends State<ItemCascada>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Timer? _arranque;
  bool _decidido = false;
  bool _animar = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decidido) return;
    _decidido = true;
    final ambito = _AmbitoCascada.de(context);
    if (ambito == null ||
        !ambito.ventanaAbierta ||
        MediaQuery.of(context).disableAnimations) {
      return;
    }
    _animar = true;
    _ctrl = AnimationController(
        vsync: this, duration: AppMovimiento.media);
    final paso = (widget.indice < ItemCascada.topeIndice
            ? widget.indice
            : ItemCascada.topeIndice) *
        ItemCascada.pasoMs;
    if (paso == 0) {
      _ctrl!.forward();
    } else {
      _arranque = Timer(Duration(milliseconds: paso), () {
        if (mounted) _ctrl?.forward();
      });
    }
  }

  @override
  void dispose() {
    _arranque?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animar || _ctrl == null) return widget.child;
    final curva =
        CurvedAnimation(parent: _ctrl!, curve: AppMovimiento.curva);
    return FadeTransition(
      opacity: curva,
      child: SlideTransition(
        position: Tween<Offset>(
                begin: const Offset(0, 0.06), end: Offset.zero)
            .animate(curva),
        child: widget.child,
      ),
    );
  }
}

/// 1.29 (Oleada 2, D-11): color categórico de un método
/// de cobro — efectivo en dorado, transferencia en azul
/// (los tokens metodoEfectivo/metodoTransferencia de la
/// Oleada 1). Cualquier otro valor (mixto, cortesía…)
/// cae al naranja de marca: no es un método de dos
/// colores y no debe disfrazarse de ninguno.
Color colorDeMetodo(String? metodo) {
  final m = (metodo ?? '').toLowerCase();
  if (m.contains('transfer')) return AppColores.metodoTransferencia;
  if (m.contains('efectivo')) return AppColores.metodoEfectivo;
  return AppColores.naranja;
}

/// 1.29 (Oleada 2, D-11): el punto de color del método,
/// para pintar JUNTO a la palabra que la fila ya escribe
/// («Mensualidad — transferencia»): la lista de dinero se
/// escanea de un vistazo sin leer cada fila, y el método
/// nunca va SOLO por color (la palabra sigue ahí).
/// (1.30 D4 · UI130-12/13) Fila de libro mayor de la casa:
/// la fila de las pantallas de dinero — icono tintado
/// opcional, concepto (+ detalle) a la izquierda y monto
/// alineado a la derecha. Nace de la fila que la vista del
/// entrenador de Pendiente ya usaba (_filaDesglose, C2 de la
/// 1.19) y la comparten Pendiente (ambos roles) y Nómina,
/// para que el dinero se lea igual en todas partes.
/// [metodo] pinta el punto categórico junto al concepto
/// (D-11 de la 1.29).
class FilaLibro extends StatelessWidget {
  final IconData? icono;
  final Color? colorIcono;
  final String concepto;
  final String? detalle;
  final String monto;
  final Color? colorMonto;
  final String? metodo;
  final TextStyle? estiloConcepto;
  final TextStyle? estiloMonto;

  /// 1.30 (Oleada D6, UI130-32): monto animado opcional
  /// — si llegan los dos, la cifra cuenta hasta su valor
  /// con MontoAnimado (mismo formato final y mismo
  /// estilo); el [monto] en texto sigue siendo el
  /// contrato del resto de filas.
  final double? valorAnimado;
  final String Function(double)? formatoAnimado;

  const FilaLibro({
    super.key,
    this.icono,
    this.colorIcono,
    required this.concepto,
    this.detalle,
    required this.monto,
    this.colorMonto,
    this.metodo,
    this.estiloConcepto,
    this.estiloMonto,
    this.valorAnimado,
    this.formatoAnimado,
  });

  @override
  Widget build(BuildContext context) {
    final estiloMontoFinal = estiloMonto ??
        AppTexto.cuerpo.copyWith(
          fontWeight: FontWeight.bold,
          color: colorMonto,
        );
    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icono != null) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor:
                  (colorIcono ?? AppColores.naranja)
                      .withValues(alpha: 0.15),
              child: Icon(icono,
                  size: 16,
                  color: colorIcono ?? AppColores.naranja),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (metodo == null)
                  Text(concepto,
                      style: estiloConcepto ?? AppTexto.cuerpo)
                else
                  Row(
                    children: [
                      PuntoMetodo(metodo: metodo!),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(concepto,
                            style: estiloConcepto ??
                                AppTexto.cuerpo),
                      ),
                    ],
                  ),
                if (detalle != null)
                  Text(detalle!, style: AppTexto.secundario),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (valorAnimado != null && formatoAnimado != null)
            MontoAnimado(
                valor: valorAnimado!,
                formato: formatoAnimado!,
                style: estiloMontoFinal)
          else
            Text(monto, style: estiloMontoFinal),
        ],
      ),
    );
  }
}

class PuntoMetodo extends StatelessWidget {
  final String? metodo;
  const PuntoMetodo({super.key, required this.metodo});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: colorDeMetodo(metodo),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// (1.30 D5 · UI130-19) Tarjeta de decisión compartida: la
/// anatomía única de las tarjetas que piden una decisión —
/// la incidencia operativa (lista de incidencias) y la
/// incidencia de sincronización comparten forma SIN
/// fusionar sus flujos (cada pantalla conserva permisos,
/// acciones y diálogos). Cabecera: icono del tipo, título y
/// chip de estado. Contexto: antigüedad/SLA, responsable o
/// dispositivo, con la prioridad como punto + palabra. El
/// motivo va en lenguaje llano sobre una superficie de
/// aviso; el resumen, en metadato; y el pie lleva las
/// acciones que construye quien llama (una primaria y una
/// destructiva). La selección se lee por el fondo
/// (primaryContainer), como en el resto de listas.
class TarjetaDecision extends StatelessWidget {
  final IconData icono;
  final Color? colorIcono;
  final String titulo;
  final String? subtitulo;
  final ChipEstado chipEstado;
  final String? contexto;
  final IconData? iconoContexto;
  final Color? colorContexto;
  final bool contextoDestacado;
  final String? contextoSecundario;
  final IconData? iconoContextoSecundario;
  final String? prioridadTexto;
  final Color? colorPrioridad;
  final String? motivo;
  final String? resumen;
  final Widget? pie;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool seleccionada;

  const TarjetaDecision({
    super.key,
    required this.icono,
    this.colorIcono,
    required this.titulo,
    this.subtitulo,
    required this.chipEstado,
    this.contexto,
    this.iconoContexto,
    this.colorContexto,
    this.contextoDestacado = false,
    this.contextoSecundario,
    this.iconoContextoSecundario,
    this.prioridadTexto,
    this.colorPrioridad,
    this.motivo,
    this.resumen,
    this.pie,
    this.onTap,
    this.onLongPress,
    this.seleccionada = false,
  });

  @override
  Widget build(BuildContext context) {
    final secundario = AppColores.textoSecundario(context);
    final contenido = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: (colorIcono ?? AppColores.naranja)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadio.sm),
              ),
              child: Icon(icono,
                  color: colorIcono ?? AppColores.naranja, size: 20),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTexto.cuerpo
                          .copyWith(fontWeight: FontWeight.w600)),
                  if (subtitulo != null)
                    Text(subtitulo!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTexto.metadato
                            .copyWith(color: secundario)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            chipEstado,
          ],
        ),
        if (contexto != null || prioridadTexto != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (contexto != null) ...[
                if (iconoContexto != null) ...[
                  Icon(iconoContexto,
                      size: 14, color: colorContexto ?? secundario),
                  const SizedBox(width: 4),
                ],
                Text(contexto!,
                    style: AppTexto.metadato.copyWith(
                      color: colorContexto ?? secundario,
                      fontWeight:
                          contextoDestacado ? FontWeight.bold : null,
                    )),
              ],
              if (contextoSecundario != null) ...[
                const SizedBox(width: 8),
                if (iconoContextoSecundario != null) ...[
                  Icon(iconoContextoSecundario,
                      size: 14, color: secundario),
                  const SizedBox(width: 2),
                ],
                Flexible(
                  child: Text(contextoSecundario!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTexto.metadato
                          .copyWith(color: secundario)),
                ),
              ],
              const Spacer(),
              if (prioridadTexto != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: colorPrioridad ?? secundario,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(prioridadTexto!, style: AppTexto.metadato),
              ],
            ],
          ),
        ],
        if (motivo != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppEspacio.sm),
            decoration: BoxDecoration(
              color: colorSignificadoChip(
                      SignificadoChip.alerta,
                      Theme.of(context).brightness == Brightness.dark)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadio.sm),
            ),
            child: Text(motivo!, style: AppTexto.secundario),
          ),
        ],
        if (resumen != null) ...[
          const SizedBox(height: AppEspacio.xs),
          Text(resumen!,
              style: AppTexto.metadato.copyWith(color: secundario)),
        ],
        if (pie != null) ...[
          const SizedBox(height: 8),
          pie!,
        ],
      ],
    );
    final tarjeta = Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      color: seleccionada
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      onTap: onTap,
      child: contenido,
    );
    if (onLongPress == null) return tarjeta;
    // Tarjeta no expone onLongPress (su InkWell es de toque):
    // el gesto largo se escucha fuera, sin tocar el kit.
    return GestureDetector(
      onLongPress: onLongPress,
      child: tarjeta,
    );
  }
}

/// 1.25 T65: la línea de corte punteada del ticket,
/// compartida por el Preview y el Recibo del cobro (el
/// mismo trazo que el comprobante ya usaba).
class LineaPunteadaTicket extends StatelessWidget {
  const LineaPunteadaTicket({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1.2,
      width: double.infinity,
      child: CustomPaint(
        painter: _PunteadaTicketPainter(AppColores.borde(context)),
      ),
    );
  }
}

class _PunteadaTicketPainter extends CustomPainter {
  final Color color;
  const _PunteadaTicketPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    const dash = 6.0;
    const gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      final fin = (x + dash).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, 0), Offset(fin, 0), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_PunteadaTicketPainter old) =>
      old.color != color;
}

/// 1.23 B6 (Argón, feedback): origen de un aviso. Los avisos
/// AUTOMÁTICOS (sync de fondo, procesos sin el usuario delante)
/// respetan la ventana de protección de una barra crítica; los
/// de una acción directa del usuario pisan siempre.
enum OrigenAviso { usuario, automatico }

/// Ventana que protege una barra crítica/accionable (P2) frente
/// a avisos automáticos P1: si la crítica lleva menos que esto
/// en pantalla, el aviso automático se DESCARTA (Argón B6 §1).
const Duration kProteccionAvisoCritico = Duration(seconds: 3);

/// Duración VISUAL de la barra Deshacer (Argón B6 §3). La
/// ventana de negocio en BD sigue siendo de 15 s: si el usuario
/// toca a los 7,9 s, la holgura cubre el procesamiento.
const Duration kDuracionVisualDeshacer = Duration(seconds: 8);

/// Duración por defecto de un aviso según su significado
/// (Argón B6 §3): éxito/info/neutral 3 s; alerta/agotado 4 s;
/// error 6 s (el error siempre lleva texto, nunca solo color,
/// V8, y dura más para que se alcance a leer).
Duration duracionAviso(SignificadoChip significado) =>
    switch (significado) {
      SignificadoChip.exito ||
      SignificadoChip.info ||
      SignificadoChip.neutral =>
        const Duration(seconds: 3),
      SignificadoChip.alerta ||
      SignificadoChip.agotado =>
        const Duration(seconds: 4),
      SignificadoChip.error => const Duration(seconds: 6),
    };

/// ¿El aviso es crítico/accionable (P2 en la política de
/// Argón B6 §1)? Todo error y toda barra con acción (p. ej.
/// Deshacer) lo es; el resto es P1 normal.
bool avisoEsCritico(SignificadoChip significado,
        {bool conAccion = false}) =>
    conAccion || significado == SignificadoChip.error;

/// Decisión pura de la política de prioridades (Argón B6 §1),
/// testeable sin temporizadores: ¿se descarta el aviso
/// entrante? Solo se descarta un P1 AUTOMÁTICO cuando una P2
/// lleva menos de [kProteccionAvisoCritico] en pantalla. Una
/// acción directa del usuario pisa siempre, y un P2 entrante
/// también (reemplaza a lo que haya).
bool avisoEntranteSeDescarta({
  required bool activaEsCritica,
  required Duration antiguedadActiva,
  required bool entranteEsCritica,
  required OrigenAviso origenEntrante,
}) {
  if (origenEntrante == OrigenAviso.usuario) return false;
  if (entranteEsCritica) return false;
  if (!activaEsCritica) return false;
  return antiguedadActiva < kProteccionAvisoCritico;
}

/// Barra viva según el helper, para la política de
/// prioridades. [dueno] es el messenger que la mostró: la
/// protección solo vale dentro del mismo messenger. `desde`
/// es un instante para MEDIR antigüedad (una diferencia),
/// no una fecha de negocio.
class _AvisoActivo {
  final ScaffoldMessengerState dueno;
  final bool critica;
  final DateTime desde;
  const _AvisoActivo({
    required this.dueno,
    required this.critica,
    required this.desde,
  });
}

_AvisoActivo? _avisoActivo;

/// Reloj con el que se MIDE la antigüedad de la barra activa
/// (solo diferencias de instantes; no es fecha de negocio).
/// Sustituible en tests: el reloj falso de testWidgets mueve
/// los temporizadores pero NO mueve DateTime.now(), así que
/// sin esta costura la ventana de 3 s no se puede envejecer
/// de forma determinista.
DateTime Function() _relojAvisos = DateTime.now;

@visibleForTesting
void fijarRelojAvisosParaTest(DateTime Function()? reloj) {
  _relojAvisos = reloj ?? DateTime.now;
}

/// Aviso breve unificado (V7): SnackBar con icono y color según el
/// significado (mismo vocabulario que [SignificadoChip], V6). El
/// fondo, la forma flotante y la acción los da el tema; aquí solo se
/// fija el significado visual.
///
/// 1.23 B6 (Argón): duraciones por clase ([duracionAviso]),
/// política de prioridades P1/P2 ([avisoEntranteSeDescarta]) y
/// [messengerState] opcional (H-04) para llamarlo con un
/// messenger capturado ANTES de un await, sin tocar el contexto
/// después. Quien ya solo tenga el messenger (feedback
/// post-await que no debe depender de `mounted`, H-01) usa
/// [mostrarSnackEnMessenger].
///
/// Nota de framework (verificado en el SDK en uso): una
/// SnackBar CON acción nace con `persist: true` y no vence
/// sola. Por eso el helper fija `persist: false` en TODAS sus
/// barras: las duraciones por clase mandan también con acción
/// (y la ventana visual del Deshacer es real). Ninguna
/// pantalla debe construir un SnackBar directo para avisar:
/// perdería el registro de prioridades P1/P2 (panel Bloque 4);
/// quien necesite el controlador usa
/// [mostrarSnackControladoEnMessenger].
///
/// La migración de los SnackBar existentes a este helper va pantalla
/// a pantalla con los grupos de diseño (V9–V35); el código nuevo usa
/// siempre este helper.
void mostrarSnack(
  BuildContext context,
  String mensaje, {
  SignificadoChip significado = SignificadoChip.neutral,
  String? accion,
  VoidCallback? alAccion,
  Duration? duracion,
  OrigenAviso origen = OrigenAviso.usuario,
  ScaffoldMessengerState? messengerState,
}) {
  _mostrarSnackEn(
    messengerState ?? ScaffoldMessenger.of(context),
    mensaje,
    significado: significado,
    accion: accion,
    alAccion: alAccion,
    duracion: duracion,
    origen: origen,
  );
}

/// Como [mostrarSnack] pero sobre un messenger ya capturado:
/// no necesita BuildContext. Es la vía del feedback post-await
/// (H-01/H-04 de Argón B6): el resultado de una acción se
/// anuncia aunque la pantalla que la lanzó ya no esté montada.
void mostrarSnackEnMessenger(
  ScaffoldMessengerState messenger,
  String mensaje, {
  SignificadoChip significado = SignificadoChip.neutral,
  String? accion,
  VoidCallback? alAccion,
  Duration? duracion,
  OrigenAviso origen = OrigenAviso.usuario,
}) {
  _mostrarSnackEn(
    messenger,
    mensaje,
    significado: significado,
    accion: accion,
    alAccion: alAccion,
    duracion: duracion,
    origen: origen,
  );
}

/// Como [mostrarSnackEnMessenger] pero devuelve el controlador
/// de la barra (null si la política de prioridades la descartó)
/// para quien necesita cerrarla por su cuenta — el Deshacer de
/// Servicios al salir de la pantalla (panel Bloque 4: TODA barra
/// con acción pasa por el mecanismo central, para que quede
/// registrada como P2 y protegida; ninguna pantalla construye
/// su SnackBar directo).
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
    mostrarSnackControladoEnMessenger(
  ScaffoldMessengerState messenger,
  String mensaje, {
  SignificadoChip significado = SignificadoChip.neutral,
  String? accion,
  VoidCallback? alAccion,
  Duration? duracion,
  OrigenAviso origen = OrigenAviso.usuario,
}) {
  return _mostrarSnackEn(
    messenger,
    mensaje,
    significado: significado,
    accion: accion,
    alAccion: alAccion,
    duracion: duracion,
    origen: origen,
  );
}

ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
    _mostrarSnackEn(
  ScaffoldMessengerState messenger,
  String mensaje, {
  required SignificadoChip significado,
  String? accion,
  VoidCallback? alAccion,
  Duration? duracion,
  required OrigenAviso origen,
}) {
  final (icono, color) = switch (significado) {
    SignificadoChip.exito => (Icons.check_circle_rounded, AppColores.exito),
    SignificadoChip.info => (Icons.info_rounded, AppColores.info),
    SignificadoChip.alerta => (Icons.warning_amber_rounded, AppColores.alerta),
    SignificadoChip.error => (Icons.error_outline_rounded, AppColores.error),
    SignificadoChip.agotado => (Icons.warning_amber_rounded, AppColores.alerta),
    SignificadoChip.neutral => (Icons.info_rounded, Colors.white),
  };
  final conAccion = accion != null && alAccion != null;
  final critica = avisoEsCritico(significado, conAccion: conAccion);
  // Política de prioridades (Argón B6 §1): una P2 joven no la
  // pisa un aviso automático P1; ese aviso se descarta.
  final activo = _avisoActivo;
  if (activo != null &&
      identical(activo.dueno, messenger) &&
      avisoEntranteSeDescarta(
        activaEsCritica: activo.critica,
        antiguedadActiva: _relojAvisos().difference(activo.desde),
        entranteEsCritica: critica,
        origenEntrante: origen,
      )) {
    return null;
  }
  // 1.23 (gramática de avisos, reporte de campo de Jc): la
  // barra nueva REEMPLAZA a todo lo anterior — clearSnackBars
  // descarta también la COLA; con hideCurrentSnackBar las
  // barras viejas esperaban su turno y «se quedaban volando»
  // sobre otras pantallas minutos después. Ningún aviso se
  // encola jamás (Argón B6 §1).
  messenger.clearSnackBars();
  final registro = _AvisoActivo(
      dueno: messenger, critica: critica, desde: _relojAvisos());
  _avisoActivo = registro;
  final ctrl = messenger.showSnackBar(
    SnackBar(
      // En este SDK, un SnackBar CON acción nace persistente
      // (persist = action != null) y la duración sería nominal:
      // las duraciones por clase de B6 (y la ventana visual de
      // 8 s del Deshacer) mandan, así que ninguna barra del
      // sistema es persistente.
      persist: false,
      duration: duracion ?? duracionAviso(significado),
      content: Row(
        children: [
          Icon(icono, color: color, size: 20),
          const SizedBox(width: AppEspacio.sm),
          Expanded(child: Text(mensaje)),
        ],
      ),
      action: conAccion
          ? SnackBarAction(label: accion, onPressed: alAccion)
          : null,
    ),
  );
  // Al cerrarse la barra (vence, acción o descarte), su
  // protección muere con ella: nada queda «protegido» en vacío.
  ctrl.closed.then((_) {
    if (identical(_avisoActivo, registro)) _avisoActivo = null;
  });
  return ctrl;
}

// ---------------------------------------------------------------------------
// B6: errores clasificados C1–C5 (Argón §4)
// ---------------------------------------------------------------------------

/// Clase de error B6 (Argón §4). La clase decide el
/// significado, la duración y la ÚNICA acción permitida:
/// Reintentar solo tiene sentido donde repetir es idempotente.
enum ClaseError {
  /// C1 — Lectura idempotente (red caída, se muestran datos
  /// locales): Reintentar es seguro.
  lectura,

  /// C2 — Escritura local SQLite (constraint/disco/corrupción):
  /// reintentar a ciegas no arregla nada; sin acción.
  escrituraLocal,

  /// C3 — Escritura al servidor con confirmación incierta
  /// (timeout): PROHIBIDO Reintentar (podría duplicar la
  /// escritura, que no es idempotente); la salida es Verificar
  /// con una lectura.
  confirmacionIncierta,

  /// C4 — Validación de negocio o permisos: la causa exacta va
  /// en el mensaje; sin acción.
  validacion,

  /// C5 — Rechazo PERMANENTE del servidor al sincronizar (el
  /// fallo de red del push NO avisa: para eso está el indicador
  /// de sync): se resuelve en la cola; acción «Ver cola».
  rechazoSync,
}

/// Configuración pura de una clase de error B6 (testeable sin
/// widgets): significado visual, duración en pantalla y
/// etiqueta de la acción permitida (null = sin acción).
///
/// EXCEPCIÓN APROBADA a la matriz general 3/4/6 por
/// significado ([duracionAviso]): las duraciones de los
/// errores CLASIFICADOS son las de la tabla por clase de
/// Argón B6 §4 (C1 5 s, C3 6 s, C4 5 s), que es la norma
/// específica para estas superficies y manda sobre la matriz
/// general — un C3 (confirmación incierta) necesita que el
/// usuario alcance a leer que NO se sabe si el servidor
/// aplicó el cambio antes de decidir Verificar. La matriz
/// 3/4/6 sigue rigiendo todos los avisos no clasificados
/// (panel Bloque 4, ajuste 2, opción «excepción documentada»).
({
  SignificadoChip significado,
  Duration duracion,
  String? etiquetaAccion,
}) configErrorClasificado(ClaseError clase) => switch (clase) {
      ClaseError.lectura => (
          significado: SignificadoChip.alerta,
          duracion: const Duration(seconds: 5),
          etiquetaAccion: 'Reintentar',
        ),
      ClaseError.escrituraLocal => (
          significado: SignificadoChip.error,
          duracion: const Duration(seconds: 6),
          etiquetaAccion: null,
        ),
      ClaseError.confirmacionIncierta => (
          significado: SignificadoChip.alerta,
          duracion: const Duration(seconds: 6),
          // PROHIBIDO 'Reintentar' en C3 (Argón §4).
          etiquetaAccion: 'Verificar',
        ),
      ClaseError.validacion => (
          significado: SignificadoChip.alerta,
          duracion: const Duration(seconds: 5),
          etiquetaAccion: null,
        ),
      ClaseError.rechazoSync => (
          significado: SignificadoChip.error,
          duracion: const Duration(seconds: 6),
          etiquetaAccion: 'Ver cola',
        ),
    };

/// Texto canónico de las clases cuyo mensaje no depende del
/// contexto (Argón §4). Null = el llamador pone el suyo.
String? textoCanonicoErrorClasificado(ClaseError clase) =>
    switch (clase) {
      ClaseError.lectura =>
        'Sin conexión al servidor. Mostrando datos locales.',
      ClaseError.confirmacionIncierta =>
        'La conexión tardó demasiado. No sabemos aún si el '
            'servidor aplicó el cambio.',
      _ => null,
    };

/// Muestra un error ya clasificado (B6) como aviso: el
/// significado, la duración y la acción salen de la CLASE,
/// nunca del llamador — así ningún C3 puede ofrecer Reintentar
/// por accidente. [alAccion] ejecuta la acción de la clase
/// (Reintentar en C1, Verificar en C3, Ver cola en C5); si es
/// null, o la clase no admite acción, la barra va sin botón.
void mostrarErrorClasificado(
  BuildContext context,
  ClaseError clase,
  String mensaje, {
  VoidCallback? alAccion,
  OrigenAviso origen = OrigenAviso.usuario,
  ScaffoldMessengerState? messengerState,
}) {
  final cfg = configErrorClasificado(clase);
  mostrarSnack(
    context,
    mensaje,
    significado: cfg.significado,
    duracion: cfg.duracion,
    accion: cfg.etiquetaAccion,
    alAccion: alAccion,
    origen: origen,
    messengerState: messengerState,
  );
}

/// v1.3.6 (Argón, diseño): badge squircle tinted del sistema de iconos.
/// 38×38 px, borderRadius 11. En oscuro: fondo del tinte al 14% + borde
/// sutil de 1px al 22%; en claro: fondo al 12% sin borde. El icono usa la
/// variante _rounded a 21 px por defecto.
class IconoModuloBadge extends StatelessWidget {
  final IconData icono;
  final Color tinte;
  final Color iconoOscuro;
  final Color iconoClaro;
  final double tamanoIcono;

  const IconoModuloBadge({
    super.key,
    required this.icono,
    required this.tinte,
    required this.iconoOscuro,
    required this.iconoClaro,
    this.tamanoIcono = 21,
  });

  /// Atajo naranja (módulos y acciones).
  factory IconoModuloBadge.naranja(IconData icono,
      {double tamanoIcono = 21}) {
    return IconoModuloBadge(
      icono: icono,
      tinte: AppColores.naranja,
      // 1.30 D1 (COMP-A): literales a token de valor exacto.
      iconoOscuro: AppColores.naranjaTextoOscuro,
      iconoClaro: AppColores.bannerEnviandoB,
      tamanoIcono: tamanoIcono,
    );
  }

  /// Atajo verde esmeralda (bandeja de WhatsApp).
  factory IconoModuloBadge.verde(IconData icono,
      {double tamanoIcono = 21}) {
    return IconoModuloBadge(
      icono: icono,
      // 1.30 D1 (COMP-A): literales a token de valor exacto.
      tinte: AppColores.exito,
      iconoOscuro: AppColores.exitoIconoOscuro,
      iconoClaro: AppColores.exitoIconoClaro,
      tamanoIcono: tamanoIcono,
    );
  }

  @override
  Widget build(BuildContext context) {
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: tinte.withValues(alpha: oscuro ? 0.14 : 0.12),
        borderRadius: BorderRadius.circular(AppRadio.md),
        border: oscuro
            ? Border.all(color: tinte.withValues(alpha: 0.22), width: 1)
            : null,
      ),
      child: Icon(icono,
          size: tamanoIcono, color: oscuro ? iconoOscuro : iconoClaro),
    );
  }
}

/// v1.4.1: mini gráfico de barras diarias para series agregadas
/// (actividad de 30 días del puente, adopción de 90 días de la
/// RPC). [datos]: lista de {"fecha": "YYYY-MM-DD", "total": n} en
/// orden ascendente. Sin dependencias nuevas: barras con layout.
class GraficoBarrasDiarias extends StatelessWidget {
  final List<Map<String, dynamic>> datos;
  final double altura;

  /// Etiquetas extremas opcionales (p. ej. un histograma por hora
  /// usa "0h"/"23h" en vez de fechas).
  final String? etiquetaPrimera;
  final String? etiquetaUltima;

  const GraficoBarrasDiarias({
    super.key,
    required this.datos,
    this.altura = 84,
    this.etiquetaPrimera,
    this.etiquetaUltima,
  });

  static String _ddmm(String fecha) {
    if (fecha.length >= 10) return fecha.substring(5, 10);
    return fecha;
  }

  @override
  Widget build(BuildContext context) {
    if (datos.isEmpty) return const SizedBox.shrink();
    var maximo = 0;
    for (final d in datos) {
      final v = (d['total'] as num?)?.toInt() ?? 0;
      if (v > maximo) maximo = v;
    }
    // Corrección del panel (T4): con TODO a cero no se dibujan
    // barras fantasma ni un "máx 1/día" falso: se dice sin datos.
    if (maximo <= 0) {
      return SizedBox(
        height: altura,
        child: Center(
          child: Text('Sin actividad en el período',
              style: AppTexto.minuscula
                  .copyWith(color: Colors.grey)),
        ),
      );
    }
    final reducir = MediaQuery.of(context).disableAnimations;
    // 1.35 (UX-08): lenguaje propio — las barras van en
    // degradado grafito tranquilo y la ÚLTIMA (hoy, en
    // las series por fecha) va «encendida»: degradado
    // naranja pleno con su cifra encima. En los
    // histogramas con etiquetas propias (por hora) no
    // hay «hoy» que encender: todas tranquilas.
    final hayHoy = etiquetaPrimera == null && datos.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1.35 (UI-03): las barras crecen al primer pintado
        // (AppMovimiento.larga / curvaSuave, como las cifras
        // de MontoAnimado); con «reducir movimiento» nacen
        // puestas. Solo anima la entrada: el tween es 0→1 y
        // los datos llegan ya calculados.
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: reducir ? Duration.zero : AppMovimiento.larga,
          curve: AppMovimiento.curvaSuave,
          builder: (context, t, _) => SizedBox(
            height: altura,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < datos.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          // La cifra de hoy: las demás
                          // celdas reservan su mismo alto
                          // (invisible) para que la
                          // proporción de las barras no
                          // se tuerza.
                          if (hayHoy) ...[
                            Opacity(
                              opacity:
                                  i == datos.length - 1 ? 1 : 0,
                              child: Text(
                                '${(datos[i]['total'] as num?)?.toInt() ?? 0}',
                                style: AppTexto.minuscula.copyWith(
                                    color: AppColores.naranja,
                                    fontWeight: FontWeight.w800),
                              ),
                            ),
                            const SizedBox(height: 2),
                          ],
                          Expanded(
                            child: FractionallySizedBox(
                              alignment: Alignment.bottomCenter,
                              // Cero = sin barra (panel T4).
                              heightFactor:
                                  ((datos[i]['total'] as num?)?.toInt() ??
                                              0) <=
                                          0
                                      ? 0.0
                                      : ((((datos[i]['total'] as num)
                                                  .toDouble()) /
                                              maximo)
                                          .clamp(0.03, 1.0) *
                                      t),
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: hayHoy &&
                                            i == datos.length - 1
                                        ? const [
                                            AppColores.naranjaOscuro,
                                            AppColores.naranja,
                                          ]
                                        : const [
                                            AppColores.grafitoTactico,
                                            Color(0xFF3A4552),
                                          ],
                                  ),
                                  borderRadius:
                                      const BorderRadius.vertical(
                                          top: Radius.circular(2)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(etiquetaPrimera ?? _ddmm('${datos.first['fecha'] ?? ''}'),
                style: AppTexto.minuscula.copyWith(color: Colors.grey)),
            Flexible(
              child: Text('máx $maximo/día',
                  overflow: TextOverflow.ellipsis,
                  style: AppTexto.minuscula.copyWith(color: Colors.grey)),
            ),
            Text(etiquetaUltima ?? _ddmm('${datos.last['fecha'] ?? ''}'),
                style: AppTexto.minuscula.copyWith(color: Colors.grey)),
          ],
        ),
      ],
    );
  }
}

/// H2 (estéticas 1.19): urgencia del badge de Vencimientos.
/// Rojo solo si hay atrasados de más de 30 días; ámbar en el
/// resto (vencen hoy, por vencer o atrasados leves). Devuelve el
/// color del badge y la pestaña inicial de ListasScreen con el
/// desglose (0 Hoy, 2 Atrasados -30d, 3 Atrasados +30d).
///
/// 1.32 (Compuertas, fila X-1): el oráculo vive aquí, en la
/// librería compartida, y no en home.dart — Dashboard lo
/// consume para que su cifra «vencidos» abra la MISMA pestaña
/// que promete (antes abría siempre la de −30 días y los de
/// +30 días, contados en la cifra, quedaban fuera de la vista:
/// era la D-3 del barrido de la 1.31, viva hasta esta
/// compuerta). Un solo oráculo: dos copias de esta regla fue
/// exactamente la clase del defecto.
({Color color, int tabInicial}) urgenciaVencimientos({
  required int atrasLeve,
  required int atras30,
}) {
  if (atras30 > 0) return (color: AppColores.error, tabInicial: 3);
  if (atrasLeve > 0) return (color: AppColores.alerta, tabInicial: 2);
  return (color: AppColores.alerta, tabInicial: 0);
}
