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
  final pr = await preciosVigentes();
  for (final op in await LocalDb.instance.pendingOps()) {
    total += _montoEfectivoOp(op, pr);
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
    if (_esPendiente(p['entregado'])) continue;
    final f = p['fecha'] as String?;
    if (f != null && (fecha == null || f.compareTo(fecha) > 0)) {
      fecha = f;
      monto = (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    if (_esPendiente(d['entregado'])) continue;
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
Future<List<Map<String, dynamic>>> pendientePorEntrenador() async {
  final mapa = <int, Map<String, dynamic>>{};
  void suma(int id, String nombre, double monto) {
    final e = mapa.putIfAbsent(id,
        () => {'id': id, 'nombre': nombre, 'total': 0.0, 'n': 0});
    e['total'] = (e['total'] as double) + monto;
    e['n'] = (e['n'] as int) + 1;
  }

  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['metodo'] as String?) != 'efectivo') continue;
    if (!_esPendiente(p['entregado'])) continue;
    final tid = p['telegram_user_id'] as int?;
    if (tid == null) continue;
    suma(tid, '${p['registrado_por'] ?? 'Entrenador $tid'}',
        (p['monto'] as num?)?.toDouble() ?? 0);
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!_esPendiente(d['entregado'])) continue;
    final tid = d['registrado_por'] as int?;
    if (tid == null) continue;
    suma(tid, '${d['registrado_por_nombre'] ?? 'Entrenador $tid'}',
        (d['total'] as num?)?.toDouble() ?? 0);
  }
  final l = mapa.values.toList()
    ..sort(
        (a, b) => (b['total'] as double).compareTo(a['total'] as double));
  return l;
}

/// Ingresos del mes calendario actual (espejo `pagos` + diarios).
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
