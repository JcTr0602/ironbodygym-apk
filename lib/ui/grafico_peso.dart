// lib/ui/grafico_peso.dart
// v1.3.9 Sprint 2: gráfico de evolución de peso (adaptado
// de app clientes v0.4). Usa el modelo Medicion local
// (pesoKg + createdAt).
//
// 1.25 T109: el dibujo vive ahora en el componente
// genérico GraficoMetricaGestion (eje de tiempo real,
// toque con valor y fecha, serie plana centrada y
// guías rotuladas, el estándar de Clientes 0.15). Esta
// clase queda como el adaptador del peso: misma firma
// de siempre para su llamador en la pestaña de progreso.
import 'package:flutter/material.dart';

import 'grafico_metrica.dart';
import 'pestana_progreso.dart';

class GraficoPesoEntrenador extends StatelessWidget {
  final List<Medicion> mediciones;

  const GraficoPesoEntrenador({super.key, required this.mediciones});

  @override
  Widget build(BuildContext context) {
    return GraficoMetricaGestion(
      titulo: 'Evolución de peso',
      unidad: 'kg',
      puntos: [
        for (final m in mediciones)
          if (m.pesoKg > 0) PuntoSerie(m.createdAt, m.pesoKg),
      ],
    );
  }
}

/// 1.25 T109: la serie de una métrica opcional de las
/// mediciones (cintura, brazo, muslo...): solo entran
/// las mediciones que la traen, en el orden dado.
List<PuntoSerie> serieMetricaOpcional(
    List<Medicion> mediciones, double? Function(Medicion) valor) {
  return [
    for (final m in mediciones)
      if (valor(m) != null) PuntoSerie(m.createdAt, valor(m)!),
  ];
}
