/// v1.13.0 (Bloque 4, D4 — diferido desde la 1.12.0): medidas del
/// cliente registradas por el entrenador (con permiso
/// `can_record_measurements`; el dueño siempre puede).
///
/// Modelo: filas INMUTABLES (nunca se editan: una corrección es una
/// fila nueva con fecha posterior). Cada fila viaja por la op
/// `registrar_medicion_cliente` (CHECK previo, otra vía) y baja por
/// el espejo `cliente_mediciones` cuando el manifiesto del servidor
/// lo incluya; hasta entonces la lectura combina espejo + ops
/// pendientes del propio teléfono (dedupe por medicion_id).
library;

import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'localdb.dart';
import 'sync.dart';
import 'tiempo.dart';

/// Métricas admitidas (lista cerrada, fail-closed: cualquier otra
/// clave se rechaza, no se guarda en silencio).
const Map<String, ({double min, double max, String unidad})>
    kMetricasMedicion = {
  'peso_kg': (min: 20, max: 300, unidad: 'kg'),
  'cintura_cm': (min: 30, max: 200, unidad: 'cm'),
  'brazo_cm': (min: 10, max: 80, unidad: 'cm'),
  'pecho_cm': (min: 40, max: 200, unidad: 'cm'),
  'muslo_cm': (min: 20, max: 120, unidad: 'cm'),
  'grasa_pct': (min: 1, max: 60, unidad: '%'),
  // 1.28 (M4-A12/B22): la cadera se leía del espejo y el
  // servidor la admite y persiste (sync.py: rango 10–300),
  // pero la lista cerrada de la app NO la traía:
  // validarMedicion la rechazaba como «Métrica no admitida»
  // si alguien la pasaba. Entra con el rango del servidor.
  'cadera_cm': (min: 10, max: 300, unidad: 'cm'),
};

/// Valida un mapa de medidas. null = válido; si no, el motivo en
/// palabras claras. PURO.
String? validarMedicion(Map<String, double> medidas) {
  if (medidas.isEmpty) return 'Escribe al menos una medida';
  for (final e in medidas.entries) {
    final spec = kMetricasMedicion[e.key];
    if (spec == null) return 'Métrica no admitida: ${e.key}';
    if (e.value.isNaN || e.value <= 0) {
      return 'La medida ${e.key} debe ser mayor que 0';
    }
    if (e.value < spec.min || e.value > spec.max) {
      return 'La medida ${e.key} está fuera de rango '
          '(${spec.min}–${spec.max} ${spec.unidad})';
    }
  }
  return null;
}

/// Registra una fila de medidas (inmutable) por la op
/// `registrar_medicion_cliente`. Si el permiso se revoca con la op
/// en cola, el servidor la rechaza de forma NO bloqueante (veredicto
/// Bloque 3, ajuste D4): nunca atasca la cola. Devuelve el
/// medicion_id (UUID de la fila).
Future<String> registrarMedicionCliente({
  required int clienteId,
  required Map<String, double> medidas,
  String? fechaHabana, // 'YYYY-MM-DD'; por defecto hoy Habana
}) async {
  final error = validarMedicion(medidas);
  if (error != null) throw Exception(error);
  final medicionId = const Uuid().v4();
  final opUuid = const Uuid().v4();
  await LocalDb.instance.queueOp(
    opUuid: opUuid,
    tipo: 'registrar_medicion_cliente',
    payload: {
      'medicion_id': medicionId,
      'cliente_id': clienteId,
      'fecha_medicion': fechaHabana ?? hoyHabanaIso(),
      'medidas': medidas,
      'registrado_por': AuthService().telegramId,
    },
  );
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return medicionId;
}

/// 1.32 (H-RPC-2): cancela la op `registrar_medicion_cliente`
/// aún pendiente de ESTE teléfono para la medición
/// [medicionId] (UUID de la vía de ops). Es la vía de
/// edición/borrado de una medición que solo tiene identidad
/// local: las RPC de staff exigen el id bigint del servidor y
/// enviarles el UUID rebotaba con 400. Devuelve true si la op
/// estaba pendiente (o en error) y quedó cancelada — la fila
/// desaparece de la lectura local, que la compone desde
/// pendingOps. False si ya salió de la cola (aplicada o
/// enviada): la fila ya vive en el servidor.
Future<bool> cancelarMedicionPendienteSiExiste(
    String medicionId) async {
  if (medicionId.isEmpty) return false;
  final db = LocalDb.instance;
  for (final op in await db.pendingOps()) {
    if ('${op['tipo']}' != 'registrar_medicion_cliente') continue;
    try {
      final p = jsonDecode(op['payload'] as String);
      if (p is Map && '${p['medicion_id'] ?? ''}' == medicionId) {
        // La columna del uuid en ops_queue es op_uuid (uuid
        // solo es el nombre legado que leen algunos sitios).
        return await db
            .cancelOp('${op['op_uuid'] ?? op['uuid'] ?? ''}');
      }
    } catch (_) {
      // Payload ilegible: no es la op buscada.
    }
  }
  return false;
}

