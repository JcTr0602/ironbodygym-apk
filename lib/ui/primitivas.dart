/// 1.32 «Mostrador Táctico» — PRIMITIVAS TRANSVERSALES del
/// mostrador (Oleada 2, Fase 0): el pad numérico empotrado,
/// la confirmación por deslizamiento y el motor de lenguaje
/// háptico, como componentes COMPARTIDOS reutilizables.
///
/// Nacieron al servicio de la hoja «Liquidar Arqueo»
/// (Oleada 1) y la Fase 0 de la Oleada 2 los promueve a
/// primitivas de toda la app SIN cambiar su comportamiento
/// probado: las fases siguientes (cobros, gastos, teléfonos,
/// adelantos y cierres críticos) los consumen desde aquí;
/// la hoja de Liquidar los sigue usando vía re-export.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'diseno.dart';

/// El LENGUAJE HÁPTICO del mostrador: un solo punto de
/// verdad para que toda la app responda al tacto con el
/// mismo vocabulario. Las pantallas y primitivas llaman a
/// estas intenciones, nunca a HapticFeedback directamente:
///
/// - [seleccion]: el clic sutil de elegir (chips, listas).
/// - [ligero]: toque leve de tecla (pad numérico, pasos).
/// - [confirmacion]: el golpe medio de cerrar un gesto
///   deliberado (el deslizamiento que confirma dinero).
/// - [exito]: el golpe firme de «operación terminada».
/// - [error]: la vibración de sistema de «eso no vale».
abstract final class Tacto {
  static void seleccion() => HapticFeedback.selectionClick();
  static void ligero() => HapticFeedback.lightImpact();
  static void confirmacion() => HapticFeedback.mediumImpact();
  static void exito() => HapticFeedback.heavyImpact();
  static void error() => HapticFeedback.vibrate();
}

/// Pad numérico empotrado del mostrador: edita un importe
/// como texto (dígitos y un punto decimal) sin abrir el
/// teclado del sistema. Reutilizable por los demás cobros
/// en la Oleada 2.
class PadNumerico extends StatelessWidget {
  final String valor;
  final void Function(String nuevo) onCambia;

  const PadNumerico({super.key, required this.valor, required this.onCambia});

  void _tecla(String t) {
    Tacto.ligero();
    var v = valor;
    if (t == '⌫') {
      v = v.isEmpty ? v : v.substring(0, v.length - 1);
    } else if (t == 'C') {
      v = '';
    } else if (t == '.') {
      if (!v.contains('.')) v = v.isEmpty ? '0.' : '$v.';
    } else {
      // Tope sano de mostrador: 9 enteros y 2 decimales.
      final partes = v.split('.');
      if (partes.length == 2 && partes[1].length >= 2) return;
      if (partes[0].length >= 9 && !v.contains('.')) return;
      v = '$v$t';
    }
    onCambia(v);
  }

  @override
  Widget build(BuildContext context) {
    Widget tecla(String t, {bool ancha = false}) {
      return Expanded(
        flex: ancha ? 2 : 1,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadio.sm),
            child: InkWell(
              key: ValueKey('pad-$t'),
              borderRadius: BorderRadius.circular(AppRadio.sm),
              onTap: () => _tecla(t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: Text(t,
                      style: AppTexto.conTabulares(AppTexto.subtitulo)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [tecla('1'), tecla('2'), tecla('3')]),
        Row(children: [tecla('4'), tecla('5'), tecla('6')]),
        Row(children: [tecla('7'), tecla('8'), tecla('9')]),
        Row(children: [tecla('C'), tecla('0'), tecla('.'), tecla('⌫')]),
      ],
    );
  }
}

/// Confirmación por deslizamiento para dinero crítico: hay
/// que arrastrar el pulgar hasta el final del carril; si se
/// suelta antes, vuelve solo. Un toque NO confirma nada.
class DeslizarConfirmar extends StatefulWidget {
  final String texto;
  final bool habilitado;
  final VoidCallback onConfirmar;

  const DeslizarConfirmar({
    super.key,
    required this.texto,
    required this.habilitado,
    required this.onConfirmar,
  });

  @override
  State<DeslizarConfirmar> createState() => _DeslizarConfirmarState();
}

class _DeslizarConfirmarState extends State<DeslizarConfirmar> {
  double _progreso = 0; // 0..1
  bool _confirmado = false;

  @override
  Widget build(BuildContext context) {
    const alto = 56.0;
    return LayoutBuilder(
      builder: (context, cons) {
        final ancho = cons.maxWidth;
        final recorrido = (ancho - alto).clamp(1.0, double.infinity);
        return Container(
          key: const ValueKey('deslizar-carril'),
          height: alto,
          decoration: BoxDecoration(
            color: widget.habilitado
                ? AppColores.naranja.withValues(alpha: 0.16)
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(alto / 2),
            border: Border.all(color: AppColores.naranja),
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  _confirmado ? 'Liquidando…' : widget.texto,
                  style: AppTexto.etiqueta.copyWith(
                    fontWeight: FontWeight.w700,
                    color: widget.habilitado
                        ? null
                        : AppColores.textoSecundario(context),
                  ),
                ),
              ),
              Positioned(
                left: _progreso * recorrido,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  key: const ValueKey('deslizar-pulgar'),
                  onHorizontalDragUpdate: widget.habilitado && !_confirmado
                      ? (d) => setState(() {
                            _progreso =
                                (_progreso + d.delta.dx / recorrido)
                                    .clamp(0.0, 1.0);
                          })
                      : null,
                  onHorizontalDragEnd: widget.habilitado && !_confirmado
                      ? (_) {
                          if (_progreso >= 0.92) {
                            setState(() {
                              _progreso = 1;
                              _confirmado = true;
                            });
                            Tacto.confirmacion();
                            widget.onConfirmar();
                          } else {
                            setState(() => _progreso = 0);
                          }
                        }
                      : null,
                  child: Container(
                    width: alto,
                    decoration: const BoxDecoration(
                      color: AppColores.naranja,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.chevron_right_rounded,
                        color: AppColores.sobreMarca, size: 30),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

