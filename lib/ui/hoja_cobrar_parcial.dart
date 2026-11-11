/// 1.26.1: hoja de «Cobrar parcial» — el dueño escribe
/// cuánto recogió del entrenador (ver pendiente.dart,
/// _abrirCobrarParcial, y lib/cobro_parcial.dart).
library;

import 'package:flutter/material.dart';

import '../cobro_parcial.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
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

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _valido =>
      _monto != null &&
      _monto! > 0 &&
      _monto! - widget.total <= 0.01;

  void _fijar(double v) {
    _ctrl.text = v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(2);
    setState(() => _monto = v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: AppEspacio.lg,
          right: AppEspacio.lg,
          top: AppEspacio.md,
          bottom: MediaQuery.of(context).viewInsets.bottom +
              AppEspacio.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Cobrar parcial — ${widget.nombre}',
                    style: AppTexto.subtitulo
                        .copyWith(fontWeight: FontWeight.bold)),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          Text('Pendiente total: ${fmtMonto(widget.total)} CUP',
              style: AppTexto.secundario),
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
          const SizedBox(height: AppEspacio.md),
          Row(
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
        ],
      ),
    );
  }
}
