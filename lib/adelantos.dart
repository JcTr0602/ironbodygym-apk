/// Adelantos a entrenadores (v1.8.0, diseño + Argón A1–A4).
///
/// Libro de eventos SIN saldos editables: registros (monto > 0) y
/// reversos (monto < 0 con reverso_de). Todo lo demás se deriva:
/// el libro corrido agrupa por `mes_nomina` (A1: fijado por el
/// servidor al crear; un mes liquidado nunca se reescribe) y
/// arrastra la deuda cuando los adelantos superan lo devengado.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'sync.dart';
import 'tiempo.dart';

/// Un mes del libro corrido de un entrenador.
class MesLibroAdelantos {
  final String mes; // 'YYYY-MM'
  final double bruto;
  final double comisiones;
  final double bonos; // #2 (Argón nómina): bonos del mes, parte
  // de la capacidad: un adelanto cubierto por un bono NO genera
  // deuda saliente (antes el libro no los veía y la deuda era
  // fantasma).
  final double adelantos; // suma con signo del mes (por mes_nomina)
  final double deudaEntrante;
  final List<Map<String, dynamic>> items;
  const MesLibroAdelantos({
    required this.mes,
    required this.bruto,
    required this.comisiones,
    this.bonos = 0,
    required this.adelantos,
    required this.deudaEntrante,
    required this.items,
  });

  /// Lo devengado del mes (bruto + comisiones + bonos).
  double get devengado => bruto + comisiones + bonos;

  /// Neto a pagar: devengado − adelantos − deuda entrante.
  /// Negativo = queda deuda (se paga 0).
  double get neto => devengado - adelantos - deudaEntrante;
  double get aPagar => neto > 0 ? neto : 0;
  double get deudaSaliente => neto < 0 ? -neto : 0;
}

/// Libro corrido: un MesLibro por mes desde el primer mes con
/// datos (evento, bruto o comisión) hasta [hastaMes] inclusive.
/// La deuda se arrastra mes a mes aunque un mes no tenga datos
/// (si hay deuda viva, los meses intermedios aparecen con su
/// deuda entrante para que la cadena sea auditable; sin deuda y
/// sin datos, el mes se omite).
List<MesLibroAdelantos> libroAdelantos({
  required List<Map<String, dynamic>> eventos,
  required Map<String, double> brutoPorMes,
  required Map<String, double> comisionesPorMes,
  Map<String, double> bonosPorMes = const {},
  required String hastaMes,
}) {
  final porMes = <String, List<Map<String, dynamic>>>{};
  for (final e in eventos) {
    final mes = '${e['mes_nomina'] ?? ''}';
    if (mes.length != 7) continue;
    (porMes[mes] ??= []).add(e);
  }
  final meses = <String>{
    ...porMes.keys,
    ...brutoPorMes.keys,
    ...comisionesPorMes.keys,
    ...bonosPorMes.keys,
    hastaMes,
  }.where((m) => m.compareTo(hastaMes) <= 0).toList()
    ..sort();
  if (meses.isEmpty) return const [];
  final out = <MesLibroAdelantos>[];
  var deuda = 0.0;
  var mes = meses.first;
  while (mes.compareTo(hastaMes) <= 0) {
    final items = porMes[mes] ?? const <Map<String, dynamic>>[];
    final adelantos = items.fold<double>(
        0, (s, e) => s + ((e['monto'] as num?)?.toDouble() ?? 0));
    final bruto = brutoPorMes[mes] ?? 0;
    final comisiones = comisionesPorMes[mes] ?? 0;
    final bonos = bonosPorMes[mes] ?? 0;
    if (items.isNotEmpty ||
        bruto != 0 ||
        comisiones != 0 ||
        bonos != 0 ||
        deuda != 0 ||
        mes == hastaMes) {
      final libro = MesLibroAdelantos(
        mes: mes,
        bruto: bruto,
        comisiones: comisiones,
        bonos: bonos,
        adelantos: adelantos,
        deudaEntrante: deuda,
        items: items,
      );
      out.add(libro);
      deuda = libro.deudaSaliente;
    }
    mes = mesSiguiente(mes);
  }
  return out;
}

