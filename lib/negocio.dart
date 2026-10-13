/// Lógica de negocio en el teléfono (espejo de ironbody/db/clientes.py).
///
/// Trabaja sobre los mapas decodificados del espejo `clientes`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'auth.dart';
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

/// Ejecuta [fn] capturando errores de SQLite. Si la BD falla (I/O,
/// bloqueada, corrupta), retorna [fallback] en vez de propagar la
/// excepción a la UI. (v1.3: auditoría Gemini 2026-10-12)
///
/// ⚠️ NO usar en funciones financieras (ingresos, cobros, pendientes).
/// Un fallback de 0.0 haría pensar que no hay dinero. Esas funciones
/// deben propagar el error para que la UI muestre "Error cargando datos".
Future<T> conBdSegura<T>(Future<T> Function() fn, T fallback) async {
  try {
    return await fn();
  } catch (_) {
    return fallback;
  }
}

Future<List<Map<String, dynamic>>> _activos() async {
  // NOTA (auditoría Gemini): NO usar conBdSegura aquí. Si la BD falla,
  // la excepción debe propagarse para que la UI muestre "Error cargando"
  // en vez de una lista vacía que parece "no hay clientes".
  return LocalDb.instance.mirrorPorEstado('clientes', 'activo');
}

/// Búsqueda por nombre (usa nombre_norm si viene en el espejo).
/// v1.2.5 (A24): búsqueda tolerante.
/// - Insensible a tildes/mayúsculas (vía _norm).
/// - Multi-token: todos los tokens deben aparecer (en cualquier orden).
/// - Teléfonos: solo dígitos, match por prefijo vía FTS (ej. "5819"
///   encuentra "58191577").
/// v1.2.5-rev6 (Gemini #5): ya no carga todo el padrón ni corre Levenshtein
/// sobre él en el hilo UI. La vía rápida FTS trae solo las filas pedidas
/// por id; la tolerancia a typos corre en un isolate sobre candidatos
/// acotados (misma inicial que algún token de la búsqueda).
Future<List<Map<String, dynamic>>> buscarClientes(String q) async {
  final nq = _norm(q);
  if (nq.isEmpty) return [];
  final db = LocalDb.instance;
  final porId = <int, Map<String, dynamic>>{};
  Future<void> cargarPorIds(List<int> ids) async {
    for (final c in await db.mirrorPorIds('clientes', ids)) {
      final id = c['id'] as int?;
      if (id != null) porId[id] = c;
    }
  }

  // Si la query es numérica, buscar por teléfono primero (vía FTS).
  // v1.3 (auditoría Gemini): criterio refinado —
  // - Cadena estrictamente numérica de 4+ dígitos (permite prefijos como "5819")
  // - O contiene un segmento que empieza con 5 de 4+ dígitos (móviles Cuba)
  // Evita falsos positivos con "calle 42" pero preserva búsqueda por prefijo.
  final digitos = q.replaceAll(RegExp(r'[^0-9]'), '');
  final esSoloDigitos = RegExp(r'^\d{4,}$').hasMatch(q.trim());
  final tienePrefijoMovil =
      digitos.startsWith('5') && digitos.length >= 4;
  if (esSoloDigitos || tienePrefijoMovil) {
    final ids = await db.buscarClientesFtsIds(digitos, porTelefono: true);
    await cargarPorIds(ids);
    final porTel =
        porId.values.where((c) => c['estado'] == 'activo').toList();
    if (porTel.isNotEmpty) {
      porTel.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
      return porTel;
    }
    // Sin match por teléfono, se sigue a la búsqueda por nombre.
  }
  // Vía rápida por FTS5 (índice SQLite, no bloquea la UI).
  final ftsIds = await db.buscarClientesFtsIds(nq);
  await cargarPorIds(ftsIds);
  final vistos = <int>{};
  final resultado = <Map<String, dynamic>>[];
  for (final id in ftsIds) {
    final c = porId[id];
    if (c != null && c['estado'] == 'activo') {
      resultado.add(c);
      vistos.add(id);
    }
  }
  if (resultado.length >= 5) {
    resultado.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
    return resultado;
  }
  // Tolerancia a typos: en un isolate, solo sobre candidatos acotados
  // (misma inicial que algún token), no sobre todo el padrón.
  final tokens =
      nq.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final iniciales = tokens.map((t) => t[0]).toSet();
  final candIds = await db.buscarClientesCandidatos(iniciales);
  final nuevosIds = candIds.where((i) => !vistos.contains(i)).toList();
  await cargarPorIds(nuevosIds);
  final rankeados = await compute(_typoFallbackAislado, {
    'candidatos': [
      for (final id in nuevosIds)
        if (porId[id] != null && porId[id]!['estado'] == 'activo')
          {
            'id': id,
            'nombre': '${porId[id]!['nombre']}',
            'nombre_norm': (porId[id]!['nombre_norm'] as String?) ??
                _norm('${porId[id]!['nombre']}'),
          }
    ],
    'vistos': vistos.toList(),
    'tokens': tokens,
  });
  final resto = [
    for (final id in rankeados) porId[id],
  ]
      .whereType<Map<String, dynamic>>()
      .where((c) => c['estado'] == 'activo')
      .toList();
  return [...resultado, ...resto];
}

