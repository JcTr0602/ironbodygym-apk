/// Lógica de negocio en el teléfono (espejo de ironbody/db/clientes.py).
///
/// Trabaja sobre los mapas decodificados del espejo `clientes`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'localdb.dart';
import 'adelantos.dart';
import 'sync.dart';
import 'tiempo.dart';

String _norm(String s) {
  var n = s.toLowerCase().trim();
  const conTilde = 'áéíóúüñ';
  const sinTilde = 'aeiouun';
  for (var i = 0; i < conTilde.length; i++) {
    n = n.replaceAll(conTilde[i], sinTilde[i]);
  }
  return n;
}

/// Orden alfabético de personas/productos para TODAS las listas
/// (v1.4.3): comparar el nombre CRUDO con compareTo manda las
/// minúsculas tras las mayúsculas (un cliente inscrito como
/// «alberto prueba» quedaba al final de la lista, tras la Z).
/// Se ordena por el nombre VISIBLE normalizado (minúsculas, sin
/// tildes) calculado aquí mismo — NO se usa ningún `nombre_norm`
/// cacheado que venga en el mapa: puede estar obsoleto o no
/// corresponder al nombre actual (panel de código 2026-10-21).
/// Desempate por id: orden total y estable entre ejecuciones.
int compararPorNombre(Map<String, dynamic> a, Map<String, dynamic> b) {
  final c = _norm('${a['nombre'] ?? ''}')
      .compareTo(_norm('${b['nombre'] ?? ''}'));
  if (c != 0) return c;
  // Desempate por id (orden de registro): total y estable,
  // sin volver a introducir el sesgo mayúsculas/minúsculas.
  return _idOrdenable(a).compareTo(_idOrdenable(b));
}

/// Id tolerante para desempatar: acepta num o texto numérico;
/// cualquier otra cosa vale 0.
int _idOrdenable(Map<String, dynamic> m) {
  final v = m['id'];
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? 0;
}