/// Suma neta de los adelantos VIVOS que descuentan de la gaveta
/// de [telegramId] (panel 1.8.0, Claude): espejo (en_pendiente=1)
/// + las ops registrar_adelanto AÚN encoladas en ESTE teléfono
/// (caja_turno + efectivo + descuenta_a == telegramId), sin
/// duplicar las que ya bajaron al espejo (se cruzan por op_uuid),
/// − las anulaciones encoladas cuyo original sigue pendiente en
/// el espejo. Los reversos del espejo netan solos (monto < 0).
double sumaAdelantosPendientes({
  required List<Map<String, dynamic>> espejo,
  required List<Map<String, dynamic>> opsPendientes,
  required int telegramId,
  required int? Function(Object?) normalizarTid,
}) {
  double total = 0;
  final uuidsEspejo = <String>{};
  final porId = <int, Map<String, dynamic>>{};
  for (final a in espejo) {
    final id = (a['id'] as num?)?.toInt();
    if (id != null) porId[id] = a;
    final u = a['op_uuid'];
    if (u != null) uuidsEspejo.add('$u');
    if (normalizarTid(a['descuenta_a']) == telegramId &&
        (a['en_pendiente'] as num?)?.toInt() == 1) {
      total += (a['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final op in opsPendientes) {
    final tipo = '${op['tipo']}';
    if (tipo != 'registrar_adelanto' && tipo != 'anular_adelanto') {
      continue;
    }
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(op['payload'] as String)
          as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (tipo == 'registrar_adelanto') {
      final uuid = op['op_uuid'] ?? op['uuid'];
      if (uuid != null && uuidsEspejo.contains('$uuid')) continue;
      if ('${payload['origen'] ?? 'caja_turno'}' == 'caja_turno' &&
          '${payload['metodo'] ?? 'efectivo'}' == 'efectivo' &&
          normalizarTid(payload['descuenta_a']) == telegramId) {
        total += (payload['monto'] as num?)?.toDouble() ?? 0;
      }
    } else {
      // Anulación encolada: resta lo que el original aún suma.
      final origId = (payload['adelanto_id'] as num?)?.toInt();
      final orig = origId == null ? null : porId[origId];
      if (orig != null &&
          normalizarTid(orig['descuenta_a']) == telegramId &&
          (orig['en_pendiente'] as num?)?.toInt() == 1) {
        total -= (orig['monto'] as num?)?.toDouble() ?? 0;
      }
    }
  }
  return total;
}

/// Servicio de adelantos: espejo + ops pendientes (este teléfono)
/// y acciones (solo dueño en el servidor; la UI también gatea).
class AdelantosService {
  AdelantosService._();
  static final AdelantosService instance = AdelantosService._();
  final LocalDb _db = LocalDb.instance;

  /// Eventos de un entrenador (por user_id APK): espejo + los
  /// registrar_adelanto aún pendientes de ESTE teléfono (con
  /// id == null = provisionales) y la marca de anulación
  /// pendiente sobre su original.
  /// Corrección panel 1.12: además de la llave APK, se acepta
  /// el telegram_id del entrenador. Los adelantos F3 aprobados
  /// llevan como clave el telegram_id autenticado (el servidor
  /// no puede resolver el id APK desde telegram_id), así que sin
  /// este segundo criterio no aparecían en su libro de nómina.
  Future<List<Map<String, dynamic>>> eventosDe(String entrenadorId,
      {int? telegramId}) async {
    final filas = [
      for (final a in await _db.allMirror('adelantos'))
        if ('${a['entrenador']}' == entrenadorId ||
            (telegramId != null &&
                LocalDb.normalizarTelegramId(
                        a['entrenador_telegram_id']) ==
                    telegramId))
          a,
    ];
    final anulacionesPendientes = <int>{};
    for (final op in await _db.pendingOps()) {
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if (op['tipo'] == 'anular_adelanto') {
          final id = (p['adelanto_id'] as num?)?.toInt();
          if (id != null) anulacionesPendientes.add(id);
        } else if (op['tipo'] == 'registrar_adelanto' &&
            '${p['entrenador']}' == entrenadorId) {
          filas.add({
            'id': null,
            'entrenador': entrenadorId,
            'entrenador_nombre': p['entrenador_nombre'],
            'monto': p['monto'],
            'fecha': p['fecha'],
            // Estimación local del mes_nomina: el servidor lo
            // fija al aplicar (puede diferir si el mes ya está
            // liquidado; el espejo manda al sincronizar).
            'mes_nomina': '${p['fecha']}'.substring(0, 7),
            'nota': p['nota'],
            'metodo': p['metodo'],
            'origen': p['origen'],
            'pendiente': 1,
          });
        }
      } catch (_) {}
    }
    for (final f in filas) {
      final id = (f['id'] as num?)?.toInt();
      if (id != null && anulacionesPendientes.contains(id)) {
        f['anulacion_pendiente'] = 1;
      }
    }
    filas.sort((a, b) =>
        '${a['fecha']}'.compareTo('${b['fecha']}'));
    return filas;
  }

  /// ¿El mes ya está liquidado para el entrenador? (espejo o la
  /// op pendiente de este teléfono).
  Future<bool> nominaLiquidada(
      String mes, String entrenadorId) async {
    // 1.14 (D17): la liquidación puede venir keyada por id APK/UID
    // o consultarse por telegram_id (adelantos aprobados guardan
    // el telegram_id como `entrenador`). Se compara por ambas
    // columnas, en espejo y en ops pendientes.
    bool coincide(Map<String, dynamic> fila) =>
        '${fila['mes']}' == mes &&
        ('${fila['entrenador']}' == entrenadorId ||
            '${fila['entrenador_telegram_id']}' == entrenadorId);
    for (final l in await _db.allMirror('nomina_liquidada')) {
      if (coincide(l)) return true;
    }
    for (final op in await _db.pendingOps()) {
      if (op['tipo'] != 'liquidar_nomina') continue;
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if (coincide(p)) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _queueYEmpujar(String tipo, Map<String, dynamic> payload) async {
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: tipo,
      payload: payload,
    );
    try {
      await SyncEngine.instance.push();
    } catch (_) {}
  }

  Future<void> registrar({
    required String entrenadorId,
    required String entrenadorNombre,
    required int? entrenadorTelegramId,
    required int monto,
    required DateTime fecha,
    String? nota,
    required String metodo,
    required String origen,
    int? descuentaA,
  }) {
    final f = '${fecha.year.toString().padLeft(4, '0')}-'
        '${fecha.month.toString().padLeft(2, '0')}-'
        '${fecha.day.toString().padLeft(2, '0')}';
    return _queueYEmpujar('registrar_adelanto', {
      'entrenador': entrenadorId,
      'entrenador_nombre': entrenadorNombre,
      'entrenador_telegram_id': entrenadorTelegramId,
      'monto': monto,
      'fecha': f,
      'nota': (nota != null && nota.trim().isNotEmpty)
          ? nota.trim()
          : null,
      'metodo': metodo,
      'origen': origen,
      'descuenta_a': origen == 'caja_turno' ? descuentaA : null,
    });
  }

  /// Anula un adelanto (solo dueño en el servidor).
  ///
  /// Fase A 2026-10-25 (M1): si el mes de nómina de ese adelanto
  /// ya está liquidado para su entrenador, se RECHAZA antes de
  /// encolar (la misma fuente de verdad que usa la UI:
  /// [nominaLiquidada], espejo `nomina_liquidada` + op
  /// `liquidar_nomina` pendiente). Sin entrenador/mes explícitos,
  /// se buscan en el espejo por id; si no se encuentran (fila
  /// provisional o espejo incompleto), se deja pasar: el servidor
  /// es la última guarda y la UI ya oculta el botón cuando sabe
  /// que el mes está liquidado.
  Future<void> anular(int adelantoId,
      {String? entrenadorId, String? mesNomina}) async {
    var ent = entrenadorId;
    var mes = mesNomina;
    if (ent == null || mes == null) {
      for (final a in await _db.allMirror('adelantos')) {
        if ((a['id'] as num?)?.toInt() == adelantoId) {
          ent ??= '${a['entrenador'] ?? ''}';
          final m = '${a['mes_nomina'] ?? ''}';
          if (mes == null && m.length == 7) mes = m;
          break;
        }
      }
    }
    if (ent != null &&
        ent.isNotEmpty &&
        mes != null &&
        await nominaLiquidada(mes, ent)) {
      throw StateError(
          'La nómina de $mes ya está liquidada: no se puede anular '
          'este adelanto.');
    }
    return _queueYEmpujar('anular_adelanto', {'adelanto_id': adelantoId});
  }

  Future<void> liquidarNomina({
    required String mes,
    required String entrenadorId,
    required String entrenadorNombre,
    int? entrenadorTelegramId,
    // #3 (Argón nómina): foto de tarifa y neto al liquidar, para
    // que la historia no cambie si la tarifa cambia después.
    double? tarifaPorCliente,
    double? neto,
  }) =>
      _queueYEmpujar('liquidar_nomina', {
        'mes': mes,
        'entrenador': entrenadorId,
        'entrenador_nombre': entrenadorNombre,
        // 1.14 (D17): el servidor guarda el telegram_id en la
        // liquidación para que el chequeo de mes liquidado
        // funcione también desde la vía de aprobación (que solo
        // conoce el telegram_id).
        if (entrenadorTelegramId != null)
          'entrenador_telegram_id': entrenadorTelegramId,
        if (tarifaPorCliente != null)
          'tarifa_por_cliente': tarifaPorCliente,
        if (neto != null) 'neto': neto,
      });

  /// El mes en curso ('YYYY-MM') en hora de La Habana.
  static String mesActual() {
    final h = ahoraHabana();
    return '${h.year.toString().padLeft(4, '0')}-'
        '${h.month.toString().padLeft(2, '0')}';
  }
}