/// Tolerancia a typos para [buscarClientes]. Corre en un isolate (vía
/// compute): recibe mapas simples y devuelve los ids rankeados.
/// Debe ser función de nivel superior (requisito de compute).
List<int> _typoFallbackAislado(Map<String, dynamic> args) {
  final candidatos =
      (args['candidatos'] as List).cast<Map<String, dynamic>>();
  final vistos = (args['vistos'] as List).cast<int>().toSet();
  final tokens = (args['tokens'] as List).cast<String>();
  final porNombre = {for (final c in candidatos) c['id'] as int: c};
  final scored = <int, int>{};
  for (final c in candidatos) {
    final id = c['id'] as int;
    if (vistos.contains(id)) continue;
    final norm = '${c['nombre_norm']}';
    final palabras = norm.split(RegExp(r'\s+'));
    var ok = true;
    var score = 0;
    for (final t in tokens) {
      if (norm.contains(t)) {
        if (palabras.any((p) => p.startsWith(t))) score += 2;
        continue;
      }
      var mejor = 999;
      for (final p in palabras) {
        final d = _levenshtein(t, p);
        if (d < mejor) mejor = d;
      }
      final umbral = t.length >= 6 ? 2 : (t.length >= 4 ? 1 : 0);
      if (mejor <= umbral) {
        score += 1;
        continue;
      }
      ok = false;
      break;
    }
    if (ok) scored[id] = score;
  }
  final ids = scored.keys.toList();
  ids.sort((a, b) {
    final s = scored[b]!.compareTo(scored[a]!);
    if (s != 0) return s;
    return '${porNombre[a]!['nombre']}'
        .compareTo('${porNombre[b]!['nombre']}');
  });
  return ids;
}

/// Distancia de Levenshtein (para typos en búsqueda).
int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  // Solo necesitamos la fila anterior.
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    var curr = <int>[i];
    for (var j = 1; j <= b.length; j++) {
      final costo = a[i - 1] == b[j - 1] ? 0 : 1;
      curr.add([
        prev[j] + 1, // borrado
        curr[j - 1] + 1, // inserción
        prev[j - 1] + costo, // sustitución
      ].reduce((x, y) => x < y ? x : y));
    }
    prev = curr;
  }
  return prev[b.length];
}

