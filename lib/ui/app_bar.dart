// lib/ui/app_bar.dart
// B10 (1.23): AppBar compartida de Gestión.
//
// appBarIron es la ÚNICA forma de construir las AppBar «planas»
// de la app (título de texto + acciones opcionales). Unifica el
// punto de construcción para que título/acciones/refresco sean
// coherentes entre pantallas y un cambio futuro de cabecera se
// haga en un solo sitio.
//
// SIN CAMBIO VISUAL BUSCADO: el helper no fija NINGUNA propiedad
// visual. El aspecto dominante de las AppBar planas nunca fue
// propio de cada pantalla: sale entero del AppBarTheme del tema
// en lib/ui/diseno.dart — backgroundColor carbón
// (AppColores.carbon / carbonProfundo en oscuro), foregroundColor
// blanco, elevation 2, scrolledUnderElevation 3, shadowColor
// negro al 35 %, centerTitle false y titleTextStyle
// AppTexto.titulo en blanco. Las ~170 AppBar planas que había
// repartidas por lib/ui eran simplemente `AppBar(title:
// Text(...), actions: [...])` apoyadas en ese tema; esto es eso
// mismo, envuelto.
//
// Qué NO toca:
// - IronAppBar (lib/ui/componentes.dart): widget con título
//   Widget (no texto) y bottom; sigue para cabeceras a medida.
// - SliverAppBar y las AppBar con bottom (tabs/buscadores),
//   colores propios, leading propio o título que no sea texto
//   simple: quedan como están (migración progresiva, B10).
import 'package:flutter/material.dart';

/// AppBar plana del sistema: [titulo] como texto simple y, si
/// hace falta, [acciones] (p. ej. el IconButton de refresco),
/// [leading] propio o [bottom] (pestañas/buscador).
///
/// [centrarTitulo] es nullable A PROPÓSITO (panel Bloque 5,
/// ajuste 1): sin argumento, la AppBar NO fija centerTitle y
/// manda el AppBarTheme (hoy false), exactamente como las
/// AppBar migradas se comportaban antes del helper. Solo una
/// pantalla que lo pida explícitamente pasa true/false.
AppBar appBarIron(
  BuildContext context,
  String titulo, {
  List<Widget>? acciones,
  Widget? leading,
  PreferredSizeWidget? bottom,
  bool? centrarTitulo,
}) {
  return AppBar(
    title: Text(titulo),
    actions: acciones,
    leading: leading,
    bottom: bottom,
    centerTitle: centrarTitulo,
  );
}
