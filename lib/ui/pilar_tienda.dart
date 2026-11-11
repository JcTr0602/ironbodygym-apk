/// 1.32 «Mostrador Táctico» — Pilar 3 · TIENDA.
///
/// ENVUELVE los hubs de la 1.31 sin reconstruirlos (Addendum
/// 98 del plano consolidado): Servicios con sus 4 zonas
/// (Vender · Día · Inventario · Análisis) tal cual, y
/// Suplementos al lado, ambos embebidos. Verificado contra el
/// código vivo al envolver (2026-11-11):
/// - Pomo ciego estricto: el medidor y la cifra de dosis viven
///   SOLO en la rama del dueño (servicios.dart, tarjeta del
///   pomo); el botón de venta del entrenador se bloquea sin
///   revelar el saldo (estadoBotonVentaServicio: el motivo
///   «no quedan» es solo-dueño) y NO existe franja de «pocas
///   dosis» para él (descartada por Jc).
/// - La pestaña Día del entrenador filtra SOLO sus ventas:
///   el predicado visibleParaMi (vendedor = él o su pomo) se
///   aplica a las ventas del espejo y a las de la cola, y el
///   Historial recibe esDueno/miTid/misPomosIds con la misma
///   regla (guarda del contraste de Argón).
/// - «Pedir relleno» sigue donde estaba: en Vender, visible
///   siempre y sin revelar saldo.
/// - Precios sigue colgando de Inventario (pantalla hija),
///   como manda el Addendum.
library;

import 'package:flutter/material.dart';

import 'diseno.dart';
import 'servicios.dart';
import 'suplementos.dart';

class PilarTienda extends StatefulWidget {
  const PilarTienda({super.key});

  @override
  State<PilarTienda> createState() => _PilarTiendaState();
}

class _PilarTiendaState extends State<PilarTienda> {
  String _segmento = 'servicios';
  final Set<String> _visitados = {'servicios'};

  @override
  Widget build(BuildContext context) {
    const segmentos = ['servicios', 'suplementos'];
    return Column(
      key: const ValueKey('pilar-tienda'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.sm),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'servicios',
                  icon: Icon(Icons.science_rounded),
                  label: Text('Servicios')),
              ButtonSegment(
                  value: 'suplementos',
                  icon: Icon(Icons.medication_rounded),
                  label: Text('Suplementos')),
            ],
            selected: {_segmento},
            onSelectionChanged: (s) => setState(() {
              _segmento = s.first;
              _visitados.add(s.first);
            }),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: segmentos.indexOf(_segmento),
            children: [
              for (final s in segmentos)
                if (_visitados.contains(s))
                  KeyedSubtree(
                    key: ValueKey('pilar-tienda-$s'),
                    child: s == 'servicios'
                        ? const ServiciosScreen(embebida: true)
                        : const SuplementosScreen(embebida: true),
                  )
                else
                  const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }
}
