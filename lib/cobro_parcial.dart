/// 1.26.1 — «Cobrar Parcial» en Pendiente a recoger
/// (pedido de Jc 2026-11-06; diseño aprobado por Argón
/// con restricciones críticas de aritmética).
///
/// El dueño teclea cuánto recogió del entrenador y el
/// monto se aplica FIFO sobre su pendiente CUP en
/// efectivo, reutilizando la op `liquidar_caja` (la del
/// Arqueo, ya auditada) SIN partir ningún pago:
///
/// - El saldo de arrastre vivo (lo que quedó debiendo de
///   una liquidación parcial anterior, sin estar atado a
///   ningún pago) va en la CABEZA de la cola: si el monto
///   no lo supera, no se consume ningún pago nuevo y la
///   op viaja con op_ids vacío (el servidor lo permite
///   cuando hay arrastre pendiente).
/// - Si lo supera, se consume el prefijo FIFO mínimo de
///   pagos vivos con arrastre + suma(prefijo) >= monto.
/// - monto_esperado = arrastre + suma(prefijo) — la
///   igualdad exacta que el servidor exige
///   (esperado = suma_ids + arrastre_previo - resto C1;
///   en el mundo limpio de las guardas H11, resto C1 = 0
///   y no hay adelantos vivos).
/// - El nuevo arrastre es esperado - monto: el pendiente
///   baja exactamente en lo tecleado.
///
/// Compositor puro, sin SQLite ni Flutter: la UI le pasa
/// la foto (filas + arrastre) y los tests lo fijan sin BD.
library;

/// Una fila del pendiente CUP en efectivo de un
/// entrenador. [tabla] usa el vocabulario de op_ids del
/// servidor; [tipoCrudo] el de los registros planos de
/// la pantalla Pendiente (para el retiro optimista).
class FilaCobro {
  final String tabla;
  final int id;

  /// Puede ser negativo: un reverso de servicio netea
  /// contra su venta dentro del prefijo.
  final double monto;
  final DateTime fecha;

  const FilaCobro({
    required this.tabla,
    required this.id,
    required this.monto,
    required this.fecha,
  });

  String get tipoCrudo => switch (tabla) {
        'pagos' => 'mensual',
        'pagos_diarios' => 'diario',
        'ventas_suplementos' => 'suplemento',
        'servicio_ventas' => 'servicio',
        _ => tabla,
      };

  /// UID con el vocabulario de la pantalla (tipo_id),
  /// el mismo que usa el retiro optimista de
  /// _confirmarPorIds.
  String get uid => '${tipoCrudo}_$id';
}

/// El cobro parcial ya compuesto, listo para
/// `crearLiquidacion`.
class CobroParcialCompuesto {
  final Map<String, List<int>> opIds;
  final double montoEsperado;
  final double montoEntregado;
  final double nuevoArrastre;

  /// Prefijo FIFO consumido (vacío si el monto se
  /// cubrió solo con el arrastre).
  final List<FilaCobro> cubiertas;

  const CobroParcialCompuesto({
    required this.opIds,
    required this.montoEsperado,
    required this.montoEntregado,
    required this.nuevoArrastre,
    required this.cubiertas,
  });
}

double _redondear2(double v) => (v * 100).roundToDouble() / 100;

/// Compone el cobro parcial. Devuelve null si el monto
/// es inválido: no finito, <= 0 o mayor que el pendiente
/// total (arrastre + suma de filas).
CobroParcialCompuesto? componerCobroParcial({
  required List<FilaCobro> filasFifo,
  required double arrastre,
  required double monto,
}) {
  if (!monto.isFinite || monto <= 0) return null;
  final total =
      arrastre + filasFifo.fold(0.0, (a, f) => a + f.monto);
  if (monto - total > 0.01) return null;
  final cubiertas = <FilaCobro>[];
  var acumulado = arrastre;
  if (monto > arrastre + 0.01) {
    for (final f in filasFifo) {
      if (acumulado >= monto - 0.01) break;
      cubiertas.add(f);
      acumulado += f.monto;
    }
  }
  final esperado = _redondear2(
      arrastre + cubiertas.fold(0.0, (a, f) => a + f.monto));
  final opIds = <String, List<int>>{
    'pagos': [],
    'pagos_diarios': [],
    'ventas_suplementos': [],
    'servicio_ventas': [],
    'adelantos': [],
  };
  for (final f in cubiertas) {
    opIds[f.tabla]!.add(f.id);
  }
  return CobroParcialCompuesto(
    opIds: opIds,
    montoEsperado: esperado,
    montoEntregado: monto,
    nuevoArrastre: _redondear2(
        (esperado - monto).clamp(0, double.infinity).toDouble()),
    cubiertas: cubiertas,
  );
}

/// Atajos de cantidad para la hoja: redondos útiles, la
/// mitad y el total, sin duplicados y en orden. Máximo 4.
List<({double valor, String etiqueta})> atajosCobroParcial(
    double total) {
  final res = <double, String>{};
  if (total > 1000) res[1000] = '1000';
  if (total > 2000) res[2000] = '2000';
  final mitad = (total / 2).floorToDouble();
  if (mitad > 0 && mitad < total && !res.containsKey(mitad)) {
    res[mitad] = 'Mitad';
  }
  res[total] = 'Todo';
  final ordenados = res.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return [
    for (final e in ordenados) (valor: e.key, etiqueta: e.value)
  ];
}