/// Clientes al día: activos con pagado_hasta >= hoy (no vencidos).
/// v1.2.1: para el filtro "Al día" del resumen.
Future<List<Map<String, dynamic>>> clientesAlDia() async {
  final hoy = _hoyIso();
  final rows = await _activos();
  final res = rows.where((c) {
    final ph = c['pagado_hasta'] as String?;
    return ph != null && ph.compareTo(hoy) >= 0;
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
  final rows = await LocalDb.instance.mirrorPorIds('clientes', [id]);
  return rows.isEmpty ? null : rows.first;
}

/// Últimos pagos de un cliente (del espejo `pagos`).
Future<List<Map<String, dynamic>>> pagosDe(int clienteId,
    {int limit = 10}) async {
  final res = await LocalDb.instance
      .mirrorFiltrado('pagos', {'cliente_id': clienteId});
  res.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return res.take(limit).toList();
}

String fmtFecha(String? iso) {
  if (iso == null || iso.length < 10) return '—';
  final p = iso.substring(0, 10).split('-');
  return '${p[2]}/${p[1]}/${p[0]}';
}

/// Etiqueta legible del periodo de un pago: Mensualidad, Semana, etc.
/// Con [detallado] en true incluye el detalle de meses/días
/// ("3 meses", "Personalizado (15 días)").
String etiquetaPeriodo(Map<String, dynamic> p,
    {bool detallado = false}) {
  final periodo = '${p['periodo'] ?? 'mensual'}';
  switch (periodo) {
    case 'semanal':
      return 'Semana';
    case 'quincenal':
      return 'Quincena';
    case 'personalizado':
      if (!detallado) return 'Personalizado';
      final dias = (p['dias'] as num?)?.toInt() ?? 0;
      return 'Personalizado ($dias días)';
    default:
      if (!detallado) return 'Mensualidad';
      final meses = (p['meses'] as num?)?.toInt() ?? 1;
      return meses == 1 ? 'Mensualidad' : '$meses meses';
  }
}

/// true si [remota] es una versión semántica superior a [actual].
/// Compara por componentes numéricos: 1.1.10 > 1.1.2.
/// Ignora build metadata (+xxx) y trata pre-releases (1.2.3-beta) como
/// inferiores a la versión final (1.2.3).
bool esVersionMayor(String remota, String actual) {
  // Quita build metadata (+...) y separa pre-release (-...)
  String nucleo(String v) => v.split('+').first;
  String? preRelease(String v) {
    final n = nucleo(v);
    final idx = n.indexOf('-');
    return idx >= 0 ? n.substring(idx + 1) : null;
  }

  List<int> partes(String v) => nucleo(v)
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final r = partes(remota);
  final a = partes(actual);
  for (var i = 0; i < r.length || i < a.length; i++) {
    final rv = i < r.length ? r[i] : 0;
    final av = i < a.length ? a[i] : 0;
    if (rv != av) return rv > av;
  }
  // Núcleos iguales: una pre-release es menor que la final.
  final rPre = preRelease(remota);
  final aPre = preRelease(actual);
  if (rPre == null && aPre != null) return true;
  if (rPre != null && aPre == null) return false;
  return false;
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

/// v1.2.4 (Hark): texto de un total de venta con su equivalente en la
/// otra moneda cuando se conoce la tasa (CUP por 1 USD). Regla única para
/// venta, inscripción+venta, venta rápida e historial.
String textoTotalVenta(double total, String moneda, double? tasa) {
  final hayTasa = tasa != null && tasa > 0;
  if (moneda == 'USD') {
    return '${total.toStringAsFixed(2)} USD'
        '${hayTasa ? ' (≈ ${(total * tasa).toStringAsFixed(0)} CUP)' : ''}';
  }
  return '${total.toStringAsFixed(0)} $moneda'
      '${hayTasa && moneda == 'CUP' ? ' (≈ ${(total / tasa).toStringAsFixed(2)} USD)' : ''}';
}

/// Precio oficial (USD) expresado en la moneda de la venta.
/// En CUP se convierte con la tasa y se redondea a la decena.
double? precioOficialEn(String moneda, double oficialUsd, double? tasa) {
  if (moneda == 'USD') return oficialUsd;
  if (tasa == null || tasa <= 0) return null;
  return ((oficialUsd * tasa) / 10).round() * 10.0;
}

/// Monto en CUP de una venta de suplemento (0 si es en USD u otra moneda).
/// Las ventas en USD se reportan por separado y no entran a los totales CUP.
double totalVentaCup(Map<String, dynamic> v) {
  if ((v['moneda'] as String?) != 'CUP') return 0;
  final total = (v['total'] as num?)?.toDouble();
  if (total != null) return total;
  final precio = (v['precio'] as num?)?.toDouble() ?? 0;
  final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
  return precio * cant;
}

/// Ventas de suplementos en CUP del espejo local.
Future<List<Map<String, dynamic>>> ventasSuplementosCup() async {
  final out = <Map<String, dynamic>>[];
  for (final v in await LocalDb.instance.allMirror('ventas_suplementos')) {
    if ((v['moneda'] as String?) == 'CUP') out.add(v);
  }
  return out;
}

/// Monto en USD de una venta de suplemento (0 si es en CUP u otra moneda).
/// Las ventas en USD se reportan por separado y no entran a los totales CUP.
double totalVentaUsd(Map<String, dynamic> v) {
  if ((v['moneda'] as String?) != 'USD') return 0;
  final total = (v['total'] as num?)?.toDouble();
  if (total != null) return total;
  final precio = (v['precio'] as num?)?.toDouble() ?? 0;
  final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
  return precio * cant;
}

/// Ventas de suplementos en USD del espejo local.
Future<List<Map<String, dynamic>>> ventasSuplementosUsd() async {
  final out = <Map<String, dynamic>>[];
  for (final v in await LocalDb.instance.allMirror('ventas_suplementos')) {
    if ((v['moneda'] as String?) == 'USD') out.add(v);
  }
  return out;
}

/// Monto en USD que representa una op encolada (0 si no aplica).
/// Cuenta las ventas de suplementos en USD aún no sincronizadas.
double _montoUsdOp(Map<String, dynamic> op) {
  final tipo = '${op['tipo']}';
  Map<String, dynamic> payload;
  try {
    payload = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
  } catch (_) {
    return 0;
  }
  Map<String, dynamic>? venta;
  if (tipo == 'venta_suplemento') {
    venta = payload;
  } else if (tipo == 'inscripcion_venta_suplemento') {
    final v = payload['venta'];
    if (v is Map<String, dynamic>) venta = v;
  }
  if (venta == null) return 0;
  if ((venta['moneda'] as String?) != 'USD') return 0;
  final precio = (venta['precio'] as num?)?.toDouble() ?? 0;
  final cant = (venta['cantidad'] as num?)?.toInt() ?? 0;
  return precio * cant;
}

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

/// Monto en efectivo que representan una lista de ops encoladas.
/// Suma lo cobrado en efectivo según [_montoEfectivoOp].
Future<double> montoEfectivoOps(List<Map<String, dynamic>> ops) async {
  final pr = await preciosVigentes();
  double total = 0;
  for (final op in ops) {
    total += _montoEfectivoOp(op, pr);
  }
  return total;
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
  // v1.3-r3 (Gemini): filtrar por telegram_user_id en SQL primero.
  for (final p in await LocalDb.instance
      .mirrorFiltrado('pagos', {'telegram_user_id': telegramId})) {
    if ((p['metodo'] as String?) == 'efectivo' &&
        esPendiente(p['entregado'])) {
      total += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance
      .mirrorFiltrado('pagos_diarios', {'registrado_por': telegramId})) {
    if (esPendiente(d['entregado'])) {
      total += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  // Ventas de suplementos en CUP en efectivo pendientes de entregar.
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) == telegramId &&
        esPendiente(v['entregado'])) {
      total += totalVentaCup(v);
    }
  }
  final pr = await preciosVigentes();
  for (final op in await LocalDb.instance.pendingOps()) {
    total += _montoEfectivoOp(op, pr);
  }
  return total;
}

/// USD que el entrenador logueado aún no le entrega al dueño.
///
/// Decisión de Jc (2026-10-10): las ventas de suplementos en USD también
/// entran al pendiente ("USD a entregar"), separado del CUP.
/// Incluye las operaciones encoladas aún no sincronizadas.
Future<double> pendienteEntregaUsd(int? telegramId) async {
  if (telegramId == null) return 0;
  double total = 0;
  for (final v in await ventasSuplementosUsd()) {
    if ((v['registrado_por'] as int?) == telegramId &&
        esPendiente(v['entregado'])) {
      total += totalVentaUsd(v);
    }
  }
  for (final op in await LocalDb.instance.pendingOps()) {
    total += _montoUsdOp(op);
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
  for (final v in await ventasSuplementosCup()) {
    if (esPendiente(v['entregado'])) {
      final tid = v['registrado_por'] as int?;
      if (excluirTelegramId != null && tid == excluirTelegramId) continue;
      total += totalVentaCup(v);
    }
  }
  return total;
}

/// v1.1.2: total USD pendiente a recoger por el dueño.
/// Suma las ventas de suplementos en USD que los entrenadores
/// tienen pendiente de entregar.
Future<double> pendienteRecogerUsd({int? excluirTelegramId}) async {
  double total = 0;
  for (final v in await ventasSuplementosUsd()) {
    if (esPendiente(v['entregado'])) {
      final tid = v['registrado_por'] as int?;
      if (excluirTelegramId != null && tid == excluirTelegramId) continue;
      total += totalVentaUsd(v);
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

/// Teléfono cubano válido: 8 dígitos empezando con 5 o 6.
/// v1.2.9+46 (Gemini): ETECSA asigna móviles 6xx; pero se mantiene
/// restricción a 5/6 para no admitir fijos ni combinaciones inválidas.
bool validarTelefono(String v) {
  final d = v.replaceAll(RegExp(r'[^0-9]'), '');
  return d.length == 8 && (d.startsWith('5') || d.startsWith('6'));
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
/// v1.2.7 (A1): incluye ops en cola (optimistic UI) además del mirror.
/// Los pendientes llevan flag 'es_optimista' para la UI.
/// Deduplicación por clave de negocio (fecha+turno+cantidad+registrado_por)
/// — la solución definitiva con op_uuid requiere migración en servidor.
Future<List<Map<String, dynamic>>> diariosDeHoy() async {
  final hoy = _hoyIso();
  final todos = await LocalDb.instance.allMirror('pagos_diarios');
  final res =
      todos.where((d) => (d['fecha'] as String?) == hoy).toList();

  // Ops pendientes de pago_diario (aún no en mirror)
  // FIX (Gemini BUG 6): incluir 'enviada' — si solo se filtra 'pendiente',
  // el pago desaparece de la pantalla en cuanto se sube pero antes de
  // que el pull descargue el mirror confirmado.
  final db = await LocalDb.instance.db;
  final opsPendientes = await db.query(
    'ops_queue',
    columns: ['op_uuid', 'payload'],
    where: "tipo = 'pago_diario' AND estado IN ('pendiente', 'enviada')",
  );
  // Claves de negocio ya en mirror para deduplicar
  final clavesMirror = <String>{};
  for (final d in res) {
    // v1.2.7 fix Gemini ronda 2: misma estructura que la clave del op
    // (incluir hora) o la deduplicación nunca coincidiría.
    final hora = (d['hora'] as String?) ??
        (d['creado_en'] as String?) ??
        (d['creada_ts'] as String?) ??
        '';
    clavesMirror.add(
        "${d['fecha']}|$hora|${d['turno']}|${d['cantidad']}|${d['registrado_por']}");
  }
  for (final op in opsPendientes) {
    try {
      final payload =
          jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final fecha = (payload['fecha'] as String?)?.substring(0, 10) ?? '';
      if (fecha != hoy) continue;
      // v1.2.7 fix Gemini: incluir hora/timestamp para no colapsar
      // pagos legítimos idénticos (misma tarifa, mismo turno).
      final hora = (payload['hora'] as String?) ??
          (payload['creado_en'] as String?) ??
          (payload['creada_ts'] as String?) ??
          '';
      final clave =
          "$fecha|$hora|${payload['turno']}|${payload['cantidad']}|${payload['registrado_por']}";
      if (clavesMirror.contains(clave)) continue; // ya en mirror
      clavesMirror.add(clave);
      payload['op_uuid'] = op['op_uuid'];
      payload['es_optimista'] = true;
      // Normalizar campos que la UI espera del mirror
      payload['registrado_por_nombre'] ??= 'Tú';
      res.add(payload);
    } catch (_) {}
  }

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
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) == telegramId &&
        (v['fecha'] as String?) == hoy) {
      cobrado += totalVentaCup(v);
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

/// Saludo según la hora del día (mejora 1 del Home).
String saludoHora() {
  final h = DateTime.now().hour;
  if (h >= 5 && h < 12) return 'Buenos días';
  if (h >= 12 && h < 18) return 'Buenas tardes';
  return 'Buenas noches';
}

/// Turno actual: Mañana (5-12), Tarde (12-18), Noche (resto).
/// Mejora 11 del Home.
String turnoActual() {
  final h = DateTime.now().hour;
  if (h >= 5 && h < 12) return 'Mañana';
  if (h >= 12 && h < 18) return 'Tarde';
  return 'Noche';
}

String _isoDia(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Total cobrado ayer (mensualidades + diarios). Mejora 7 del Home.
Future<double> cobradoAyer() async {
  final ayer = _isoDia(
      DateTime.now().subtract(const Duration(days: 1)));
  double total = 0;
  for (final p in await LocalDb.instance
      .mirrorPorFecha('pagos', 'fecha', ayer, ayer)) {
    total += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance
      .mirrorPorFecha('pagos_diarios', 'fecha', ayer, ayer)) {
    total += (d['total'] as num?)?.toDouble() ?? 0;
  }
  for (final v in await ventasSuplementosCup()) {
    if ('${v['fecha'] ?? ''}'.length >= 10 &&
        '${v['fecha']}'.substring(0, 10) == ayer) {
      total += totalVentaCup(v);
    }
  }
  return total;
}

/// Antigüedad en días del cobro pendiente más viejo sin entregar.
/// Si telegramId es null, considera todos (vista del dueño).
/// Mejora 14 del Home.
Future<int?> antiguedadPendiente({int? telegramId}) async {
  DateTime? masVieja;
  void considera(String? fecha) {
    if (fecha == null || fecha.length < 10) return;
    try {
      final f = DateTime.parse(fecha.substring(0, 10));
      if (masVieja == null || f.isBefore(masVieja!)) {
        masVieja = f;
      }
    } catch (_) {}
  }

  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['metodo'] as String?) != 'efectivo') continue;
    if (!esPendiente(p['entregado'])) continue;
    if (telegramId != null &&
        (p['telegram_user_id'] as int?) != telegramId) {
      continue;
    }
    considera(p['fecha'] as String?);
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    if (telegramId != null &&
        (d['registrado_por'] as int?) != telegramId) {
      continue;
    }
    considera(d['fecha'] as String?);
  }
  if (masVieja == null) return null;
  final hoy = DateTime.now();
  return DateTime(hoy.year, hoy.month, hoy.day)
      .difference(
          DateTime(masVieja!.year, masVieja!.month, masVieja!.day))
      .inDays;
}

/// Últimas entregas confirmadas (ops `confirmar_entrega` aplicadas),
/// ordenadas por fecha descendente. {fecha, entrenador}.
/// Mejora 12 del Home.
Future<List<Map<String, dynamic>>> entregasRecientes(
    {int limite = 3}) async {
  final ops =
      await LocalDb.instance.opsByEstado('aplicada');
  final lista = <Map<String, dynamic>>[];
  for (final op in ops) {
    if (op['tipo'] != 'confirmar_entrega') continue;
    Map<String, dynamic> payload = {};
    try {
      payload = Map<String, dynamic>.from(
          jsonDecode('${op['payload'] ?? '{}'}') as Map);
    } catch (_) {}
    lista.add({
      'fecha': '${op['creada_ts'] ?? ''}',
      'trainer_id': payload['trainer_telegram_id'],
      // v1.2.1: nombre del entrenador (puede faltar en ops antiguas).
      'trainer_nombre': payload['trainer_nombre'],
    });
  }
  lista.sort((a, b) =>
      '${b['fecha']}'.compareTo('${a['fecha']}'));
  return lista.take(limite).toList();
}

/// Total entregado (confirmado) hoy por el dueño.
/// Usa `entregado_ts` (fecha real de confirmación que guarda el servidor),
/// no la fecha del pago. Incluye mensualidades y pagos diarios.
Future<double> entregadoHoy() async {
  final hoy = _isoDia(DateTime.now());
  double total = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if (_diaEntrega(p) == hoy) {
      total += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (_diaEntrega(d) == hoy) {
      total += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  return total;
}

/// Día (ISO yyyy-MM-dd, hora local) en que se confirmó la entrega,
/// o '' si el pago sigue pendiente o no trae marca de entrega.
String _diaEntrega(Map<String, dynamic> p) {
  final ts = '${p['entregado_ts'] ?? ''}';
  if (ts.isEmpty) return '';
  try {
    return _isoDia(DateTime.parse(ts).toLocal());
  } catch (_) {
    return '';
  }
}

/// Resumen de la semana actual: cobrado total y clientes nuevos.
/// Mejora 16 del Home.
Future<Map<String, dynamic>> resumenSemanal() async {
  final hoy = DateTime.now();
  final lunes =
      hoy.subtract(Duration(days: hoy.weekday - 1));
  final inicio = _isoDia(DateTime(lunes.year, lunes.month, lunes.day));
  double cobrado = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10).compareTo(inicio) >= 0) {
      cobrado += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10).compareTo(inicio) >= 0) {
      cobrado += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  var nuevos = 0;
  for (final c in await LocalDb.instance.allMirror('clientes')) {
    final f = '${c['fecha_inscripcion'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10).compareTo(inicio) >= 0) {
      nuevos++;
    }
  }
  return {'cobrado': cobrado, 'nuevos': nuevos};
}

/// Última actividad por actor desde el feed de actividad.
/// {actor: DateTime}. Mejora 13 del Home.
Future<Map<String, DateTime>> ultimaActividadPorActor() async {
  final mapa = <String, DateTime>{};
  final raw = await LocalDb.instance.getMeta('sync_estado_actividad');
  if (raw == null || raw.isEmpty) return mapa;
  try {
    for (final a in jsonDecode(raw) as List) {
      final m = Map<String, dynamic>.from(a as Map);
      final actor = '${m['actor'] ?? ''}';
      final ts = '${m['ts'] ?? ''}';
      if (actor.isEmpty || ts.isEmpty) continue;
      try {
        final f = DateTime.parse(ts);
        final prev = mapa[actor];
        if (prev == null || f.isAfter(prev)) mapa[actor] = f;
      } catch (_) {}
    }
  } catch (_) {}
  return mapa;
}

/// Desglose del pendiente del entrenador cobrado hoy.
/// {mensualidades: total, diarios: total, n}. Mejora 20 del Home.
Future<Map<String, dynamic>> pendienteDetalleHoy(
    int? telegramId) async {
  final hoy = _isoDia(DateTime.now());
  double mens = 0, diar = 0;
  var n = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['metodo'] as String?) != 'efectivo') continue;
    if (!esPendiente(p['entregado'])) continue;
    if (telegramId != null &&
        (p['telegram_user_id'] as int?) != telegramId) {
      continue;
    }
    if ('${p['fecha'] ?? ''}'.length < 10 ||
        '${p['fecha']}'.substring(0, 10) != hoy) {
      continue;
    }
    mens += (p['monto'] as num?)?.toDouble() ?? 0;
    n++;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    if (telegramId != null &&
        (d['registrado_por'] as int?) != telegramId) {
      continue;
    }
    if ('${d['fecha'] ?? ''}'.length < 10 ||
        '${d['fecha']}'.substring(0, 10) != hoy) {
      continue;
    }
    diar += (d['total'] as num?)?.toDouble() ?? 0;
    n++;
  }
  return {'mensualidades': mens, 'diarios': diar, 'n': n};
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
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) != telegramId) continue;
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      t += totalVentaCup(v);
    }
  }
  return t;
}

