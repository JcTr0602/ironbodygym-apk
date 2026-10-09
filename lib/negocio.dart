/// Lógica de negocio en el teléfono (espejo de ironbody/db/clientes.py).
///
/// Trabaja sobre los mapas decodificados del espejo `clientes`.
library;

import 'dart:convert';

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

/// Tiempo relativo legible: "hace 2 horas", "ayer", etc. (v1.0.14)
String tiempoRelativo(String? iso) {
  if (iso == null || iso.isEmpty) return 'Sin accesos registrados';
  try {
    final dt = DateTime.parse(iso).toLocal();
    final ahora = DateTime.now();
    final diff = ahora.difference(dt);
    if (diff.isNegative) return 'ahora mismo';
    if (diff.inMinutes < 1) return 'ahora mismo';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return 'hace $m minuto${m == 1 ? '' : 's'}';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return 'hace $h hora${h == 1 ? '' : 's'}';
    }
    if (diff.inDays == 1) return 'ayer';
    if (diff.inDays < 7) {
      final d = diff.inDays;
      return 'hace $d día${d == 1 ? '' : 's'}';
    }
    if (diff.inDays < 30) {
      final s = (diff.inDays / 7).floor();
      return 'hace $s semana${s == 1 ? '' : 's'}';
    }
    if (diff.inDays < 365) {
      final me = (diff.inDays / 30).floor();
      return 'hace $me mes${me == 1 ? '' : 'es'}';
    }
    final a = (diff.inDays / 365).floor();
    return 'hace $a año${a == 1 ? '' : 's'}';
  } catch (_) {
    return 'Sin accesos registrados';
  }
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
///
/// v1.0.14: la base es lo más lejano entre el pagado_hasta actual y la
/// fecha del pago (no "hoy"). Así, si el cliente paga por adelantado,
/// los días restantes no se pierden.
String previewHastaDias(String? pagadoHasta, int dias,
    {String? fechaPago}) {
  final fp = fechaPago ?? _hoyIso();
  final base = (pagadoHasta != null && pagadoHasta.compareTo(fp) > 0)
      ? pagadoHasta
      : fp;
  final p = base.split('-').map(int.parse).toList();
  final d = DateTime(p[0], p[1], p[2]).add(Duration(days: dias));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

bool esPendiente(dynamic v) => v == 0 || v == false;

/// Precios vigentes (del espejo de ajustes).
Future<Map<String, double>> preciosVigentes() async {
  final aj = await LocalDb.instance.getAjustes();
  return {
    'mensual': (aj['mensualidad'] as num?)?.toDouble() ?? 2000,
    'transfer': (aj['transferencia'] as num?)?.toDouble() ?? 2500,
    'diario': (aj['pago_diario'] as num?)?.toDouble() ?? 200,
    'semanal': (aj['pago_semanal'] as num?)?.toDouble() ?? 600,
    'quincenal': (aj['pago_quincenal'] as num?)?.toDouble() ?? 1200,
  };
}

/// Monto en efectivo que representa una op encolada (0 si no aplica).
/// Solo cuenta lo que el entrenador cobró en efectivo y aún no entrega.
double _montoEfectivoOp(
    Map<String, dynamic> op, Map<String, double> pr) {
  final tipo = '${op['tipo']}';
  Map<String, dynamic> payload;
  try {
    payload = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
  } catch (_) {
    return 0;
  }
  double mensualidad(String periodo, int meses, String metodo,
      double? montoManual) {
    if (metodo != 'efectivo') return 0;
    if (periodo == 'personalizado') return montoManual ?? 0;
    if (periodo == 'semanal') return pr['semanal']!;
    if (periodo == 'quincenal') return pr['quincenal']!;
    return pr['mensual']! * meses;
  }

  if (tipo == 'pago_mensual') {
    return mensualidad(
        '${payload['periodo'] ?? 'mensual'}',
        (payload['meses'] as num?)?.toInt() ?? 1,
        '${payload['metodo'] ?? 'efectivo'}',
        (payload['monto'] as num?)?.toDouble());
  }
  if (tipo == 'inscribir') {
    // la inscripción inicial se cobra en efectivo
    return mensualidad(
        '${payload['periodo'] ?? 'mensual'}',
        (payload['meses'] as num?)?.toInt() ?? 1,
        'efectivo',
        (payload['monto'] as num?)?.toDouble());
  }
  if (tipo == 'pago_diario') {
    final cant = (payload['cantidad'] as num?)?.toInt() ?? 0;
    return cant * pr['diario']!;
  }
  return 0;
}

/// Dinero en efectivo que el entrenador logueado aún no le entrega al dueño.
///
/// Regla del servidor (ronda 14): efectivo registrado por entrenador queda
/// `entregado=0`; transferencia o registros del dueño quedan entregados.
/// Cuando el dueño confirma en el bot, el espejo se actualiza y esto baja solo.
/// Incluye las operaciones encoladas aún no sincronizadas (son del
/// entrenador logueado por definición).
Future<double> pendienteEntrega(int? telegramId) async {
  if (telegramId == null) return 0;
  double total = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) == telegramId &&
        (p['metodo'] as String?) == 'efectivo' &&
        esPendiente(p['entregado'])) {
      total += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) == telegramId &&
        esPendiente(d['entregado'])) {
      total += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  final pr = await preciosVigentes();
  for (final op in await LocalDb.instance.pendingOps()) {
    total += _montoEfectivoOp(op, pr);
  }
  return total;
}

