/// 1.26.1: hoja de «Cobrar parcial» — el dueño escribe
/// cuánto recogió del entrenador (ver pendiente.dart,
/// _abrirCobrarParcial, y lib/cobro_parcial.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../cobro_parcial.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'hoja_accion.dart';
import 'primitivas.dart';

/// 1.26.1: hoja de «Cobrar parcial» — el dueño escribe
/// cuánto recogió del entrenador. StatefulWidget
/// propio: el TextEditingController se libera en
/// dispose (regla de la casa para diálogos con campo).
/// Devuelve el monto tecleado (Navigator.pop(monto)) o
/// null si se cancela; la reverificación contra la foto
/// fresca y el encolado viven en _abrirCobrarParcial.
class HojaCobrarParcial extends StatefulWidget {
  final String nombre;
  final double total;
  final double arrastre;

  const HojaCobrarParcial({
    super.key,
    required this.nombre,
    required this.total,
    required this.arrastre,
  });

  @override
  State<HojaCobrarParcial> createState() =>
      HojaCobrarParcialState();
}

class HojaCobrarParcialState extends State<HojaCobrarParcial> {
  final _ctrl = TextEditingController();
  double? _monto;
  // 1.36 H-B2 (136-622): confirmación visual breve al fijar
  // un atajo, con UN temporizador reiniciable.
  bool _recienFijado = false;
  Timer? _timerFijado;

  @override
  void dispose() {
    _timerFijado?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  // 1.36 H-B2 (136-616): la validez se compara contra el
  // total redondeado a 2 decimales, SIN el margen superior
  // de 0.01 que dejaba cobrar de más (función pura en
  // cobro_parcial.dart, probada por contrato).
  bool get _valido => montoCobroParcialValido(_monto, widget.total);

  void _fijar(double v) {
    _ctrl.text = v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(2);
    setState(() {
      _monto = v;
      _recienFijado = true;
    });
    _timerFijado?.cancel();
    _timerFijado = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _recienFijado = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // SL-X1 (G10-3): la hoja se compone sobre la jerarquía
    // de la casa (HojaAccion, la raíz de showHojaIron y de
    // las hojas con estado propio como HojaLiquidar): asa,
    // cabecera con título y cerrar, cuerpo desplazable y pie
    // fijo los da el esqueleto; aquí solo vive el contenido
    // del cobro parcial, con el mismo comportamiento.
    return HojaAccion(
      titulo: 'Cobrar parcial — ${widget.nombre}',
      icono: Icons.payments_rounded,
      cuerpo: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pendiente total: ${fmtMonto(widget.total)} CUP',
              // 1.36 (136-296/314): importe tabular.
              style: AppTexto.conTabulares(AppTexto.secundario)),
          const SizedBox(height: AppEspacio.md),
          // 1.32 (O2F2, Pieza 4): la hoja del cobro parcial
          // compone el importe con el PAD empotrado (antes
          // abría el teclado del sistema sobre la hoja). El
          // controlador sigue existiendo como fuente del
          // texto: los atajos (_fijar) y la validación
          // (_valido) no cambian.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.md, vertical: AppEspacio.sm),
            decoration: BoxDecoration(
              border: Border.all(color: AppColores.borde(context)),
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
            // 1.36 H-B2 (136-620): el importe se anuncia con
            // monto y moneda a los lectores de pantalla.
            child: Semantics(
              label:
                  'Importe: ${fmtMonto(_monto ?? 0)} CUP',
              child: Text(
              _ctrl.text.isEmpty ? '0' : _ctrl.text,
              style: AppTexto.display.copyWith(
                  color: AppColores.textoNaranja(context),
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [
                    FontFeature.tabularFigures()
                  ]),
              textAlign: TextAlign.end,
              ),
            ),
          ),
          const SizedBox(height: AppEspacio.sm),
          PadNumerico(
            valor: _ctrl.text,
            onCambia: (t) {
              _ctrl.text = t;
              setState(() =>
                  _monto = double.tryParse(t.replaceAll(',', '.')));
            },
          ),
          const SizedBox(height: AppEspacio.sm),
          Wrap(
            spacing: AppEspacio.sm,
            children: [
              for (final a in atajosCobroParcial(widget.total))
                ActionChip(
                  label: Text(a.etiqueta),
                  onPressed: () => _fijar(a.valor),
                ),
            ],
          ),
          // 136-622: confirmación visual breve al fijar.
          AnimatedSwitcher(
            duration: AppMovimiento.corta,
            child: _recienFijado
                ? Row(
                    key: const ValueKey('fijado'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded,
                          size: 16, color: AppColores.exito),
                      const SizedBox(width: AppEspacio.xs),
                      Text('Importe fijado',
                          style: AppTexto.secundario.copyWith(
                              color: AppColores.exito,
                              fontWeight: FontWeight.w700)),
                    ],
                  )
                : const SizedBox.shrink(key: ValueKey('nada')),
          ),
          const SizedBox(height: AppEspacio.sm),
          if (_monto != null)
            Text(
              !_valido
                  ? (_monto! > widget.total
                      ? 'Supera el pendiente total.'
                      : 'Escribe una cantidad mayor que cero.')
                  : 'Se aplica ${widget.arrastre > 0.01 ? 'primero al saldo de cobros parciales y luego ' : ''}a los pagos más viejos primero. Quedan pendientes ${fmtMonto(widget.total - _monto!)} CUP.',
              style: AppTexto.secundario,
            ),
        ],
      ),
      pie: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
          ),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: BotonPrimario(
              texto: 'Confirmar cobro',
              onPressed: _valido
                  ? () => Navigator.pop(context, _monto)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
