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

/// Yunque R5-M9-2/M9-4: los puntos de peso VÁLIDOS de la
/// lista (peso > 0 y fecha no época). Es la serie que
/// pinta el gráfico y el conteo que decide su rama.
List<PuntoSerie> puntosPesoValidos(List<Medicion> mediciones) => [
      for (final m in mediciones)
        // 1.28 (M4-A12): peso nullable — las mediciones sin
        // peso no entran en la serie (antes entraban como 0
        // inventado desde el modelo).
        // R5-M9-2: una fecha época (el respaldo de
        // «created_at corrupto» de la pestaña) tampoco: un
        // punto de 1970 aplastaba el eje contra ~56 años.
        if (m.pesoKg != null && m.pesoKg! > 0 && m.createdAt.year >= 2000)
          PuntoSerie(m.createdAt, m.pesoKg!),
    ];

class GraficoPesoEntrenador extends StatelessWidget {
  final List<Medicion> mediciones;

  const GraficoPesoEntrenador({super.key, required this.mediciones});

  @override
  Widget build(BuildContext context) {
    return GraficoMetricaGestion(
      titulo: 'Evolución de peso',
      unidad: 'kg',
      puntos: puntosPesoValidos(mediciones),
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
      // Yunque R5-M9-3: el mismo filtro de validez que el
      // peso y que validarMedicion (<= 0 o NaN no es una
      // medición): un 0 legado en el espejo caía como punto
      // real y arrastraba el eje a cero. Y sin fechas época
      // (R5-M9-2).
      if (valor(m) != null &&
          valor(m)! > 0 &&
          valor(m)!.isFinite &&
          m.createdAt.year >= 2000)
        PuntoSerie(m.createdAt, valor(m)!),
  ];
}