/// v1.0.15: total pendiente a recoger por el dueño.
/// Suma lo que todos los entrenadores tienen pendiente de entregar.
/// Con `excluirTelegramId` se omiten los cobros hechos por esa persona
/// (el dueño no tiene nada que recogerse a sí mismo).
Future<double> pendienteRecoger({int? excluirTelegramId}) async {
  double total = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['metodo'] as String?) == 'efectivo' &&
        esPendiente(p['entregado'])) {
      final tid = p['telegram_user_id'] as int?;
      if (excluirTelegramId != null && tid == excluirTelegramId) continue;
      total += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (esPendiente(d['entregado'])) {
      final tid = d['registrado_por'] as int?;
      if (excluirTelegramId != null && tid == excluirTelegramId) continue;
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

/// Nº de clientes distintos con al menos un pago con fecha en el mes
/// calendario actual (espejo `pagos`).
Future<int> pagosRealizadosMes() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final ids = <int>{};
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    final f = p['fecha'] as String?;
    if (f != null && f.startsWith(pref)) {
      final cid = p['cliente_id'] as int?;
      if (cid != null) ids.add(cid);
    }
  }
  return ids.length;
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

/// Fecha de nacimiento desde el carnet (6 primeros dígitos = AAMMDD).
DateTime? fechaNacDeCarnet(String? carnet) {
  final d = (carnet ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length < 6) return null;
  final hoy = DateTime.now();
  var anio = int.tryParse(d.substring(0, 2)) ?? 0;
  final mes = int.tryParse(d.substring(2, 4)) ?? 0;
  final dia = int.tryParse(d.substring(4, 6)) ?? 0;
  if (mes < 1 || mes > 12 || dia < 1 || dia > 31) return null;
  anio += (anio <= hoy.year % 100) ? 2000 : 1900;
  try {
    final f = DateTime(anio, mes, dia);
    if (f.month != mes || f.day != dia) return null;
    return f;
  } catch (_) {
    return null;
  }
}

/// True si el carnet indica menos de 18 años (precio reducido).
bool esMenor(String? carnet) {
  final nac = fechaNacDeCarnet(carnet);
  if (nac == null) return false;
  final hoy = DateTime.now();
  var edad = hoy.year - nac.year;
  if (hoy.month < nac.month ||
      (hoy.month == nac.month && hoy.day < nac.day)) {
    edad--;
  }
  return edad < 18;
}

/// Precio mensual para menores de 18 años.
const precioMenorMensual = 1500.0;

/// Clientes que cumplen años en los próximos [dias] (incluye hoy).
/// Cada mapa trae '_dias_para' (días que faltan) y '_cumple' (edad que cumple).
Future<List<Map<String, dynamic>>> cumpleanosProximos(
    {int dias = 7}) async {
  final hoy = DateTime.now();
  final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
  final rows = await _activos();
  final res = <Map<String, dynamic>>[];
  for (final c in rows) {
    final nac = fechaNacDeCarnet('${c['carnet'] ?? ''}');
    if (nac == null) continue;
    var proximo = DateTime(hoyDia.year, nac.month, nac.day);
    if (proximo.isBefore(hoyDia)) {
      proximo = DateTime(hoyDia.year + 1, nac.month, nac.day);
    }
    final falta = proximo.difference(hoyDia).inDays;
    if (falta <= dias) {
      res.add({
        ...c,
        '_dias_para': falta,
        '_cumple': proximo.year - nac.year,
      });
    }
  }
  res.sort(
      (a, b) => (a['_dias_para'] as int).compareTo(b['_dias_para'] as int));
  return res;
}

/// Clientes que cumplen años en el mes actual.
/// Cada mapa trae '_dia' (día del mes), '_fecha_cumple' (DD/MM),
/// '_cumple' (edad que cumple) y '_paso' (true si ya pasó este mes).
/// Ordenados por día del mes.
Future<List<Map<String, dynamic>>> cumpleanosDelMes() async {
  final hoy = DateTime.now();
  final rows = await _activos();
  final res = <Map<String, dynamic>>[];
  for (final c in rows) {
    final nac = fechaNacDeCarnet('${c['carnet'] ?? ''}');
    if (nac == null) continue;
    if (nac.month != hoy.month) continue;
    final dia = nac.day;
    final etiqueta =
        '${dia.toString().padLeft(2, '0')}/${hoy.month.toString().padLeft(2, '0')}';
    res.add({
      ...c,
      '_dia': dia,
      '_fecha_cumple': etiqueta,
      '_cumple': hoy.year - nac.year,
      '_paso': dia < hoy.day,
    });
  }
  res.sort((a, b) => (a['_dia'] as int).compareTo(b['_dia'] as int));
  return res;
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

/// v1.0.15: pagos diarios de una fecha específica (para reporte).
Future<List<Map<String, dynamic>>> diariosDeFecha(
    String fechaIso) async {
  final todos = await LocalDb.instance.allMirror('pagos_diarios');
  final res = todos
      .where((d) => (d['fecha'] as String?) == fechaIso)
      .toList();
  res.sort((a, b) =>
      '${b['registrado_por_nombre']}'.compareTo('${a['registrado_por_nombre']}'));
  return res;
}

/// v1.0.15: resumen de pagos diarios por turno para una fecha.
/// Devuelve {mañana: {cantidad, total}, tarde: {cantidad, total}}.
Future<Map<String, Map<String, double>>> resumenDiarioPorTurno(
    String fechaIso) async {
  final datos = await diariosDeFecha(fechaIso);
  final res = {
    'mañana': {'cantidad': 0.0, 'total': 0.0},
    'tarde': {'cantidad': 0.0, 'total': 0.0},
  };
  for (final d in datos) {
    final turno = '${d['turno'] ?? 'mañana'}';
    final key = turno == 'tarde' ? 'tarde' : 'mañana';
    res[key]!['cantidad'] =
        res[key]!['cantidad']! + ((d['cantidad'] as num?)?.toDouble() ?? 0);
    res[key]!['total'] =
        res[key]!['total']! + ((d['total'] as num?)?.toDouble() ?? 0);
  }
  return res;
}

/// v1.0.15: totales de pagos diarios de los últimos N días.
/// Devuelve lista de {fecha, total} ordenada cronológicamente.
Future<List<Map<String, dynamic>>> totalesDiariosUltimos(
    int dias) async {
  final todos = await LocalDb.instance.allMirror('pagos_diarios');
  final porFecha = <String, double>{};
  for (final d in todos) {
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      porFecha[dia] =
          (porFecha[dia] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
    }
  }
  final hoy = DateTime.now();
  final res = <Map<String, dynamic>>[];
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  for (var i = dias - 1; i >= 0; i--) {
    final fecha = iso(hoy.subtract(Duration(days: i)));
    res.add({'fecha': fecha, 'total': porFecha[fecha] ?? 0.0});
  }
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
        esPendiente(p['entregado'])) {
      mens.add(p);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) == telegramId &&
        esPendiente(d['entregado'])) {
      diarios.add(d);
    }
  }
  mens.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  diarios.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return (mens, diarios);
}

