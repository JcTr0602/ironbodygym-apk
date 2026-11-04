/// Componentes reutilizables v1.1 — Iron Body Gym.
///
/// Construidos sobre los tokens de [diseno.dart]. Toda pantalla nueva
/// o rediseñada debe usar estos componentes en vez de armar
/// sus propios botones/tarjetas/diálogos.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'diseno.dart';

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
    final boton = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radio,
        gradient: activo ? AppColores.gradienteNaranja : null,
        boxShadow: activo ? AppSombra.botonPrimario : null,
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

/// Tarjeta «Acciones» de la ficha: agrupa como filas lo que antes
/// eran botones sueltos al final (Progreso y Nutrición,
/// Renovación rápida solo si está vencido, Congelar/Descongelar
/// y A papelera en rojo). Widget presentacional sin dependencias
/// (flags + callbacks): la ficha conserva las condiciones y los
/// destinos; aquí solo se pinta y se hacen widget tests.
class TarjetaAccionesCliente extends StatelessWidget {
  final bool vencido;
  final bool congelado;
  final VoidCallback onProgreso;
  final VoidCallback onRenovar;
  final VoidCallback onCongelar;
  final VoidCallback onPapelera;

  const TarjetaAccionesCliente({
    super.key,
    required this.vencido,
    required this.congelado,
    required this.onProgreso,
    required this.onRenovar,
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
          _fila(
            icono: Icons.show_chart_rounded,
            color: AppColores.info,
            texto: 'Progreso y Nutrición',
            onTap: onProgreso,
            chevron: true,
          ),
          if (vencido)
            _fila(
              icono: Icons.refresh_rounded,
              color: AppColores.naranja,
              texto: 'Renovación rápida (1 mes)',
              onTap: onRenovar,
            ),
          _fila(
            icono: congelado ? Icons.wb_sunny_rounded : Icons.ac_unit_rounded,
            color: AppColores.naranja,
            texto: congelado ? 'Descongelar' : 'Congelar',
            onTap: onCongelar,
          ),
          const Divider(height: 1),
          _fila(
            icono: Icons.delete_outline_rounded,
            color: AppColores.error,
            texto: 'A papelera',
            onTap: onPapelera,
            peligro: true,
          ),
        ],
      ),
    );
  }
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
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
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
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
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
    final card = Container(
      decoration: BoxDecoration(
        color: color ?? AppColores.superficie(context),
        borderRadius: BorderRadius.circular(AppRadio.lg),
        border: Border.all(color: AppColores.borde(context)),
        boxShadow: AppSombra.tarjeta(context),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadio.lg),
      onTap: onTap,
      child: card,
    );
  }
}

// ---------------------------------------------------------------------------
// Badge de estado (membresía)
// ---------------------------------------------------------------------------

/// Estado de membresía para badges.
enum EstadoMembresia { alDia, porVencer, vencido }

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
    switch (estado) {
      case EstadoMembresia.alDia:
        fondo = AppColores.exito.withValues(alpha: 0.15);
        frente = AppColores.exitoOscuro;
        icono = Icons.check_circle_rounded;
        break;
      case EstadoMembresia.porVencer:
        fondo = AppColores.alerta.withValues(alpha: 0.15);
        frente = AppColores.alertaOscuro;
        icono = Icons.schedule_rounded;
        break;
      case EstadoMembresia.vencido:
        fondo = AppColores.error.withValues(alpha: 0.15);
        frente = AppColores.errorOscuro;
        icono = Icons.warning_rounded;
        break;
    }
    // En modo oscuro aclarar el texto del badge.
    final oscuro =
        Theme.of(context).brightness == Brightness.dark;
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
          Icon(icono, size: 16, color: oscuro ? _aclarar(frente) : frente),
          const SizedBox(width: 4),
          Text(texto,
              style: AppTexto.etiqueta.copyWith(
                  color: oscuro ? _aclarar(frente) : frente)),
        ],
      ),
    );
  }

  Color _aclarar(Color c) => Color.lerp(c, Colors.white, 0.35) ?? c;

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
              foregroundColor: Colors.white,
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
        padding: const EdgeInsets.symmetric(vertical: 8),
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
        iconoTitulo: Icons.warning_rounded,
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
                padding: const EdgeInsets.only(left: 32, bottom: 4),
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

  const EstadoVacio({
    super.key,
    required this.icono,
    required this.titulo,
    this.subtitulo,
    this.textoAccion,
    this.onAccion,
  });

  @override
  Widget build(BuildContext context) {
    final secundario = AppColores.textoSecundario(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color:
                    AppColores.textoSecundario(context).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icono,
                  size: 36, color: AppColores.textoSecundario(context)),
            ),
            const SizedBox(height: AppEspacio.lg),
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
              const SizedBox(height: AppEspacio.lg),
              BotonSecundario(
                  texto: textoAccion!, onPressed: onAccion),
            ],
          ],
        ),
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
        const Icon(Icons.error_rounded,
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
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: teclado,
      validator: validador,
      onChanged: onChanged,
      maxLines: maxLineas,
      style: AppTexto.cuerpo,
      decoration: InputDecoration(
        labelText: etiqueta,
        hintText: hint,
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
      padding: const EdgeInsets.only(top: 8),
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
      padding: const EdgeInsets.only(top: 8),
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

class EncabezadoSeccion extends StatelessWidget {
  final String titulo;
  final String? accionTexto;
  final VoidCallback? onAccion;
  final IconData? accionIcono;
  final String? accionTooltip;
  const EncabezadoSeccion(
      {super.key,
      required this.titulo,
      this.accionTexto,
      this.onAccion,
      this.accionIcono,
      this.accionTooltip});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.sm),
      child: Row(
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
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(
                  minWidth: 44, minHeight: 44),
              color: Colors.grey,
              icon: Icon(accionIcono),
              onPressed: onAccion,
            ),
        ],
      ),
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
          horizontal: AppEspacio.sm, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadio.lg),
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
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: valor),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (_, v, __) => Text(formato(v), style: base),
    );
  }
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
    SignificadoChip.error => (Icons.error_rounded, AppColores.error),
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
      iconoOscuro: const Color(0xFFFB923C),
      iconoClaro: const Color(0xFFEA580C),
      tamanoIcono: tamanoIcono,
    );
  }

  /// Atajo verde esmeralda (bandeja de WhatsApp).
  factory IconoModuloBadge.verde(IconData icono,
      {double tamanoIcono = 21}) {
    return IconoModuloBadge(
      icono: icono,
      tinte: const Color(0xFF22C55E),
      iconoOscuro: const Color(0xFF4ADE80),
      iconoClaro: const Color(0xFF16A34A),
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
        borderRadius: BorderRadius.circular(12),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: altura,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final d in datos)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: FractionallySizedBox(
                      // Cero = sin barra (panel T4).
                      heightFactor:
                          ((d['total'] as num?)?.toInt() ?? 0) <= 0
                              ? 0.0
                              : (((d['total'] as num).toDouble()) / maximo)
                                  .clamp(0.03, 1.0),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: AppColores.naranja,
                          borderRadius: BorderRadius.vertical(
                              top: Radius.circular(2)),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
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
