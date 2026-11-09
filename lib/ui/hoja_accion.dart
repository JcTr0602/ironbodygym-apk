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
    return ConstrainedBox(
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
                color: AppColores.bordeClaro,
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
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.xs, AppEspacio.lg, AppEspacio.md),
              child: cuerpo,
            ),
          ),
          if (pie != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  AppEspacio.lg,
                  AppEspacio.sm,
                  AppEspacio.lg,
                  AppEspacio.md +
                      MediaQuery.of(context).viewInsets.bottom),
              child: pie!,
            ),
        ],
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
    builder: (ctx) => HojaAccion(
      titulo: titulo,
      icono: icono,
      cuerpo: cuerpo,
      pie: pie,
    ),
  );
}