/// Historial diario del entrenador: lista de días con lo cobrado,
/// desglose por método y detalle de operaciones. Del espejo local.
/// Cada día: {fecha, cobrado, efectivo, transferencia, ops}.
Future<List<Map<String, dynamic>>> historialTurno(int? telegramId,
    {int dias = 30}) async {
  if (telegramId == null) return [];
  final nombres = <int, String>{};
  for (final c in await LocalDb.instance.allMirror('clientes')) {
    final id = c['id'] as int?;
    if (id != null) nombres[id] = '${c['nombre'] ?? ''}';
  }
  final porDia = <String, Map<String, dynamic>>{};
  void suma(String fecha, double monto, String metodo,
      String etiqueta) {
    final e = porDia.putIfAbsent(fecha, () => {
          'fecha': fecha,
          'cobrado': 0.0,
          'efectivo': 0.0,
          'transferencia': 0.0,
          'ops': <Map<String, String>>[],
        });
    e['cobrado'] = (e['cobrado'] as double) + monto;
    if (metodo == 'transferencia') {
      e['transferencia'] = (e['transferencia'] as double) + monto;
    } else {
      e['efectivo'] = (e['efectivo'] as double) + monto;
    }
    (e['ops'] as List<Map<String, String>>)
        .add({'etiqueta': etiqueta, 'monto': fmtMonto(monto)});
  }

  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
    final f = '${p['fecha'] ?? ''}';
    if (f.length < 10) continue;
    final cid = p['cliente_id'] as int?;
    final quien = nombres[cid] ?? 'Cliente $cid';
    final metodo = '${p['metodo'] ?? 'efectivo'}';
    suma(f.substring(0, 10), (p['monto'] as num?)?.toDouble() ?? 0,
        metodo, '$quien · ${p['periodo'] ?? 'mensual'} ($metodo)');
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    final f = '${d['fecha'] ?? ''}';
    if (f.length < 10) continue;
    suma(f.substring(0, 10), (d['total'] as num?)?.toDouble() ?? 0,
        'efectivo',
        'Diario ${d['turno'] ?? ''} x${d['cantidad'] ?? '?'}');
  }
  final lista = porDia.values.toList()
    ..sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return lista.take(dias).toList();
}