/// Dashboard por rol (v1.2): ingresos de hoy de un entrenador.
/// Suma pagos/pagos_diarios/ventas CUP de hoy donde telegram_user_id
/// o registrado_por == telegramId. Sigue el patrón de cobradoMes.
Future<double> ingresosHoyPorEntrenador(int? telegramId) async {
  if (telegramId == null) return 0;
  final hoy = _hoyIso();
  double t = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) != telegramId) continue;
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      t += totalVentaCup(v);
    }
  }
  return t;
}

/// Dashboard por rol (v1.2): ingresos últimos 7 días de un entrenador.
Future<double> ingresosSemanaPorEntrenador(int? telegramId) async {
  if (telegramId == null) return 0;
  final hoy = DateTime.now();
  final desde = hoy.subtract(const Duration(days: 6));
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  final desdeIso = iso(desde);
  final hoyIso = iso(hoy);
  double t = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 && dia.compareTo(hoyIso) <= 0) {
        t += (p['monto'] as num?)?.toDouble() ?? 0;
      }
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 && dia.compareTo(hoyIso) <= 0) {
        t += (d['total'] as num?)?.toDouble() ?? 0;
      }
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) != telegramId) continue;
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 && dia.compareTo(hoyIso) <= 0) {
        t += totalVentaCup(v);
      }
    }
  }
  return t;
}

