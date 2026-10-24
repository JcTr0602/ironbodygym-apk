/// Modelos de dominio para "Pendiente a recoger" v2.
/// Agrupación Entrenador > Días. Testeable sin SQLite.
library;

import '../tiempo.dart';

/// Un pago individual pendiente de entrega.
class PagoPendiente {
  final int id;
  final double monto;
  final String moneda; // 'CUP' o 'USD'
  final DateTime fecha;
  final String tipo; // 'mensual', 'diario', etc.
  final String descripcion;
  final String entrenador;
  // Fix #17 (Sol): ID estable del entrenador para agrupar.
  // El nombre es solo presentación.
  final String trainerTelegramId;

  const PagoPendiente({
    required this.id,
    required this.monto,
    required this.moneda,
    required this.fecha,
    required this.tipo,
    required this.descripcion,
    required this.entrenador,
    this.trainerTelegramId = '',
  });

  /// Fix #26 (Sol): valida en vez de inventar defaults.
  /// Retorna null si el registro es inválido (sin ID, monto <= 0,
  /// fecha inválida). El llamador debe filtrar los null.
  static PagoPendiente? tryFromMap(Map<String, dynamic> map) {
    final id = map['id'] as int?;
    if (id == null || id <= 0) return null;
    final monto = (map['monto'] as num?)?.toDouble();
    if (monto == null || monto <= 0) return null;
    final fechaRaw = map['creada_en'] ?? map['fecha'];
    final fechaParsed = fechaRaw == null
        ? null
        : DateTime.tryParse('$fechaRaw');
    if (fechaParsed == null) return null;
    final moneda = map['moneda'] as String?;
    if (moneda != null &&
        moneda != 'CUP' &&
        moneda != 'USD') return null;
    return PagoPendiente(
      id: id,
      monto: monto,
      moneda: moneda ?? 'CUP',
      fecha: fechaParsed.toLocal(),
      tipo: map['tipo'] as String? ?? 'mensual',
      descripcion: map['descripcion'] as String? ?? '',
      entrenador:
          map['entrenador_nombre'] as String? ?? 'Sin asignar',
      // Fix #17: conservar el ID aunque el nombre cambie.
      trainerTelegramId:
          '${map['trainer_telegram_id'] ?? map['entrenador_id'] ?? ''}',
    );
  }

  factory PagoPendiente.fromMap(Map<String, dynamic> map) {
    // Compatibilidad: delega a tryFromMap, lanza si inválido.
    final p = tryFromMap(map);
    if (p == null) {
      throw FormatException(
          'PagoPendiente inválido: $map');
    }
    return p;
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
    // Gemini: usar UTC para evitar problemas con DST.
    // v1.3.4: hora de La Habana, no la del dispositivo.
    final hoy = ahoraHabana();
    final f =
        DateTime.utc(fecha.year, fecha.month, fecha.day);
    final h =
        DateTime.utc(hoy.year, hoy.month, hoy.day);
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

  /// IDs separados por tipo (Gemini: evita colisión pagos/pagos_diarios).
  List<int> get mensualIds => pagos
      .where((p) => p.tipo == 'mensual')
      .map((p) => p.id)
      .toList();
  List<int> get diarioIds => pagos
      .where((p) => p.tipo == 'diario')
      .map((p) => p.id)
      .toList();

  /// v1.3.1 (Alto #1): IDs de ventas de suplementos para confirmar entrega.
  List<int> get suplementoIds => pagos
      .where((p) => p.tipo == 'suplemento')
      .map((p) => p.id)
      .toList();

  /// post-1.8.0 (ítem 10): IDs de ventas de servicios (dosis, combos
  /// y pomos de agua en efectivo) para confirmar su entrega.
  List<int> get servicioIds => pagos
      .where((p) => p.tipo == 'servicio')
      .map((p) => p.id)
      .toList();
}

/// UID único para optimistic UI (tipo + id).
extension PagoPendienteUid on PagoPendiente {
  String get uid => '${tipo}_$id';
}

/// Todo lo pendiente de un entrenador, agrupado por días.
class EntrenadorPendiente {
  final String nombre;
  // Fix #17 (Sol): ID estable para agrupar/identificar.
  final String trainerTelegramId;
  final List<PendienteDia> dias;

  const EntrenadorPendiente(
      {required this.nombre,
      this.trainerTelegramId = '',
      required this.dias});

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
/// Fix #17 (Sol): agrupa por trainerTelegramId (estable),
/// no por nombre (puede duplicarse).
/// Fix #26: filtra registros inválidos vía tryFromMap.
/// Fix #15: separa pagos por moneda en días distintos para evitar
/// confirmar CUP+USD juntos.
List<EntrenadorPendiente> procesarPendientes(
    List<Map<String, dynamic>> registrosPlanos) {
  final porEntrenador =
      <String, List<PagoPendiente>>{};
  final nombres = <String, String>{};
  for (final raw in registrosPlanos) {
    final pago = PagoPendiente.tryFromMap(raw);
    if (pago == null) continue; // Fix #26: descartar inválidos
    // Clave: telegram_id si existe, si no el nombre (legacy).
    final clave = pago.trainerTelegramId.isNotEmpty
        ? 'id:${pago.trainerTelegramId}'
        : 'nom:${pago.entrenador}';
    porEntrenador.putIfAbsent(clave, () => []).add(pago);
    nombres[clave] = pago.entrenador;
  }

  return porEntrenador.entries.map((entry) {
    // Fix #15: agrupar por fecha+moneda para no mezclar CUP/USD.
    final porFechaMoneda =
        <String, List<PagoPendiente>>{};
    for (final pago in entry.value) {
      final key =
          '${pago.fecha.year}-${pago.fecha.month.toString().padLeft(2, '0')}-${pago.fecha.day.toString().padLeft(2, '0')}'
          '|${pago.moneda}';
      porFechaMoneda.putIfAbsent(key, () => []).add(pago);
    }

    final dias = porFechaMoneda.entries.map((f) {
      final partes = f.key.split('|');
      return PendienteDia(
        fecha: DateTime.parse(partes[0]),
        pagos: f.value,
      );
    }).toList()
      ..sort((a, b) => b.fecha.compareTo(a.fecha));

    final clave = entry.key;
    final tid = clave.startsWith('id:')
        ? clave.substring(3)
        : '';
    return EntrenadorPendiente(
        nombre: nombres[clave] ?? 'Sin asignar',
        trainerTelegramId: tid,
        dias: dias);
  }).toList();
}