String _hoyIso() {
  final n = ahoraHabana();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

String _hace(int dias) {
  final d = ahoraHabana().subtract(Duration(days: dias));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// v1.3.8: días de atraso entre pagado_hasta y hoy (formato YYYY-MM-DD).
/// Retorna 0 si la fecha es inválida o futura.
int _diasAtraso(String pagadoHasta, String hoyIso) {
  try {
    final ph = DateTime.parse(pagadoHasta.substring(0, 10));
    final hoy = DateTime.parse(hoyIso.substring(0, 10));
    final d = hoy.difference(ph).inDays;
    return d > 0 ? d : 0;
  } catch (_) {
    return 0;
  }
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

/// v1.7.0: ¿el cliente (mapa del espejo) es Cuenta a la Casa?
/// Delega en el punto único de verdad de LocalDb.
bool esCuentaCasa(Map<String, dynamic> c) => LocalDb.cuentaCasaDe(c);

/// v1.7.0: payload EXACTO de la op `cuenta_casa` (contrato con el
/// servidor B2): {cliente_id, activar, motivo?} — el motivo solo
/// viaja si no está vacío. Función pura para fijarlo con tests.
Map<String, dynamic> payloadOpCuentaCasa({
  required int clienteId,
  required bool activar,
  String? motivo,
}) {
  final m = (motivo ?? '').trim();
  return {
    'cliente_id': clienteId,
    'activar': activar,
    if (m.isNotEmpty) 'motivo': m,
  };
}

/// v1.8.0: payload EXACTO de la op `eliminar_cliente` (contrato
/// con el servidor): {cliente_id, definitivo: true, modo} con
/// modo 'todo' | 'conservar'. El servidor trata un modo ausente o
/// desconocido como 'todo' (compatibilidad con APKs viejas);
/// aquí siempre se envía explícito. Función pura para fijarlo
/// con tests, como [payloadOpCuentaCasa].
Map<String, dynamic> payloadOpEliminarCliente({
  required int clienteId,
  required String modo,
}) {
  return {
    'cliente_id': clienteId,
    'definitivo': true,
    'modo': modo == 'conservar' ? 'conservar' : 'todo',
  };
}

/// v1.8.0: ¿el cliente (mapa del espejo) es la cáscara de una
/// baja conservando estadísticas? Delega en el punto único de
/// verdad de LocalDb. Toda lista/conteo de PERSONAS lo excluye;
/// los historiales de dinero NO usan este filtro (la cáscara
/// sostiene los pagos/ventas anónimos y se muestra como
/// «Cliente eliminado»).
bool esClienteEliminado(Map<String, dynamic> c) =>
    LocalDb.esEliminadoDe(c);

/// v1.7.0: predicado compuesto de Argón para COMPUERTAS de acceso
/// y UI de estado (nunca para contabilidad/nómina, que miran pagos
/// reales): el cliente tiene acceso vigente si es Cuenta a la Casa
/// O su `pagado_hasta` no ha vencido a [hoyIso] ('YYYY-MM-DD').
bool accesoEfectivoVigente(Map<String, dynamic> c, String hoyIso) {
  if (esCuentaCasa(c)) return true;
  final ph = c['pagado_hasta'] as String?;
  return ph != null && ph.compareTo(hoyIso) >= 0;
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
      porTel.sort(compararPorNombre);
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
    resultado.sort(compararPorNombre);
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
  // v1.7.0: predicado compuesto (UI de estado): la Cuenta a la
  // Casa está siempre al día, aunque su pagado_hasta sea NULL.
  final res = rows.where((c) => accesoEfectivoVigente(c, hoy)).toList();
  res.sort(compararPorNombre);
  return res;
}

/// Vencen exactamente hoy.
/// v1.7.0: la Cuenta a la Casa queda FUERA (nunca vence; no es un
/// vencimiento cobrable ni entra en recordatorios de cobro).
Future<List<Map<String, dynamic>>> vencenHoy() async {
  final hoy = _hoyIso();
  final rows = await _activos();
  final res = rows
      .where((c) =>
          !esCuentaCasa(c) && (c['pagado_hasta'] as String?) == hoy)
      .toList();
  res.sort(compararPorNombre);
  return res;
}

/// Atrasados: masDe30=false -> 1..30 días (incluye sin pagado_hasta);
/// masDe30=true -> más de 30 días.
Future<List<Map<String, dynamic>>> atrasados({required bool masDe30}) async {
  final hoy = _hoyIso();
  final limite = _hace(30);
  final rows = await _activos();
  List<Map<String, dynamic>> res;
  // v1.7.0: la Cuenta a la Casa queda FUERA de atrasados en ambas
  // ramas (su pagado_hasta puede ser NULL o viejo sin que deba
  // nada: excluirla explícitamente, no por accidente del filtro).
  if (masDe30) {
    res = rows.where((c) {
      if (esCuentaCasa(c)) return false;
      final ph = c['pagado_hasta'] as String?;
      return ph != null && ph.compareTo(limite) < 0;
    }).toList();
  } else {
    res = rows.where((c) {
      if (esCuentaCasa(c)) return false;
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
///
/// v1.3.4 (B1): usa la columna indexada `cliente_id` (idx_pagos_cliente,
/// migración v26) en vez de `mirrorFiltrado` (json_extract → full scan).
/// Mantiene el fallback de filas con columna NULL del patrón de
/// [LocalDb.pagosCortesiaClienteAnio].
Future<List<Map<String, dynamic>>> pagosDe(int clienteId,
    {int limit = 10}) async {
  final d = await LocalDb.instance.db;
  final res = <Map<String, dynamic>>[];
  final rows = await d.rawQuery(
      'SELECT id, data FROM pagos WHERE cliente_id = ? '
      'ORDER BY fecha DESC LIMIT ?',
      [clienteId, limit]);
  for (final r in rows) {
    try {
      res.add({
        ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
        'id': r['id'],
      });
    } catch (_) {}
  }
  // Fallback: filas con columna cliente_id NULL cuyo JSON sí trae el
  // cliente (backfill incompleto o fila escrita por camino viejo).
  final nulos = await d.rawQuery(
      'SELECT id, data FROM pagos WHERE cliente_id IS NULL');
  final vistos = res.map((p) => p['id']).toSet();
  for (final r in nulos) {
    if (vistos.contains(r['id'])) continue;
    try {
      final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
      if (LocalDb.normalizarTelegramId(p['cliente_id']) == clienteId) {
        res.add({...p, 'id': r['id']});
      }
    } catch (_) {}
  }
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
    final ahora = ahoraHabana();
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

/// v1.4.6: línea «Cobró: …» de los historiales de pago (ficha del
/// cliente y «Pagos realizados»). `registrado_por` ya viaja en el
/// espejo de pagos; si falta o viene vacío se dice explícito en
/// vez de dejar la línea en blanco.
String textoCobradoPor(dynamic registradoPor) {
  final s = '${registradoPor ?? ''}'.trim();
  return s.isEmpty ? 'Cobró: No registrado' : 'Cobró: $s';
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
///
/// v1.3.2: parámetro `base` explícito ("siguió viniendo"). Si el cliente
/// estaba vencido y siguió entrenando, el período nuevo se cuenta desde
/// el vencimiento anterior, no desde hoy.
String previewHastaDias(String? pagadoHasta, int dias,
    {String? fechaPago, String? base}) {
  final fp = fechaPago ?? _hoyIso();
  final b = base ??
      ((pagadoHasta != null && pagadoHasta.compareTo(fp) > 0)
          ? pagadoHasta
          : fp);
  // v1.3.2 (Argón #3): UTC para que el cambio de horario (DST) de Cuba
  // no reste un día al cruzar noviembre.
  final p = b.substring(0, 10).split('-').map(int.parse).toList();
  final d =
      DateTime.utc(p[0], p[1], p[2]).add(Duration(days: dias));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

bool esPendiente(dynamic v) => v == 0 || v == false;

/// v1.2.4 (Hark): texto de un total de venta con su equivalente en la
/// otra moneda cuando se conoce la tasa (CUP por 1 USD). Regla única para
/// venta, inscripción+venta, venta rápida e historial.
/// v1.8.1 (pedido de Jc 2026-10-23): comprobante de compra de
/// suplemento para WhatsApp, embellecido: emojis funcionales,
/// negritas de WhatsApp, separadores y — si la compra llevó
/// la promo del mes gratis — la NUEVA fecha de vencimiento del
/// cliente (calculada con previewHasta, la misma regla del
/// servidor: max(vencimiento actual, hoy) + 30 días).
/// Función pura: la pantalla solo le pasa los datos.
String textoComprobanteCompra({
  required String nombreProducto,
  required int cantidad,
  required double precio,
  required String moneda,
  required double total,
  required String nombreComprador,
  required String fechaIso,
  bool conPromo = false,
  String? nuevoVencimientoIso,
  bool esFiado = false,
}) {
  String fechaBonita(String iso) {
    final p = iso.substring(0, 10).split('-');
    return p.length == 3 ? '${p[2]}/${p[1]}/${p[0]}' : iso;
  }

  final buf = StringBuffer()
    ..writeln('🏋️ *IRON BODY GYM* 🏋️')
    ..writeln('🧾 *Comprobante de compra*')
    ..writeln('━━━━━━━━━━━━━━━')
    ..writeln('💊 *Producto:* $nombreProducto')
    ..writeln('🔢 *Cantidad:* $cantidad')
    ..writeln('💵 *Precio:* ${precio.toStringAsFixed(2)} $moneda')
    ..writeln('━━━━━━━━━━━━━━━')
    ..writeln('💰 *TOTAL: ${total.toStringAsFixed(2)} $moneda*')
    ..writeln('━━━━━━━━━━━━━━━')
    ..writeln('👤 *Comprador:* $nombreComprador')
    ..writeln('📅 *Fecha:* ${fechaBonita(fechaIso)}');
  if (esFiado) {
    buf.writeln('📝 *Estado:* Fiado (pendiente de pago)');
  }
  if (conPromo) {
    buf
      ..writeln('')
      ..writeln('🎁 *¡Promoción aplicada!*')
      ..writeln('✅ 1 mes de mensualidad *GRATIS* sumado a tu cuenta.');
    if (nuevoVencimientoIso != null) {
      buf.writeln(
          '🗓️ *Tu nueva fecha de vencimiento:* ${fechaBonita(nuevoVencimientoIso)}');
    }
  }
  buf
    ..writeln('━━━━━━━━━━━━━━━')
    ..writeln('💪 ¡Gracias por tu compra! A seguir entrenando.');
  return buf.toString().trim();
}

String textoTotalVenta(double total, String moneda, double? tasa) {
  final hayTasa = tasa != null && tasa > 0;
  if (moneda == 'USD') {
    // v1.3.1 (Medio #6): si la tasa es 1.0 o menor es la normalización por
    // defecto (tasa no indicada), no mostrar equivalencia falsa "≈ 1 CUP".
    final mostrarCup = hayTasa && tasa > 1.0;
    return '${total.toStringAsFixed(2)} USD'
        '${mostrarCup ? ' (≈ ${(total * tasa).toStringAsFixed(0)} CUP)' : ''}';
  }
  return '${total.toStringAsFixed(0)} $moneda'
      '${hayTasa && moneda == 'CUP' ? ' (≈ ${(total / tasa).toStringAsFixed(2)} USD)' : ''}';
}

/// Precio oficial (USD) expresado en la moneda de la venta.
/// En CUP se convierte con la tasa y se redondea a la decena.
double? precioOficialEn(String moneda, double oficialUsd, double? tasa) {
  if (moneda == 'USD') return oficialUsd;
  if (tasa == null || tasa <= 0 || !tasa.isFinite) return null;
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
    'menores': (aj['mensualidad_menores'] as num?)?.toDouble() ?? 1500,
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
  // v1.3.2 (Argón #4): si ya está entregado (dueño), no suma al pendiente.
  if (payload['entregado'] == true || payload['entregado'] == 1) {
    return 0;
  }
  double mensualidad(String periodo, int meses, String metodo,
      double? montoManual, String? tipoId) {
    if (metodo != 'efectivo') return 0;
    if (periodo == 'personalizado') return montoManual ?? 0;
    // v1.3.9: tipo de pago personalizado (ej. "Oferta 50%") —
    // usa el monto real del payload, no el precio estándar.
    if (periodo.startsWith('tipo:')) return montoManual ?? 0;
    if (periodo == 'semanal') return pr['semanal']!;
    if (periodo == 'quincenal') return pr['quincenal']!;
    // v1.3.2 (Argón #4): tarifa de menores.
    if (tipoId == 'menores') return pr['menores']! * meses;
    return pr['mensual']! * meses;
  }

  if (tipo == 'pago_mensual') {
    return mensualidad(
        '${payload['periodo'] ?? 'mensual'}',
        (payload['meses'] as num?)?.toInt() ?? 1,
        '${payload['metodo'] ?? 'efectivo'}',
        (payload['monto'] as num?)?.toDouble(),
        payload['tipo_id'] as String?);
  }
  if (tipo == 'inscribir') {
    // v1.3.9 (Bug 2): si fue por transferencia no es efectivo a entregar.
    if ('${payload['metodo_pago'] ?? 'efectivo'}' == 'transferencia') return 0;
    return mensualidad(
        '${payload['periodo'] ?? 'mensual'}',
        (payload['meses'] as num?)?.toInt() ?? 1,
        'efectivo',
        (payload['monto'] as num?)?.toDouble(),
        payload['tipo_id'] as String?);
  }
  if (tipo == 'pago_diario') {
    final cant = (payload['cantidad'] as num?)?.toInt() ?? 0;
    return cant * pr['diario']!;
  }
  // v1.3.2 (Argón #4): ventas de suplementos en CUP suman al pendiente.
  if (tipo == 'venta_suplemento') {
    if ('${payload['moneda'] ?? 'CUP'}'.toUpperCase() != 'CUP') return 0;
    final cant = (payload['cantidad'] as num?)?.toDouble() ?? 0;
    final precio = (payload['precio'] as num?)?.toDouble() ?? 0;
    return cant * precio;
  }
  // v1.8.0: venta de servicio en efectivo suma al pendiente (Casa y
  // transferencia no; el reverso encolado no se neta aquí — se neta al
  // espejarse la fila de reverso en servicio_ventas, como con las
  // anulaciones de suplementos).
  if (tipo == 'venta_servicio') {
    if (payload['casa'] == true) return 0;
    if ('${payload['metodo'] ?? 'efectivo'}' != 'efectivo') return 0;
    final cant = (payload['cantidad'] as num?)?.toDouble() ?? 0;
    final precio = (payload['precio_unitario'] as num?)?.toDouble() ?? 0;
    return cant * precio;
  }
  if (tipo == 'inscripcion_venta_suplemento') {
    double t = 0;
    final c = payload['cliente'];
    if (c is Map<String, dynamic>) {
      t += mensualidad(
          '${c['periodo'] ?? 'mensual'}',
          (c['meses'] as num?)?.toInt() ?? 1,
          'efectivo',
          (c['monto'] as num?)?.toDouble(),
          c['tipo_id'] as String?);
    }
    final v = payload['venta'];
    if (v is Map<String, dynamic>) {
      if ('${v['moneda'] ?? 'CUP'}'.toUpperCase() == 'CUP') {
        final cant = (v['cantidad'] as num?)?.toDouble() ?? 0;
        final precio = (v['precio'] as num?)?.toDouble() ?? 0;
        t += cant * precio;
      }
    }
    return t;
  }
  return 0;
}

/// Monto en efectivo que representan una lista de ops encoladas.
/// Suma lo cobrado en efectivo según [_montoEfectivoOp].
Future<double> montoEfectivoOps(List<Map<String, dynamic>> ops) async {
  final pr = await preciosVigentes();  double total = 0;
  for (final op in ops) {
    total += _montoEfectivoOp(op, pr);
  }
  return total;
}

/// v1.3.3: monto en CUP cobrado que representa una op encolada.
/// Como [_montoEfectivoOp] pero SIN filtrar por método de pago ni por
/// entrega: para el KPI "Total cobrado" de Actividad reciente.
/// Sigue la misma regla de precios que el servidor (_precio_metodo).
Future<double> montoCobradoCupOp(Map<String, dynamic> op) async {
  final pr = await preciosVigentes();
  final tipo = '${op['tipo']}';
  Map<String, dynamic> payload;
  try {
    payload =
        jsonDecode(op['payload'] as String) as Map<String, dynamic>;
  } catch (_) {
    return 0;
  }

  double mensualidad(String periodo, int meses, String metodo,
      double? montoManual, String? tipoId) {
    if (periodo == 'personalizado') return montoManual ?? 0;
    if (periodo == 'semanal') return pr['semanal']!;
    if (periodo == 'quincenal') return pr['quincenal']!;
    // v1.3.1: tarifa de menores (igual que el servidor).
    if (tipoId == 'menores') return pr['menores']! * meses;
    final unit =
        metodo == 'transferencia' ? pr['transfer']! : pr['mensual']!;
    return unit * meses;
  }

  if (tipo == 'pago_mensual' || tipo == 'pago' || tipo == 'mensual') {
    return mensualidad(
        '${payload['periodo'] ?? 'mensual'}',
        (payload['meses'] as num?)?.toInt() ?? 1,
        '${payload['metodo'] ?? 'efectivo'}',
        (payload['monto'] as num?)?.toDouble(),
        payload['tipo_id'] as String?);
  }
  if (tipo == 'inscribir') {
    // v1.3.9 (Bug 2): usar el método de pago del payload (fallback 'efectivo'
    // para ops viejas). El precio por transferencia difiere del efectivo.
    return mensualidad(
        '${payload['periodo'] ?? 'mensual'}',
        (payload['meses'] as num?)?.toInt() ?? 1,
        '${payload['metodo_pago'] ?? 'efectivo'}',
        (payload['monto'] as num?)?.toDouble(),
        payload['tipo_id'] as String?);
  }
  if (tipo == 'pago_diario' || tipo == 'diario') {
    final cant = (payload['cantidad'] as num?)?.toInt() ?? 0;
    return cant * pr['diario']!;
  }
  if (tipo == 'venta_suplemento') {
    if ('${payload['moneda'] ?? 'CUP'}'.toUpperCase() != 'CUP') return 0;
    final cant = (payload['cantidad'] as num?)?.toDouble() ?? 0;
    final precio = (payload['precio'] as num?)?.toDouble() ?? 0;
    return cant * precio;
  }
  if (tipo == 'inscripcion_venta_suplemento') {
    double t = 0;
    final c = payload['cliente'];
    if (c is Map<String, dynamic>) {
      t += mensualidad(
          '${c['periodo'] ?? 'mensual'}',
          (c['meses'] as num?)?.toInt() ?? 1,
          'efectivo',
          (c['monto'] as num?)?.toDouble(),
          c['tipo_id'] as String?);
    }
    final v = payload['venta'];
    if (v is Map<String, dynamic>) {
      if ('${v['moneda'] ?? 'CUP'}'.toUpperCase() == 'CUP') {
        final cant = (v['cantidad'] as num?)?.toDouble() ?? 0;
        final precio = (v['precio'] as num?)?.toDouble() ?? 0;
        t += cant * precio;
      }
    }
    return t;
  }
  // v1.8.0: venta de servicio cobrada (cualquier método; Casa = 0
  // porque su precio snapshot es 0).
  if (tipo == 'venta_servicio') {
    if (payload['casa'] == true) return 0;
    final cant = (payload['cantidad'] as num?)?.toDouble() ?? 0;
    final precio = (payload['precio_unitario'] as num?)?.toDouble() ?? 0;
    return cant * precio;
  }
  return 0;
}

/// v1.3.3: monto en USD cobrado que representa una op encolada
/// (ventas de suplementos). Para el KPI "Total cobrado" de Actividad.
double montoCobradoUsdOp(Map<String, dynamic> op) => _montoUsdOp(op);

/// Dinero en efectivo que el entrenador logueado aún no le entrega al dueño.
///
/// Regla del servidor (ronda 14): efectivo registrado por entrenador queda
/// `entregado=0`; transferencia o registros del dueño quedan entregados.
/// Cuando el dueño confirma en el bot, el espejo se actualiza y esto baja solo.
/// Incluye las operaciones encoladas aún no sincronizadas (son del
/// entrenador logueado por definición).
/// v1.8.0: adelantos vivos que descuentan del pendiente del
/// entrenador DE TURNO (A2 de Argón): salieron de su gaveta en
/// efectivo y ya no están en su mano. Los reversos llevan el
/// monto en negativo y netan solos. (Los registrados en ESTE
/// teléfono aún sin sincronizar no están en el espejo: el
/// pendiente los refleja al llegar el espejo, como el resto.)
Future<double> adelantosEnPendiente(int? telegramId) async {
  if (telegramId == null) return 0;
  // Panel 1.8.0 (Claude): con overlay de ops encoladas en ESTE
  // teléfono, como el resto del pendiente: registrar el adelanto
  // lo descuenta al momento en este mismo equipo.
  return sumaAdelantosPendientes(
    espejo: await LocalDb.instance.allMirror('adelantos'),
    opsPendientes: await LocalDb.instance.pendingOps(),
    telegramId: telegramId,
    normalizarTid: LocalDb.normalizarTelegramId,
  );
}

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
    if (LocalDb.normalizarTelegramId(v['registrado_por']) == telegramId &&
        esPendiente(v['entregado'])) {
      total += totalVentaCup(v);
    }
  }
  // v1.8.0: ventas de servicios en efectivo pendientes (las filas de
  // reverso llevan cantidad negativa y netan solas; Casa queda fuera
  // por su entregado=1 en el servidor, y se excluye por si acaso).
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    // Ítems 8/10: la gaveta es del RESPONSABLE del efectivo.
    final resp =
        LocalDb.normalizarTelegramId(v['responsable_efectivo_id']) ??
            LocalDb.normalizarTelegramId(v['registrado_por']);
    if (resp == telegramId &&
        (v['metodo'] as String?) == 'efectivo' &&
        (v['casa'] as num?)?.toInt() != 1 &&
        esPendiente(v['entregado'])) {
      total += ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
          ((v['cantidad'] as num?)?.toDouble() ?? 0);
    }
  }
  final pr = await preciosVigentes();
  for (final op in await LocalDb.instance.pendingOps()) {
    total += _montoEfectivoOp(op, pr);
  }
  // v1.8.0: los adelantos de su gaveta ya salieron de su mano.
  total -= await adelantosEnPendiente(telegramId);
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
    if (LocalDb.normalizarTelegramId(v['registrado_por']) == telegramId &&
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
  // v1.3.4 (B2): filtro metodo='efectivo' por columna indexada (v26).
  for (final p in await LocalDb.instance.pagosPorFiltro(metodo: 'efectivo')) {
    if (esPendiente(p['entregado'])) {
      final tid = LocalDb.normalizarTelegramId(p['telegram_user_id']);
      if (excluirTelegramId != null && tid == excluirTelegramId) continue;
      total += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (esPendiente(d['entregado'])) {
      final tid = LocalDb.normalizarTelegramId(d['registrado_por']);
      if (excluirTelegramId != null && tid == excluirTelegramId) continue;
      total += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (esPendiente(v['entregado'])) {
      final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
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
      final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
      if (excluirTelegramId != null && tid == excluirTelegramId) continue;
      total += totalVentaUsd(v);
    }
  }
  return total;
}

// =====================================================================
// v1.3.6 (ítems 1B+1C): arqueo de caja e incidencias de sync.
// =====================================================================

/// IDs de operaciones ya incluidas en alguna liquidación (por entrenador).
/// Se usa para no contar dos veces: un pago en op_ids de una liquidación
/// ya está saldado aunque su fila espejo aún no traiga entregado=1
/// (ventana entre pulls de tablas distintas).
Future<Set<String>> _idsLiquidados(int telegramId) async {
  final cubiertos = <String>{};
  for (final l
      in await LocalDb.instance.allMirror('liquidaciones_caja')) {
    if (LocalDb.normalizarTelegramId(l['entrenador_telegram_id']) !=
        telegramId) {
      continue;
    }
    try {
      final raw = l['op_ids'];
      final opIds = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : Map<String, dynamic>.from(raw as Map);
      for (final tabla in ['pagos', 'pagos_diarios', 'ventas_suplementos']) {
        for (final x in (opIds[tabla] as List?) ?? const []) {
          cubiertos.add('$tabla:$x');
        }
      }
    } catch (_) {}
  }
  return cubiertos;
}

/// Pendiente CONFIRMADO de un entrenador (invariante 2 de Argón, ítem 1B):
/// solo filas espejo con sync_seq, IGNORANDO ops_queue. Es la base del
/// monto_esperado de una liquidación: lo que el servidor ya vio.
/// Incluye el saldo de arrastre de liquidaciones parciales.
Future<({double cup, double usd})> pendienteArqueo(int? telegramId) async {
  if (telegramId == null) return (cup: 0.0, usd: 0.0);
  final cubiertos = await _idsLiquidados(telegramId);
  var cup = 0.0;
  var usd = 0.0;
  for (final p in await LocalDb.instance
      .mirrorFiltrado('pagos', {'telegram_user_id': telegramId})) {
    if (cubiertos.contains('pagos:${p['id']}')) continue;
    if ((p['metodo'] as String?) == 'efectivo' &&
        esPendiente(p['entregado'])) {
      cup += (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance
      .mirrorFiltrado('pagos_diarios', {'registrado_por': telegramId})) {
    if (cubiertos.contains('pagos_diarios:${d['id']}')) continue;
    if (esPendiente(d['entregado'])) {
      cup += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) {
      continue;
    }
    if (cubiertos.contains('ventas_suplementos:${v['id']}')) continue;
    if (esPendiente(v['entregado'])) cup += totalVentaCup(v);
  }
  for (final v in await ventasSuplementosUsd()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) {
      continue;
    }
    if (cubiertos.contains('ventas_suplementos:${v['id']}')) continue;
    if (esPendiente(v['entregado'])) usd += totalVentaUsd(v);
  }
  // v1.8.0: ventas de servicios en efectivo (CUP) pendientes de
  // arqueo; los reversos (cantidad negativa) netan solos.
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) {
      continue;
    }
    if (cubiertos.contains('servicio_ventas:${v['id']}')) continue;
    if ((v['metodo'] as String?) == 'efectivo' &&
        (v['casa'] as num?)?.toInt() != 1 &&
        esPendiente(v['entregado'])) {
      cup += ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
          ((v['cantidad'] as num?)?.toDouble() ?? 0);
    }
  }
  // v1.8.0: adelantos vivos de su gaveta (A2) — descuentan.
  cup -= await adelantosEnPendiente(telegramId);
  // Saldo de arrastre de liquidaciones parciales (sin partir ops).
  for (final l
      in await LocalDb.instance.allMirror('liquidaciones_caja')) {
    if (LocalDb.normalizarTelegramId(l['entrenador_telegram_id']) !=
        telegramId) {
      continue;
    }
    if ((l['estado'] as String?) != 'parcial') continue;
    final arrastre = (l['saldo_arrastre'] as num?)?.toDouble() ?? 0;
    if ((l['moneda'] as String?) == 'USD') {
      usd += arrastre;
    } else {
      cup += arrastre;
    }
  }
  return (cup: cup, usd: usd);
}

/// IDs que componen el pendiente confirmado (para op_ids de la liquidación).
Future<Map<String, List<int>>> idsPendienteArqueo(int? telegramId,
    {String moneda = 'CUP'}) async {
  final res = <String, List<int>>{
    'pagos': [],
    'pagos_diarios': [],
    'ventas_suplementos': [],
    'servicio_ventas': [], // v1.8.0 (el servidor la lee con este nombre)
    'adelantos': [], // v1.8.0: la liquidación los saca del pendiente
  };
  if (telegramId == null) return res;
  final cubiertos = await _idsLiquidados(telegramId);
  final esUsd = moneda == 'USD';
  for (final p in await LocalDb.instance
      .mirrorFiltrado('pagos', {'telegram_user_id': telegramId})) {
    if (esUsd) continue; // los pagos siempre son CUP
    if (cubiertos.contains('pagos:${p['id']}')) continue;
    if ((p['metodo'] as String?) == 'efectivo' &&
        esPendiente(p['entregado'])) {
      final id = (p['id'] as num?)?.toInt();
      if (id != null) res['pagos']!.add(id);
    }
  }
  for (final d in await LocalDb.instance
      .mirrorFiltrado('pagos_diarios', {'registrado_por': telegramId})) {
    if (esUsd) continue; // los pagos diarios siempre son CUP
    if (cubiertos.contains('pagos_diarios:${d['id']}')) continue;
    if (esPendiente(d['entregado'])) {
      final id = (d['id'] as num?)?.toInt();
      if (id != null) res['pagos_diarios']!.add(id);
    }
  }
  final ventas = esUsd ? await ventasSuplementosUsd() : await ventasSuplementosCup();
  for (final v in ventas) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) {
      continue;
    }
    if (cubiertos.contains('ventas_suplementos:${v['id']}')) continue;
    if (esPendiente(v['entregado'])) {
      final id = (v['id'] as num?)?.toInt();
      if (id != null) res['ventas_suplementos']!.add(id);
    }
  }
  if (!esUsd) {
    for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
      if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) {
        continue;
      }
      if (cubiertos.contains('servicio_ventas:${v['id']}')) continue;
      if ((v['metodo'] as String?) == 'efectivo' &&
          (v['casa'] as num?)?.toInt() != 1 &&
          esPendiente(v['entregado'])) {
        final id = (v['id'] as num?)?.toInt();
        if (id != null) res['servicio_ventas']!.add(id);
      }
    }
    // v1.8.0: adelantos vivos de su gaveta (en_pendiente=1 ya
    // codifica «aún no liquidados»: no hace falta el filtro de
    // cubiertos, que mira las liquidaciones por op_ids).
    for (final a in await LocalDb.instance.allMirror('adelantos')) {
      if (LocalDb.normalizarTelegramId(a['descuenta_a']) != telegramId) {
        continue;
      }
      if ((a['en_pendiente'] as num?)?.toInt() == 1) {
        final id = (a['id'] as num?)?.toInt();
        if (id != null) res['adelantos']!.add(id);
      }
    }
  }
  return res;
}

/// Entrenadores con pendiente de arqueo: [{telegram_id, nombre, cup, usd}].
/// Solo para el dueño.
Future<List<Map<String, dynamic>>> entrenadoresConPendiente() async {
  final porEntrenador = <int, Map<String, dynamic>>{};
  Future<void> acumular(int? tid, String? nombre, double cup, double usd) async {
    if (tid == null || (cup <= 0 && usd <= 0)) return;
    final e = porEntrenador.putIfAbsent(
        tid, () => {'telegram_id': tid, 'nombre': nombre ?? '—', 'cup': 0.0, 'usd': 0.0});
    e['cup'] = (e['cup'] as double) + cup;
    e['usd'] = (e['usd'] as double) + usd;
    if (nombre != null && nombre.isNotEmpty && e['nombre'] == '—') {
      e['nombre'] = nombre;
    }
  }

  // Se itera por entrenador conocido: los que tienen pagos/ventas.
  final tids = <int>{};
  for (final p in await LocalDb.instance.pagosPorFiltro(metodo: 'efectivo')) {
    final tid = LocalDb.normalizarTelegramId(p['telegram_user_id']);
    if (tid != null) tids.add(tid);
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    final tid = LocalDb.normalizarTelegramId(d['registrado_por']);
    if (tid != null) tids.add(tid);
  }
  for (final v in await ventasSuplementosCup()) {
    final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
    if (tid != null) tids.add(tid);
  }
  for (final v in await ventasSuplementosUsd()) {
    final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
    if (tid != null) tids.add(tid);
  }
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
    if (tid != null) tids.add(tid);
  }
  // Nombre de cada entrenador (del primer pago/venta que aparezca).
  for (final tid in tids) {
    String? nombre;
    for (final p in await LocalDb.instance
        .mirrorFiltrado('pagos', {'telegram_user_id': tid})) {
      nombre = p['registrado_por'] as String?;
      if (nombre != null && nombre.isNotEmpty) break;
    }
    final pend = await pendienteArqueo(tid);
    await acumular(tid, nombre, pend.cup, pend.usd);
  }
  final lista = porEntrenador.values.toList()
    ..sort((a, b) =>
        ((b['cup'] as double) + (b['usd'] as double))
            .compareTo((a['cup'] as double) + (a['usd'] as double)));
  return lista;
}

/// Historial de liquidaciones de un entrenador (más recientes primero).
Future<List<Map<String, dynamic>>> liquidacionesDeEntrenador(
    int telegramId) async {
  final res = <Map<String, dynamic>>[];
  for (final l
      in await LocalDb.instance.allMirror('liquidaciones_caja')) {
    if (LocalDb.normalizarTelegramId(l['entrenador_telegram_id']) ==
        telegramId) {
      res.add(l);
    }
  }
  res.sort((a, b) =>
      '${b['creada_en']}'.compareTo('${a['creada_en']}'));
  return res;
}

/// Crea una liquidación de caja (solo dueño). Encola la op `liquidar_caja`
/// con UUID idempotente y dispara el push en segundo plano.
/// Devuelve el UUID de la liquidación.
Future<String> crearLiquidacion({
  required int entrenadorTelegramId,
  required String entrenadorNombre,
  required double montoEsperado,
  required double montoEntregado,
  required Map<String, List<int>> opIds,
  String moneda = 'CUP',
  String? nota,
}) async {
  if (!AuthService().isOwner) {
    throw Exception('Solo el dueño puede liquidar caja');
  }
  if (montoEsperado < 0 || montoEntregado < 0) {
    throw Exception('Montos no pueden ser negativos');
  }
  if (montoEntregado - montoEsperado > 0.01) {
    throw Exception('Lo entregado no puede superar lo esperado');
  }
  final liqId = const Uuid().v4();
  final db = LocalDb.instance;
  await db.queueOp(
    opUuid: liqId,
    tipo: 'liquidar_caja',
    payload: {
      'liquidacion_id': liqId,
      'entrenador_telegram_id': entrenadorTelegramId,
      'entrenador_nombre': entrenadorNombre,
      'monto_esperado': montoEsperado,
      'monto_entregado': montoEntregado,
      'moneda': moneda,
      'op_ids': opIds,
      if (nota != null && nota.isNotEmpty) 'nota': nota,
      'creada_en': isoHabana(ahoraHabana()),
    },
  );
  // Push en segundo plano; el pull silencioso posterior trae la fila
  // espejo (invariante 1C: _download inmediato tras el 200 OK).
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return liqId;
}

/// Incidencias de sync pendientes de revisión (solo dueño).
Future<List<Map<String, dynamic>>> incidenciasSyncPendientes() async {
  final res = <Map<String, dynamic>>[];
  for (final i in await LocalDb.instance.allMirror('incidencias_sync')) {
    if ((i['estado'] as String?) == 'pendiente') res.add(i);
  }
  res.sort((a, b) => '${a['creada_en']}'.compareTo('${b['creada_en']}'));
  return res;
}

/// Historial de incidencias de sync ya resueltas (solo dueño).
Future<List<Map<String, dynamic>>> incidenciasSyncResueltas() async {
  final res = <Map<String, dynamic>>[];
  for (final i in await LocalDb.instance.allMirror('incidencias_sync')) {
    if ((i['estado'] as String?) != 'pendiente') res.add(i);
  }
  res.sort((a, b) => '${b['creada_en']}'.compareTo('${a['creada_en']}'));
  return res;
}

/// Aprueba una incidencia: el servidor aplica la op original a su tabla
/// destino. Solo dueño.
Future<void> aprobarIncidenciaSync(String incidenciaId) async {
  if (!AuthService().isOwner) {
    throw Exception('Solo el dueño puede aprobar incidencias');
  }
  await LocalDb.instance.queueOp(
    opUuid: const Uuid().v4(),
    tipo: 'aprobar_incidencia_sync',
    payload: {'incidencia_id': incidenciaId},
  );
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
}

/// Descarta una incidencia de sync. Solo dueño.
Future<void> descartarIncidenciaSync(String incidenciaId,
    {String? nota}) async {
  if (!AuthService().isOwner) {
    throw Exception('Solo el dueño puede descartar incidencias');
  }
  await LocalDb.instance.queueOp(
    opUuid: const Uuid().v4(),
    tipo: 'descartar_incidencia_sync',
    payload: {
      'incidencia_id': incidenciaId,
      if (nota != null && nota.isNotEmpty) 'nota': nota,
    },
  );
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
}

/// Días restantes de vigencia (negativo si vencido, null si sin pagos).
int? diasRestantes(String? pagadoHasta) {  if (pagadoHasta == null || pagadoHasta.length < 10) return null;
  // v1.3.2 (Argón post-fix): NO usar .toUtc() antes de extraer la fecha.
  // En Cuba (UTC-4/UTC-5), a las 8pm local ya es medianoche UTC del día
  // siguiente y restaría 1 día a todas las membresías por la noche.
  // Se extrae la fecha local y se compara en UTC.
  final hoy = ahoraHabana();
  final hoyDia = DateTime.utc(hoy.year, hoy.month, hoy.day);
  final p = pagadoHasta.substring(0, 10).split('-').map(int.parse).toList();
  final ph = DateTime.utc(p[0], p[1], p[2]);
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
  res.sort(compararPorNombre);
  return res;
}

/// Clientes que vencen en los próximos `dias` (incluye hoy).
Future<List<Map<String, dynamic>>> porVencer({int dias = 3}) async {
  final hoy = _hoyIso();
  final limite = ahoraHabana().add(Duration(days: dias));
  final limIso =
      '${limite.year.toString().padLeft(4, '0')}-${limite.month.toString().padLeft(2, '0')}-${limite.day.toString().padLeft(2, '0')}';
  final rows = await _activos();
  final res = rows.where((c) {
    // v1.7.0: la Cuenta a la Casa nunca está «por vencer».
    if (esCuentaCasa(c)) return false;
    final ph = c['pagado_hasta'] as String?;
    // v1.3.7: excluye los que vencen hoy (tienen su propio segmento).
    return ph != null &&
        ph.compareTo(hoy) > 0 &&
        ph.compareTo(limIso) <= 0;
  }).toList();
  res.sort((a, b) => '${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}'));
  return res;
}

// =====================================================================
// v1.3.6 (ítem 1A): bandeja "Avisos WhatsApp de Hoy".
// =====================================================================

/// Arma la bandeja de avisos de WhatsApp del día: cumpleañeros, vencen hoy,
/// por vencer (3 días) y recibos de pagos de hoy. Cada mapa trae:
/// tipo, cliente_id, nombre, telefono, detalle y mensaje (texto pre-rellenado
/// para wa.me).
///
/// Privacidad: los recibos se filtran por el entrenador logueado (si no es
/// dueño); las secciones por cliente son las mismas que ya ve en Listas.
Future<List<Map<String, dynamic>>> avisosWhatsappHoy() async {
  final esDueno = AuthService().isOwner;
  final tid = AuthService().telegramId;
  final hoy = hoyHabanaIso();
  final avisos = <Map<String, dynamic>>[];

  String nombreDe(Map<String, dynamic> c) =>
      '${c['nombre'] ?? 'Cliente'}'.trim();
  String telDe(Map<String, dynamic> c) => '${c['telefono'] ?? ''}';

  // 0) Vencidos (1-30 días de atraso). Van primero: son los que más
  // dinero representan (v1.3.8, 1C: Vencidos > Vencen hoy > Por vencer
  // > Recibos > Cumpleaños).
  final idsVencidos = <int>{};
  for (final c in await atrasados(masDe30: false)) {
    final cid = (c['id'] as num?)?.toInt() ?? 0;
    idsVencidos.add(cid);
    final ph = '${c['pagado_hasta'] ?? ''}';
    final dias = _diasAtraso(ph, hoy);
    avisos.add({
      'tipo': 'vencido',
      'cliente_id': cid,
      'nombre': nombreDe(c),
      'telefono': telDe(c),
      'detalle': dias > 0
          ? 'Vencido hace $dias día${dias == 1 ? '' : 's'}'
          : 'Mensualidad vencida',
      'mensaje': 'Hola ${nombreDe(c)}, te escribe Iron Body Gym.\n'
          'Tu mensualidad está vencida. Pásate por el gym para renovar. '
          '¡Te esperamos! 💪',
    });
  }

  // 1) Cumpleaños hoy.
  for (final c in await cumpleanosProximos(dias: 0)) {
    if ((c['_dias_para'] as int?) != 0) continue;
    avisos.add({
      'tipo': 'cumple',
      'cliente_id': (c['id'] as num?)?.toInt() ?? 0,
      'nombre': nombreDe(c),
      'telefono': telDe(c),
      'detalle': 'Cumple ${c['_cumple']} años',
      'mensaje': '¡Feliz cumpleaños, ${nombreDe(c)}! 🎂\n'
          'De parte de todo el equipo de Iron Body Gym, '
          'que tengas un día excelente 💪',
    });
  }

  // 2) Vencen hoy.
  final idsVenceHoy = <int>{};
  for (final c in await vencenHoy()) {
    final cid = (c['id'] as num?)?.toInt() ?? 0;
    idsVenceHoy.add(cid);
    avisos.add({
      'tipo': 'vence_hoy',
      'cliente_id': cid,
      'nombre': nombreDe(c),
      'telefono': telDe(c),
      'detalle': 'Su mensualidad vence hoy',
      'mensaje': 'Hola ${nombreDe(c)}, te escribe Iron Body Gym.\n'
          'Tu mensualidad vence hoy. Puedes renovarla pasando por el gym. '
          '¡Te esperamos! 💪',
    });
  }

  // 3) Por vencer (próximos 3 días, sin los que vencen hoy).
  for (final c in await porVencer(dias: 3)) {
    final cid = (c['id'] as num?)?.toInt() ?? 0;
    if (idsVenceHoy.contains(cid)) continue;
    final ph = '${c['pagado_hasta'] ?? ''}';
    final fechaCorta =
        ph.length >= 10 ? '${ph.substring(8, 10)}/${ph.substring(5, 7)}' : ph;
    avisos.add({
      'tipo': 'por_vencer',
      'cliente_id': cid,
      'nombre': nombreDe(c),
      'telefono': telDe(c),
      'detalle': 'Vence el $fechaCorta',
      'mensaje': 'Hola ${nombreDe(c)}, te escribe Iron Body Gym.\n'
          'Tu mensualidad vence el $fechaCorta. ¡No olvides renovar a tiempo! 💪',
    });
  }

  // 4) Recibos de pagos de hoy.
  final pagosHoy = (!esDueno && tid != null)
      ? await LocalDb.instance.pagosPorDiaYEntrenador(hoy, tid)
      : await LocalDb.instance.mirrorFiltrado('pagos', {'fecha': hoy});
  // Nombres de clientes (una sola carga).
  final clientes = <int, Map<String, dynamic>>{};
  for (final c in await LocalDb.instance.allMirror('clientes')) {
    final cid = (c['id'] as num?)?.toInt();
    if (cid != null) clientes[cid] = c;
  }
  for (final p in pagosHoy) {
    final cid = (p['cliente_id'] as num?)?.toInt() ?? 0;
    final c = clientes[cid];
    final nombre = c != null ? nombreDe(c) : 'Cliente $cid';
    final monto = (p['monto'] as num?)?.toDouble() ?? 0;
    if (monto <= 0) continue;
    avisos.add({
      'tipo': 'recibo',
      'cliente_id': cid,
      'nombre': nombre,
      'telefono': c != null ? telDe(c) : '',
      'detalle': 'Recibo: ${fmtMonto(monto)} CUP',
      'mensaje': '*Iron Body Gym* — Recibo\n'
          'Cliente: $nombre\n'
          'Monto: ${fmtMonto(monto)} CUP\n'
          'Fecha: $hoy\n'
          'Cobrado por: ${p['registrado_por'] ?? ''}'.trim(),
    });
  }

  return avisos;
}

/// Clientes inactivos (papelera de reciclaje).
/// v1.8.0: la cáscara (estado='eliminado') NO es papelera: ya
/// está eliminada y no se puede restaurar ni re-borrar desde
/// aquí (candado 4 de Argón).
Future<List<Map<String, dynamic>>> clientesInactivos() async {
  final todos = await LocalDb.instance.allMirror('clientes');
  final res = todos
      .where((c) => c['estado'] != 'activo' && !esClienteEliminado(c))
      .toList();
  res.sort(compararPorNombre);
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
    l.sort(compararPorNombre);
  }
  return mapa;
}

/// Nº de clientes distintos con al menos un pago con fecha en el mes
/// calendario actual (espejo `pagos`).
/// v1.3.3: excluye pagos con monto 0 (regalos de cumpleaños, promos) para
/// que no inflen el conteo que alimenta la comisión de entrenadores.
Future<int> pagosRealizadosMes() async {
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final ids = <int>{};
  // v1.3.4 (B2): filtro fecha LIKE 'yyyy-MM%' por columna indexada (v26).
  // El chequeo en Dart se conserva para las filas del fallback con
  // columna fecha NULL.
  for (final p in await LocalDb.instance.pagosPorFiltro(fechaPrefijo: pref)) {
    final f = p['fecha'] as String?;
    if (f != null && f.startsWith(pref)) {
      // v1.3.3: los regalos/promos (monto 0) no cuentan como pago cobrado.
      if ((p['monto'] as num? ?? 0) <= 0) continue;
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

/// Normaliza un teléfono cubano para wa.me (v1.3.3, Argón spec 3):
/// quita todo lo no numérico; 8 dígitos empezando con 5/6 → antepone
/// 53; 10 dígitos empezando con 535/536 → tal cual (veredicto de Argón:
/// un 53XXXXXXXX genérico podría ser un fijo de La Habana o un error).
/// Retorna '' si no es un móvil cubano válido.
String normalizarTelefonoWaMe(String tel) {
  final t = tel.replaceAll(RegExp(r'[^0-9]'), '');
  if (t.length == 8 && (t.startsWith('5') || t.startsWith('6'))) {
    return '53$t';
  }
  if (t.length == 10 && (t.startsWith('535') || t.startsWith('536'))) {
    return t;
  }
  return '';
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
  final hoy = ahoraHabana();
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
  final hoy = ahoraHabana();
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

/// v1.5.0 (Bloque G, decisión de Jc 2026-10-22): ¿los dígitos del
/// carnet NO forman una fecha AAMMDD real? La UI avisa en el momento
/// («esa fecha no existe, revísala») SIN bloquear el guardado: el
/// error típico es teclear día/mes invertidos (ej. «122303», mes 23).
///
/// Única fuente de verdad: [fechaNacDeCarnet]. Con menos de 6
/// dígitos no hay fecha que juzgar → no avisa (no se exige ninguna
/// longitud: ni 11 ni 6 rígidos; el formulario no cambia).
bool carnetFechaInvalida(String? carnet) {
  final d = (carnet ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length < 6) return false;
  return fechaNacDeCarnet(carnet) == null;
}

/// True si el carnet indica menos de 18 años (precio reducido).
bool esMenor(String? carnet) {
  final nac = fechaNacDeCarnet(carnet);
  if (nac == null) return false;
  final hoy = ahoraHabana();
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
  final hoy = ahoraHabana();
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
        // v1.4.6: la tarjeta de cumpleaños (cumpleanos.dart) lee '_dia' y
        // '_fecha_cumple' en AMBAS pestañas; sin estas claves la de
        // «Próximos 7 días» mostraba «Día 0» y «null · Cumple …».
        '_dia': nac.day,
        '_fecha_cumple':
            '${nac.day.toString().padLeft(2, '0')}/${nac.month.toString().padLeft(2, '0')}',
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
  final hoy = ahoraHabana();
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
Future<List<Map<String, dynamic>>> diariosDeHoy(
    {int? soloTelegramId}) async {
  final hoy = _hoyIso();
  // v1.3.6 (Argón): filtro SQL cuando no es el dueño.
  final todos = soloTelegramId == null
      ? await LocalDb.instance.allMirror('pagos_diarios')
      : await LocalDb.instance.mirrorFiltrado(
          'pagos_diarios', {'registrado_por': soloTelegramId});
  final res = todos.where((d) {
    if ((d['fecha'] as String?) != hoy) return false;
    // v1.3.6 (Argón): verificación de normalización post-SQL.
    if (soloTelegramId != null &&
        LocalDb.normalizarTelegramId(d['registrado_por']) !=
            soloTelegramId) {
      return false;
    }
    return true;
  }).toList();

  // Ops pendientes de pago_diario (aún no en mirror)
  // FIX (Gemini BUG 6): incluir 'enviada' — si solo se filtra 'pendiente',
  // el pago desaparece de la pantalla en cuanto se sube pero antes de
  // que el pull descargue el mirror confirmado.
  final db = await LocalDb.instance.db;
  final opsPendientes = await db.query(
    'ops_queue',
    columns: ['op_uuid', 'payload', 'telegram_id'],
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
  final pr = await preciosVigentes();
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
      // v1.3.1: registrado_por antes de armar la clave.
      payload['registrado_por'] ??= op['telegram_id'];
      // v1.3.6 (Argón): NO asumir que toda ops_queue es del usuario
      // actual. Verificar registrado_por del payload contra el filtro
      // (un entrenador pudo cambiar de cuenta antes de sincronizar).
      if (soloTelegramId != null &&
          LocalDb.normalizarTelegramId(payload['registrado_por']) !=
              soloTelegramId) {
        continue;
      }
      final clave =
          "$fecha|$hora|${payload['turno']}|${payload['cantidad']}|${payload['registrado_por']}";
      if (clavesMirror.contains(clave)) continue; // ya en mirror
      clavesMirror.add(clave);
      payload['op_uuid'] = op['op_uuid'];
      payload['es_optimista'] = true;
      // Normalizar campos que la UI espera del mirror
      payload['registrado_por_nombre'] ??= 'Tú';
      // v1.3.1: calcular total si no viene en el payload.
      if (payload['total'] == null) {
        final cant = (payload['cantidad'] as num?)?.toInt() ?? 0;
        payload['total'] = cant * (pr['diario'] ?? 200);
      }
      res.add(payload);
    } catch (_) {}
  }

  res.sort((a, b) =>
      '${b['registrado_por_nombre']}'.compareTo('${a['registrado_por_nombre']}'));
  return res;
}

/// v1.0.15: pagos diarios de una fecha específica (para reporte).
Future<List<Map<String, dynamic>>> diariosDeFecha(
    String fechaIso, {int? soloTelegramId}) async {
  // v1.3.6 (Argón): filtro SQL cuando no es el dueño.
  final todos = soloTelegramId == null
      ? await LocalDb.instance.allMirror('pagos_diarios')
      : await LocalDb.instance.mirrorFiltrado(
          'pagos_diarios', {'registrado_por': soloTelegramId});
  final res = todos.where((d) {
    if ((d['fecha'] as String?) != fechaIso) return false;
    if (soloTelegramId != null &&
        LocalDb.normalizarTelegramId(d['registrado_por']) !=
            soloTelegramId) {
      return false;
    }
    return true;
  }).toList();
  res.sort((a, b) =>
      '${b['registrado_por_nombre']}'.compareTo('${a['registrado_por_nombre']}'));
  return res;
}

/// v1.3.2: resumen mensual de pagos diarios.
/// Agrupa por turno y por entrenador. Solo pagos diarios (las
/// mensualidades tienen sus propios reportes).
/// Retorna {porTurno, porEntrenador, porDia, total}.
Future<Map<String, dynamic>> resumenMensualDiarios(
    int year, int month, {int? soloTelegramId}) async {
  // v1.3.6 (Argón): si soloTelegramId != null, filtrar en SQL por
  // registrado_por (normalizado). El dueño pasa null y ve todo.
  final todos = soloTelegramId == null
      ? await LocalDb.instance.allMirror('pagos_diarios')
      : await LocalDb.instance.mirrorFiltrado(
          'pagos_diarios', {'registrado_por': soloTelegramId});
  final porTurno = {
    'mañana': {'cantidad': 0.0, 'total': 0.0},
    'tarde': {'cantidad': 0.0, 'total': 0.0},
    'noche': {'cantidad': 0.0, 'total': 0.0},
  };
  final porEntrenador = <String, Map<String, double>>{};
  final porDia = <String, double>{};
  for (final d in todos) {
    // v1.3.6 (Argón): verificación de normalización post-SQL. El
    // mirrorFiltrado compara el valor crudo del JSON; si registrado_por
    // viene como String y soloTelegramId es int (o viceversa), el SQL
    // puede no matchear. Esta verificación garantiza el filtro.
    if (soloTelegramId != null &&
        LocalDb.normalizarTelegramId(d['registrado_por']) !=
            soloTelegramId) {
      continue;
    }
    final f = '${d['fecha'] ?? ''}';
    if (f.length < 10) continue;
    final dia = f.substring(0, 10);
    final partes = dia.split('-');
    if (partes.length < 3) continue;
    if (int.tryParse(partes[0]) != year ||
        int.tryParse(partes[1]) != month) {
      continue;
    }
    final total = (d['total'] as num?)?.toDouble() ?? 0;
    final cantidad = (d['cantidad'] as num?)?.toDouble() ?? 0;
    final t = '${d['turno'] ?? 'mañana'}'.toLowerCase();
    final key =
        t == 'tarde' ? 'tarde' : t == 'noche' ? 'noche' : 'mañana';
    porTurno[key]!['total'] = porTurno[key]!['total']! + total;
    porTurno[key]!['cantidad'] =
        porTurno[key]!['cantidad']! + cantidad;
    final quien = '${d['registrado_por_nombre'] ?? '—'}';
    final g = porEntrenador.putIfAbsent(
        quien, () => {'total': 0.0, 'cantidad': 0.0});
    g['total'] = g['total']! + total;
    g['cantidad'] = g['cantidad']! + cantidad;
    porDia[dia] = (porDia[dia] ?? 0) + total;
  }
  return {
    'porTurno': porTurno,
    'porEntrenador': porEntrenador,
    'porDia': porDia,
    'total': porDia.values.fold(0.0, (a, b) => a + b),
  };
}
/// v1.3.2 (Argón #11): substring seguro para fechas.
/// Retorna los primeros N caracteres o el string completo si es más corto.
String fechaCorta(dynamic v, int n) {
  final s = '$v';
  return s.length >= n ? s.substring(0, n) : s;
}

/// v1.3.2 (Argón): turnos sin reporte explícito en pagos_diarios.
/// Se basa SOLO en el campo `turno` declarado, no en la hora de pagos
/// sueltos (evita falsos positivos: un pago de mensualidad por la tarde
/// no implica que el turno mañana reportó su caja).
/// Retorna la lista de turnos esperados sin registro ('mañana', 'tarde').
/// v1.3.9 (Bug 3, Argón): filtro por día de la semana + exigibilidad por hora.
/// - Domingo: gym cerrado → siempre [].
/// - Sábado: solo se evalúa 'mañana' (7am-12pm); 'tarde' jamás.
/// - Lunes-viernes: 'mañana' exigible desde las 12:30, 'tarde' desde las 20:30
///   (30 min de gracia tras el cierre; hora de La Habana).
/// - Fechas pasadas (anteriores a hoy): todo turno laborable no reportado
///   es exigible sin importar la hora actual.
Future<List<String>> turnosSinReporte(String fechaIso,
    {int? soloTelegramId}) async {
  // v1.3.2 (Argón #15): para hoy usar diariosDeHoy (incluye la cola
  // optimista offline); normalizar 'manana'; cruzar con turnos_cierre
  // (un turno cerrado sin pagos diarios también cuenta como reportado).
  // v1.3.6: propagar el filtro por entrenador.
  final datos = fechaIso == _hoyIso()
      ? await diariosDeHoy(soloTelegramId: soloTelegramId)
      : await diariosDeFecha(fechaIso, soloTelegramId: soloTelegramId);
  final turnos = datos
      .map((d) =>
          '${d['turno'] ?? ''}'.toLowerCase().replaceAll('manana', 'mañana'))
      .toSet();
  try {
    final cierres = await LocalDb.instance.allMirror('turnos_cierre');
    for (final c in cierres) {
      if ('${c['fecha'] ?? ''}'.substring(0, 10) == fechaIso) {
        turnos.add('${c['turno'] ?? ''}'
            .toLowerCase()
            .replaceAll('manana', 'mañana'));
      }
    }
  } catch (_) {}
  // v1.3.9 (Bug 3): día de la semana de la fecha evaluada.
  final fecha = DateTime.tryParse(fechaIso);
  final dow = fecha?.weekday ?? 7; // 1=lunes … 7=domingo
  if (dow == DateTime.sunday) return []; // Gym cerrado.
  final esHoy = fechaIso == _hoyIso();
  // Turnos laborables según el día.
  final esperados = <String>[
    'mañana',
    if (dow != DateTime.saturday) 'tarde', // Sábado: solo mañana.
  ];
  if (!esHoy) {
    // Fecha pasada: todo lo no reportado es exigible.
    return esperados.where((t) => !turnos.contains(t)).toList();
  }
  // Hoy: exigir solo si ya pasó la hora de cierre + 30 min de gracia.
  final ahora = ahoraHabana();
  final horaNum = ahora.hour + ahora.minute / 60.0;
  final mananaExigible = horaNum >= 12.5;
  final tardeExigible = horaNum >= 20.5;
  return [
    if (!turnos.contains('mañana') && mananaExigible) 'mañana',
    if (!turnos.contains('tarde') &&
        tardeExigible &&
        dow != DateTime.saturday)
      'tarde',
  ];
}

/// v1.0.15: resumen de pagos diarios por turno para una fecha.
/// Devuelve {mañana: {cantidad, total}, tarde: {cantidad, total}}.
Future<Map<String, Map<String, double>>> resumenDiarioPorTurno(
    String fechaIso, {int? soloTelegramId}) async {
  // v1.3.1: para hoy, incluir pagos optimistas en cola.
  // v1.3.6: propagar el filtro por entrenador.
  final datos = fechaIso == _hoyIso()
      ? await diariosDeHoy(soloTelegramId: soloTelegramId)
      : await diariosDeFecha(fechaIso, soloTelegramId: soloTelegramId);
  final res = {
    'mañana': {'cantidad': 0.0, 'total': 0.0},
    'tarde': {'cantidad': 0.0, 'total': 0.0},
    'noche': {'cantidad': 0.0, 'total': 0.0},
  };
  for (final d in datos) {
    final turno = '${d['turno'] ?? 'mañana'}'.toLowerCase();
    final key = turno == 'tarde'
        ? 'tarde'
        : turno == 'noche'
            ? 'noche'
            : 'mañana';
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
  final hoy = ahoraHabana();
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
/// [fecha] opcional (YYYY-MM-DD): si se omite usa hoy. El cierre de
/// turno la fija a fecha_turno para que el dinero contado coincida con
/// el día que declara el payload aunque se cierre pasada la medianoche
/// (fix medianoche, Argón).
Future<(double, double)> miTurnoHoy(int? telegramId, {String? fecha}) async {
  if (telegramId == null) return (0.0, 0.0);
  final hoy = fecha ?? _hoyIso();
  double cobrado = 0;
  // v1.3.4 (ítem 2): lectura indexada (fecha, telegram_user_id) en vez
  // de allMirror('pagos') + filtro en Dart. Incluye fallback para filas
  // con columnas NULL.
  for (final p in await LocalDb.instance.pagosPorDiaYEntrenador(hoy, telegramId)) {
    cobrado += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) == telegramId &&
        (d['fecha'] as String?) == hoy) {
      cobrado += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) == telegramId &&
        (v['fecha'] as String?) == hoy) {
      cobrado += totalVentaCup(v);
    }
  }
  // v1.3.1: incluir ops pendientes de hoy en cobrado (offline).
  final pr = await preciosVigentes();
  for (final op in await LocalDb.instance.pendingOps()) {
    if (op['telegram_id'] != telegramId) continue;
    try {
      final payload =
          jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final fecha = (payload['fecha'] as String?)?.substring(0, 10) ?? '';
      if (fecha != hoy) continue;
      cobrado += _montoEfectivoOp(op, pr);
    } catch (_) {}
  }
  final pendiente = await pendienteEntrega(telegramId);
  return (cobrado, pendiente);
}

/// Conteo de pagos del DÍA de un entrenador (no solo de la franja):
/// espejo (pagos, pagos_diarios, ventas) + ops pendientes de hoy.
/// Misma cobertura que miTurnoHoy() pero contando registros en vez de
/// sumar montos. Para el pagos_count del cierre de turno (auditoría
/// ChatGPT #6): NO se calcula sobre la cola después de sincronizar,
/// porque tras un sync exitoso daría 0 aunque hubo pagos.
/// NOTA: pagos_count y total_cobrado son movimientos del DÍA del
/// entrenador (lo que devuelve miTurnoHoy), no solo de la franja que
/// se cierra. Las franjas del gym son informativas; el cuadre es diario.
/// [fecha] opcional (YYYY-MM-DD): si se omite usa hoy. Ver [miTurnoHoy].
Future<int> conteoPagosDia(int? telegramId, {String? fecha}) async {
  if (telegramId == null) return 0;
  final hoy = fecha ?? _hoyIso();
  final pr = await preciosVigentes();
  var n = 0;
  // v1.3.4 (ítem 2): lectura indexada (fecha, telegram_user_id) en vez
  // de allMirror('pagos') + filtro en Dart. El descarte de 'cortesia'
  // sigue en Dart: en SQL, `metodo != 'cortesia'` excluiría también los
  // NULL, y la semántica vieja los contaba (Argón spec 1: solo el
  // metodo 'cortesia' explícito se excluye).
  for (final p in await LocalDb.instance.pagosPorDiaYEntrenador(hoy, telegramId)) {
    // v1.3.3 (Argón spec 1): los regalos de cumpleaños (metodo
    // 'cortesia', monto 0) no cuentan como cobro: no inflan el
    // pagos_count del cierre ni generan comisión.
    if ((p['metodo'] as String?) == 'cortesia') continue;
    n++;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) == telegramId &&
        (d['fecha'] as String?) == hoy) {
      n++;
    }
  }
  for (final v in await LocalDb.instance.allMirror('ventas_suplementos')) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) == telegramId &&
        (v['fecha'] as String?) == hoy) {
      n++;
    }
  }
  for (final op in await LocalDb.instance.pendingOps()) {
    if (op['telegram_id'] != telegramId) continue;
    try {
      final payload =
          jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final fecha = (payload['fecha'] as String?)?.substring(0, 10) ?? '';
      if (fecha != hoy) continue;
      // Solo tipos que representan un cobro (igual que _montoEfectivoOp
      // cubre); el resto no cuenta como "pago".
      if (_montoEfectivoOp(op, pr) > 0) n++;
    } catch (_) {}
  }
  return n;
}