/// Última entrega confirmada por Jc: el pago con entregado=1 más reciente
/// del entrenador. {fecha, monto} o null si nunca hubo.
Future<Map<String, dynamic>?> ultimaEntregaConfirmada(
    int? telegramId) async {
  if (telegramId == null) return null;
  String? fecha;
  double monto = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
    if (esPendiente(p['entregado'])) continue;
    final f = p['fecha'] as String?;
    if (f != null && (fecha == null || f.compareTo(fecha) > 0)) {
      fecha = f;
      monto = (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    if (esPendiente(d['entregado'])) continue;
    final f = d['fecha'] as String?;
    if (f != null && (fecha == null || f.compareTo(fecha) > 0)) {
      fecha = f;
      monto = (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  if (fecha == null) return null;
  return {'fecha': fecha, 'monto': monto};
}

/// Total cobrado por el entrenador en el mes calendario actual.
Future<double> cobradoMes(int? telegramId) async {
  if (telegramId == null) return 0;
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double t = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
    if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return t;
}

/// Pendiente a entregar agrupado por entrenador (vista del admin).
/// Lista de {id, nombre, total, n} ordenada por total desc.
/// Con `excluirTid` se omite a ese entrenador (el dueño no se lista
/// a sí mismo en "pendiente a recoger").
///
/// Detalle de cada movimiento pendiente de un entrenador (v1.0.16).
/// Lista de {tipo, ...} donde tipo es 'pago' o 'diario':
/// - pago: {pago_id, cliente_id, cliente_nombre, monto, fecha, periodo,
///          metodo, meses, dias, es_inscripcion}
/// - diario: {diario_id, fecha, turno, cantidad, total, nota}
Future<List<Map<String, dynamic>>> detallePendienteEntrenador(
    int tid) async {
  final items = <Map<String, dynamic>>[];
  // Mapa cliente_id -> {nombre, fecha_inscripcion} (una sola pasada)
  final clientes = <int, Map<String, String>>{};
  for (final c in await LocalDb.instance.allMirror('clientes')) {
    final id = (c['id'] as num?)?.toInt();
    if (id == null) continue;
    clientes[id] = {
      'nombre': '${c['nombre'] ?? 'Cliente $id'}',
      'fecha_inscripcion': '${c['fecha_inscripcion'] ?? ''}',
    };
  }
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['metodo'] as String?) != 'efectivo') continue;
    if (!esPendiente(p['entregado'])) continue;
    if ((p['telegram_user_id'] as int?) != tid) continue;
    final cid = (p['cliente_id'] as num?)?.toInt() ?? 0;
    final cli = clientes[cid];
    final fecha = '${p['fecha'] ?? ''}';
    items.add({
      'tipo': 'pago',
      'pago_id': (p['id'] as num?)?.toInt(),
      'cliente_id': cid,
      'cliente_nombre': cli?['nombre'] ?? 'Cliente $cid',
      'monto': (p['monto'] as num?)?.toDouble() ?? 0,
      'fecha': fecha,
      'periodo': '${p['periodo'] ?? 'mensual'}',
      'metodo': '${p['metodo'] ?? 'efectivo'}',
      'meses': (p['meses'] as num?)?.toInt() ?? 1,
      'dias': (p['dias'] as num?)?.toInt() ?? 0,
      // inscripción si el pago coincide con la fecha de inscripción
      'es_inscripcion':
          cli != null && (cli['fecha_inscripcion'] ?? '').isNotEmpty && fecha.startsWith(cli['fecha_inscripcion']!),
    });
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    if ((d['registrado_por'] as int?) != tid) continue;
    items.add({
      'tipo': 'diario',
      'diario_id': (d['id'] as num?)?.toInt(),
      'fecha': '${d['fecha'] ?? ''}',
      'turno': '${d['turno'] ?? ''}',
      'cantidad': (d['cantidad'] as num?)?.toInt() ?? 0,
      'total': (d['total'] as num?)?.toDouble() ?? 0,
      'nota': '${d['nota'] ?? ''}',
    });
  }
  items.sort((a, b) =>
      '${b['fecha']}'.compareTo('${a['fecha']}'));
  return items;
}

Future<List<Map<String, dynamic>>> pendientePorEntrenador(
    {int? excluirTid}) async {
  final mapa = <int, Map<String, dynamic>>{};
  void suma(int id, String nombre, double monto) {
    final e = mapa.putIfAbsent(id,
        () => {'id': id, 'nombre': nombre, 'total': 0.0, 'n': 0});
    e['total'] = (e['total'] as double) + monto;
    e['n'] = (e['n'] as int) + 1;
  }

  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['metodo'] as String?) != 'efectivo') continue;
    if (!esPendiente(p['entregado'])) continue;
    final tid = p['telegram_user_id'] as int?;
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    suma(tid, '${p['registrado_por'] ?? 'Entrenador $tid'}',
        (p['monto'] as num?)?.toDouble() ?? 0);
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    final tid = d['registrado_por'] as int?;
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    suma(tid, '${d['registrado_por_nombre'] ?? 'Entrenador $tid'}',
        (d['total'] as num?)?.toDouble() ?? 0);
  }
  final l = mapa.values.toList()
    ..sort(
        (a, b) => (b['total'] as double).compareTo(a['total'] as double));
  return l;
}