/// Dashboard por rol (v1.2): desglose por método del mes de un entrenador.
/// Claves: 'efectivo', 'transferencia', 'suplementos'.
Future<Map<String, double>> ingresosPorMetodoEntrenador(
    int? telegramId) async {
  if (telegramId == null) {
    return {'efectivo': 0, 'transferencia': 0, 'suplementos': 0};
  }
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double efectivo = 0, transferencia = 0, suplementos = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
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
    if ((d['registrado_por'] as int?) != telegramId) continue;
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      efectivo += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) != telegramId) continue;
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      suplementos += totalVentaCup(v);
    }
  }
  return {
    'efectivo': efectivo,
    'transferencia': transferencia,
    'suplementos': suplementos
  };
}

/// Dashboard por rol (v1.2): desglose por tipo del mes de un entrenador.
/// Claves: 'mensual', 'diario', 'suplementos'.
Future<Map<String, double>> ingresosPorTipoEntrenador(
    int? telegramId) async {
  if (telegramId == null) {
    return {'mensual': 0, 'diario': 0, 'suplementos': 0};
  }
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double mensual = 0, diario = 0, suplementos = 0;
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
    if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
      mensual += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      diario += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) != telegramId) continue;
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      suplementos += totalVentaCup(v);
    }
  }
  return {'mensual': mensual, 'diario': diario, 'suplementos': suplementos};
}

