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

/// Botón primario: naranja sólido con gradiente y sombra sutil.
class BotonPrimario extends StatelessWidget {
  final String texto;
  final VoidCallback? onPressed;
  final IconData? icono;
  final bool expandido;

  const BotonPrimario({
    super.key,
    required this.texto,
    this.onPressed,
    this.icono,
    this.expandido = true,
  });

  @override
  Widget build(BuildContext context) {
    final boton = Container(
      decoration: BoxDecoration(
        gradient: AppColores.gradienteNaranja,
        borderRadius: BorderRadius.circular(AppRadio.lg),
        boxShadow: AppSombra.botonPrimario,
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.lg, horizontal: AppEspacio.xl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadio.lg),
          ),
          textStyle: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icono != null) ...[
              Icon(icono, size: 20),
              const SizedBox(width: AppEspacio.sm),
            ],
            Text(texto),
          ],
        ),
      ),
    );
    if (!expandido) return boton;
    return SizedBox(width: double.infinity, child: boton);
  }
}

/// Botón secundario: contorno naranja, fondo transparente.
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
          foregroundColor: AppColores.naranja,
          side: const BorderSide(
              color: AppColores.naranja, width: 1.5),
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.lg, horizontal: AppEspacio.xl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadio.lg),
          ),
          textStyle: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icono != null) ...[
              Icon(icono, size: 20),
              const SizedBox(width: AppEspacio.sm),
            ],
            Text(texto),
          ],
        ),
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
        boxShadow: AppSombra.tarjeta(context),
        border: Border.all(color: AppColores.borde(context)),
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
  const EncabezadoSeccion(
      {super.key,
      required this.titulo,
      this.accionTexto,
      this.onAccion});

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