/// Ingresos del mes calendario actual (espejo `pagos` + diarios).
/// v1.0.15: ingresos del mes anterior (para comparativa).
Future<double> ingresosMesAnterior() async {
  final n = DateTime.now();
  var mes = n.month - 1;
  var anio = n.year;
  if (mes < 1) {
    mes = 12;
    anio--;
  }
  final pref = '${anio.toString().padLeft(4, '0')}-'
      '${mes.toString().padLeft(2, '0')}';
  double t = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return t;
}

/// v1.0.15: desglose de ingresos por método (efectivo vs transferencia).
Future<Map<String, double>> ingresosPorMetodo() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double efectivo = 0, transferencia = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
      final m = (p['monto'] as num?)?.toDouble() ?? 0;
      if ('${p['metodo']}' == 'transferencia') {
        transferencia += m;
      } else {
        efectivo += m;
      }
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      efectivo += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return {'efectivo': efectivo, 'transferencia': transferencia};
}

/// v1.0.15: desglose mensualidades vs pago diario.
Future<Map<String, double>> ingresosPorTipo() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double mensual = 0, diario = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
      mensual += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      diario += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return {'mensual': mensual, 'diario': diario};
}

/// v1.0.15: proyección de cierre de mes.
Future<double> proyeccionMes() async {
  final n = DateTime.now();
  final dia = n.day;
  final diasMes = DateTime(n.year, n.month + 1, 0).day;
  if (dia < 1) return 0;
  final actual = await ingresosMes();
  return actual / dia * diasMes;
}

