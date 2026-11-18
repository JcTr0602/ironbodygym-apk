/// (1.30 D3, UI130-15) Hoja de acción de la casa: la ÚNICA
/// superficie de hoja inferior de Gestión 1.30. El tema ya
/// le da fondo y radio superior ([AppTema] bottomSheetTheme);
/// esta clase aporta el esqueleto fijo: asa, cabecera con
/// icono + título + cerrar, cuerpo desplazable y pie fijo
/// que sube con el teclado.
///
/// Regla de uso de la casa: tarea corta o decisión con
/// 1–3 campos → hoja; confirmación destructiva breve →
/// DialogoApp; editor complejo → pantalla completa.
library;

import 'package:flutter/material.dart';

import 'diseno.dart';

/// Esqueleto visual de una hoja: ver [showHojaIron] para
/// abrir una simple, o componer esta clase como raíz de una
/// hoja con estado propio (p. ej. HojaLiquidar).
class HojaAccion extends StatelessWidget {
  final String titulo;
  final IconData? icono;
  final Widget cuerpo;

  /// Pie fijo bajo el cuerpo (botones de acción). Si es
  /// null, la hoja no lleva franja de acciones.
  final Widget? pie;

  /// Al cerrar con la X; por defecto cierra la hoja con el
  /// Navigator de ESTE contexto (el de la hoja).
  final VoidCallback? onCerrar;

  const HojaAccion({
    super.key,
    required this.titulo,
    this.icono,
    required this.cuerpo,
    this.pie,
    this.onCerrar,
  });

  @override
  Widget build(BuildContext context) {
    // 1.36 H-B1 (136-403): el teclado empuja la hoja
    // ENTERA siempre — antes solo subía el pie y una hoja
    // sin pie quedaba tapada por el teclado.
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppEspacio.sm),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                // 1.36 (136-282): el asa se resuelve por brillo
                // (antes bordeClaro fijo: invisible en oscuro).
                color: AppColores.borde(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.md, AppEspacio.sm, AppEspacio.xs),
            child: Row(
              children: [
                if (icono != null) ...[
                  Icon(icono,
                      color: AppColores.textoNaranja(context)),
                  const SizedBox(width: AppEspacio.sm),
                ],
                Expanded(
                  child:
                      Text(titulo, style: AppTexto.subtitulo),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Cerrar',
                  onPressed: onCerrar ??
                      () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              // 1.36 H-B1 (136-406): arrastrar esconde el
              // teclado, como en el resto de la casa.
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.xs, AppEspacio.lg, AppEspacio.md),
              child: cuerpo,
            ),
          ),
          if (pie != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg,
                  AppEspacio.sm,
                  AppEspacio.lg,
                  AppEspacio.md),
              child: pie!,
            ),
        ],
      ),
      ),
    );
  }
}

/// Abre una [HojaAccion] simple. Los botones del [pie] que
/// cierren la hoja deben envolverse en un Builder para usar
/// el contexto de la HOJA (con el de la pantalla se cerraría
/// la ruta equivocada).
Future<T?> showHojaIron<T>(
  BuildContext context, {
  required String titulo,
  IconData? icono,
  required Widget cuerpo,
  Widget? pie,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    // 1.36 H-B1 (136-403): la hoja respeta el área segura.
    useSafeArea: true,
    builder: (ctx) => HojaAccion(
      titulo: titulo,
      icono: icono,
      cuerpo: cuerpo,
      pie: pie,
    ),
  );
}