/// Lectura local de medidas de un cliente: espejo + ops pendientes
/// del propio teléfono (dedupe por medicion_id: la fila espejada
/// manda sobre la op pendiente con el mismo id). Recientes primero.
Future<List<Map<String, dynamic>>> medicionesClienteLocal(
    int clienteId) async {
  final db = LocalDb.instance;
  final espejo = await db.allMirror('cliente_mediciones');
  final porId = <String, Map<String, dynamic>>{};
  for (final r in espejo) {
    if ((r['cliente_id'] as num?)?.toInt() != clienteId) continue;
    final id = '${r['id'] ?? r['medicion_id'] ?? ''}';
    if (id.isEmpty) continue;
    // Corrección panel 1.13 (D4): el espejo baja la fila en
    // columnas planas (peso_kg, fecha, ...) dentro de data, no
    // como mapa 'medidas' ni 'fecha_medicion'. Sin reconstruir,
    // una medición sincronizada se veía vacía en la pantalla.
    const clavesMedida = [
      'peso_kg',
      'grasa_pct',
      'pecho_cm',
      'brazo_cm',
      'cintura_cm',
      'cadera_cm',
      'muslo_cm',
    ];
    final medidasEspejo = r['medidas'] is Map
        ? Map<String, dynamic>.from(r['medidas'] as Map)
        : <String, dynamic>{
            for (final k in clavesMedida)
              if (r[k] != null) k: r[k],
          };
    porId[id] = {
      'medicion_id': id,
      'fecha_medicion': '${r['fecha_medicion'] ?? r['fecha'] ?? ''}',
      // 1.23 AT-03: el instante REAL de creación si la fila lo
      // trae (created_at del servidor); la UI lo usa para la
      // ventana de edición de 24 h en vez de la fecha plana.
      'creado_en': '${r['created_at'] ?? r['creada_en'] ?? ''}',
      'medidas': medidasEspejo,
      'espejado': true,
    };
  }
  // Yunque 3 (K5-3): lectura AMPLIA (pendingOpsLectura:
  // pendiente + enviada + error). Con pendingOps, al registrar
  // con conexión el push pasaba la op a 'enviada' al momento y
  // la medición desaparecía de la lista hasta que el ciclo del
  // puente la bajaba al espejo (el entrenador podía registrarla
  // otra vez). El dedupe por medicion_id de abajo ya evita el
  // duplicado cuando la fila espejada llega. NO se toca
  // cancelarMedicionPendienteSiExiste: su contrato «enviada ya
  // no se cancela» es de diseño.
  for (final op in await db.pendingOpsLectura()) {
    if ('${op['tipo']}' != 'registrar_medicion_cliente') continue;
    Map<String, dynamic> p;
    try {
      final dec = jsonDecode(op['payload'] as String);
      if (dec is! Map<String, dynamic>) continue;
      p = dec;
    } catch (_) {
      continue;
    }
    if ((p['cliente_id'] as num?)?.toInt() != clienteId) continue;
    final id = '${p['medicion_id'] ?? ''}';
    if (id.isEmpty || porId.containsKey(id)) continue;
    porId[id] = {
      'medicion_id': id,
      'fecha_medicion': '${p['fecha_medicion'] ?? ''}',
      // 1.23 AT-03: la op en cola SÍ sabe cuándo se creó
      // (creada_ts de ops_queue): ese instante manda para la
      // ventana de 24 h; antes la UI reconstruía created_at
      // desde la FECHA plana y una medición de las 23:00
      // «cumplía 24 h» a las 00:01.
      'creado_en': '${op['creada_ts'] ?? ''}',
      'medidas': p['medidas'] is Map
          ? Map<String, dynamic>.from(p['medidas'] as Map)
          : <String, dynamic>{},
      'espejado': false,
    };
  }
  // 1.36 H-B2 (136-559): el orden manda por el instante real
  // de creación (creado_en); la fecha_medicion solo desempata
  // (dos filas del mismo día se ordenaban antes por fecha
  // plana y la «última» podía ser la más vieja del día).
  final lista = porId.values.toList()
    ..sort((a, b) {
      final c = '${b['creado_en']}'.compareTo('${a['creado_en']}');
      if (c != 0) return c;
      return '${b['fecha_medicion']}'.compareTo('${a['fecha_medicion']}');
    });
  return lista;
}