/// v1.0.15: mejor y peor día del mes.
Future<Map<String, Map<String, dynamic>>> mejorPeorDia() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porDia = <String, double>{};
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    final f = '${p['fecha'] ?? ''}';
    if (f.startsWith(pref) && f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((p['monto'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    final f = '${d['fecha'] ?? ''}';
    if (f.startsWith(pref) && f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
    }
  }
  if (porDia.isEmpty) return {};
  var mejor = porDia.entries.first;
  var peor = porDia.entries.first;
  for (final e in porDia.entries) {
    if (e.value > mejor.value) mejor = e;
    if (e.value < peor.value) peor = e;
  }
  return {
    'mejor': {'dia': mejor.key, 'monto': mejor.value},
    'peor': {'dia': peor.key, 'monto': peor.value},
  };
}

/// v1.0.15: clientes nuevos este mes.
Future<int> nuevosEsteMes() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  int c = 0;
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    final f = '${cl['creado'] ?? cl['fecha_inscripcion'] ?? ''}';
    if (f.startsWith(pref)) c++;
  }
  return c;
}

/// v1.0.15: clientes por vencer en 7 días.
Future<List<Map<String, dynamic>>> porVencer7Dias() async {
  final hoy = DateTime.now();
  final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
  final limite = hoyDia.add(const Duration(days: 7));
  final res = <Map<String, dynamic>>[];
  for (final c in await LocalDb.instance.allMirror('clientes')) {
    try {
      final ph = '${c['pagado_hasta'] ?? ''}';
      if (ph.length < 10) continue;
      final v = DateTime.parse(ph.substring(0, 10));
      if (v.isAfter(hoyDia.subtract(const Duration(days: 1))) &&
          !v.isAfter(limite)) {
        res.add(c);
      }
    } catch (_) {}
  }
  res.sort((a, b) => '${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}'));
  return res;
}

/// v1.0.15: ingresos últimos 30 días (para gráfico extendido).
Future<List<Map<String, dynamic>>> ingresosUltimos30Dias() async {
  final hoy = DateTime.now();
  final res = <Map<String, dynamic>>[];
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  const dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  for (var i = 29; i >= 0; i--) {
    final dia = hoy.subtract(Duration(days: i));
    final diaIso = iso(dia);
    double t = 0;
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final f = '${p['fecha'] ?? ''}';
      if (f.length >= 10 && f.substring(0, 10) == diaIso) {
        t += (p['monto'] as num?)?.toDouble() ?? 0;
      }
    }
    for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
      final f = '${d['fecha'] ?? ''}';
      if (f.length >= 10 && f.substring(0, 10) == diaIso) {
        t += (d['total'] as num?)?.toDouble() ?? 0;
      }
    }
    res.add({
      'dia': dias[dia.weekday - 1],
      'fecha': diaIso,
      'monto': t,
    });
  }
  return res;
}

