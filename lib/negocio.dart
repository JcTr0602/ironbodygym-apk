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

/// Días restantes de vigencia (negativo si vencido, null si sin pagos).
int? diasRestantes(String? pagadoHasta) {
  if (pagadoHasta == null || pagadoHasta.length < 10) return null;
  final hoy = DateTime.now();
  final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
  final p = pagadoHasta.substring(0, 10).split('-').map(int.parse).toList();
  final ph = DateTime(p[0], p[1], p[2]);
  return ph.difference(hoyDia).inDays;
}

/// Texto de estado de mensualidad para listas.
String textoEstado(String? pagadoHasta) {
  final d = diasRestantes(pagadoHasta);
  if (d == null) return 'Sin pagos registrados';
  if (d < 0) return 'Vencido hace ${-d} día${-d == 1 ? '' : 's'}';
  if (d == 0) return 'Vence hoy';
  return '$d día${d == 1 ? '' : 's'} restantes';
}

/// Lista de clientes activos. Si `q` está vacío devuelve TODOS ordenados
/// por nombre; si no, filtra por nombre, carnet o teléfono.
Future<List<Map<String, dynamic>>> listaClientes([String q = '']) async {
  final nq = _norm(q);
  final digitos =
      q.replaceAll(RegExp(r'[^0-9]'), ''); // para carnet/teléfono
  final rows = await _activos();
  List<Map<String, dynamic>> res;
  if (nq.isEmpty && digitos.isEmpty) {
    res = rows;
  } else {
    res = rows.where((c) {
      final norm = (c['nombre_norm'] as String?) ?? _norm('${c['nombre']}');
      if (nq.isNotEmpty && norm.contains(nq)) return true;
      if (digitos.isNotEmpty) {
        for (final k in ['telefono', 'movil', 'carnet']) {
          final v = '${c[k] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
          if (v.contains(digitos)) return true;
        }
      }
      return false;
    }).toList();
  }
  res.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
  return res;
}

/// Clientes que vencen en los próximos `dias` (incluye hoy).
Future<List<Map<String, dynamic>>> porVencer({int dias = 3}) async {
  final hoy = _hoyIso();
  final limite = DateTime.now().add(Duration(days: dias));
  final limIso =
      '${limite.year.toString().padLeft(4, '0')}-${limite.month.toString().padLeft(2, '0')}-${limite.day.toString().padLeft(2, '0')}';
  final rows = await _activos();
  final res = rows.where((c) {
    final ph = c['pagado_hasta'] as String?;
    return ph != null &&
        ph.compareTo(hoy) >= 0 &&
        ph.compareTo(limIso) <= 0;
  }).toList();
  res.sort((a, b) => '${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}'));
  return res;
}

/// Clientes inactivos (papelera de reciclaje).
Future<List<Map<String, dynamic>>> clientesInactivos() async {
  final todos = await LocalDb.instance.allMirror('clientes');
  final res =
      todos.where((c) => c['estado'] != 'activo').toList();
  res.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
  return res;
}

/// Agrupa clientes activos por quién los inscribió (para el dueño).
Future<Map<String, List<Map<String, dynamic>>>> clientesPorEntrenador() async {
  final rows = await _activos();
  final mapa = <String, List<Map<String, dynamic>>>{};
  for (final c in rows) {
    final quien = '${c['registrado_por_nombre'] ?? '—'}';
    mapa.putIfAbsent(quien, () => []).add(c);
  }
  for (final l in mapa.values) {
    l.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
  }
  return mapa;
}

/// (cantidad de activos, pendientes de pago que restan en el mes,
/// estimado de cobro total del mes en CUP).
Future<(int, int, double)> resumenCartera(double mensualidad) async {
  final rows = await _activos();
  final n = DateTime.now();
  final finMes =
      '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${DateTime(n.year, n.month + 1, 0).day.toString().padLeft(2, '0')}';
  var pendientes = 0;
  for (final c in rows) {
    final ph = c['pagado_hasta'] as String?;
    if (ph == null || ph.compareTo(finMes) < 0) pendientes++;
  }
  return (rows.length, pendientes, pendientes * mensualidad);
}

/// Teléfono cubano válido: 8 dígitos empezando con 5.
bool validarTelefono(String v) {
  final d = v.replaceAll(RegExp(r'[^0-9]'), '');
  return d.length == 8 && d.startsWith('5');
}

/// Carnet: 6 a 11 dígitos (6 = fecha de nacimiento para menores sin carnet).
bool validarCarnet(String v) {
  final d = v.replaceAll(RegExp(r'[^0-9]'), '');
  return d.length >= 6 && d.length <= 11;
}

/// Edad calculada desde el carnet (los 6 primeros dígitos = AAMMDD).
int? edadDeCarnet(String? carnet) {
  final d = (carnet ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length < 6) return null;
  final hoy = DateTime.now();
  var anio = int.tryParse(d.substring(0, 2)) ?? 0;
  final mes = int.tryParse(d.substring(2, 4)) ?? 0;
  final dia = int.tryParse(d.substring(4, 6)) ?? 0;
  if (mes < 1 || mes > 12 || dia < 1 || dia > 31) return null;
  anio += (anio <= hoy.year % 100) ? 2000 : 1900;
  var edad = hoy.year - anio;
  if (hoy.month < mes || (hoy.month == mes && hoy.day < dia)) edad--;
  return edad < 0 || edad > 120 ? null : edad;
}

/// Posibles duplicados al inscribir (nombre parecido, carnet o teléfono igual).
Future<List<Map<String, dynamic>>> posiblesDuplicados(
    {required String nombre,
    String? carnet,
    String? telefono}) async {
  final rows = await _activos();
  final nn = _norm(nombre);
  final dc = (carnet ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  final dt = (telefono ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  final res = <Map<String, dynamic>>[];
  for (final c in rows) {
    final cn = (c['nombre_norm'] as String?) ?? _norm('${c['nombre']}');
    var motivo = '';
    if (dc.isNotEmpty &&
        '${c['carnet'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '') == dc) {
      motivo = 'mismo carnet';
    } else if (dt.isNotEmpty &&
        ('${c['telefono'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '') == dt ||
            '${c['movil'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '') == dt)) {
      motivo = 'mismo teléfono';
    } else if (nn.isNotEmpty && (cn.contains(nn) || nn.contains(cn))) {
      motivo = 'nombre parecido';
    }
    if (motivo.isNotEmpty) {
      res.add({...c, '_motivo': motivo});
    }
  }
  return res;
}

/// Pagos diarios de hoy (del espejo).
Future<List<Map<String, dynamic>>> diariosDeHoy() async {
  final hoy = _hoyIso();
  final todos = await LocalDb.instance.allMirror('pagos_diarios');
  final res =
      todos.where((d) => (d['fecha'] as String?) == hoy).toList();
  res.sort((a, b) =>
      '${b['registrado_por_nombre']}'.compareTo('${a['registrado_por_nombre']}'));
  return res;
}

/// Resumen del turno del entrenador: (cobrado hoy, pendiente a entregar).
Future<(double, double)> miTurnoHoy(int? telegramId) async {
  if (telegramId == null) return (0.0, 0.0);
  final hoy = _hoyIso();
  double cobrado = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) == telegramId &&
        (p['fecha'] as String?) == hoy) {
      cobrado += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) == telegramId &&
        (d['fecha'] as String?) == hoy) {
      cobrado += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  final pendiente = await pendienteEntrega(telegramId);
  return (cobrado, pendiente);
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