/// Dashboard por rol (v1.2): mejor y peor día del mes de un entrenador.
/// Misma estructura que mejorPeorDia: {'mejor': {'dia', 'monto'},
/// 'peor': {'dia', 'monto'}}.
Future<Map<String, Map<String, dynamic>>> mejorPeorDiaEntrenador(
    int? telegramId) async {
  if (telegramId == null) return {};
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porDia = <String, double>{};
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['telegram_user_id'] as int?) != telegramId) continue;
    final f = '${p['fecha'] ?? ''}';
    if (f.startsWith(pref) && f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((p['monto'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ((d['registrado_por'] as int?) != telegramId) continue;
    final f = '${d['fecha'] ?? ''}';
    if (f.startsWith(pref) && f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if ((v['registrado_por'] as int?) != telegramId) continue;
    final f = '${v['fecha'] ?? ''}';
    if (f.startsWith(pref) && f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] = (porDia[dia] ?? 0) + totalVentaCup(v);
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

/// v1.3.0 (Pendiente v2): lista PLANA de pagos individuales pendientes.
/// Para agrupar en Dart con procesarPendientes().
Future<List<Map<String, dynamic>>> pagosPendientesDetalle(
    {int? excluirTid}) async {
  final lista = <Map<String, dynamic>>[];

  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if ((p['metodo'] as String?) != 'efectivo') continue;
    if (!esPendiente(p['entregado'])) continue;
    final tid = p['telegram_user_id'] as int?;
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    lista.add({
      'id': p['id'],
      'monto': (p['monto'] as num?)?.toDouble() ?? 0,
      'moneda': p['moneda'] as String? ?? 'CUP',
      'creada_en': p['creada_en'] ?? p['fecha'],
      'tipo': 'mensual',
      'descripcion': 'Mensualidad',
      'entrenador_nombre':
          '${p['registrado_por'] ?? 'Entrenador $tid'}',
      'trainer_telegram_id': tid,
    });
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    final tid = d['registrado_por'] as int?;
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    lista.add({
      'id': d['id'],
      'monto': (d['total'] as num?)?.toDouble() ?? 0,
      'moneda': 'CUP',
      'creada_en': d['fecha'],
      'tipo': 'diario',
      'descripcion': 'Pago diario',
      'entrenador_nombre':
          '${d['registrado_por_nombre'] ?? 'Entrenador $tid'}',
      'trainer_telegram_id': tid,
    });
  }
  // Orden descendente por fecha.
  lista.sort((a, b) =>
      '${b['creada_en']}'.compareTo('${a['creada_en']}'));
  return lista;
}

/// v1.3.0 (Pendiente v2): confirma entrega por lista de IDs.
/// Gemini: IDs separados por tipo para evitar colisión.
/// Fix #14 (Sol): confirmar entrega actualiza los mirrors en BD
/// (no solo listas en memoria) en la misma transacción que encola la op.
/// Así el optimismo persiste al salir/volver a la pantalla.
Future<void> confirmarEntregaPorIds({
  required List<int> mensualIds,
  required List<int> diarioIds,
  required String entrenadorNombre,
  int? trainerTelegramId,
}) async {
  final db = LocalDb.instance;
  final d = await db.db;
  final opUuid = const Uuid().v4();
  final ahora = DateTime.now().toIso8601String();
  await d.transaction((txn) async {
    // 1. Marcar mirrors como entregados (optimismo persistente).
    for (final id in mensualIds) {
      await txn.update(
        'pagos',
        {'entregado': 'entregado'},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    for (final id in diarioIds) {
      await txn.update(
        'pagos_diarios',
        {'entregado': 'entregado'},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    // 2. Encolar la op en la misma transacción.
    await txn.insert('ops_queue', {
      'op_uuid': opUuid,
      'tipo': 'confirmar_entrega',
      'payload': jsonEncode({
        'trainer_nombre': entrenadorNombre,
        // Argón B3: incluir trainer_telegram_id.
        if (trainerTelegramId != null)
          'trainer_telegram_id': trainerTelegramId,
        'pago_ids': mensualIds,
        'pago_diario_ids': diarioIds,
      }),
      'estado': 'pendiente',
      'creada_ts': ahora,
      'user_id': AuthService().userId,
      'telegram_id': AuthService().telegramId,
    });
  });
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
  // Gemini: incluir ventas de suplementos en CUP pendientes.
  for (final v in await ventasSuplementosCup()) {
    if (!esPendiente(v['entregado'])) continue;
    final tid = v['registrado_por'] as int?;
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    suma(tid, '${v['registrado_por_nombre'] ?? 'Entrenador $tid'}',
        totalVentaCup(v));
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
  for (final v in await ventasSuplementosCup()) {
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      t += totalVentaCup(v);
    }
  }
  return t;
}

/// v1.0.15: desglose de ingresos por método (efectivo vs transferencia).
Future<Map<String, double>> ingresosPorMetodo() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double efectivo = 0, transferencia = 0, suplementos = 0;
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
  for (final v in await ventasSuplementosCup()) {
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      suplementos += totalVentaCup(v);
    }
  }
  return {
    'efectivo': efectivo,
    'transferencia': transferencia,
    'suplementos': suplementos
  };
}

/// v1.0.15: desglose mensualidades vs pago diario.
Future<Map<String, double>> ingresosPorTipo() async {
  final n = DateTime.now();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double mensual = 0, diario = 0, suplementos = 0;
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
  for (final v in await ventasSuplementosCup()) {
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      suplementos += totalVentaCup(v);
    }
  }
  return {'mensual': mensual, 'diario': diario, 'suplementos': suplementos};
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
  for (final v in await ventasSuplementosCup()) {
    final f = '${v['fecha'] ?? ''}';
    if (f.startsWith(pref) && f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] = (porDia[dia] ?? 0) + totalVentaCup(v);
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
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  const dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  // v1.3-r3 (Gemini): UNA sola carga por rango de 30 días, no 60.
  // Antes: 30 iteraciones × 2 allMirror = 60 full scans.
  final desdeIso = iso(hoy.subtract(const Duration(days: 29)));
  final hastaIso = iso(hoy);
  final pagos = await LocalDb.instance
      .mirrorPorFecha('pagos', 'fecha', desdeIso, hastaIso);
  final diarios = await LocalDb.instance
      .mirrorPorFecha('pagos_diarios', 'fecha', desdeIso, hastaIso);
  final suplementos = await ventasSuplementosCup();
  // Agrupar por día en Dart (datasets ya acotados a 30 días).
  final porDia = <String, double>{};
  for (final p in pagos) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] = (porDia[dia] ?? 0) +
          ((p['monto'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final d in diarios) {
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final v in suplementos) {
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 && dia.compareTo(hastaIso) <= 0) {
        porDia[dia] = (porDia[dia] ?? 0) + totalVentaCup(v);
      }
    }
  }
  final res = <Map<String, dynamic>>[];
  for (var i = 29; i >= 0; i--) {
    final dia = hoy.subtract(Duration(days: i));
    final diaIso = iso(dia);
    res.add({
      'dia': dias[dia.weekday - 1],
      'fecha': diaIso,
      'monto': porDia[diaIso] ?? 0.0,
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
  for (final v in await ventasSuplementosCup()) {
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      final ent =
          '${v['registrado_por_nombre'] ?? v['registrado_por'] ?? '?'}';
      porEntrenador[ent] = (porEntrenador[ent] ?? 0) + totalVentaCup(v);
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
  // Primer y último día del mes para mirrorPorFecha.
  final desde = '$pref-01';
  final ultimoDia = DateTime(n.year, n.month + 1, 0).day;
  final hasta = '$pref-${ultimoDia.toString().padLeft(2, '0')}';
  double t = 0;
  for (final p in await LocalDb.instance
      .mirrorPorFecha('pagos', 'fecha', desde, hasta)) {
    t += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance
      .mirrorPorFecha('pagos_diarios', 'fecha', desde, hasta)) {
    t += (d['total'] as num?)?.toDouble() ?? 0;
  }
  for (final v in await ventasSuplementosCup()) {
    if ('${v['fecha'] ?? ''}'.startsWith(pref)) {
      t += totalVentaCup(v);
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
  for (final v in await ventasSuplementosCup()) {
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] = (porDia[dia] ?? 0) + totalVentaCup(v);
    }
  }
  return porDia;
}

/// Ingresos de hoy (espejo `pagos` + diarios). v1.0.8.
Future<double> ingresosHoy() async {
  final hoy = _hoyIso();
  double t = 0;
  for (final p
      in await LocalDb.instance.mirrorPorFecha('pagos', 'fecha', hoy, hoy)) {
    t += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance
      .mirrorPorFecha('pagos_diarios', 'fecha', hoy, hoy)) {
    t += (d['total'] as num?)?.toDouble() ?? 0;
  }
  for (final v in await ventasSuplementosCup()) {
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      t += totalVentaCup(v);
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
  for (final p in await LocalDb.instance
      .mirrorPorFecha('pagos', 'fecha', desdeIso, hoyIso)) {
    t += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance
      .mirrorPorFecha('pagos_diarios', 'fecha', desdeIso, hoyIso)) {
    t += (d['total'] as num?)?.toDouble() ?? 0;
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
