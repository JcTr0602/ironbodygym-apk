/// Componentes reutilizables v1.1 — Iron Body Gym.
///
/// Construidos sobre los tokens de [diseno.dart]. Toda pantalla nueva
/// o rediseñada debe usar estos componentes en vez de armar
/// sus propios botones/tarjetas/diálogos.
library;

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
    this.icono = Icons.delete_outline,
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
        icono = Icons.check_circle;
        break;
      case EstadoMembresia.porVencer:
        fondo = AppColores.alerta.withValues(alpha: 0.15);
        frente = AppColores.alertaOscuro;
        icono = Icons.schedule;
        break;
      case EstadoMembresia.vencido:
        fondo = AppColores.error.withValues(alpha: 0.15);
        frente = AppColores.errorOscuro;
        icono = Icons.warning;
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
          Icon(icono, size: 14, color: oscuro ? _aclarar(frente) : frente),
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
            Icon(iconoTitulo, color: AppColores.naranja),
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
    IconData icono = Icons.help_outline,
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
                color: AppColores.naranja.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icono,
                  size: 36, color: AppColores.naranja),
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
class EstadoError extends StatelessWidget {
  final String titulo;
  final String? detalle;
  final VoidCallback? onReintentar;

  const EstadoError({
    super.key,
    this.titulo = 'No se pudo cargar',
    this.detalle,
    this.onReintentar,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: AppColores.error),
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
            if (onReintentar != null) ...[
              const SizedBox(height: AppEspacio.lg),
              BotonSecundario(
                  texto: 'Reintentar',
                  icono: Icons.refresh,
                  onPressed: onReintentar),
            ],
          ],
        ),
      ),
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
                minimumSize: Size.zero,
                tapTargetSize:
                    MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(accionTexto!,
                  style: AppTexto.etiqueta.copyWith(
                      color: AppColores.naranja)),
            ),
          if (accionIcono != null && onAccion != null)
            IconButton(
              tooltip: accionTooltip,
              iconSize: 20,
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

class ChipEstado extends StatelessWidget {
  final String texto;
  final Color color;
  final IconData? icono;
  const ChipEstado(
      {super.key,
      required this.texto,
      required this.color,
      this.icono});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.sm, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadio.lg),
        border: Border.all(
            color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icono != null) ...[
            Icon(icono, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(texto,
                style: AppTexto.etiqueta
                    .copyWith(color: color),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
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
        borderRadius: BorderRadius.circular(11),
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
        child: const Center(
          child: Text('Sin actividad en el período',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
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
                style: const TextStyle(
                    fontSize: 10, color: Colors.grey)),
            Flexible(
              child: Text('máx $maximo/día',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10, color: Colors.grey)),
            ),
            Text(etiquetaUltima ?? _ddmm('${datos.last['fecha'] ?? ''}'),
                style: const TextStyle(
                    fontSize: 10, color: Colors.grey)),
          ],
        ),
      ],
    );
  }
}