/// v1.0.15: ranking de entrenadores por cobros del mes.
Future<List<Map<String, dynamic>>> rankingEntrenadores() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porEntrenador = <String, double>{};
  final nombres = <String, String>{};
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
      final ent = '${p['entrenador'] ?? p['creado_por'] ?? '?'}';
      porEntrenador[ent] =
          (porEntrenador[ent] ?? 0) + ((p['monto'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      final ent = '${d['entrenador'] ?? d['creado_por'] ?? '?'}';
      porEntrenador[ent] =
          (porEntrenador[ent] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
    }
  }
  final res = porEntrenador.entries
      .map((e) => {
            'entrenador': e.key,
            'nombre': nombres[e.key] ?? e.key,
            'total': e.value,
          })
      .toList();
  res.sort(
      (a, b) => (b['total'] as double).compareTo(a['total'] as double));
  return res;
}

/// v1.0.15: clientes inactivos (pagado_hasta vencido hace 90+ días).
Future<int> inactivosCount() async {
  final limite = DateTime.now().subtract(const Duration(days: 90));
  int c = 0;
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    try {
      final ph = '${cl['pagado_hasta'] ?? ''}';
      if (ph.length < 10) continue;
      final v = DateTime.parse(ph.substring(0, 10));
      if (v.isBefore(limite)) c++;
    } catch (_) {}
  }
  return c;
}

Future<double> ingresosMes() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double t = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return t;
}

/// v1.0.16: mapa fecha (YYYY-MM-DD) -> total ingresos del día,
/// incluyendo pagos mensuales Y pagos diarios. Centraliza el cálculo
/// para que tarjetas, gráficos y desgloses usen los mismos números.
Future<Map<String, double>> ingresosPorDia() async {
  final porDia = <String, double>{};
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((p['monto'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
    }
  }
  return porDia;
}

/// Ingresos de hoy (espejo `pagos` + diarios). v1.0.8.
Future<double> ingresosHoy() async {
  final hoy = _hoyIso();
  double t = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return t;
}

/// Ingresos de los últimos 7 días (espejo `pagos` + diarios). v1.0.8.
Future<double> ingresosSemana() async {
  final hoy = DateTime.now();
  final desde = hoy.subtract(const Duration(days: 6));
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  final desdeIso = iso(desde);
  final hoyIso = iso(hoy);
  double t = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 && dia.compareTo(hoyIso) <= 0) {
        t += (p['monto'] as num?)?.toDouble() ?? 0;
      }
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 && dia.compareTo(hoyIso) <= 0) {
        t += (d['total'] as num?)?.toDouble() ?? 0;
      }
    }
  }
  return t;
}

/// Pagos del período para desglose (v1.0.11).
/// periodo: 'hoy', 'semana', 'mes'. Devuelve lista con monto y método.
Future<List<Map<String, dynamic>>> pagosDelPeriodo(
    String periodo) async {
  String desdeIso, hastaIso;
  final hoy = DateTime.now();
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  if (periodo == 'hoy') {
    desdeIso = hastaIso = iso(hoy);
  } else if (periodo == 'semana') {
    desdeIso = iso(hoy.subtract(const Duration(days: 6)));
    hastaIso = iso(hoy);
  } else {
    desdeIso =
        '${hoy.year.toString().padLeft(4, '0')}-${hoy.month.toString().padLeft(2, '0')}-01';
    hastaIso = iso(hoy);
  }
  final out = <Map<String, dynamic>>[];
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 &&
          dia.compareTo(hastaIso) <= 0) {
        out.add({
          'monto': (p['monto'] as num?)?.toDouble() ?? 0,
          'metodo': '${p['metodo'] ?? 'efectivo'}',
        });
      }
    }
  }
  // v1.0.16: incluir pagos diarios (antes se excluían del desglose)
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 &&
          dia.compareTo(hastaIso) <= 0) {
        out.add({
          'monto': (d['total'] as num?)?.toDouble() ?? 0,
          'metodo': 'efectivo',
        });
      }
    }
  }
  return out;
}