/// Desglose del pendiente: (mensualidades, diarios, servicios).
/// post-1.8.0 (ítem 10): los servicios son las ventas en efectivo de
/// SU gaveta (responsable del efectivo, ítem 8) aún sin entregar.
Future<
    (
      List<Map<String, dynamic>>,
      List<Map<String, dynamic>>,
      List<Map<String, dynamic>>
    )> detallePendiente(int? telegramId) async {
  final mens = <Map<String, dynamic>>[];
  final diarios = <Map<String, dynamic>>[];
  final servicios = <Map<String, dynamic>>[];
  if (telegramId == null) return (mens, diarios, servicios);
  // v1.3.4 (B2): filtro por columnas indexadas (v26);
  // 'entregado' no tiene columna y sigue filtrándose en Dart.
  for (final p in await LocalDb.instance
      .pagosPorFiltro(telegramId: telegramId, metodo: 'efectivo')) {
    if (esPendiente(p['entregado'])) {
      mens.add(p);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) == telegramId &&
        esPendiente(d['entregado'])) {
      diarios.add(d);
    }
  }
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    final resp =
        LocalDb.normalizarTelegramId(v['responsable_efectivo_id']) ??
            LocalDb.normalizarTelegramId(v['registrado_por']);
    if (resp == telegramId &&
        (v['metodo'] as String?) == 'efectivo' &&
        (v['casa'] as num?)?.toInt() != 1 &&
        esPendiente(v['entregado'])) {
      servicios.add(v);
    }
  }
  mens.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  diarios.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  servicios.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return (mens, diarios, servicios);
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

  // v1.3.4 (B2): filtro por columna indexada telegram_user_id (v26).
  for (final p in await LocalDb.instance.pagosPorFiltro(telegramId: telegramId)) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length < 10) continue;
    final cid = p['cliente_id'] as int?;
    final quien = nombres[cid] ?? 'Cliente $cid';
    final metodo = '${p['metodo'] ?? 'efectivo'}';
    suma(f.substring(0, 10), (p['monto'] as num?)?.toDouble() ?? 0,
        metodo, '$quien · ${p['periodo'] ?? 'mensual'} ($metodo)');
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
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
  // v1.3.4 (B2): filtro por columna indexada telegram_user_id (v26);
  // 'entregado' no tiene columna y sigue filtrándose en Dart.
  for (final p in await LocalDb.instance.pagosPorFiltro(telegramId: telegramId)) {
    if (esPendiente(p['entregado'])) continue;
    final f = p['fecha'] as String?;
    if (f != null && (fecha == null || f.compareTo(fecha) > 0)) {
      fecha = f;
      monto = (p['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
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
  final h = ahoraHabana().hour;
  if (h >= 5 && h < 12) return 'Buenos días';
  if (h >= 12 && h < 18) return 'Buenas tardes';
  return 'Buenas noches';
}

/// Turno actual: Mañana (5-12), Tarde (12-18), Noche (resto).
/// Mejora 11 del Home.
String turnoActual() {
  final h = ahoraHabana().hour;
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
      ahoraHabana().subtract(const Duration(days: 1)));
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

  // v1.3.4 (B2): filtro por columnas indexadas (v26);
  // 'entregado' no tiene columna y sigue filtrándose en Dart.
  for (final p in await LocalDb.instance
      .pagosPorFiltro(metodo: 'efectivo', telegramId: telegramId)) {
    if (!esPendiente(p['entregado'])) continue;
    considera(p['fecha'] as String?);
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    if (telegramId != null &&
        LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) {
      continue;
    }
    considera(d['fecha'] as String?);
  }
  if (masVieja == null) return null;
  final hoy = ahoraHabana();
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
  final hoy = _isoDia(ahoraHabana());
  double total = 0;
  // v1.3.4 (B2): full scan INTENCIONAL — el filtro es `entregado_ts`
  // (fecha de confirmación que guarda el servidor), campo del JSON sin
  // columna indexada en la migración v26. No migra a SQL indexado.
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
  final hoy = ahoraHabana();
  final lunes =
      hoy.subtract(Duration(days: hoy.weekday - 1));
  final inicio = _isoDia(DateTime(lunes.year, lunes.month, lunes.day));
  double cobrado = 0;
  // v1.3.4 (B2): filtro fecha >= inicio por columna indexada (v26).
  // El chequeo en Dart se conserva para las filas del fallback con
  // columna fecha NULL.
  for (final p in await LocalDb.instance.pagosPorFiltro(fechaDesde: inicio)) {
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
    if (esClienteEliminado(c)) continue; // v1.8.0: no es persona
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
  final hoy = _isoDia(ahoraHabana());
  double mens = 0, diar = 0;
  var n = 0;
  for (final p in await LocalDb.instance
      .pagosPorDiaMetodo(hoy, 'efectivo', telegramId)) {
    if (!esPendiente(p['entregado'])) continue;
    mens += (p['monto'] as num?)?.toDouble() ?? 0;
    n++;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    if (telegramId != null &&
        LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) {
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double t = 0;
  for (final p
      in await LocalDb.instance.pagosMesPorEntrenador(telegramId, pref)) {
    t += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) continue;
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
  for (final p in await LocalDb.instance
      .pagosPorDiaYEntrenador(hoy, telegramId)) {
    t += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) continue;
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
  final hoy = ahoraHabana();
  final desde = hoy.subtract(const Duration(days: 6));
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  final desdeIso = iso(desde);
  final hoyIso = iso(hoy);
  double t = 0;
  for (final p in await LocalDb.instance
      .pagosRangoPorEntrenador(telegramId, desdeIso, hoyIso)) {
    t += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
    final f = '${d['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 && dia.compareTo(hoyIso) <= 0) {
        t += (d['total'] as num?)?.toDouble() ?? 0;
      }
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) continue;
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double efectivo = 0, transferencia = 0, suplementos = 0;
  for (final p
      in await LocalDb.instance.pagosMesPorEntrenador(telegramId, pref)) {
    final m = (p['monto'] as num?)?.toDouble() ?? 0;
    if ('${p['metodo']}' == 'transferencia') {
      transferencia += m;
    } else {
      efectivo += m;
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      efectivo += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) continue;
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double mensual = 0, diario = 0, suplementos = 0;
  for (final p
      in await LocalDb.instance.pagosMesPorEntrenador(telegramId, pref)) {
    mensual += (p['monto'] as num?)?.toDouble() ?? 0;
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      diario += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) continue;
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porDia = <String, double>{};
  for (final p
      in await LocalDb.instance.pagosMesPorEntrenador(telegramId, pref)) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((p['monto'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != telegramId) continue;
    final f = '${d['fecha'] ?? ''}';
    if (f.startsWith(pref) && f.length >= 10) {
      final dia = f.substring(0, 10);
      porDia[dia] =
          (porDia[dia] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final v in await ventasSuplementosCup()) {
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) continue;
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
  for (final p
      in await LocalDb.instance.pagosEfectivoPorEntrenador(tid)) {
    if (!esPendiente(p['entregado'])) continue;
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
    if (LocalDb.normalizarTelegramId(d['registrado_por']) != tid) continue;
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
  // v1.3.1 (UI2): ventas de suplementos pendientes del entrenador.
  for (final s in await LocalDb.instance.allMirror('ventas_suplementos')) {
    if (!esPendiente(s['entregado'])) continue;
    if (LocalDb.normalizarTelegramId(s['registrado_por']) != tid) continue;
    final moneda = s['moneda'] as String? ?? 'CUP';
    items.add({
      'tipo': 'suplemento',
      'suplemento_id': (s['id'] as num?)?.toInt(),
      'fecha': '${s['creada_en'] ?? s['fecha'] ?? ''}',
      'suplemento_nombre': '${s['suplemento_nombre'] ?? ''}',
      'cantidad': (s['cantidad'] as num?)?.toInt() ?? 1,
      'total': moneda == 'USD' ? totalVentaUsd(s) : totalVentaCup(s),
      'moneda': moneda,
      'nota': '${s['nota'] ?? ''}',
    });
  }
  // post-1.8.0 (ítem 10): servicios en efectivo de SU gaveta — la
  // gaveta es del RESPONSABLE del efectivo (ítem 8), no de quien
  // registró; sin la columna se cae a registrado_por. Los reversos
  // traen cantidad negativa y netean en el total.
  for (final s in await LocalDb.instance.allMirror('servicio_ventas')) {
    if (!esPendiente(s['entregado'])) continue;
    if ('${s['metodo']}' != 'efectivo') continue;
    if (((s['casa'] as num?)?.toInt() ?? 0) == 1) continue;
    final resp =
        LocalDb.normalizarTelegramId(s['responsable_efectivo_id']) ??
            LocalDb.normalizarTelegramId(s['registrado_por']);
    if (resp != tid) continue;
    items.add({
      'tipo': 'servicio',
      'servicio_id': (s['id'] as num?)?.toInt(),
      'fecha': '${s['fecha'] ?? ''}',
      'servicio_tipo': '${s['tipo'] ?? ''}',
      'cantidad': (s['cantidad'] as num?)?.toInt() ?? 1,
      'total': ((s['precio_unitario'] as num?)?.toDouble() ?? 0) *
          ((s['cantidad'] as num?)?.toDouble() ?? 0),
      'moneda': 'CUP',
      'cliente_nombre': '${s['cliente_nombre'] ?? ''}',
      'nota': '',
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

  for (final p
      in await LocalDb.instance.pagosEfectivoPorEntrenador(null)) {
    if (!esPendiente(p['entregado'])) continue;
    final tid = LocalDb.normalizarTelegramId(p['telegram_user_id']);
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
    final tid = LocalDb.normalizarTelegramId(d['registrado_por']);
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
  // v1.3.1 (B1): ventas de suplementos pendientes de entrega.
  for (final s in await LocalDb.instance.allMirror('ventas_suplementos')) {
    if (!esPendiente(s['entregado'])) continue;
    final tid = LocalDb.normalizarTelegramId(s['registrado_por']);
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    final moneda = s['moneda'] as String? ?? 'CUP';
    final monto = moneda == 'USD' ? totalVentaUsd(s) : totalVentaCup(s);
    lista.add({
      'id': s['id'],
      'monto': monto,
      'moneda': moneda,
      'creada_en': s['creada_en'] ?? s['fecha'],
      'tipo': 'suplemento',
      'descripcion': 'Venta suplemento: ${s['suplemento_nombre'] ?? ''}',
      'entrenador_nombre':
          '${s['registrado_por_nombre'] ?? 'Entrenador $tid'}',
      'trainer_telegram_id': tid,
    });
  }
  // post-1.8.0 (ítem 10): servicios en efectivo pendientes, por
  // RESPONSABLE del efectivo (ítem 8) con fallback a registrado_por.
  for (final s in await LocalDb.instance.allMirror('servicio_ventas')) {
    if (!esPendiente(s['entregado'])) continue;
    if ('${s['metodo']}' != 'efectivo') continue;
    if (((s['casa'] as num?)?.toInt() ?? 0) == 1) continue;
    final tid =
        LocalDb.normalizarTelegramId(s['responsable_efectivo_id']) ??
            LocalDb.normalizarTelegramId(s['registrado_por']);
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    final cant = (s['cantidad'] as num?)?.toInt() ?? 1;
    lista.add({
      'id': s['id'],
      'monto': ((s['precio_unitario'] as num?)?.toDouble() ?? 0) * cant,
      'moneda': 'CUP',
      'creada_en': s['fecha'],
      'tipo': 'servicio',
      'descripcion': switch ('${s['tipo']}') {
        'dosis_con_agua' => 'Combo (dosis con agua)',
        'agua_suelta' => 'Pomo de agua',
        _ => 'Ración (dosis)',
      },
      'entrenador_nombre':
          '${s['registrado_por_nombre'] ?? 'Entrenador $tid'}',
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
  List<int> suplementoIds = const [],
  List<int> servicioIds = const [],
  required String entrenadorNombre,
  int? trainerTelegramId,
}) async {
  final db = LocalDb.instance;
  final d = await db.db;
  final opUuid = const Uuid().v4();
  // v1.3.4: timestamp canónico de La Habana (con offset -05:00), no UTC.
  final ahora = isoHabana(ahoraHabana());

  /// Marca como entregado actualizando el JSON data (las tablas espejo
  /// solo tienen id, data, sync_seq — no hay columna 'entregado').
  Future<void> marcarEntregados(
      Transaction txn, String tabla, List<int> ids) async {
    for (final id in ids) {
      final rows = await txn.query(tabla,
          columns: ['data'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) continue;
      final data =
          Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String));
      data['entregado'] = 1;
      data['entregado_ts'] = ahora;
      await txn.update(
        tabla,
        {'data': jsonEncode(data)},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  await d.transaction((txn) async {
    // 1. Marcar mirrors como entregados (optimismo persistente).
    await marcarEntregados(txn, 'pagos', mensualIds);
    await marcarEntregados(txn, 'pagos_diarios', diarioIds);
    await marcarEntregados(txn, 'ventas_suplementos', suplementoIds);
    await marcarEntregados(txn, 'servicio_ventas', servicioIds);
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
        'suplemento_ids': suplementoIds,
        // Ítem 10 (Argón): la confirmación va SIEMPRE por lista de
        // ids explícita — también «confirmar todo»: la pantalla
        // empaqueta los ids que está mostrando, nunca una orden
        // ciega por categoría o por entrenador.
        'servicio_ids': servicioIds,
      }),
      'estado': 'pendiente',
      'creada_ts': ahora,
      'user_id': AuthService().userId,
      'telegram_id': AuthService().telegramId,
    });
  });
}

/// Pendiente de entregar por entrenador (vista del dueño).
///
/// Devuelve filas {id, nombre, total (CUP), total_usd, n} ordenadas
/// por CUP descendente (desempate: USD descendente). `n` cuenta
/// TODOS los movimientos pendientes, incluidos los de USD.
///
/// Fuentes: SOLO el espejo (lo ya sincronizado). La vista del
/// entrenador (pendienteEntrega/pendienteEntregaUsd) suma además SU
/// cola local sin sincronizar, que en el teléfono del dueño no
/// existe; sobre lo sincronizado ambas vistas coinciden exactamente
/// (misma regla: esPendiente + normalizarTelegramId + totalVenta*).
/// El USD faltaba aquí hasta 2026-10-21 (panel): el dueño no veía
/// los dólares pendientes de cada entrenador, solo el total global.
Future<List<Map<String, dynamic>>> pendientePorEntrenador(
    {int? excluirTid}) async {
  final mapa = <int, Map<String, dynamic>>{};
  Map<String, dynamic> entrada(int id, String nombre) =>
      mapa.putIfAbsent(id, () => {
            'id': id,
            'nombre': nombre,
            'total': 0.0,
            'total_usd': 0.0,
            'n': 0,
          });
  void suma(int id, String nombre, double monto) {
    final e = entrada(id, nombre);
    e['total'] = (e['total'] as double) + monto;
    e['n'] = (e['n'] as int) + 1;
  }

  void sumaUsd(int id, String nombre, double monto) {
    final e = entrada(id, nombre);
    e['total_usd'] = (e['total_usd'] as double) + monto;
    e['n'] = (e['n'] as int) + 1;
  }

  for (final p
      in await LocalDb.instance.pagosEfectivoPorEntrenador(null)) {
    if (!esPendiente(p['entregado'])) continue;
    final tid = LocalDb.normalizarTelegramId(p['telegram_user_id']);
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    suma(tid, '${p['registrado_por'] ?? 'Entrenador $tid'}',
        (p['monto'] as num?)?.toDouble() ?? 0);
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if (!esPendiente(d['entregado'])) continue;
    final tid = LocalDb.normalizarTelegramId(d['registrado_por']);
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    suma(tid, '${d['registrado_por_nombre'] ?? 'Entrenador $tid'}',
        (d['total'] as num?)?.toDouble() ?? 0);
  }
  // Gemini: incluir ventas de suplementos en CUP pendientes.
  for (final v in await ventasSuplementosCup()) {
    if (!esPendiente(v['entregado'])) continue;
    final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    suma(tid, '${v['registrado_por_nombre'] ?? 'Entrenador $tid'}',
        totalVentaCup(v));
  }
  // USD: misma regla que pendienteEntregaUsd sobre el espejo
  // (ventas USD pendientes del entrenador). Crea la entrada aunque
  // el entrenador no tenga nada en CUP.
  for (final v in await ventasSuplementosUsd()) {
    if (!esPendiente(v['entregado'])) continue;
    final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    sumaUsd(tid, '${v['registrado_por_nombre'] ?? 'Entrenador $tid'}',
        totalVentaUsd(v));
  }
  // post-1.8.0 (ítem 10): servicios en efectivo pendientes, por
  // RESPONSABLE del efectivo (ítem 8) con fallback a registrado_por.
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    if (!esPendiente(v['entregado'])) continue;
    if ('${v['metodo']}' != 'efectivo') continue;
    if (((v['casa'] as num?)?.toInt() ?? 0) == 1) continue;
    final tid =
        LocalDb.normalizarTelegramId(v['responsable_efectivo_id']) ??
            LocalDb.normalizarTelegramId(v['registrado_por']);
    if (tid == null) continue;
    if (excluirTid != null && tid == excluirTid) continue;
    suma(tid, '${v['registrado_por_nombre'] ?? 'Entrenador $tid'}',
        ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
            ((v['cantidad'] as num?)?.toDouble() ?? 0));
  }
  final l = mapa.values.toList()
    ..sort((a, b) {
      final c = (b['total'] as double).compareTo(a['total'] as double);
      if (c != 0) return c;
      return (b['total_usd'] as double)
          .compareTo(a['total_usd'] as double);
    });
  return l;
}

/// Ingresos del mes calendario actual (espejo `pagos` + diarios).
/// v1.0.15: ingresos del mes anterior (para comparativa).
Future<double> ingresosMesAnterior() async {
  final n = ahoraHabana();
  var mes = n.month - 1;
  var anio = n.year;
  if (mes < 1) {
    mes = 12;
    anio--;
  }
  final pref = '${anio.toString().padLeft(4, '0')}-'
      '${mes.toString().padLeft(2, '0')}';
  double t = 0;
  for (final p in await LocalDb.instance.pagosDelMes(pref)) {
    t += (p['monto'] as num?)?.toDouble() ?? 0;
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double efectivo = 0, transferencia = 0, suplementos = 0;
  for (final p in await LocalDb.instance.pagosDelMes(pref)) {
    final m = (p['monto'] as num?)?.toDouble() ?? 0;
    if ('${p['metodo']}' == 'transferencia') {
      transferencia += m;
    } else {
      efectivo += m;
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  double mensual = 0, diario = 0, suplementos = 0;
  for (final p in await LocalDb.instance.pagosDelMes(pref)) {
    mensual += (p['monto'] as num?)?.toDouble() ?? 0;
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
  final n = ahoraHabana();
  final dia = n.day;
  final diasMes = DateTime(n.year, n.month + 1, 0).day;
  if (dia < 1) return 0;
  final actual = await ingresosMes();
  return actual / dia * diasMes;
}

/// v1.0.15: mejor y peor día del mes.
Future<Map<String, Map<String, dynamic>>> mejorPeorDia() async {
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porDia = <String, double>{};
  for (final p in await LocalDb.instance.pagosDelMes(pref)) {
    final f = '${p['fecha'] ?? ''}';
    if (f.length >= 10) {
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  int c = 0;
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    if (esClienteEliminado(cl)) continue; // v1.8.0: no es persona
    final f = '${cl['creado'] ?? cl['fecha_inscripcion'] ?? ''}';
    if (f.startsWith(pref)) c++;
  }
  return c;
}

/// v1.0.15: clientes por vencer en 7 días.
Future<List<Map<String, dynamic>>> porVencer7Dias() async {
  final hoy = ahoraHabana();
  final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
  final limite = hoyDia.add(const Duration(days: 7));
  final res = <Map<String, dynamic>>[];
  for (final c in await LocalDb.instance.allMirror('clientes')) {
    try {
      // v1.8.0: la cáscara conserva pagado_hasta (lo lee la
      // nómina) pero NO es una persona por vencer.
      if (esClienteEliminado(c)) continue;
      // v1.7.0: la Cuenta a la Casa queda fuera (no vence nunca).
      if (esCuentaCasa(c)) continue;
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
  final hoy = ahoraHabana();
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
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porEntrenador = <String, double>{};
  final nombres = <String, String>{};
  for (final p in await LocalDb.instance.pagosDelMes(pref)) {
    final ent =
        '${p['registrado_por_nombre'] ?? p['registrado_por'] ?? '?'}';
    porEntrenador[ent] =
        (porEntrenador[ent] ?? 0) + ((p['monto'] as num?)?.toDouble() ?? 0);
  }
  for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
    if ('${d['fecha'] ?? ''}'.startsWith(pref)) {
      final ent =
          '${d['registrado_por_nombre'] ?? d['registrado_por'] ?? '?'}';
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
  final limite = ahoraHabana().subtract(const Duration(days: 90));
  int c = 0;
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    try {
      if (esClienteEliminado(cl)) continue; // v1.8.0: no es persona
      // v1.7.0: la Cuenta a la Casa no cuenta como inactiva por
      // vencimiento (no tiene vencimiento).
      if (esCuentaCasa(cl)) continue;
      final ph = '${cl['pagado_hasta'] ?? ''}';
      if (ph.length < 10) continue;
      final v = DateTime.parse(ph.substring(0, 10));
      if (v.isBefore(limite)) c++;
    } catch (_) {}
  }
  return c;
}

Future<double> ingresosMes() async {
  final n = ahoraHabana();
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
  // v1.3.4 (ítem 2): full scan INTENCIONAL — agregación analítica sobre
  // TODOS los pagos sin filtro por fecha/cliente/entrenador/método; el
  // monto vive en el JSON (sin columna indexada) y hay que leer cada
  // fila de todos modos. No migra a SQL indexado.
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
  final hoy = ahoraHabana();
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
  // v1.3.2 (Argón #5): incluir suplementos en CUP como en ingresosHoy/Mes.
  for (final v in await ventasSuplementosCup()) {
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

/// Pagos del período para desglose (v1.0.11).
/// periodo: 'hoy', 'semana', 'mes'. Devuelve lista con monto y método.
Future<List<Map<String, dynamic>>> pagosDelPeriodo(
    String periodo) async {
  String desdeIso, hastaIso;
  final hoy = ahoraHabana();
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
    // Ventana mensual ÚNICA del dashboard: el detalle del mes cubre
    // el mes completo, igual que la tarjeta «Este mes»
    // (ingresosMes). Antes cortaba en hoy y una fila con fecha
    // futura dentro del mes salía en la tarjeta pero no en su
    // detalle (panel 2026-10-21).
    hastaIso = iso(DateTime(hoy.year, hoy.month + 1, 0));
  }
  final out = <Map<String, dynamic>>[];
  // Cada fila lleva su ORIGEN ('pago' | 'diario' | 'suplemento')
  // para que el detalle del dashboard haga una partición real:
  // antes diarios y suplementos viajaban plegados como
  // metodo='efectivo' y el detalle los sumaba dos veces
  // (panel 2026-10-21).
  // v1.3.4 (ítem 2): mirrorPorFecha usa la columna indexada `fecha`
  // para el espejo `pagos` (misma semántica que el filtro en Dart).
  for (final p in await LocalDb.instance
      .mirrorPorFecha('pagos', 'fecha', desdeIso, hastaIso)) {
    out.add({
      'monto': (p['monto'] as num?)?.toDouble() ?? 0,
      'metodo': '${p['metodo'] ?? 'efectivo'}',
      'origen': 'pago',
    });
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
          'origen': 'diario',
        });
      }
    }
  }
  // v1.3.2 (Argón #5): incluir suplementos en CUP en el desglose.
  for (final v in await ventasSuplementosCup()) {
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (dia.compareTo(desdeIso) >= 0 &&
          dia.compareTo(hastaIso) <= 0) {
        out.add({
          'monto': totalVentaCup(v),
          'metodo': 'efectivo',
          'origen': 'suplemento',
        });
      }
    }
  }
  return out;
}

/// Ingresos por día de los últimos 7 días (v1.0.8).
/// Devuelve lista de {dia: 'Lun', fecha: 'YYYY-MM-DD', monto: 123.0}
/// ordenada de más antiguo a hoy. La `fecha` la necesita el gráfico
/// del dashboard para abrir el detalle del día tocado (sin ella, la
/// vista de 7 días lanzaba un TypeError al tocar una barra; la de
/// 30 días ya la traía).
/// v1.0.16: usa ingresosPorDia() centralizado (incluye pagos diarios).
Future<List<Map<String, dynamic>>> ingresosUltimos7Dias() async {
  final hoy = ahoraHabana();
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
      'fecha': diaIso,
      'monto': porDia[diaIso] ?? 0.0,
    });
  }
  return resultado;
}

/// Nº de clientes activos. v1.0.8.
Future<int> activosCount() async => (await _activos()).length;

/// Inscripciones del mes calendario actual.
Future<int> inscripcionesMes() async {
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  var c = 0;
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    if (esClienteEliminado(cl)) continue; // v1.8.0: no es persona
    if ('${cl['fecha_inscripcion'] ?? ''}'.startsWith(pref)) c++;
  }
  return c;
}

/// Inscripciones del mes agrupadas por entrenador (v1.0.7).
/// Devuelve lista de {nombre, cantidad}.
Future<List<Map<String, dynamic>>> inscripcionesPorEntrenador() async {
  final n = ahoraHabana();
  final pref = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}';
  final porEntrenador = <String, int>{};
  for (final cl in await LocalDb.instance.allMirror('clientes')) {
    if (esClienteEliminado(cl)) continue; // v1.8.0: no es persona
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
/// v1.7.0: la Cuenta a la Casa no es morosa (no debe nada).
Future<int> morosos() async {
  final hoy = _hoyIso();
  var c = 0;
  for (final cl in await _activos()) {
    if (esCuentaCasa(cl)) continue;
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

/// Total de gastos del mes [pref] ('YYYY-MM').
/// Contrato verificado (2026-10-21): la tabla `gastos` no tiene
/// moneda ni anulaciones; todos sus montos son CUP. Alimenta el
/// «Neto del mes (CUP)» del dashboard (ingresos − gastos).
Future<double> gastosDelMes(String pref) async {
  double t = 0;
  for (final g in await LocalDb.instance.allMirror('gastos')) {
    if ('${g['fecha'] ?? ''}'.startsWith(pref)) {
      t += (g['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  return t;
}

/// Cobrado hoy por método (cierre de caja): {efectivo, transferencia}.
Future<Map<String, double>> cobradoHoyPorMetodo(
    {int? soloTelegramId}) async {
  final hoy = _hoyIso();
  double ef = 0, tr = 0;
  // v1.3.6: propagar el filtro por entrenador (usa columna indexada).
  for (final p
      in await LocalDb.instance.pagosDelDia(hoy, soloTelegramId: soloTelegramId)) {
    final m = (p['monto'] as num?)?.toDouble() ?? 0;
    if ('${p['metodo']}' == 'transferencia') {
      tr += m;
    } else {
      ef += m;
    }
  }
  // v1.3.6 (Argón): filtro SQL + verificación de normalización.
  final diarios = soloTelegramId == null
      ? await LocalDb.instance.allMirror('pagos_diarios')
      : await LocalDb.instance.mirrorFiltrado(
          'pagos_diarios', {'registrado_por': soloTelegramId});
  for (final d in diarios) {
    if (soloTelegramId != null &&
        LocalDb.normalizarTelegramId(d['registrado_por']) !=
            soloTelegramId) {
      continue;
    }
    if ('${d['fecha'] ?? ''}'.length >= 10 &&
        '${d['fecha']}'.substring(0, 10) == hoy) {
      ef += (d['total'] as num?)?.toDouble() ?? 0;
    }
  }
  // v1.3.2 (Argón #5): suplementos en CUP van a efectivo.
  for (final v in await ventasSuplementosCup()) {
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10 && f.substring(0, 10) == hoy) {
      ef += totalVentaCup(v);
    }
  }
  // v1.8.0: servicios del día por método (Casa fuera: precio 0).
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    final f = '${v['fecha'] ?? ''}';
    if (f.length < 10 || f.substring(0, 10) != hoy) continue;
    if ((v['casa'] as num?)?.toInt() == 1) continue;
    final monto = ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
        ((v['cantidad'] as num?)?.toDouble() ?? 0);
    if ('${v['metodo']}' == 'transferencia') {
      tr += monto;
    } else {
      ef += monto;
    }
  }
  return {'efectivo': ef, 'transferencia': tr};
}

/// Comparación de precios en centavos enteros (candado (a) de auditoría,
/// B3/C-Auditoría): evita los falsos positivos/negativos del double
/// (p. ej. 0.1 + 0.2). Dos precios "iguales" en centavos no difieren.
bool precioDifiereEnCentavos(double a, double b) =>
    (a * 100).round() != (b * 100).round();

/// Registra una venta de suplemento — ÚNICO punto de venta de la app
/// (v1.3.4, B1-Unificación / C1 / C2 / C3).
///
/// La usan la tarjeta del catálogo, el detalle (`ventaRapidaSuplemento`) y
/// el diálogo (`VentaSuplementoScreen`): prohibido duplicar esta lógica en
/// la UI.
///
/// Transacción atómica: descuento optimista del stock en el JSON de
/// `suplementos.data` + encolado de la op `venta_suplemento`. Si [txn] se
/// pasa, todo corre dentro de esa transacción; si es null, se abre una.
///
/// NUNCA inserta en `ventas_suplementos`: es espejo puro poblado por pull
/// (evita doble conteo en `pendienteEntrega` y colisión de ids con el
/// servidor). El estado de sync vive en `ops_queue`, no en el payload.
///
/// Validación: `cantidad > 0` y `precioVenta > 0` se verifican ANTES de la
/// transacción; el stock se lee del JSON DENTRO de la transacción y si
/// `cantidad > stockActual` lanza `Exception('Stock insuficiente')`.
///
/// Devuelve el `op_uuid` generado. NO toca `ultimo_precio` (telemetría
/// muerta de v18: el precio mostrado es siempre `precio_oficial`).
Future<String> registrarVentaSuplemento({
  required int suplementoId,
  required int cantidad,
  required double precioOficial, // por unidad
  required double precioVenta, // por unidad (puede diferir del oficial)
  String moneda = 'USD',
  double? usdTasa,
  required String compradorTipo, // 'cliente' | 'externo'
  int? clienteId,
  required String compradorNombre,
  String? nota,
  String? notaPrecio,
  // v1.3.7 (Fase B §6.2): fiado — solo con cliente asociado. El fiado
  // NO suma al "Total cobrado" hasta que se salda (regla de negocio).
  bool esFiado = false,
  DatabaseExecutor? txn,
}) async {
  // Validación PRE-transacción (no necesita BD).
  if (cantidad <= 0) throw Exception('Cantidad inválida');
  if (precioVenta <= 0) throw Exception('Precio de venta inválido');
  if (compradorTipo != 'cliente' && compradorTipo != 'externo') {
    throw Exception('comprador_tipo inválido');
  }
  if (compradorTipo == 'cliente' && clienteId == null) {
    throw Exception('Falta el cliente comprador');
  }
  // v1.3.7 (Fase B §6.2): el fiado exige cliente asociado.
  if (esFiado && (compradorTipo != 'cliente' || clienteId == null)) {
    throw Exception('El fiado requiere un cliente asociado');
  }

  final db = LocalDb.instance;
  final oficialCent = (precioOficial * 100).round();
  final ventaCent = (precioVenta * 100).round();
  final opUuid = const Uuid().v4();
  // Contrato exacto con el servidor (candados de auditoría C2):
  // doubles por retrocompat + centavos enteros para comparar.
  final payload = <String, dynamic>{
    'suplemento_id': suplementoId,
    'cantidad': cantidad,
    'precio': precioVenta, // double retrocompat
    'precio_oficial': precioOficial, // double retrocompat
    'precio_oficial_centavos': oficialCent,
    'precio_venta_centavos': ventaCent,
    'descuento_autorizado_centavos': ventaCent - oficialCent,
    'moneda': moneda, // explícita, nunca implícita
    'usd_tasa': (usdTasa != null && usdTasa > 0) ? usdTasa : 1.0,
    'comprador_tipo': compradorTipo,
    if (compradorTipo == 'cliente') 'cliente_id': clienteId,
    'comprador_nombre': compradorNombre,
    'fecha': hoyHabanaIso(), // PROHIBIDO DateTime.now()
    if (nota != null && nota.isNotEmpty) 'nota': nota,
    if (notaPrecio != null && notaPrecio.isNotEmpty)
      'nota_precio': notaPrecio,
    'entregado': 0, // int; el estado de sync va en ops_queue
    // v1.3.7 (Fase B §6.2): fiado — estado estructurado (no texto).
    if (esFiado) 'es_fiado': 1,
    if (esFiado && clienteId != null) 'fiado_cliente_id': clienteId,
  };

  Future<String> dentro(DatabaseExecutor ex) async {
    // Stock actual leído del JSON DENTRO de la transacción (evita TOCTOU).
    final rows = await ex.query('suplementos',
        columns: ['data'],
        where: 'id = ?',
        whereArgs: [suplementoId],
        limit: 1);
    if (rows.isEmpty) throw Exception('Suplemento no encontrado');
    final data = Map<String, dynamic>.from(
        jsonDecode(rows.first['data'] as String) as Map);
    final stockActual = (data['stock'] as num?)?.toInt() ?? 0;
    if (cantidad > stockActual) throw Exception('Stock insuficiente');
    // (a) decremento optimista del stock en el JSON.
    await db.actualizarSuplemento(
        suplementoId, {'stock': stockActual - cantidad}, ex);
    // (b) encolar la op.
    await db.queueOp(
        opUuid: opUuid, tipo: 'venta_suplemento', payload: payload, txn: ex);
    return opUuid;
  }

  final String resultado;
  if (txn != null) {
    resultado = await dentro(txn);
  } else {
    final d = await db.db;
    resultado = await d.transaction(dentro);
  }
  // Push en segundo plano SOLO si no hay txn externa: con txn externa
  // el commit aún no ocurrió y el push leería datos inconsistentes.
  // El onError evita errores no manejados en tests/entornos sin sesión.
  if (txn == null) {
    unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  }
  return resultado;
}
