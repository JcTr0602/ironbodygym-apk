/// Lógica de negocio en el teléfono (espejo de ironbody/db/clientes.py).
///
/// Trabaja sobre los mapas decodificados del espejo `clientes`.
library;

import 'localdb.dart';

String _norm(String s) {
  var n = s.toLowerCase().trim();
  const conTilde = 'áéíóúüñ';
  const sinTilde = 'aeiouun';
  for (var i = 0; i < conTilde.length; i++) {
    n = n.replaceAll(conTilde[i], sinTilde[i]);
  }
  return n;
}

String _hoyIso() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

String _hace(int dias) {
  final d = DateTime.now().subtract(Duration(days: dias));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

Future<List<Map<String, dynamic>>> _activos() async {
  final todos = await LocalDb.instance.allMirror('clientes');
  return todos.where((c) => c['estado'] == 'activo').toList();
}

/// Búsqueda por nombre (usa nombre_norm si viene en el espejo).
Future<List<Map<String, dynamic>>> buscarClientes(String q) async {
  final nq = _norm(q);
  if (nq.isEmpty) return [];
  final rows = await _activos();
  final res = rows.where((c) {
    final norm = (c['nombre_norm'] as String?) ?? _norm('${c['nombre']}');
    return norm.contains(nq);
  }).toList();
  res.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
  return res;
}

/// Vencen exactamente hoy.
Future<List<Map<String, dynamic>>> vencenHoy() async {
  final hoy = _hoyIso();
  final rows = await _activos();
  final res =
      rows.where((c) => (c['pagado_hasta'] as String?) == hoy).toList();
  res.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
  return res;
}

/// Atrasados: masDe30=false -> 1..30 días (incluye sin pagado_hasta);
/// masDe30=true -> más de 30 días.
Future<List<Map<String, dynamic>>> atrasados({required bool masDe30}) async {
  final hoy = _hoyIso();
  final limite = _hace(30);
  final rows = await _activos();
  List<Map<String, dynamic>> res;
  if (masDe30) {
    res = rows.where((c) {
      final ph = c['pagado_hasta'] as String?;
      return ph != null && ph.compareTo(limite) < 0;
    }).toList();
  } else {
    res = rows.where((c) {
      final ph = c['pagado_hasta'] as String?;
      return ph == null ||
          (ph.compareTo(hoy) < 0 && ph.compareTo(limite) >= 0);
    }).toList();
  }
  res.sort((a, b) =>
      ('${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}')));
  return res;
}

Future<Map<String, dynamic>?> clientePorId(int id) async {
  final rows = await LocalDb.instance.allMirror('clientes');
  for (final c in rows) {
    if ((c['id'] as int?) == id) return c;
  }
  return null;
}

/// Últimos pagos de un cliente (del espejo `pagos`).
Future<List<Map<String, dynamic>>> pagosDe(int clienteId,
    {int limit = 10}) async {
  final todos = await LocalDb.instance.allMirror('pagos');
  final res =
      todos.where((p) => (p['cliente_id'] as int?) == clienteId).toList();
  res.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return res.take(limit).toList();
}

String fmtFecha(String? iso) {
  if (iso == null || iso.length < 10) return '—';
  final p = iso.substring(0, 10).split('-');
  return '${p[2]}/${p[1]}/${p[0]}';
}

String fmtMonto(dynamic m) {
  if (m == null) return '—';
  final v = (m as num).toDouble();
  return v == v.roundToDouble() ? '${v.toInt()}' : '$v';
}

/// Nuevo pagado_hasta estimado si se pagan `meses` hoy.
/// Regla del servidor: max(pagado_hasta actual, hoy) + meses*30 días.
String previewHasta(String? pagadoHasta, int meses) =>
    previewHastaDias(pagadoHasta, 30 * meses);

/// Nuevo pagado_hasta estimado sumando `dias` exactos.
String previewHastaDias(String? pagadoHasta, int dias) {
  final hoy = _hoyIso();
  final base = (pagadoHasta != null && pagadoHasta.compareTo(hoy) > 0)
      ? pagadoHasta
      : hoy;
  final p = base.split('-').map(int.parse).toList();
  final d = DateTime(p[0], p[1], p[2]).add(Duration(days: dias));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

bool _esPendiente(dynamic v) => v == 0 || v == false;

/// Dinero en efectivo que el entrenador logueado aún no le entrega al dueño.
///
/// Regla del servidor (ronda 14): efectivo registrado por entrenador queda
/// `entregado=0`; transferencia o registros del dueño quedan entregados.
/// Cuando el dueño confirma en el bot, el espejo se actualiza y esto baja solo.
Future<double> pendienteEntrega(int? telegramId) async {
  if (telegramId == null) return 0;
  double total = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) == telegramId &&
        (p['metodo'] as String?) == 'efectivo' &&
        _esPendiente(p['entregado'])) {
      total += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) == telegramId &&
        _esPendiente(d['entregado'])) {
      total += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return total;
}

/// Desglose del pendiente: (mensualidades, diarios).
Future<
    (
      List<Map<String, dynamic>>,
      List<Map<String, dynamic>>
    )> detallePendiente(int? telegramId) async {
  final mens = <Map<String, dynamic>>[];
  final diarios = <Map<String, dynamic>>[];
  if (telegramId == null) return (mens, diarios);
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) == telegramId &&
        (p['metodo'] as String?) == 'efectivo' &&
        _esPendiente(p['entregado'])) {
      mens.add(p);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) == telegramId &&
        _esPendiente(d['entregado'])) {
      diarios.add(d);
    }
  }
  mens.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  diarios.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return (mens, diarios);
}