/// Ingresos por día de los últimos 7 días (v1.0.8).
/// Devuelve lista de {dia: 'Lun', monto: 123.0} ordenada de más antiguo a hoy.
/// v1.0.16: usa ingresosPorDia() centralizado (incluye pagos diarios).
Future<List<Map<String, dynamic>>> ingresosUltimos7Dias() async {
  final hoy = DateTime.now();
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  const diasSem = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  final porDia = await ingresosPorDia();
  final resultado = <Map<String, dynamic>>[];
  for (int i = 6; i >= 0; i--) {
    final d = hoy.subtract(Duration(days: i));
    final diaIso = iso(d);
    resultado.add({
      'dia': diasSem[d.weekday - 1],
      'monto': porDia[diaIso] ?? 0.0,
    });
  }
  return resultado;
}

/// Nº de clientes activos. v1.0.8.
Future<int> activosCount() async => (await _activos()).length;

/// Inscripciones del mes calendario actual.
Future<int> inscripcionesMes() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  var c = 0;
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    if ('${cl['fecha_inscripcion'] ?? ''}'.startsWith(pref)) c++;
  }
  return c;
}

/// Inscripciones del mes agrupadas por entrenador (v1.0.7).
/// Devuelve lista de {nombre, cantidad}.
Future<List<Map<String, dynamic>>> inscripcionesPorEntrenador() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porEntrenador = <String, int>{};
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    if ('${cl['fecha_inscripcion'] ?? ''}'.startsWith(pref)) {
      final nombre =
          (cl['registrado_por_nombre'] as String?)?.trim() ?? 'Desconocido';
      porEntrenador[nombre] = (porEntrenador[nombre] ?? 0) + 1;
    }
  }
  final lista = porEntrenador.entries
      .map((e) => {'nombre': e.key, 'cantidad': e.value})
      .toList();
  lista.sort((a, b) =>
      ((b['cantidad'] as int)).compareTo((a['cantidad'] as int)));
  return lista;
}

/// Nº de morosos: clientes activos con pagado_hasta anterior a hoy.
Future<int> morosos() async {
  final hoy = _hoyIso();
  var c = 0;
  for (final cl in await _activos()) {
    final ph = cl['pagado_hasta'] as String?;
    if (ph != null && ph.compareTo(hoy) < 0) c++;
  }
  return c;
}

/// Gastos del espejo, ordenados por fecha descendente.
Future<List<Map<String, dynamic>>> gastosTodos() async {
  final rows = await LocalDb.instance.allMirror('gastos');
  rows.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return rows;
}

/// Total de gastos de un día (fecha ISO yyyy-MM-dd).
Future<double> gastosDe(String fechaIso) async {
  double t = 0;
  for (final g in await LocalDb.instance.allMirror('gastos')) {
    if ('${g['fecha'] ?? ''}'.length >= 10 &&
        '${g['fecha']}'.substring(0, 10) == fechaIso) {
      t += (g['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  return t;
}

/// Cobrado hoy por método (cierre de caja): {efectivo, transferencia}.
Future<Map<String, double>> cobradoHoyPorMetodo() async {
  final hoy = _hoyIso();
  double ef = 0, tr = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ('${p['fecha'] ?? ''}'.length < 10 ||
        '${p['fecha']}'.substring(0, 10) != hoy) {
      continue;
    }
    final m = (p['monto'] as num?)?.toDouble() ?? 0;
    if ('${p['metodo']}' == 'transferencia') {
      tr += m;
    } else {
      ef += m;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ('${d['fecha'] ?? ''}'.length >= 10 &&
        '${d['fecha']}'.substring(0, 10) == hoy) {
      ef += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return {'efectivo': ef, 'transferencia': tr};
}
