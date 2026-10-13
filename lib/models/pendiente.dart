/// Modelos de dominio para "Pendiente a recoger" v2.
/// Agrupación Entrenador > Días. Testeable sin SQLite.
library;

/// Un pago individual pendiente de entrega.
class PagoPendiente {
  final int id;
  final double monto;
  final String moneda; // 'CUP' o 'USD'
  final DateTime fecha;
  final String tipo; // 'mensual', 'diario', etc.
  final String descripcion;
  final String entrenador;

  const PagoPendiente({
    required this.id,
    required this.monto,
    required this.moneda,
    required this.fecha,
    required this.tipo,
    required this.descripcion,
    required this.entrenador,
  });

  factory PagoPendiente.fromMap(Map<String, dynamic> map) {
    return PagoPendiente(
      id: map['id'] as int? ?? 0,
      monto: (map['monto'] as num?)?.toDouble() ?? 0,
      // Gemini: fallback seguro, sin migraciones de BD.
      moneda: map['moneda'] as String? ?? 'CUP',
      fecha: DateTime.tryParse('${map['creada_en'] ?? map['fecha']}') ??
          DateTime.now(),
      tipo: map['tipo'] as String? ?? 'mensual',
      descripcion: map['descripcion'] as String? ?? '',
      entrenador:
          map['entrenador_nombre'] as String? ?? 'Sin asignar',
    );
  }
}

/// Pagos de un entrenador agrupados por día.
class PendienteDia {
  final DateTime fecha;
  final List<PagoPendiente> pagos;

  const PendienteDia({required this.fecha, required this.pagos});

  double totalPorMoneda(String moneda) => pagos
      .where((p) => p.moneda == moneda)
      .fold(0.0, (acc, p) => acc + p.monto);

  int get diasDeAntiguedad {
    final hoy = DateTime.now();
    final f = DateTime(fecha.year, fecha.month, fecha.day);
    final h = DateTime(hoy.year, hoy.month, hoy.day);
    return h.difference(f).inDays;
  }

  String get etiquetaFecha {
    final d = diasDeAntiguedad;
    if (d == 0) return 'HOY';
    if (d == 1) return 'AYER';
    if (d <= 3) return 'HACE $d DÍAS';
    return '${fecha.day.toString().padLeft(2, '0')}/'
        '${fecha.month.toString().padLeft(2, '0')}';
  }

  /// Nivel de alerta: 0=normal, 1=aviso (2-3 días), 2=crítico (4+).
  int get nivelAlerta {
    final d = diasDeAntiguedad;
    if (d >= 4) return 2;
    if (d >= 2) return 1;
    return 0;
  }

  List<int> get ids => pagos.map((p) => p.id).toList();
}

/// Todo lo pendiente de un entrenador, agrupado por días.
class EntrenadorPendiente {
  final String nombre;
  final List<PendienteDia> dias;

  const EntrenadorPendiente(
      {required this.nombre, required this.dias});

  double totalPorMoneda(String moneda) => dias.fold(
      0.0, (acc, d) => acc + d.totalPorMoneda(moneda));

  int get totalPagos =>
      dias.fold(0, (acc, d) => acc + d.pagos.length);

  bool get tieneRetraso =>
      dias.any((d) => d.nivelAlerta > 0);

  List<int> get todosLosIds =>
      dias.expand((d) => d.ids).toList();
}

/// Agrupa una lista plana de pagos en entrenadores > días.
/// Orden descendente por fecha dentro de cada entrenador.
List<EntrenadorPendiente> procesarPendientes(
    List<Map<String, dynamic>> registrosPlanos) {
  final porEntrenador =
      <String, List<PagoPendiente>>{};
  for (final raw in registrosPlanos) {
    final pago = PagoPendiente.fromMap(raw);
    porEntrenador
        .putIfAbsent(pago.entrenador, () => [])
        .add(pago);
  }

  return porEntrenador.entries.map((entry) {
    final porFecha = <String, List<PagoPendiente>>{};
    for (final pago in entry.value) {
      final key =
          '${pago.fecha.year}-${pago.fecha.month.toString().padLeft(2, '0')}-${pago.fecha.day.toString().padLeft(2, '0')}';
      porFecha.putIfAbsent(key, () => []).add(pago);
    }

    final dias = porFecha.entries.map((f) {
      return PendienteDia(
        fecha: DateTime.parse(f.key),
        pagos: f.value,
      );
    }).toList()
      ..sort((a, b) => b.fecha.compareTo(a.fecha));

    return EntrenadorPendiente(
        nombre: entry.key, dias: dias);
  }).toList();
}