/// 1.28 (M4-B3): variación de cada métrica de la medición
/// MÁS RECIENTE contra la anterior que trae ESA métrica
/// (las filas son parciales: no todas traen todas las
/// métricas). Sin anterior comparable, la métrica no entra
/// en el mapa. La lista llega recientes primero
/// (medicionesClienteLocal). PURO.
Map<String, double> deltasUltimaMedicion(
    List<Map<String, dynamic>> mediciones) {
  if (mediciones.isEmpty) return const {};
  final ultima = mediciones.first['medidas'];
  if (ultima is! Map) return const {};
  final r = <String, double>{};
  for (final e in ultima.entries) {
    final v = (e.value as num?)?.toDouble();
    // 1.36 H-B2 (136-560): el mismo filtro de validez de
    // serieMedicion (>0 y finito): un 0/NaN legado no genera
    // delta ni sirve de anterior comparable.
    if (v == null || v <= 0 || !v.isFinite) continue;
    for (var i = 1; i < mediciones.length; i++) {
      final m = mediciones[i]['medidas'];
      if (m is! Map) continue;
      final anterior = (m[e.key] as num?)?.toDouble();
      if (anterior != null && anterior > 0 && anterior.isFinite) {
        r['${e.key}'] = v - anterior;
        break;
      }
    }
  }
  return r;
}

/// 1.28 (M4-B3): serie cronológica (antigua → reciente) de
/// una métrica para el mini-gráfico de la ficha: solo las
/// mediciones que la traen y cuya fecha parsea. PURO.
List<({DateTime fecha, double valor})> serieMedicion(
    List<Map<String, dynamic>> mediciones, String metrica) {
  final puntos = <({DateTime fecha, double valor})>[];
  for (final m in mediciones) {
    final medidas = m['medidas'];
    if (medidas is! Map) continue;
    final v = (medidas[metrica] as num?)?.toDouble();
    // Yunque R5-M9-3: el mismo filtro de validez que
    // validarMedicion: un 0/NaN legado no es una medición
    // y no se pinta como caída a cero de la serie.
    if (v == null || v <= 0 || !v.isFinite) continue;
    final f = DateTime.tryParse('${m['fecha_medicion'] ?? ''}');
    if (f == null) continue;
    puntos.add((fecha: f, valor: v));
  }
  puntos.sort((a, b) => a.fecha.compareTo(b.fecha));
  return puntos;
}

/// 1.25 T57: resumen de la última medida con peso para la
/// fila de la ficha: el peso más reciente y su variación
/// contra la medición anterior con peso (null si no hay
/// anterior comparable). La lista llega recientes primero
/// (medicionesClienteLocal). La variación se presenta sin
/// juicio (subir o bajar no es bueno ni malo por sí solo).
({double peso, double? delta, String fecha})? resumenUltimaMedida(
    List<Map<String, dynamic>> mediciones) {
  double? pesoDe(Map<String, dynamic> m) {
    final medidas = m['medidas'];
    if (medidas is Map) {
      final p = (medidas['peso_kg'] as num?)?.toDouble();
      // 1.36 H-B2 (136-560): filtro de validez de serieMedicion.
      if (p == null || p <= 0 || !p.isFinite) return null;
      return p;
    }
    return null;
  }

  double? ultimo;
  double? anterior;
  var fecha = '';
  for (final m in mediciones) {
    final p = pesoDe(m);
    if (p == null) continue;
    if (ultimo == null) {
      ultimo = p;
      fecha = '${m['fecha_medicion'] ?? ''}';
    } else {
      anterior = p;
      break;
    }
  }
  if (ultimo == null) return null;
  return (
    peso: ultimo,
    delta: anterior == null ? null : ultimo - anterior,
    fecha: fecha,
  );
}
