/// Sincronización detallada: última vez, qué subió/bajó, errores
/// y cola de operaciones (con opción de cancelar las pendientes).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../comprobantes.dart';
import '../diario_sync.dart';
import '../errores_sync.dart';
import '../fotos_qos.dart';
import '../bloque3.dart';
import '../app_log.dart';
import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_operacion.dart';
import 'app_bar.dart';
import 'auditoria.dart';
import 'centro_sync.dart';
import 'componentes.dart';
import 'skeleton.dart';
import 'diseno.dart';


/// v1.4.4: título de una op consciente del payload. Para la op
/// 'ajuste' la etiqueta sale de la clave ajustada («Ajuste:
/// horario de turnos») y no del tipo genérico («Cambio de precio»).
String tituloDeOp(Map<String, dynamic> op) {
  Map<String, dynamic> payload = {};
  try {
    final raw = op['payload'];
    if (raw is String && raw.isNotEmpty) {
      payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } else if (raw is Map) {
      payload = Map<String, dynamic>.from(raw);
    }
  } catch (_) {}
  return describirTipoOpConPayload('${op['tipo']}', payload);
}

/// 1.29 (Oleada 6, D-A3 · migración v68): ¿esta foto de la
/// cola es visible para el actor de la sesión? REGLA
/// DECLARADA (vive aquí, junto a su único consumidor):
/// - El dueño ve todas.
/// - Un no-dueño solo ve las fotos con SU sello
///   (fotos_cola.telegram_id = su telegram_id).
/// - Las fotos SIN sello (NULL) son las previas a v68:
///   a efectos de visibilidad son DEL DUEÑO — las ve el
///   dueño y ningún no-dueño, ni en la lista ni en los
///   contadores.
/// - Sin identidad numérica de sesión no se acredita
///   ninguna foto como propia (fail-closed).
/// Este filtro decide qué se enseña en esta pantalla
/// y, desde la 1.30 (Oleada 9, ítem 11), también qué
/// fotos puede REINTENTAR a mano cada actor
/// (reintentarFotoCola / reintentarTodasFotosCola, más
/// abajo). Lo que NO decide es la subida:
/// FotosColaService procesa la cola completa sin mirar
/// el sello — ocultar una foto a una cuenta nunca
/// detiene su subida.
bool fotoVisibleParaActor(Map<String, dynamic> foto,
    {required bool esDueno, required int? miTelegramId}) {
  if (esDueno) return true;
  final sello = foto['telegram_id'];
  if (sello == null) return false;
  if (miTelegramId == null) return false;
  return sello == miTelegramId;
}

/// 1.30 (Oleada 9, ítem 11): reintento INDIVIDUAL de una
/// foto de la cola, con el filtro de autor del plan: para
/// el no-dueño, una fila que [fotoVisibleParaActor] no le
/// acredita (ajena, sin sello — las previas a v68 son del
/// dueño — o sin identidad de sesión, fail-closed) NO se
/// procesa: devuelve `autorizada: false` sin tocarla. El
/// dueño procesa cualquier fila: su reintento es la
/// operación de rescate. `tocadas` es el resultado del
/// UPDATE histórico (0 si la fila está 'subiendo':
/// cinturón H-01 de la 1.24 — no se le quita el lease al
/// worker).
Future<({int tocadas, bool autorizada})> reintentarFotoCola(
  Database db,
  int id, {
  required bool esDueno,
  required int? miTelegramId,
}) async {
  if (!esDueno) {
    final filas = await db.query('fotos_cola',
        columns: ['telegram_id'], where: 'id = ?', whereArgs: [id]);
    if (filas.isEmpty ||
        !fotoVisibleParaActor(filas.first,
            esDueno: false, miTelegramId: miTelegramId)) {
      return (tocadas: 0, autorizada: false);
    }
  }
  final tocadas = await db.update(
    'fotos_cola',
    {
      'estado': 'pendiente',
      'intentos': 0,
      'ultimo_error': null,
      'proximo_intento_en': null,
      'worker_id': null,
      'lease_hasta': null,
      // v1.3.10: el reintento manual salta el filtro QoS de 'original'.
      'forzar_qos': 1,
    },
    where: "id = ? AND estado != 'subiendo'",
    whereArgs: [id],
  );
  return (tocadas: tocadas, autorizada: true);
}

/// 1.30 (Oleada 9, ítem 11): reintento MASIVO de la cola
/// de fotos, con el mismo filtro de autor: el no-dueño
/// solo marca SUS filas (las selladas con su telegram_id;
/// sin identidad numérica no marca ninguna —
/// fail-closed) y el dueño marca la cola completa.
/// Devuelve cuántas filas se marcaron de verdad, para
/// que el aviso no mienta. OJO: esto filtra el REINTENTO
/// manual, no el procesamiento — el servicio sigue
/// subiendo la cola completa (regla declarada en
/// [fotoVisibleParaActor]).
Future<int> reintentarTodasFotosCola(
  Database db, {
  required bool esDueno,
  required int? miTelegramId,
}) async {
  if (!esDueno && miTelegramId == null) return 0;
  return db.update(
    'fotos_cola',
    {
      'estado': 'pendiente',
      'intentos': 0,
      'ultimo_error': null,
      'proximo_intento_en': null,
      'worker_id': null,
      'lease_hasta': null,
    },
    where: esDueno
        ? "estado IN ('pendiente', 'error')"
        : "estado IN ('pendiente', 'error') AND telegram_id = ?",
    whereArgs: esDueno ? null : [miTelegramId],
  );
}

/// 1.35 (CAMPO-9): UNA foto de la cola = el grupo de sus
/// variantes (thumb/display/original) bajo el mismo
/// `op_uuid`. La pantalla del panel enseña fotos, no
/// variantes: la fila es la foto, identificada por su
/// cliente, con el estado CONJUNTO de sus variantes y las
/// acciones (reintentar/descartar) sobre la foto entera;
/// las variantes viven dentro del detalle de la fila.
class GrupoFotoCola {
  GrupoFotoCola(this.opUuid, this.variantes);

  final String opUuid;
  final List<Map<String, dynamic>> variantes;

  int? get clienteId {
    for (final v in variantes) {
      final c = v['cliente_id'];
      if (c is num) return c.toInt();
    }
    return null;
  }

  int? get suplementoId {
    for (final v in variantes) {
      final s = v['suplemento_id'];
      if (s is num) return s.toInt();
    }
    return null;
  }

  /// Estado conjunto con prioridad: error > subiendo >
  /// pendiente (el peor estado de una variante es el
  /// estado que el usuario debe leer de la foto).
  String get estadoConjunto {
    if (variantes.any((v) => v['estado'] == 'error')) return 'error';
    if (variantes.any((v) => v['estado'] == 'subiendo')) {
      return 'subiendo';
    }
    return 'pendiente';
  }

  bool get algunaSubiendo =>
      variantes.any((v) => v['estado'] == 'subiendo');

  /// 1.35 (SP-09): la variante grande ('original') sigue
  /// pendiente sin que nadie la haya forzado: está en la
  /// espera QoS de la casa (sale cuando la cola de
  /// operaciones lleva un rato vacía, o a los 15 min).
  bool get originalEsperaQos => variantes.any((v) =>
      v['tipo'] == 'original' &&
      v['estado'] == 'pendiente' &&
      ((v['forzar_qos'] as num?)?.toInt() ?? 0) != 1);

  /// Ruta para la miniatura de la fila: la de pantalla si
  /// está; si no, la miniatura; si no, la original.
  String? get rutaMiniatura {
    for (final tipo in const ['display', 'thumb', 'original']) {
      for (final v in variantes) {
        if (v['tipo'] == tipo) {
          final r = v['ruta_local'];
          if (r is String && r.isNotEmpty) return r;
        }
      }
    }
    return null;
  }

  Map<String, dynamic>? variante(String tipo) {
    for (final v in variantes) {
      if (v['tipo'] == tipo) return v;
    }
    return null;
  }

  /// El instante más antiguo del grupo (cuándo se pidió
  /// la foto), para ordenar y para «Solicitada: …».
  String? get creadoEn {
    String? menor;
    for (final v in variantes) {
      final c = v['creado_en'];
      if (c is String && (menor == null || c.compareTo(menor) < 0)) {
        menor = c;
      }
    }
    return menor;
  }
}

/// Agrupa las filas vivas de fotos_cola por `op_uuid`
/// (CAMPO-9). Las variantes de cada grupo quedan en orden
/// de presentación (thumb, display, original) y los
/// grupos, por su instante más antiguo.
List<GrupoFotoCola> agruparFotosCola(List<Map<String, dynamic>> filas) {
  final porUuid = <String, List<Map<String, dynamic>>>{};
  for (final f in filas) {
    final uuid = '${f['op_uuid'] ?? ''}';
    if (uuid.isEmpty) continue;
    porUuid.putIfAbsent(uuid, () => []).add(f);
  }
  const ordenTipo = {'thumb': 0, 'display': 1, 'original': 2};
  final grupos = porUuid.entries.map((e) {
    final variantes = [...e.value]..sort((a, b) => (ordenTipo[a['tipo']] ?? 9)
        .compareTo(ordenTipo[b['tipo']] ?? 9));
    return GrupoFotoCola(e.key, variantes);
  }).toList();
  grupos.sort((a, b) => (a.creadoEn ?? '').compareTo(b.creadoEn ?? ''));
  return grupos;
}

/// 1.35 (SP-05): conteos del panel POR FOTO, no por
/// variante — el estado que cuenta es el conjunto del
/// grupo (una foto con la original en error y las demás
/// subidas es UNA foto con error, no tres pendientes).
({int pendientes, int subiendo, int error}) conteosFotosPorFoto(
    List<Map<String, dynamic>> filas) {
  var p = 0, s = 0, e = 0;
  for (final g in agruparFotosCola(filas)) {
    switch (g.estadoConjunto) {
      case 'error':
        e++;
      case 'subiendo':
        s++;
      default:
        p++;
    }
  }
  return (pendientes: p, subiendo: s, error: e);
}

/// 1.35 (SP-08): la fila de foto NUNCA pinta el
/// `ultimo_error` crudo (excepciones con rutas y códigos
/// internos): se traduce por CLASE a la frase de la casa.
/// El texto crudo queda en la BD y en AppLog para el
/// detalle técnico.
String fraseErrorFoto(String? ultimoError) {
  final e = (ultimoError ?? '').trim();
  if (e.isEmpty) return 'No pudo subirse';
  // E3 (C2-03): la clase vinculación reconoce TAMBIÉN el
  // texto real que SP-01 guarda a las 24 h sin espejo
  // («La foto no pudo enlazarse: el cliente no aparece en
  // este teléfono», fotos_cola.dart): buscar solo
  // «vinculación» lo dejaba caer al genérico «No pudo
  // subirse», que es falso — los bytes SÍ subieron.
  if (e.contains('vinculación') ||
      e.contains('enlaz') ||
      e.contains('no aparece en este teléfono')) {
    return 'Llegó al servidor pero no pudo enlazarse';
  }
  if (e.contains('archivo no existe') ||
      e.contains('archivo ilegible') ||
      e.contains('archivo cambió') ||
      e.contains('archivo del sistema')) {
    return 'El archivo ya no está en este teléfono';
  }
  if (e.contains('ID de entidad nunca resuelto')) {
    return 'No se pudo saber de quién es esta foto';
  }
  if (e.contains('SocketException') ||
      e.contains('TimeoutException') ||
      e.contains('HttpException') ||
      e.contains('ClientException') ||
      e.contains('tiempo de espera') ||
      e.contains('conexión') ||
      e.contains('red')) {
    return 'La conexión falló al subirla';
  }
  return 'No pudo subirse';
}

/// 1.35 (SP-07): reintento POR FOTO — actúa sobre todas
/// las variantes del grupo (cada una pasa por
/// [reintentarFotoCola], con su filtro de autor y su
/// cinturón de 'subiendo'). Devuelve cuántas filas se
/// tocaron de verdad.
Future<int> reintentarFotoGrupoCola(
  Database db,
  String opUuid, {
  required bool esDueno,
  required int? miTelegramId,
}) async {
  final filas = await db.query('fotos_cola',
      columns: ['id'], where: 'op_uuid = ?', whereArgs: [opUuid]);
  var tocadas = 0;
  for (final f in filas) {
    final r = await reintentarFotoCola(db, (f['id'] as num).toInt(),
        esDueno: esDueno, miTelegramId: miTelegramId);
    tocadas += r.tocadas;
  }
  return tocadas;
}

/// 1.35 (SP-07): descarte POR FOTO — borra TODAS las
/// variantes del grupo (antes el botón borraba una sola
/// fila y la foto «descartada» reaparecía con otra
/// variante, contra lo que el diálogo prometía). La
/// variante que esté 'subiendo' no se toca (cinturón
/// H-01: no se le quita el lease al worker). Para el
/// no-dueño, TODAS las variantes deben ser visibles
/// para él (fail-closed). Devuelve las filas borradas.
///
/// G#25 (Hy4): el descarte es ATÓMICO respecto a la
/// subida — chequeo y borrado van en una transacción y
/// si CUALQUIER variante está 'subiendo' en ese momento
/// no se borra NINGUNA (devuelve -1). Antes el borrado
/// excluía solo la fila subiendo: si el worker empezaba
/// a subir una variante mientras el diálogo de
/// confirmación estaba abierto (el chequeo de la UI se
/// hizo sobre la foto pintada), el grupo quedaba partido
/// — las demás se borraban, la subiendo subía sola y el
/// snack decía «Foto descartada».
Future<int> descartarFotoGrupoCola(
  Database db,
  String opUuid, {
  required bool esDueno,
  required int? miTelegramId,
}) async {
  if (!esDueno) {
    final filas = await db.query('fotos_cola',
        columns: ['telegram_id'],
        where: 'op_uuid = ?',
        whereArgs: [opUuid]);
    if (filas.isEmpty ||
        filas.any((f) => !fotoVisibleParaActor(f,
            esDueno: false, miTelegramId: miTelegramId))) {
      return 0;
    }
  }
  return db.transaction((txn) async {
    final subiendo = await txn.query('fotos_cola',
        columns: ['id'],
        where: "op_uuid = ? AND estado = 'subiendo'",
        whereArgs: [opUuid],
        limit: 1);
    if (subiendo.isNotEmpty) return -1;
    return txn.delete('fotos_cola',
        where: 'op_uuid = ?', whereArgs: [opUuid]);
  });
}

/// 1.29 (Oleada 6, FA-06): etiqueta de autor para una op
/// pendiente AJENA en la vista del DUEÑO («de Duany ·
/// suben cuando él entre»): las ops de otra cuenta en
/// el mismo teléfono solo suben cuando esa cuenta entra
/// (el push firma con la sesión activa), y sin la
/// etiqueta el dueño las leía como suyas atascadas.
/// Devuelve null si la op es mía o no trae evidencia de
/// otro autor (sin firma = mía, la regla de esOpMia).
/// El nombre sale de la firma de texto de la propia op;
/// si solo trae firma numérica (o la columna
/// telegram_id), se resuelve contra [nombresPorTelegram]
/// (el directorio de usuarios del pull); si no resuelve,
/// «de otra cuenta» — nunca un nombre inventado.
String? etiquetaOpAjena(Map<String, dynamic> op,
    {required String? miActor,
    required int? miTelegramId,
    required Map<int, String> nombresPorTelegram}) {
  if (!esOpDeOtro(op, miActor: miActor, miTelegramId: miTelegramId)) {
    return null;
  }
  final firma = actorFirmaDeOp(op);
  if (firma != null && firma.trim().isNotEmpty) {
    return 'de ${firma.trim()} · suben cuando él entre';
  }
  final tid = actorIdNumericoDeOp(op) ??
      int.tryParse('${op['telegram_id'] ?? ''}');
  final nombre = tid == null ? null : nombresPorTelegram[tid];
  if (nombre != null && nombre.trim().isNotEmpty) {
    return 'de ${nombre.trim()} · suben cuando él entre';
  }
  return 'de otra cuenta · suben cuando entre su cuenta';
}

/// 1.29 (Oleada 6, FA-06): desglose por autor de las ops
/// pendientes GLOBALES (el conjunto completo de la BD,
/// no la lista reciente truncada): cuántas son de la
/// sesión actual y cuántas de otras cuentas.
/// 1.35 (SP-03 + SP-11): el desglose cubre el MISMO
/// conjunto que el total de cabecera (pendiente + enviada
/// + error, el de LocalDb.countPendingOps) — antes solo
/// contaba 'pendiente' y la línea «N · A tuyas · B de
/// otros» no cuadraba en cuanto una op entraba en error o
/// quedaba enviada. Y las ops SIN FIRMA alguna (legadas,
/// pre-sello de autor) ya no se atribuyen a la sesión
/// actual: forman una tercera clase, «sin autor conocido»
/// (esOpMia las daba por «mías» de cualquier sesión).
/// mias + deOtros + sinAutor == pendientes.length.
({int mias, int deOtros, int sinAutor}) desglosePendientesPorAutor(
    List<Map<String, dynamic>> pendientes,
    {required String? miActor, required int? miTelegramId}) {
  var mias = 0;
  var sinAutor = 0;
  for (final o in pendientes) {
    final sinFirma = actorIdNumericoDeOp(o) == null &&
        actorFirmaDeOp(o) == null;
    if (sinFirma) {
      sinAutor++;
    } else if (esOpMia(o, miActor: miActor, miTelegramId: miTelegramId)) {
      mias++;
    }
  }
  return (
    mias: mias,
    deOtros: pendientes.length - mias - sinAutor,
    sinAutor: sinAutor
  );
}

/// v1.3.4 (detalle ampliable Bajados/Subidos): utilidades de UI
/// compartidas entre [ColaScreen] y [DetalleSyncScreen].
/// Detalles legibles del payload según el tipo de operación (v1.0.11).
/// v1.3.4: extraído de `_ColaScreenState._detallesOp` a función top-level
/// para reutilizarlo en [DetalleSyncScreen].
Future<List<String>> detallesDeOp(Map<String, dynamic> op) async {
  final detalles = <String>[];
  Map<String, dynamic> payload = {};
  try {
    final raw = op['payload'];
    if (raw is String && raw.isNotEmpty) {
      payload = Map<String, dynamic>.from(
          jsonDecode(raw) as Map);
    } else if (raw is Map) {
      payload = Map<String, dynamic>.from(raw);
    }
  } catch (_) {}
  if (payload.isEmpty) return detalles;

  // Ronda 17 M6-H1: de un cliente protegido no se muestra
  // ningún detalle (ni nombre, ni monto, ni método).
  final cidRaw = payload['cliente_id'];
  if (cidRaw != null) {
    try {
      final c = await clientePorId(int.tryParse('$cidRaw') ?? 0);
      if (c != null && esVistaProtegida(c)) return ['Cliente protegido'];
    } catch (_) {}
  }

  // Nombre del cliente si hay cliente_id
  Future<String?> nombreCliente(dynamic id) async {
    if (id == null) return null;
    try {
      final c = await clientePorId(int.tryParse('$id') ?? 0);
      final nombre = c?['nombre'] as String?;
      // v1.3.9: si no se encuentra el nombre, mostrar el ID
      // para identificar el pago pendiente
      if (nombre == null || nombre.isEmpty) {
        return 'ID $id';
      }
      return nombre;
    } catch (_) {
      return 'ID $id';
    }
  }

  // SL-8 (G08-6): el suplemento se nombra desde el espejo,
  // nunca por su ID crudo («ID suplemento: 5» no dice nada
  // al decidir). Si no se resuelve, la fila no sale.
  Future<String?> nombreSuplemento(dynamic id) async {
    final sid = int.tryParse('$id');
    if (sid == null) return null;
    try {
      final filas =
          await LocalDb.instance.mirrorPorIds('suplementos', [sid]);
      if (filas.isEmpty) return null;
      final n = '${filas.first['nombre'] ?? ''}'.trim();
      return n.isEmpty ? null : n;
    } catch (_) {
      return null;
    }
  }

  final tipo = '${op['tipo']}';
  if (tipo == 'foto') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
  } else if (tipo == 'pago_mensual' || tipo == 'pago_diario') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
    if (payload['monto'] != null) {
      detalles.add('Monto: ${payload['monto']} CUP');
    }
    if (payload['metodo'] != null) {
      final m = payload['metodo'] == 'efectivo'
          ? 'Efectivo'
          : 'Transferencia';
      detalles.add('Método: $m');
    }
    if (payload['fecha'] != null) {
      // G08-6: fecha legible de la casa, no el ISO crudo.
      detalles.add('Fecha: ${fmtFecha('${payload['fecha']}')}');
    }
  } else if (tipo == 'inscribir') {
    if (payload['nombre'] != null) {
      detalles.add('Cliente: ${payload['nombre']}');
    }
  } else if (tipo == 'editar_cliente') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
  } else if (tipo == 'cambiar_estado') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
    if (payload['estado'] != null) {
      detalles.add('Estado: ${payload['estado']}');
    }
  } else if (tipo == 'gasto') {
    if (payload['concepto'] != null) {
      detalles.add('${payload['concepto']}');
    }
    if (payload['monto'] != null) {
      detalles.add('Monto: ${payload['monto']} CUP');
    }
  } else if (tipo == 'confirmar_entrega') {
    // Campo 2026-11-02 (1.22): el payload de confirmar_entrega
    // NO trae 'monto': trae entrenador y las listas de ids. El
    // detalle salía VACÍO (solo fecha y estado) y el dueño no
    // podía ver qué confirmó ni por qué falló.
    if (payload['trainer_nombre'] != null) {
      detalles.add('Entrenador: ${payload['trainer_nombre']}');
    }
    if (payload['monto'] != null) {
      detalles.add('Monto: ${payload['monto']} CUP');
    }
    int nDe(String clave) => (payload[clave] as List?)?.length ?? 0;
    final partes = <String>[
      if (nDe('pago_ids') > 0) '${nDe('pago_ids')} mensualidades',
      if (nDe('pago_diario_ids') > 0)
        '${nDe('pago_diario_ids')} pagos diarios',
      if (nDe('suplemento_ids') > 0)
        '${nDe('suplemento_ids')} ventas de suplementos',
      if (nDe('servicio_ids') > 0)
        '${nDe('servicio_ids')} ventas de servicios',
      if (nDe('adelanto_ids') > 0)
        '${nDe('adelanto_ids')} adelantos saldados',
    ];
    if (partes.isNotEmpty) {
      detalles.add('Ítems: ${partes.join(' · ')}');
    }
    final nota = '${payload['nota'] ?? ''}'.trim();
    if (nota.isNotEmpty) detalles.add('Nota: $nota');
  } else if (tipo == 'liquidar_nomina') {
    // Campo 2026-11-02 (1.22): su detalle también salía vacío.
    if (payload['entrenador_nombre'] != null) {
      detalles.add('Entrenador: ${payload['entrenador_nombre']}');
    }
    if (payload['mes'] != null) {
      detalles.add('Mes: ${payload['mes']}');
    }
    final neto = (payload['neto'] as num?)?.toDouble();
    if (neto != null) {
      detalles.add('Neto pagado: ${fmtMonto(neto)} CUP');
    }
  } else if (tipo == 'venta_suplemento') {
    if (payload['suplemento_nombre'] != null) {
      detalles.add('Suplemento: ${payload['suplemento_nombre']}');
    }
    final cant = (payload['cantidad'] as num?) ?? 1;
    detalles.add('Cantidad: $cant');
    final total = (payload['total'] as num?) ??
        (((payload['precio'] as num?) ?? 0) * cant);
    final moneda = payload['moneda'] ?? 'CUP';
    if (total > 0) detalles.add('Total: ${fmtMonto(total)} $moneda');
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) {
      detalles.add('Cliente: $n');
    } else if (payload['comprador_nombre'] != null) {
      detalles.add('Comprador: ${payload['comprador_nombre']}');
    }
  } else if (tipo == 'crear_suplemento' || tipo == 'editar_suplemento') {
    if (payload['nombre'] != null) {
      detalles.add('Suplemento: ${payload['nombre']}');
    }
    final p = payload['precio_oficial'] ?? payload['precio'];
    if (p != null) detalles.add('Precio: $p USD');
  } else if (tipo == 'eliminar_suplemento') {
    // G08-6: por su nombre del espejo (o sin la fila).
    final n = await nombreSuplemento(payload['suplemento_id']);
    if (n != null) detalles.add('Suplemento: $n');
    detalles.add('Acción: Eliminar');
  } else if (tipo == 'incidencia' || tipo == 'incidencia_estado') {
    if (payload['descripcion'] != null) {
      detalles.add('Descripción: ${payload['descripcion']}');
    }
    if (payload['tipo'] != null) {
      detalles.add('Tipo: ${payload['tipo']}');
    }
    if (payload['estado'] != null) {
      detalles.add('Estado: ${payload['estado']}');
    }
    if (payload['nota_resolucion'] != null) {
      detalles.add('Nota: ${payload['nota_resolucion']}');
    }
  } else if (tipo == 'cierre_turno') {
    if (payload['fecha'] != null) {
      // G08-6: fecha legible de la casa, no el ISO crudo.
      detalles.add('Fecha: ${fmtFecha('${payload['fecha']}')}');
    }
    if (payload['turno'] != null) {
      detalles.add('Turno: ${payload['turno']}');
    }
    final tc = payload['total_cobrado'] ?? payload['total'];
    if (tc != null) detalles.add('Total cobrado: ${fmtMonto(tc)} CUP');
  } else if (tipo == 'foto_suplemento') {
    // G08-6: por su nombre del espejo (o sin la fila).
    final n = await nombreSuplemento(payload['suplemento_id']);
    if (n != null) detalles.add('Suplemento: $n');
  }
  return detalles;
}

/// Chip de estado para operaciones (v1.0.9.1).
/// v1.3.4: extraído de `_ColaScreenState._estadoChip` a función top-level
/// para reutilizarlo en [DetalleSyncScreen].
/// 1.25 T123 (F6-05): la etiqueta legible de un estado de
/// op, separada del chip para poder usarla en textos
/// (diálogos, subtítulos) sin pintar el estado crudo.
String etiquetaEstadoOp(String estado) => switch (estado) {
      'aplicada' => 'Confirmada',
      'rechazada' => 'Rechazada',
      'enviada' => 'Confirmación pendiente',
      'pendiente' => 'Pendiente',
      'error' => 'Falló',
      'necesita_revision' => 'Requiere revisión',
      _ => estado,
    };

/// 1.31 (Yunque A): «dd/MM HH:mm» de un sello de sincronización
/// en hora de La Habana. Los sellos se parsean en UTC y antes se
/// imprimían crudos (16:35 por las 11:35 de La Habana).
/// Conversión canónica de la casa ([aHabana]); un instante que
/// no venga en UTC no se toca. Función pura, la usa
/// [_ColaScreenState._hora].
String horaCortaHabana(DateTime? d) {
  if (d == null) return '—';
  final h = d.isUtc ? aHabana(d) : d;
  return '${h.day.toString().padLeft(2, '0')}/${h.month.toString().padLeft(2, '0')} '
      '${h.hour.toString().padLeft(2, '0')}:${h.minute.toString().padLeft(2, '0')}';
}

Widget chipEstadoOp(String estado) {
  Color color;
  IconData icono;
  final texto = etiquetaEstadoOp(estado);
  if (estado == 'aplicada') {
    color = AppColores.exito;
    icono = Icons.check_circle_rounded;
  } else if (estado == 'rechazada') {
    color = AppColores.error;
    icono = Icons.block_rounded;
  } else if (estado == 'enviada') {
    // v1.2.9+46: ámbar + etiqueta legible.
    color = AppColores.alerta;
    icono = Icons.sync_problem_rounded;
  } else if (estado == 'pendiente') {
    color = AppColores.naranja;
    icono = Icons.schedule_rounded;
  } else if (estado == 'error') {
    color = AppColores.error;
    icono = Icons.warning_amber_rounded;
  } else if (estado == 'necesita_revision') {
    // v1.3.5 (auditoría 2026-10-16): etiqueta legible en vez del código.
    color = AppColores.alerta;
    icono = Icons.rule_rounded;
  } else {
    color = AppColores.naranja;
    icono = Icons.schedule_rounded;
  }
  return ChipEstado.libre(texto: texto, color: color, icono: icono);
}

class ColaScreen extends StatefulWidget {
  const ColaScreen({super.key});
  @override
  State<ColaScreen> createState() => _ColaScreenState();
}

class _ColaScreenState extends State<ColaScreen> {
  // Ronda 17 M6-H1: actor de la sesión para filtrar ops ajenas.
  String? _miActor;
  int? _miTelegramId;
  // Ronda 17 M6-H1: dueño confirmado en la última carga
  // (fail-closed: falso hasta que _cargar lo confirme).
  bool _esDueno = false;
  // Ronda 17 M6-H2: candados anti-doble-toque en reintentos.
  final Set<String> _opsReintentando = {};
  // 1.35 (CAMPO-9): el candado anti-doble-toque del
  // reintento de fotos es por FOTO (op_uuid), no por fila.
  final Set<String> _fotosReintentando = {};
  bool _reintentandoTodasFotos = false;
  // Corrección A4-D2: ¿hay internet AHORA? (de la foto de
  // estado del motor, refrescada sin bloquear la carga).
  // Lo usa la explicación por op para no decir «No hay
  // conexión a internet» cuando quien no responde es el
  // servidor. null = aún no se sabe (traducción clásica).
  bool? _hayInternet;

  /// 1.33 (coherencia de sync, §7.2/§7.3): EL texto visible
  /// del error de corrida en esta pantalla, compuesto UNA
  /// sola vez. Si detalle() lo trae en datos (el registro
  /// 1.33: código + pierna + tablas + hora), se compone
  /// desde el código con la conectividad de AHORA — el
  /// matiz A4-D2 vive dentro del compositor —; si es un
  /// texto legado o el detalle del Diario, se conserva el
  /// camino anterior. Lo consumen el subtítulo del héroe y
  /// la banda de error: hasta la 1.32 el héroe re-traducía
  /// el mensaje persistido (y degradaba al genérico) y la
  /// banda lo pintaba crudo.
  String? get _textoErrorVisible {
    final e = _det.error;
    if (e == null || e.isEmpty) return null;
    if (_det.errorCodigo != null) {
      return textoErrorCorridaPersistido(
          codigo: _det.errorCodigo!,
          pierna: _det.errorPierna ?? '',
          tablas: _det.errorTablas,
          horaIso: _det.errorHoraIso,
          hayInternet: _hayInternet);
    }
    // Fase 1 (INT-01): sin código, el texto de detalle() ya
    // viene compuesto (el Diario, con su crudo traducido en
    // la fuente desde SYNC-04) o es el mensaje humano legado
    // de la 1.32: se pinta TAL CUAL. Re-clasificarlo aquí
    // degradaba los legados más comunes («No hay conexión a
    // internet.») al genérico mudo «Hubo un problema al
    // sincronizar», sin pierna ni causa.
    return e;
  }

  List<Map<String, dynamic>> _ops = [];
  // v1.2.5 (D15): ops bloqueadas que necesitan revisión manual.
  List<Map<String, dynamic>> _bloqueadas = [];
  SyncDetalle _det = const SyncDetalle();
  // v1.12.0 (E1/E2): resumen en sencillo + retenidas en ventana
  // de edición (retenerHasta → proximo_reintento futuro).
  int _retenidas = 0;
  int _totalPendientes = 0;
  // Yunque 3 (K7-1): conteos del héroe leídos de la BD
  // (LocalDb.conteosHeroeCola), NO de la lista visible
  // truncada a 30: una op en error/rechazada/enviada empujada
  // fuera de la ventana ya no desaparece del encabezado.
  int _heroErrorOps = 0;
  int _heroEnLimbo = 0;
  // 1.15: desglose por tipo de LO PENDIENTE (mismo conjunto que
  // _totalPendientes), contado en la BD. Antes se agrupaba la
  // lista reciente (30 ops de cualquier estado) y el desglose
  // sumaba 30 con solo 1 op en vuelo.
  Map<String, int> _desglosePendientes = {};
  String? _masAntiguaIso;
  // D-03 (1.21): guardia de reentrada de _cargar (el listener de
  // estado + pull-to-refresh + botones podían solapar cargas).
  bool _cargandoAhora = false;
  bool _recargaPendiente = false;
  // A-03 (1.21): comprobantes de pago en error (reintento
  // deliberado, patrón H-12 de fotos de incidencias).
  List<Map<String, dynamic>> _compError = [];
  // 1.36 (136-142): comprobantes pendientes de subir, para
  // los totales del héroe (fuera de ops_queue).
  int _compPendientes = 0;
  // D-12 (1.21): títulos de op memoizados al cargar —
  // tituloDeOp decodifica el payload JSON; hacerlo por op en
  // cada build era el coste real de la lista (la lista en sí
  // está acotada a las 30 ops recientes de recentOps).
  Map<String, String> _titulosOp = {};
  bool _sincronizando = false;
  // SL-8 (G08-4): los bloques auxiliares de la Cola
  // (estadísticas, resumen, bloqueadas, fotos…) nacen
  // PLEGADOS tras el control «Resumen y detalle»; la
  // lista de operaciones es el contenido que manda.
  bool _auxAbierto = false;

  /// G08-4: la línea que resume el estado de los bloques
  /// plegados en su control — el estado del héroe y las
  /// cifras que piden atención, para que plegar no oculte
  /// nada que haya que atender.
  String _resumenAuxiliares({
    required String tituloHeroe,
    required int totalPendiente,
  }) {
    // Cierre del lote 1.35: el subtítulo NO repite las
    // cifras de error — la sync se dice una sola vez
    // (contrato SP-06): el error de ops lo vocean sus
    // filas y el de fotos, su pastilla. Aquí quedan el
    // estado del héroe, el flujo y lo por subir.
    return [
      tituloHeroe,
      '↓ ${_det.bajados} · ↑ ${_det.subidos}',
      if (totalPendiente > 0) '$totalPendiente por subir',
    ].join(' · ');
  }

  // v1.4.0: progreso visible de la sincronización manual.
  SyncProgress? _progresoSync;
  int _ultimoProgresoMs = 0;
  SyncFase? _ultimaFaseSync;
  // v1.2.9+46: contadores de la cola de fotos.
  int _fotosPendientes = 0;
  int _fotosSubiendo = 0;
  int _fotosError = 0;
  // 1.29 (Oleada 6, FA-06): desglose por autor de las
  // pendientes globales en la vista del DUEÑO (la cifra
  // de cabecera sigue siendo el total global) y el
  // directorio telegram_id → nombre para etiquetar las
  // ops ajenas sin inventar nombres.
  int _pendientesMias = 0;
  int _pendientesDeOtros = 0;
  // 1.35 (SP-11): ops del conjunto sin firma de autor
  // (legadas): tercera clase del desglose, no se atribuyen.
  int _pendientesSinAutor = 0;
  Map<int, String> _nombresPorTelegram = {};
  // v1.2.9+46: detalle de fotos pendientes/error para gestión.
  // 1.35 (CAMPO-9): el detalle son GRUPOS (una fila por foto);
  // _nombresFotos identifica cada foto por su entidad
  // ('c<clienteId>' / 's<suplementoId>' → nombre del espejo)
  // y _fotosGruposExpandidos guarda qué grupos muestran sus
  // variantes.
  List<GrupoFotoCola> _fotosGrupos = [];
  Map<String, String> _nombresFotos = {};
  final Set<String> _fotosGruposExpandidos = {};
  bool _fotosExpandido = false;
  // Pasada (Argón): la expansión pinta una VENTANA de
  // filas (12); sin ella, expandir decodificaba hasta 50
  // miniaturas en un solo frame. «Ver las restantes» la
  // abre entera, a petición.
  bool _fotosMostrarTodas = false;
  // H-12 (1.20): fotos de incidencias en 'error' (tabla propia),
  // con su marca de recuperable calculada por LocalDb.
  List<Map<String, dynamic>> _fotosIncError = [];
  bool _reintentandoFotosInc = false;
  StreamSubscription<SyncStatus>? _syncSub;
  // Yunque B (YB-SYNC-01/02): la BAJADA también se atasca, y
  // ese atasco es del propio teléfono: su tabla se nombra
  // aquí para cualquier rol (no son datos del dueño: es el
  // diagnóstico de este aparato). Lo alimenta _cargar desde
  // el rastro persistente del pull y la foto del motor.
  ({String? tabla, String? nombre, int? seq, int filas}) _atasco =
      (tabla: null, nombre: null, seq: null, filas: 0);
  String? _tablaAtrasada;

  @override
  void initState() {
    super.initState();
    _cargar();
    // v1.2.9+46 (Gemini): refresco reactivo al terminar un push/pull.
    _syncSub = SyncEngine.instance.statusStream.listen((s) {
      if (s.phase == SyncPhase.idle) _cargar();
    });
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }


  /// v1.3.1: permite descartar una foto pendiente (ej: sin cliente asociado).
  /// 1.35 (SP-07): el descarte es POR FOTO — borra todas
  /// las variantes del grupo (antes borraba una sola fila
  /// y la foto «descartada» reaparecía con la variante
  /// siguiente, contra lo que el diálogo prometía).
  Future<void> _cancelarFotoGrupo(GrupoFotoCola g) async {
    // 1.24 Bloque 4 (H-01, cinturón): si el worker está
    // subiendo alguna variante, no se descarta (la fila
    // desaparecería a mitad de la subida y los bytes
    // quedarían huérfanos). La UI ya no ofrece el botón
    // en ese estado; esto cubre la ventana en que la
    // foto cambió tras pintarse.
    if (g.algunaSubiendo) {
      if (mounted) {
        mostrarSnack(
            context, 'Esa foto se está subiendo ahora mismo',
            significado: SignificadoChip.alerta);
      }
      return;
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Descartar foto',
      mensaje: '¿Descartar esta foto? Se descartan todas '
          'sus versiones (miniatura, pantalla y original) '
          'y no se subirá al sistema.',
      aceptar: 'Sí, descartar',
      peligro: true,
      icono: Icons.delete_outline_rounded,
    );
    if (ok != true) return;
    try {
      final db = await LocalDb.instance.db;
      final n = await descartarFotoGrupoCola(db, g.opUuid,
          esDueno: _esDueno, miTelegramId: _miTelegramId);
      AppLog.info('fotos', 'descartada_manual',
          d: 'op=${g.opUuid} filas=$n');
      await _cargar();
      if (mounted) {
        // G#25: -1 = una variante empezó a subir durante
        // la confirmación: no se descartó nada.
        if (n < 0) {
          mostrarSnack(context, 'Esa foto se está subiendo ahora mismo',
              significado: SignificadoChip.alerta);
        } else {
          mostrarSnack(context,
              n == 0 ? 'Esa foto ya no estaba en la cola' : 'Foto descartada');
        }
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo descartar la foto: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    }
  }

  // AA2 H-4: quien llama durante una carga en curso espera a
  // que la recarga coalescida TERMINE (Completer compartido):
  // antes el Future volvía al instante y el pull-to-refresh o
  // un snack encadenado podían adelantarse a los datos.
  Completer<void>? _recargaCompleter;

  /// Corrección A4-D2: refresca [_hayInternet] desde la
  /// foto del motor (que reutiliza la suya si es fresca).
  /// Nunca lanza ni bloquea: es un dato para el texto.
  ///
  /// SYNC-12 (1.35): si la foto trae la línea sin verificar
  /// (null), el bool local NO se toca — un «no se sabe» no
  /// puede pisar el último valor conocido de la pantalla.
  Future<void> _refrescarInternet() async {
    try {
      final f = await SyncEngine.instance.fotoEstado();
      final enLinea = f.enLinea;
      if (mounted && enLinea != null && enLinea != _hayInternet) {
        setState(() => _hayInternet = enLinea);
      }
    } catch (_) {}
  }

  Future<void> _cargar() async {
    // D-03 (1.21): si ya hay una carga en curso, se marca y se
    // repite al terminar (no se solapan ni se pierde la última).
    if (_cargandoAhora) {
      _recargaPendiente = true;
      _recargaCompleter ??= Completer<void>();
      return _recargaCompleter!.future;
    }
    _cargandoAhora = true;
    try {
      await _cargarInterno();
    } finally {
      _cargandoAhora = false;
      // Quien esperó durante esta carga se libera cuando la
      // recarga coalescida termina (o ya, si la pantalla se
      // cerró y la recarga no va a correr: nadie queda colgado).
      // AA3-1: la recarga va envuelta — si _cargarInterno lanza
      // en sus primeros awaits (sin try/catch propio), el error
      // no debe saltarse el complete(): el Future del que
      // espera quedaría colgado para siempre (el indicador de
      // pull-to-refresh girando sin fin).
      final espera = _recargaCompleter;
      _recargaCompleter = null;
      if (_recargaPendiente && mounted) {
        _recargaPendiente = false;
        try {
          await _cargar();
        } catch (_) {
          // La recarga falló: el error ya quedó registrado en
          // el ciclo que lo lanzó; aquí solo importa liberar
          // a quien espera.
        }
      }
      espera?.complete();
    }
  }

  Future<void> _cargarInterno() async {
    // Corrección A4-D2: la foto de internet se refresca en
    // segundo plano (nunca se espera antes de pintar: la
    // cola es 100 % local); cuando aterriza, las filas se
    // repintan con la explicación corregida.
    unawaited(_refrescarInternet());
    // Ronda 17 M6-H1: actor de la sesión (fail-closed).
    try {
      _miActor = AuthService().displayName;
      _miTelegramId = AuthService().telegramId;
    } catch (_) {
      _miActor = null;
      _miTelegramId = null;
    }
    try {
      _esDueno = AuthService().isOwner;
    } catch (_) {
      _esDueno = false;
    }
    final ops = await LocalDb.instance.recentOps();
    final bloqueadas = await LocalDb.instance.opsNecesitanRevision();
    final det = await SyncEngine.instance.detalle();
    // Yunque B (YB-SYNC-01/02): el estado de la BAJADA de
    // este teléfono (tabla atascada sin verificar y tabla
    // más atrasada), tolerante: si la lectura falla, la
    // tarjeta simplemente no sale.
    // Yunque B (YB-SYNC-01/02): el diagnóstico de la bajada
    // se enriquece EN SEGUNDO PLANO (ver _cargarBajada): la
    // cola pinta primero con sus datos locales y la tarjeta
    // llega cuando la lectura ligera termina. Esperarlo aquí
    // retrasaba toda la pantalla (y rompía su arnés).
    // v1.2.9+46: contadores y detalle de fotos.
    int fPend = 0, fSub = 0, fErr = 0;
    List<Map<String, dynamic>> fDet = [];
    // H-12 (1.20): fotos de incidencias en error (otra tabla).
    var fotosIncError = <Map<String, dynamic>>[];
    try {
      fotosIncError =
          await LocalDb.instance.fotosIncidenciasEnError();
    } catch (_) {}
    // A-03 (1.21): comprobantes de pago en error.
    var compError = <Map<String, dynamic>>[];
    try {
      compError =
          await ComprobantesService.instance.comprobantesEnError();
    } catch (_) {}
    // 1.36 (136-142): comprobantes aún pendientes de subir —
    // entran en el total del héroe para que no diga «Todo
    // al día» con un comprobante vivo fuera de ops_queue.
    var compPendientes = 0;
    try {
      compPendientes =
          await LocalDb.instance.contarComprobantesPendientes();
    } catch (_) {}
    // 1.29 (Oleada 6, D-A3): las filas vivas de la cola se
    // leen UNA vez, con el sello de autor (v68), y de ahí
    // salen contadores y detalle. Antes los contadores eran
    // COUNT(*) globales: un entrenador veía en la cabecera
    // las fotos de TODOS. Sin límite en la lectura: los
    // contadores del no-dueño se calculan sobre el conjunto
    // ya filtrado por autor (la lista truncada a 50 no
    // puede ser su fuente sin mentir); las filas son
    // ligeras (sin blobs) y la cola viva es corta por
    // diseño (lo completado sale de este conjunto).
    List<Map<String, dynamic>> filasFotos = [];
    try {
      final db = await LocalDb.instance.db;
      filasFotos = await db.query(
        'fotos_cola',
        columns: [
          'id',
          'op_uuid',
          'tipo',
          'cliente_id',
          'suplemento_id',
          'ruta_local',
          'estado',
          'intentos',
          'ultimo_error',
          'creado_en',
          'proximo_intento_en',
          'forzar_qos',
          'tamano_bytes',
          'telegram_id'
        ],
        where: "estado IN ('pendiente', 'subiendo', 'error')",
        orderBy: 'creado_en DESC',
      );
    } catch (_) {}
    if (_esDueno) {
      // El dueño ve el total global, como siempre.
      // 1.35 (SP-05): conteos POR FOTO (estado conjunto del
      // grupo), no por variante.
      final conteosF = conteosFotosPorFoto(filasFotos);
      fPend = conteosF.pendientes;
      fSub = conteosF.subiendo;
      fErr = conteosF.error;
      fDet = filasFotos;
    }
    // v1.12.0 (E1/E2): totales reales (la lista visible tiene
    // límite) + retenidas + la más antigua, para el resumen en
    // sencillo y el botón «Subir ahora».
    var retenidas = 0;
    var totalPendientes = 0;
    var desglosePendientes = <String, int>{};
    String? masAntiguaIso;
    try {
      retenidas = await LocalDb.instance.countOpsRetenidas();
      totalPendientes = await LocalDb.instance.countPendingOps();
      desglosePendientes =
          await LocalDb.instance.conteoPendientesPorTipo();
      masAntiguaIso =
          await LocalDb.instance.isoOpPendienteMasAntigua();
    } catch (_) {}
    // 1.29 (Oleada 6, FA-06): en la vista del DUEÑO, el
    // desglose por autor de las pendientes GLOBALES (la
    // cifra de cabecera NO cambia: sigue siendo el total
    // global de countPendingOps, el mismo de Salud del
    // sync) y el directorio de nombres para las etiquetas
    // de las filas. Se lee el conjunto completo de
    // pendientes (columnas ligeras), no la lista reciente
    // de 30: el desglose tiene que sumar el total.
    var pendientesMias = 0;
    var pendientesDeOtros = 0;
    var pendientesSinAutor = 0;
    var nombresPorTelegram = <int, String>{};
    if (_esDueno) {
      try {
        final db = await LocalDb.instance.db;
        // 1.35 (SP-03): el desglose se lee sobre el MISMO
        // conjunto que el total (countPendingOps: pendiente
        // + enviada + error), no solo 'pendiente'.
        final pendientes = await db.query('ops_queue',
            columns: ['op_uuid', 'tipo', 'payload', 'telegram_id'],
            where: "estado IN ('pendiente', 'enviada', 'error')");
        final desg = desglosePendientesPorAutor(pendientes,
            miActor: _miActor, miTelegramId: _miTelegramId);
        pendientesMias = desg.mias;
        pendientesDeOtros = desg.deOtros;
        pendientesSinAutor = desg.sinAutor;
        final rawDir = await LocalDb.instance.getMeta('usuarios_apk');
        if (rawDir != null && rawDir.isNotEmpty) {
          final dec = jsonDecode(rawDir);
          if (dec is List) {
            for (final e in dec) {
              if (e is Map) {
                final tid = int.tryParse('${e['telegram_id'] ?? ''}');
                final nombre = '${e['nombre'] ?? ''}'.trim();
                if (tid != null && nombre.isNotEmpty) {
                  nombresPorTelegram[tid] = nombre;
                }
              }
            }
          }
        }
      } catch (_) {}
    }
    // Ronda 17 M6-H1: un no-dueño solo ve sus ops (y el banner
    // cuenta solo lo suyo: exacto si la lista no se truncó en 30).
    final opsVisibles = _esDueno
        ? ops
        : ops
            .where((o) => esOpMia(o,
                miActor: _miActor, miTelegramId: _miTelegramId))
            .toList();
    final bloqueadasVisibles = _esDueno
        ? bloqueadas
        : bloqueadas
            .where((o) => esOpMia(o,
                miActor: _miActor, miTelegramId: _miTelegramId))
            .toList();
    // Ronda 17 M6-H1 (extensión) + 1.29 (Oleada 6, D-A3):
    // a un no-dueño, la lista Y los contadores de fotos
    // pasan por DOS filtros que se componen: (1) el de
    // AUTOR de v68 (fotoVisibleParaActor: suyas selladas;
    // las previas sin sello son del dueño y no se le
    // enseñan) y (2) el de cliente protegido vigente (la
    // fila enseña la miniatura: la foto pendiente de un
    // protegido no se muestra ni siendo de su autor).
    var fotosVisibles = fDet;
    if (!_esDueno) {
      var porAutor = filasFotos
          .where((f) => fotoVisibleParaActor(f,
              esDueno: false, miTelegramId: _miTelegramId))
          .toList();
      try {
        // D-03 (1.21): solo hacen falta los clientes de las
        // fotos en juego, no el espejo entero.
        final idsFotos = <int>{
          for (final f in porAutor)
            if (f['cliente_id'] is int) f['cliente_id'] as int,
        };
        final clientes = idsFotos.isEmpty
            ? <Map<String, dynamic>>[]
            : await LocalDb.instance
                .mirrorPorIds('clientes', idsFotos.toList());
        final protegidos = <int>{
          for (final c in clientes)
            if (esVistaProtegida(c)) c['id'] as int,
        };
        porAutor = porAutor.where((f) {
          final cid = f['cliente_id'];
          if (cid is int) return !protegidos.contains(cid);
          final n = int.tryParse('$cid');
          return n == null || !protegidos.contains(n);
        }).toList();
      } catch (_) {}
      fotosVisibles = porAutor;
      // 1.35 (SP-05): también aquí, conteos por foto.
      final conteosF = conteosFotosPorFoto(porAutor);
      fPend = conteosF.pendientes;
      fSub = conteosF.subiendo;
      fErr = conteosF.error;
    }
    // Ronda 17 M6-H1+H3: a un no-dueño, el banner cuenta
    // solo lo suyo (el total de BD es global).
    var totalPendientesFinal = totalPendientes;
    var desgloseFinal = desglosePendientes;
    if (!_esDueno) {
      // Respaldo (ventana): solo queda si la lectura de BD de
      // abajo lanza; el valor bueno es el de la BD sin truncar.
      final pendientesPropias =
          opsVisibles.where((o) => o['estado'] == 'pendiente');
      totalPendientesFinal = pendientesPropias.length;
      desgloseFinal = <String, int>{};
      for (final o in pendientesPropias) {
        final t = '${o['tipo']}';
        desgloseFinal[t] = (desgloseFinal[t] ?? 0) + 1;
      }
      // Yunque 3 (K7-2): el total y el desglose del entrenador
      // salen de la BD con su filtro de autor (el mismo
      // esOpMia de la lista visible), no de la ventana de 30:
      // con 35 pendientes propias entre aplicadas ajenas la
      // tarjeta decía 30.
      try {
        final propias =
            await LocalDb.instance.conteoPendientesPropias(
          esMia: (o) => esOpMia(o,
              miActor: _miActor, miTelegramId: _miTelegramId),
        );
        totalPendientesFinal = propias.total;
        desgloseFinal = propias.porTipo;
      } catch (_) {}
      // Yunque 4 (L7-3): la antigüedad de la más antigua y
      // las retenidas que alimentan la tarjeta, el aviso de
      // 6 h y el botón «Subir ahora» también son DEL AUTOR:
      // las lecturas globales le atribuían al entrenador la
      // op vieja retenida del dueño en el teléfono
      // compartido.
      try {
        retenidas =
            await LocalDb.instance.countOpsRetenidasDe(
          esMia: (o) => esOpMia(o,
              miActor: _miActor, miTelegramId: _miTelegramId),
        );
        masAntiguaIso = await LocalDb.instance
            .isoOpPendienteMasAntiguaDe(
          esMia: (o) => esOpMia(o,
              miActor: _miActor, miTelegramId: _miTelegramId),
        );
      } catch (_) {}
    }
    // Yunque 3 (K7-1): los conteos del héroe (error/enviada)
    // salen de la BD, no de _ops truncada. Para el dueño son
    // globales; para el entrenador van filtrados por el mismo
    // esOpMia. Si la lectura lanza, quedan los de la carga
    // anterior (nunca un cero inventado a mitad de sesión).
    var heroErrorOps = _heroErrorOps;
    var heroEnLimbo = _heroEnLimbo;
    try {
      final hero = await LocalDb.instance.conteosHeroeCola(
        esMia: _esDueno
            ? null
            : (o) => esOpMia(o,
                miActor: _miActor, miTelegramId: _miTelegramId),
      );
      heroErrorOps = hero.error;
      heroEnLimbo = hero.enviada;
    } catch (_) {}
    // 1.35 (CAMPO-9): el detalle se agrupa por foto y cada
    // foto se identifica por el nombre de su entidad.
    final fotosGrupos = agruparFotosCola(fotosVisibles);
    final nombresFotos = await _nombresDeFotos(fotosGrupos);
    if (mounted) {
      setState(() {
        _ops = opsVisibles;
        _bloqueadas = bloqueadasVisibles;
        _det = det;
        _fotosPendientes = fPend;
        _fotosSubiendo = fSub;
        _fotosError = fErr;
        _fotosGrupos = fotosGrupos;
        _nombresFotos = nombresFotos;
        _fotosIncError = fotosIncError;
        _compError = compError;
        _compPendientes = compPendientes;
        _titulosOp = {
          for (final op in [...opsVisibles, ...bloqueadasVisibles])
            '${op['op_uuid']}': tituloDeOp(op),
        };
        _retenidas = retenidas;
        _heroErrorOps = heroErrorOps;
        _heroEnLimbo = heroEnLimbo;
        _totalPendientes = totalPendientesFinal;
        _desglosePendientes = desgloseFinal;
        _masAntiguaIso = masAntiguaIso;
        _pendientesMias = pendientesMias;
        _pendientesDeOtros = pendientesDeOtros;
        _pendientesSinAutor = pendientesSinAutor;
        _nombresPorTelegram = nombresPorTelegram;
      });
    }
    unawaited(_cargarBajada());
  }

  /// 1.35 (CAMPO-9): nombres de las entidades de los
  /// grupos de fotos, desde el espejo local, para que la
  /// fila diga «Foto de <cliente>» en vez de un id. Claves
  /// 'c<clienteId>' y 's<suplementoId>'. Tolerante: sin
  /// espejo o sin nombre, la fila cae a su etiqueta por id.
  Future<Map<String, String>> _nombresDeFotos(
      List<GrupoFotoCola> grupos) async {
    final out = <String, String>{};
    try {
      // mirrorPorIds devuelve la data ya decodificada con
      // la columna 'id' garantizada.
      final idsC =
          grupos.map((g) => g.clienteId).whereType<int>().toSet();
      if (idsC.isNotEmpty) {
        final filas = await LocalDb.instance
            .mirrorPorIds('clientes', idsC.toList());
        for (final f in filas) {
          final id = (f['id'] as num?)?.toInt();
          final n = f['nombre'];
          if (id != null && n is String && n.trim().isNotEmpty) {
            out['c$id'] = n.trim();
          }
        }
      }
      final idsS =
          grupos.map((g) => g.suplementoId).whereType<int>().toSet();
      if (idsS.isNotEmpty) {
        final filas = await LocalDb.instance
            .mirrorPorIds('suplementos', idsS.toList());
        for (final f in filas) {
          final id = (f['id'] as num?)?.toInt();
          final n = f['nombre'];
          if (id != null && n is String && n.trim().isNotEmpty) {
            out['s$id'] = n.trim();
          }
        }
      }
    } catch (_) {}
    return out;
  }

  /// Yunque B (YB-SYNC-01/02): lee el diagnóstico de la
  /// BAJADA de este teléfono sin bloquear la carga de la
  /// cola: el rastro persistente del atasco
  /// ([SyncEngine.atascoSinVerificar]) y la tabla más
  /// atrasada, calculada directa de los watermarks (la foto
  /// completa del motor incluye red y no debe esperarse
  /// para pintar una pantalla local). Tolerante: si la
  /// lectura falla, la tarjeta simplemente no sale.
  Future<void> _cargarBajada() async {
    try {
      final atasco = await SyncEngine.instance.atascoSinVerificar();
      final minR = await LocalDb.instance.tablaMasAtrasada(
          excluir: {'borrados'}, esAdmin: _esDueno);
      final ss =
          int.tryParse(await LocalDb.instance.getMeta('server_seq') ?? '0') ??
              0;
      final atrasada = minR.tabla != null && ss > minR.wm
          ? SyncEngine.nombreAmigableTabla(minR.tabla!)
          : null;
      if (!mounted) return;
      if (_atasco != atasco || _tablaAtrasada != atrasada) {
        setState(() {
          _atasco = atasco;
          _tablaAtrasada = atrasada;
        });
      }
    } catch (_) {}
  }

  /// v1.2.9+46: reintenta una foto específica (resetea backoff).
  /// 1.35 (CAMPO-9/SP-07): el reintento es POR FOTO —
  /// resetea el backoff de todas sus variantes (cada una
  /// pasa por reintentarFotoCola, con su filtro de autor).
  Future<void> _reintentarFotoGrupo(GrupoFotoCola g) async {
    // Ronda 17 M6-H2: candado anti-doble-toque.
    if (_fotosReintentando.contains(g.opUuid)) return;
    _fotosReintentando.add(g.opUuid);
    try {
      final db = await LocalDb.instance.db;
      final tocadas = await reintentarFotoGrupoCola(db, g.opUuid,
          esDueno: _esDueno, miTelegramId: _miTelegramId);
      if (tocadas == 0) {
        if (mounted) {
          mostrarSnack(
              context, 'Esa foto se está subiendo ahora mismo',
              significado: SignificadoChip.alerta);
        }
        await _cargar();
        return;
      }
      AppLog.info('fotos', 'reintento_manual', d: 'op=${g.opUuid}');
      await _cargar();
      if (mounted) {
        mostrarSnack(context, 'Foto marcada para reintento', significado: SignificadoChip.exito);
      }
      // Disparar sincronización para procesarla de inmediato.
      unawaited(SyncEngine.instance.push());
    } catch (e) {
      AppLog.error('fotos', 'reintento_manual_fallo', d: 'op=${g.opUuid} · $e');
      if (mounted) {
        mostrarSnack(context, 'No se pudo reintentar: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    } finally {
      _fotosReintentando.remove(g.opUuid);
    }
  }

  /// v1.2.9+46: reintenta todas las fotos pendientes/con error.
  Future<void> _reintentarTodasFotos() async {
    // Ronda 17 M6-H2: candado anti-doble-toque.
    if (_reintentandoTodasFotos) return;
    _reintentandoTodasFotos = true;
    try {
      final db = await LocalDb.instance.db;
      // 1.30 (Oleada 9, ítem 11): la mutación vive en
      // reintentarTodasFotosCola, con el filtro de autor:
      // el no-dueño solo marca las suyas; el dueño conserva
      // la cola completa (su reintento es el rescate).
      // 1.35 (SP-05): el aviso cuenta FOTOS (grupos con
      // alguna variante por reintentar), no filas: el
      // helper devuelve filas tocadas y una foto son 3.
      final fotos = _fotosGrupos
          .where((g) => g.variantes.any((v) =>
              v['estado'] == 'pendiente' || v['estado'] == 'error'))
          .length;
      final n = await reintentarTodasFotosCola(db,
          esDueno: _esDueno, miTelegramId: _miTelegramId);
      AppLog.info('fotos', 'reintento_manual_todas', d: 'tocadas=$n');
      await _cargar();
      if (mounted) {
        mostrarSnack(
            context,
            fotos == 0
                ? 'No había fotos por reintentar'
                : fotos == 1
                    ? '1 foto marcada para reintento'
                    : '$fotos fotos marcadas para reintento',
            significado:
                fotos == 0 ? SignificadoChip.alerta : SignificadoChip.exito);
      }
      if (n > 0) unawaited(SyncEngine.instance.push());
    } catch (e) {
      AppLog.error('fotos', 'reintento_manual_todas_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context, 'No se pudo reintentar: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    } finally {
      _reintentandoTodasFotos = false;
    }
  }

  /// H-12 (1.20): reintento DELIBERADO de las fotos de
  /// incidencias en 'error' cuyo archivo local aún existe. Las
  /// que perdieron el archivo no se reactivan: volverían a
  /// fallar al instante y el conteo mentiría.
  Future<void> _reintentarFotosIncidencias() async {
    if (_reintentandoFotosInc) return;
    _reintentandoFotosInc = true;
    try {
      final ids = [
        for (final f in _fotosIncError)
          if (f['recuperable'] == true) '${f['id']}',
      ];
      final n = await LocalDb.instance
          .reactivarFotosIncidenciasError(ids);
      AppLog.info('fotos', 'reintento_incidencias_manual',
          d: 'reactivadas=$n');
      await _cargar();
      if (mounted) {
        mostrarSnack(
            context,
            n == 1
                ? 'Foto de incidencia marcada para reintento'
                : '$n fotos de incidencias marcadas para reintento',
            significado: SignificadoChip.exito);
      }
      SyncEngine.instance.reintentarFotosIncidencias();
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'Sigue pendiente de subir; se reintentará solo.',
            significado: SignificadoChip.alerta);
      }
    } finally {
      _reintentandoFotosInc = false;
    }
  }

  bool _reintentandoComp = false;

  /// A-03 (1.21): reintento DELIBERADO de los comprobantes de
  /// pago en 'error' cuyo archivo sigue en el teléfono (el
  /// servicio decide; aquí solo se dispara y se reporta).
  Future<void> _reintentarComprobantes() async {
    if (_reintentandoComp) return;
    _reintentandoComp = true;
    try {
      final n = await ComprobantesService.instance
          .reactivarComprobantesError();
      await _cargar();
      if (mounted) {
        mostrarSnack(
            context,
            n == 1
                ? 'Comprobante marcado para reintento'
                : '$n comprobantes marcados para reintento',
            significado: SignificadoChip.exito);
      }
      unawaited(ComprobantesService.instance.procesar());
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'Sigue pendiente de subir; se reintentará solo.',
            significado: SignificadoChip.alerta);
      }
    } finally {
      _reintentandoComp = false;
    }
  }

  /// A-03 (1.21): tarjeta de comprobantes de pago cuya subida
  /// quedó en 'error' (espejo de la de fotos de incidencias).
  Widget _tarjetaComprobantesError(BuildContext context) {
    final total = _compError.length;
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long_rounded,
                  size: 24, color: AppColores.error),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Comprobantes de pago sin subir',
                    style: AppTexto.subtitulo),
              ),
              ContadorBadge(numero: total),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            total == 1
                ? 'Un comprobante de transferencia no se pudo '
                    'subir. Se reintentan solo los que aún tienen '
                    'el archivo en este teléfono.'
                : '$total comprobantes de transferencia no se '
                    'pudieron subir. Se reintentan solo los que '
                    'aún tienen el archivo en este teléfono.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reintentar'),
              onPressed:
                  _reintentandoComp ? null : _reintentarComprobantes,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sincronizar() async {
    setState(() {
      _sincronizando = true;
      _progresoSync = null;
      _ultimaFaseSync = null;
    });
    SyncResultado? resultado;
    try {
      // v1.4.0: vibración sutil al tocar, sin bloquear la sync.
      unawaited(vibrarConfirmacion());
      // v1.2.5 (D14): "Sincronizar ahora" cancela el backoff de reintentos.
      // v1.8.0 (Frente 5): el resumen se arma con el SyncResultado
      // de ESTA corrida (run() ya no traga el «no corrió»).
      resultado = await SyncEngine.instance.run(
        forzar: true,
        onProgreso: (p) {
          // v1.4.0: throttle de setState (~150 ms) para no saturar la
          // UI — PERO los cambios de fase y el tick final pasan
          // siempre (Argón: si no, la barra se queda visualmente
          // a medias y el último mensaje nunca se anuncia).
          final esCambioFase = p.fase != _ultimaFaseSync;
          final esFinal =
              p.actual != null && p.total != null && p.actual == p.total;
          final ahoraMs = DateTime.now().millisecondsSinceEpoch;
          if (!esCambioFase &&
              !esFinal &&
              ahoraMs - _ultimoProgresoMs < 150) {
            return;
          }
          _ultimoProgresoMs = ahoraMs;
          _ultimaFaseSync = p.fase;
          if (mounted) setState(() => _progresoSync = p);
        },
      );
    } catch (_) {
      // El motor captura sus errores en el SyncResultado; si algo
      // escapó hasta aquí, resultado queda null y el resumen lo
      // dice como error (nunca como éxito).
      resultado = null;
    } finally {
      await _cargar();
      if (mounted) {
        setState(() {
          _sincronizando = false;
          _progresoSync = null;
        });
      }
    }
    // Resumen post-sync (solo en sincronización manual desde aquí)
    if (mounted) _mostrarResumen(resultado);
  }

  /// v1.12.0 (E1): resumen de la cola en palabras claras.
  Widget _tarjetaColaEnSencillo() {
    if (_totalPendientes == 0) {
      // 1.33 (coherencia de sync, §7.1 de la investigación):
      // esta tarjeta solo sabe de la SUBIDA — su condición
      // es la cola de operaciones — y su frase se
      // re-etiqueta a esa verdad parcial: el «Todo está al
      // día» global desaparece de aquí (solo lo puede
      // afirmar quien componga el estado entero, como el
      // héroe o la Salud). Y si el detalle trae un error de
      // corrida vigente — la bajada rota con la subida sana
      // del caso de Jc — la tarjeta lo dice y pierde el
      // verde triunfal.
      final errorVigente = _textoErrorVisible;
      // Fase 1 (SYNC-08): el aviso nombra la pierna REAL del
      // error vigente (la trae detalle()): con un error de
      // subida o de sesión, acusar a «la descarga» era decir
      // lo contrario de lo que pasó. Sin pierna conocida
      // (legado), la frase neutra no acusa a nadie.
      final avisoPierna = switch (_det.errorPierna) {
        'subida' => 'la subida no está al día',
        'bajada' || 'incidencias' => 'la descarga no está al día',
        'sesion' => 'la sesión no está al día',
        _ => 'la sincronización no está al día',
      };
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppEspacio.md),
        decoration: BoxDecoration(
          // Corte B de Argón (B-1): con error vigente la
          // tarjeta va en la superficie de ALERTA resuelta
          // por tema (con su borde), no en avisoFondo
          // sólido: sobre #92400E el texto de cuerpo en los
          // temas claros (claro/Sol) caía a 2,18:1, ilegible.
          color: errorVigente == null
              ? AppColores.exito.withValues(alpha: 0.10)
              : AppColores.alertaSuperficie(context),
          border: errorVigente == null
              ? null
              : Border.all(color: AppColores.alertaBorde(context)),
          borderRadius: BorderRadius.circular(AppRadio.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '✅ No tienes operaciones por subir.',
              style: AppTexto.cuerpo,
            ),
            // 1.35 (SP-04): con 0 operaciones pero fotos en
            // la cola, el resumen NO declara vacío total:
            // nombra las fotos (por foto, SP-05).
            if (_fotosPendientes + _fotosSubiendo > 0) ...[
              const SizedBox(height: 4),
              Text(
                // (1.36 H-B4 136-914) plural real.
                '📷 Además, ${_fotosPendientes + _fotosSubiendo} '
                '${(_fotosPendientes + _fotosSubiendo) == 1 ? 'foto' : 'fotos'} por subir.',
                style: AppTexto.cuerpo,
              ),
            ],
            // UI136-12: los comprobantes de transferencia
            // también se nombran — el héroe los suma a su
            // total y esta tarjeta no los mencionaba: con
            // 0 operaciones y 1 comprobante, el héroe
            // anunciaba 1 y aquí no se decía de qué.
            if (_compPendientes > 0) ...[
              const SizedBox(height: 4),
              Text(
                '🧾 Además, $_compPendientes '
                '${_compPendientes == 1 ? 'comprobante' : 'comprobantes'} '
                'de transferencia por subir.',
                style: AppTexto.cuerpo,
              ),
            ],
            if (_fotosError > 0) ...[
              const SizedBox(height: 4),
              Text(
                '⚠️ $_fotosError '
                '${_fotosError == 1 ? 'foto falló' : 'fotos fallaron'} al subir — '
                'míralas en «Fotos», aquí abajo.',
                style: AppTexto.cuerpo,
              ),
            ],
            if (errorVigente != null) ...[
              const SizedBox(height: 4),
              Text(
                '⚠️ Ojo: $avisoPierna. '
                '$errorVigente',
                style: AppTexto.cuerpo,
              ),
            ],
          ],
        ),
      );
    }
    // 1.15: desglose por tipo de LO PENDIENTE, contado en la BD
    // (mismo conjunto que _totalPendientes). Antes se agrupaba
    // la lista reciente (30 ops de cualquier estado) y el
    // desglose no cuadraba con el encabezado.
    final porTipo = <String, int>{};
    for (final e in _desglosePendientes.entries) {
      final t = describirTipoOp(e.key);
      porTipo[t] = (porTipo[t] ?? 0) + e.value;
    }
    final desglose = porTipo.entries
        .map((e) => '${e.value} ${e.key.toLowerCase()}')
        .join(', ');
    final masAntigua = _masAntiguaIso != null
        ? parseFecha(_masAntiguaIso)
        : null;
    // E3 (mismo umbral que Mi nómina, 6 h): si la operación más
    // antigua lleva 6 horas o más sin subir, aviso ámbar aquí
    // también, que es donde el entrenador viene a subir.
    final horasSinSubir =
        horasSinSubirDesde(_masAntiguaIso, ahoraHabana());
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.alerta.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadio.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tienes $_totalPendientes operación'
            '${_totalPendientes == 1 ? '' : 'es'} por subir'
            '${masAntigua != null ? ' · la más antigua es de ${hace(masAntigua)}' : ''}.',
            style: AppTexto.cuerpo
                .copyWith(fontWeight: FontWeight.w600),
          ),
          // 1.29 (Oleada 6, FA-06): el desglose por autor
          // junto a la cifra global (solo dueño: en su
          // vista el total es el de TODAS las cuentas del
          // teléfono; el de un entrenador ya viene
          // recortado a lo suyo y no llevaría esta línea).
          if (_esDueno) ...[
            const SizedBox(height: 4),
            Text(
              // 1.35 (SP-03 + SP-11): desglose y total sobre
              // el mismo conjunto (mias + deOtros + sinAutor
              // == total) y las legadas sin firma en su clase.
              '$_totalPendientes pendientes · $_pendientesMias tuyas · '
              '$_pendientesDeOtros de otros'
              '${_pendientesSinAutor > 0 ? ' · $_pendientesSinAutor sin autor conocido' : ''}',
              style: AppTexto.secundario,
            ),
          ],
          if (desglose.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(desglose, style: AppTexto.secundario),
          ],
          if (horasSinSubir != null &&
              horasSinSubir >= kHorasAvisoSinSubir) ...[
            const SizedBox(height: 4),
            Text(
              '⚠ Llevas ${horasSinSubir.toStringAsFixed(0)} horas sin subir '
              'operaciones. Toca «Sincronizar ahora» cuando tengas conexión.',
              style: AppTexto.cuerpo.copyWith(
                  color: AppColores.alerta, fontWeight: FontWeight.w600),
            ),
          ],
          if (_retenidas > 0) ...[
            const SizedBox(height: 4),
            Text(
              '$_retenidas recién '
              '${_retenidas == 1 ? 'creada' : 'creadas'} en ventana de edición: '
              'suben solas en unos segundos, o toca «Subir ahora».',
              style: AppTexto.secundario,
            ),
          ],
          if (_fotosPendientes + _fotosSubiendo > 0) ...[
            const SizedBox(height: 4),
            Text(
              // 1.35 (SP-04/SP-05): «por subir» cuenta las
              // fotos pendientes Y las que están subiendo,
              // por foto (no por variante).
              'Además, ${_fotosPendientes + _fotosSubiendo} '
              '${(_fotosPendientes + _fotosSubiendo) == 1 ? 'foto' : 'fotos'} por subir.',
              style: AppTexto.secundario,
            ),
          ],
        ],
      ),
    );
  }

  /// Yunque B (YB-SYNC-01/02): la bajada de ESTE teléfono,
  /// en sencillo y con nombre. Si hay una tabla atascada
  /// (filas sin verificar), tarjeta roja con el paso de
  /// salida; si solo hay atraso, línea ámbar con la tabla
  /// más atrasada. Es la superficie que le faltaba al
  /// entrenador: Salud y Diagnóstico son del dueño, pero
  /// este atasco es suyo.
  Widget _tarjetaBajada() {
    final nombre = _atasco.nombre;
    if (nombre != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppEspacio.md),
        decoration: BoxDecoration(
          color: AppColores.error.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadio.md),
        ),
        child: Text(
          '⚠ La tabla «$nombre» quedó atascada al bajar: una '
          'fila no se pudo verificar'
          '${_atasco.seq != null ? ' (posición ${_atasco.seq})' : ''}'
          '${_atasco.filas > 0 ? ' · ${_atasco.filas} ${_atasco.filas == 1 ? 'fila' : 'filas'} con problema' : ''}. '
          'El resto de la app sigue funcionando y esa tabla se '
          'reintenta sola en cada ciclo. Toca «Sincronizar '
          'ahora» para reintentar ya; si el atasco sigue, dile '
          'este nombre al dueño para que lo revise.',
          style: AppTexto.cuerpo,
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.alerta.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadio.md),
      ),
      child: Text(
        'Faltan cambios por bajar. La tabla más atrasada es '
        '«$_tablaAtrasada».',
        style: AppTexto.cuerpo,
      ),
    );
  }

  /// v1.12.0 (E2): el toque actúa como forzado explícito — libera
  /// lo retenido y corre la sincronización normal.
  Future<void> _subirAhora() async {
    final n = _retenidas;
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Subir ahora',
      mensaje: 'Tienes $n operación'
          '${n == 1 ? '' : 'es'} recién creada'
          '${n == 1 ? '' : 's'} en ventana de edición. '
          '¿Subir todo ya?',
      aceptar: 'Subir todo ya',
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.liberarOpsRetenidas();
    await _cargar();
    if (mounted) _sincronizar();
  }

  /// v1.2.5 (D15): reintento manual de una bloqueada. La devuelve a
  /// 'pendiente' (limpia backoff); si vuelve a fallar, se reclasifica.
  Future<void> _reintentarBloqueada(String opUuid) async {
    // Ronda 17 M6-H2: candado anti-doble-toque.
    if (_opsReintentando.contains(opUuid)) return;
    _opsReintentando.add(opUuid);
    try {
      // UPDATE atómico y acotado: solo se reactiva si sigue en
      // estado reintentable; si el sync la aplicó mientras tanto,
      // no se resucita (n == 0).
      final d = await LocalDb.instance.db;
      final n = await d.rawUpdate(
          'UPDATE ops_queue SET estado=?, error=NULL, '
          'proximo_reintento=NULL, codigo_error=NULL, '
          'intentos=0 WHERE op_uuid=? AND estado IN '
          "('error','rechazada','necesita_revision')",
          ['pendiente', opUuid]);
      if (n == 0) {
        if (mounted) {
          mostrarSnack(context, 'La operación ya cambió de estado', significado: SignificadoChip.alerta);
        }
        await _cargar();
        return;
      }
      await _cargar();
      // v1.3.1 (E6): sincronizar al instante.
      unawaited(SyncEngine.instance.push());
      // v1.2.6 (Gemini): confirmación háptica en reintento manual.
      await vibrarConfirmacion();
      if (mounted) {
        mostrarSnack(context, 'Reintentando sincronización...', significado: SignificadoChip.info);
      }
    } finally {
      _opsReintentando.remove(opUuid);
    }
  }

  /// Muestra un diálogo con el resumen de la sincronización recién hecha.
  /// v1.4.0: el texto explica el resultado en lenguaje claro (todo al
  /// día, éxito parcial, error) en vez de solo mostrar los conteos.
  /// v1.8.0 (Frente 5): el resumen sale SOLO del [SyncResultado] de
  /// ESTA corrida. Antes se leía `detalle()` (contadores meta de
  /// corridas anteriores) y el diálogo salía siempre, incluso
  /// cuando el ciclo ni siquiera corrió (lock ocupado): de ahí el
  /// «Subidos 0 · Bajados 0 · Todo estaba al día» falso del reporte
  /// de campo 2026-10-23. Ahora: si no corrió, se dice en claro;
  /// si corrió y quedan pendientes, se dice cuántas y de qué tipo;
  /// «Todo estaba al día» solo con la cola vacía y sin error.
  Future<void> _mostrarResumen(SyncResultado? res) async {
    if (!mounted) return;
    // El ciclo NO corrió (u escapó una excepción): jamás éxito.
    if (res == null || !res.corrio) {
      final enCurso =
          res != null && res.motivoNoCorrio == SyncMotivoNoCorrio.enCurso;
      await showDialog(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo:
              enCurso ? 'Sincronización en curso' : 'No se pudo sincronizar',
          iconoTitulo: Icons.sync_rounded,
          contenido: Text(
            enCurso
                ? 'Ya hay una sincronización en curso en este '
                    'teléfono. Espera unos segundos y vuelve a '
                    'intentarlo.'
                : res == null
                    ? 'La sincronización no se pudo completar. '
                        'Inténtalo de nuevo.'
                    : 'No hay una sesión activa para sincronizar. '
                        'Entra de nuevo e inténtalo.',
            style: AppTexto.cuerpo.copyWith(height: 1.4),
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
      return;
    }
    final subidos = res.subidos;
    final bajados = res.bajados;
    final error = res.error;
    final reactivadas = res.reactivadas;
    await showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        // 1.24.2 (auditoría sync M3-H05): el título sale del
        // resumen veraz del resultado — antes decía siempre
        // «Sincronización completada» aunque la corrida
        // hubiera terminado con error o parcial.
        titulo: res.resumenCorto,
        iconoTitulo: error != null && error.isNotEmpty
            ? Icons.error_outline_rounded
            : Icons.sync_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _resumenFila(context, Icons.upload_rounded, 'Subidos', '$subidos'),
            const SizedBox(height: 8),
            _resumenFila(context, Icons.download_rounded, 'Bajados', '$bajados'),
            if (reactivadas > 0) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.refresh_rounded,
                      size: 16, color: AppColores.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Se reintentaron $reactivadas operaciones que '
                      'estaban atascadas.',
                      style: AppTexto.secundario,
                    ),
                  ),
                ],
              ),
            ],
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16,
                      color: AppColores.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error,
                      style: AppTexto.secundario.copyWith(color: AppColores.error),
                    ),
                  ),
                ],
              ),
            ],
            // v1.8.0 (Frente 5): si al cerrar el ciclo queda algo
            // en la cola, el resumen lo dice con su categoría —
            // prohibido «al día» con pendientes.
            // 1.36 (136-142): también con trabajo FUERA de la
            // cola (el textoPendientes ya lo incluye).
            if (res.pendientesRestantes > 0 ||
                res.trabajoFueraCola > 0) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.schedule_rounded,
                      size: 16, color: AppColores.alerta),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      res.textoPendientes,
                      style: AppTexto.secundario,
                    ),
                  ),
                ],
              ),
            ],
            // Yunque B (YB-TRA-01): si el conteo de la cola
            // falló, el resumen lo dice — jamás «al día».
            if (res.conteoIndeterminado &&
                (error == null || error.isEmpty)) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: AppColores.alerta),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      res.textoPendientes,
                      style: AppTexto.secundario,
                    ),
                  ),
                ],
              ),
            ],
            if (subidos == 0 &&
                bajados == 0 &&
                res.pendientesRestantes == 0 &&
                res.trabajoFueraCola == 0 &&
                !res.conteoIndeterminado &&
                (error == null || error.isEmpty))
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.md),
                child: Text(
                  'Todo estaba al día: no había nada nuevo que subir '
                  'ni bajar.',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(
                          context)),
                ),
              ),
            if (subidos == 0 &&
                bajados == 0 &&
                error != null &&
                error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.md),
                child: Text(
                  'No se pudo sincronizar. Revisa tu conexión e '
                  'inténtalo de nuevo.',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(
                          context)),
                ),
              ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _resumenFila(
      BuildContext ctx, IconData icono, String etiqueta, String valor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icono,
                size: 20,
                color:
                    Theme.of(ctx).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(etiqueta,
                style: AppTexto.titulo),
          ],
        ),
        Text(
          valor,
          style: AppTexto.titulo.copyWith(color: AppColores.naranja),
        ),
      ],
    );
  }

  Future<void> _cancelar(String uuid, String tipo) async {
    // Ronda 17 M6-H1: un no-dueño no cancela ops ajenas.
    if (!_esDueno) {
      try {
        final db = await LocalDb.instance.db;
        final rows = await db.query('ops_queue',
            columns: ['payload'],
            where: 'op_uuid=?', whereArgs: [uuid], limit: 1);
        if (rows.isNotEmpty) {
          final op = {'payload': rows.first['payload']};
          if (!esOpMia(op,
              miActor: _miActor, miTelegramId: _miTelegramId)) {
            if (mounted) {
              mostrarSnack(context, 'Solo puedes cancelar tus propias operaciones', significado: SignificadoChip.alerta);
            }
            return;
          }
        } else {
          // Yunque de cambios 1.31 (M3): la op no está en la
          // cola (ya salió o se descartó): no hay nada que
          // cancelar. Arropar «no encontrada» con la guarda
          // de autoría sería fail-closed sobre el caso MÁS
          // común tras navegar un rato — cancelOp devuelve
          // false y el texto lo declara, igual que antes.
          // Distinto de una op sin firma: esas SÍ son mías
          // por definición de esOpMia (Ronda 17: «sin firma =
          // nació en este teléfono») y SÍ se pueden cancelar.
          return;
        }
      } catch (e) {
        // Yunque de cambios 1.31 (M3): el catch ERA mudo y
        // fail-open en apariencia; el hueco real es que el
        // fallo de la guarda no quedaba en ningún registro.
        // Se registra sin cambiar el comportamiento: si la
        // lectura falló por un parpadeo transitorio, el DELETE
        // con guarda de estado sigue siendo la barrera que
        // decide; cerrar el paso por defecto dejaría al
        // entrenador sin poder descartar NI sus ops sin firma
        // cuando la BD parpadea.
        AppLog.error('sync', 'cancelar_autoria_fallo', d: '$e');
      }
    }
    // Ronda 17 M6-H2: la consulta anterior es un hueco async;
    // sin mounted, el diálogo usaría un context muerto.
    if (!mounted) return;
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cancelar operación',
      mensaje:
          '¿Cancelar esta operación (${_tipo(tipo)})? No se subirá al sistema.',
      aceptar: 'Sí, cancelar',
      peligro: true,
      icono: Icons.cancel_rounded,
    );
    if (ok != true) return;
    final borrada = await LocalDb.instance.cancelOp(uuid);
    // Yunque de cambios 1.31 (M3): el descarte deja rastro en
    // la bitácora (antes el DELETE era silencioso: ni tipo ni
    // uuid quedaban en ningún registro).
    AppLog.info('sync', 'op_cancelada_local',
        d: 'uuid=$uuid tipo=$tipo borrada=$borrada');
    if (!mounted) return;
    mostrarSnack(context, borrada
            ? 'Operación cancelada'
            : 'Ya no se puede cancelar (ya salió del teléfono)');
    _cargar();
  }

  /// Icono y color por estado de operación (v1.1: sin emojis).
  IconData _iconoEstado(String estado) {
    switch (estado) {
      case 'aplicada':
        return Icons.check_circle_rounded;
      case 'enviada':
        // v1.2.9+46: ámbar = confirmación pendiente.
        return Icons.sync_problem_rounded;
      case 'rechazada':
        return Icons.block_rounded;
      case 'error':
        return Icons.warning_amber_rounded;
      default:
        return Icons.schedule_rounded;
    }
  }

  Color _colorEstado(String estado) {
    switch (estado) {
      case 'aplicada':
        return AppColores.exito;
      case 'enviada':
        // v1.2.9+46: ámbar = confirmación pendiente.
        return AppColores.alerta;
      case 'rechazada':
      case 'error':
        return AppColores.error;
      default:
        return AppColores.naranja;
    }
  }

  // La etiqueta legible del estado vive en la función
  // compartida etiquetaEstadoOp (la copia local de v1.2.9+46
  // quedó sin uso y se retiró en la 1.25 T123/F6-05).

  String _hora(DateTime? d) => horaCortaHabana(d);

  /// v1.2.9+46 (Gemini): delega al mapa centralizado.
  String _tipo(String t) => describirTipoOp(t);

  /// v1.2.9+46: tarjeta expandible con gestión completa de fotos.
  /// Muestra cada foto pendiente: miniatura, entidad, cuándo se solicitó,
  /// intentos, error exacto, y botones para reintentar una o todas.
  Widget _tarjetaFotos(BuildContext context) {
    final total = _fotosPendientes + _fotosSubiendo + _fotosError;
    final hayError = _fotosError > 0;
    final color = hayError
        ? AppColores.error
        : (total > 0 ? AppColores.alerta : AppColores.exito);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: total > 0
                ? () => setState(
                    () => _fotosExpandido = !_fotosExpandido)
                : null,
            borderRadius: BorderRadius.circular(AppRadio.sm),
            child: Row(
              children: [
                Icon(Icons.photo_library_rounded,
                    size: 24, color: AppColores.textoSecundario(context)),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Fotos', style: AppTexto.subtitulo),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: AppEspacio.xs),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppRadio.md),
                  ),
                  child: Text(
                    // 1.35 (SP-06): la pastilla también cuenta
                    // las fotos CON ERROR (antes una foto
                    // fallida desaparecía del titular y solo
                    // salía en una línea con la tarjeta
                    // plegada).
                    total == 0
                        ? 'Al día'
                        : '$_fotosPendientes pendientes · '
                            '$_fotosSubiendo subiendo'
                            '${hayError ? ' · $_fotosError con error' : ''}',
                    style: AppTexto.metadato.copyWith(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                if (total > 0)
                  Icon(
                    _fotosExpandido
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: AppColores.textoSecundario(context),
                  ),
              ],
            ),
          ),
          if (_fotosExpandido && _fotosGrupos.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            // 1.35 (CAMPO-9): una fila por FOTO (grupo de
            // variantes), no una por variante.
            for (final g in (_fotosMostrarTodas
                ? _fotosGrupos
                : _fotosGrupos.take(12).toList()))
              _filaFotoGrupo(context, g),
            if (!_fotosMostrarTodas && _fotosGrupos.length > 12)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      setState(() => _fotosMostrarTodas = true),
                  child: Text(
                      'Ver las ${_fotosGrupos.length - 12} restantes'),
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Reintentar todas'),
                onPressed: _reintentarTodasFotos,
              ),
            ),
          ],
          if (hayError && !_fotosExpandido) ...[
            const SizedBox(height: 8),
            Text(
              '$_fotosError ${_fotosError == 1 ? 'foto falló' : 'fotos fallaron'} — toca para ver detalle',
              style: AppTexto.secundario.copyWith(color: AppColores.error),
            ),
          ],
        ],
      ),
    );
  }

  /// H-12 (1.20): tarjeta de fotos de incidencias que agotaron
  /// sus intentos. Distingue las recuperables (el archivo sigue
  /// en el teléfono) de las perdidas (sin archivo: ningún
  /// reintento las puede subir desde aquí).
  Widget _tarjetaFotosIncidencias(BuildContext context) {
    final total = _fotosIncError.length;
    final recuperables =
        _fotosIncError.where((f) => f['recuperable'] == true).length;
    final perdidas = total - recuperables;
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.report_problem_rounded,
                  size: 24, color: AppColores.error),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Fotos de incidencias sin subir',
                    style: AppTexto.subtitulo),
              ),
              ContadorBadge(numero: total),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            recuperables > 0
                ? '$recuperables ${recuperables == 1 ? 'foto agotó' : 'fotos agotaron'} '
                    'sus intentos de subida y ${recuperables == 1 ? 'puede' : 'pueden'} '
                    'reintentarse.'
                : 'Ninguna se puede reintentar desde este teléfono.',
            style: AppTexto.secundario,
          ),
          if (perdidas > 0) ...[
            const SizedBox(height: 4),
            Text(
              '$perdidas ${perdidas == 1 ? 'foto ya no tiene' : 'fotos ya no tienen'} '
                  'el archivo en este teléfono: no ${perdidas == 1 ? 'es recuperable' : 'son recuperables'}.',
              style: AppTexto.secundario
                  .copyWith(color: AppColores.error),
            ),
          ],
          if (recuperables > 0) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Reintentar'),
                onPressed: _reintentandoFotosInc
                    ? null
                    : _reintentarFotosIncidencias,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 1.35 (CAMPO-9): fila de UNA foto (su grupo de
  /// variantes): miniatura, identificación por su cliente,
  /// estado conjunto, cuándo se pidió y las acciones sobre
  /// la foto entera. Las variantes viven en el detalle
  /// expandible de la fila.
  Widget _filaFotoGrupo(BuildContext context, GrupoFotoCola g) {
    final estado = g.estadoConjunto;
    final ruta = g.rutaMiniatura;
    final creadoEn = DateTime.tryParse('${g.creadoEn}');
    // Identificación por la entidad: nombre del espejo si
    // se conoce; si no, la etiqueta por id de siempre.
    final String titulo;
    final cid = g.clienteId;
    final sid = g.suplementoId;
    if (cid != null) {
      final n = _nombresFotos['c$cid'];
      titulo = n != null ? 'Foto de $n' : 'Cliente $cid';
    } else if (sid != null) {
      final n = _nombresFotos['s$sid'];
      titulo = n != null ? 'Suplemento $n' : 'Suplemento $sid';
    } else {
      titulo = 'Foto sin asignar';
    }
    // 1.35 (SP-09): si lo único que queda vivo de la foto
    // es la variante grande en su espera QoS, la etiqueta
    // dice ESA verdad (espera a que la cola esté
    // tranquila), no un problema de red.
    final soloEsperaLaOriginal = estado == 'pendiente' &&
        g.originalEsperaQos &&
        g.variantes.every((v) => v['tipo'] == 'original');
    final colorEstado = estado == 'error'
        ? AppColores.error
        : estado == 'subiendo'
            ? AppColores.info
            : AppColores.alerta;
    // Pasada (Argón): el TEXTO del chip (metadato, ~11 px)
    // va en el token resuelto por tema — infoTexto y sus
    // pares — no en el color de relleno.
    final textoEstado = estado == 'error'
        ? AppColores.errorTexto(context)
        : estado == 'subiendo'
            ? AppColores.infoTexto(context)
            : AppColores.alertaTexto(context);
    // El error que se enseña es el de la primera variante
    // en error, TRADUCIDO por clase (SP-08): jamás el
    // texto crudo de la excepción.
    String? errorVisible;
    for (final v in g.variantes) {
      if (v['estado'] == 'error') {
        errorVisible = fraseErrorFoto(v['ultimo_error'] as String?);
        break;
      }
    }
    final intentos = g.variantes.fold<int>(
        0, (m, v) => (v['intentos'] as num?)?.toInt() != null &&
                (v['intentos'] as num).toInt() > m
            ? (v['intentos'] as num).toInt()
            : m);
    final expandida = _fotosGruposExpandidos.contains(g.opUuid);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Miniatura (la variante de pantalla si está).
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadio.sm),
                child: ruta != null
                    ? Image.file(
                        File(ruta),
                        width: 48,
                        height: 48,
                        // 1.32 (S-G3/Paso 0): decodificación
                        // acotada al triple del destino.
                        cacheWidth: 144,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 48,
                          height: 48,
                          color: AppColores.fondo(context),
                          child: const Icon(Icons.broken_image_rounded, size: 24),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        color: AppColores.fondo(context),
                        child: const Icon(Icons.image_rounded, size: 24),
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            titulo,
                            style: AppTexto.secundario.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppEspacio.sm, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorEstado.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(AppRadio.md),
                            ),
                            child: Text(
                              estado == 'error'
                                  ? 'Falló'
                                  : estado == 'subiendo'
                                      ? 'Subiendo'
                                      : soloEsperaLaOriginal
                                          ? 'En espera'
                                          : 'Pendiente',
                              style: AppTexto.metadato.copyWith(color: textoEstado, fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Solicitada: ${_hora(creadoEn)} · '
                      '${g.variantes.length} ${g.variantes.length == 1 ? 'versión' : 'versiones'}'
                      '${intentos > 0 ? ' · $intentos ${intentos == 1 ? 'intento' : 'intentos'}' : ''}',
                      style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                    ),
                    if (soloEsperaLaOriginal) ...[
                      const SizedBox(height: 2),
                      Text(
                        // SP-09: la verdad de la espera QoS y
                        // cuándo sale (la puerta de la casa:
                        // cola tranquila unos minutos o la
                        // holgura de 15 min).
                        'La foto grande espera a que la cola '
                        'esté tranquila; sale sola en unos '
                        'minutos, o súbela ahora.',
                        style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                      ),
                    ],
                    if (errorVisible != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        errorVisible,
                        style: AppTexto.metadato.copyWith(color: AppColores.error),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              // 1.24 Bloque 4 (H-01): mientras alguna variante
              // está 'subiendo', el worker la tiene tomada:
              // sin botones de acción, solo el indicador.
              if (g.algunaSubiendo)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else ...[
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  tooltip:
                      soloEsperaLaOriginal ? 'Subir ahora' : 'Reintentar',
                  onPressed: () => _reintentarFotoGrupo(g),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: 'Descartar',
                  onPressed: () => _cancelarFotoGrupo(g),
                ),
              ],
              IconButton(
                icon: Icon(
                    expandida
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20),
                tooltip: expandida ? 'Ocultar versiones' : 'Ver versiones',
                onPressed: () => setState(() {
                  if (expandida) {
                    _fotosGruposExpandidos.remove(g.opUuid);
                  } else {
                    _fotosGruposExpandidos.add(g.opUuid);
                  }
                }),
              ),
            ],
          ),
          if (expandida)
            Padding(
              padding: const EdgeInsets.only(left: 56, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final v in g.variantes) _filaVarianteFoto(context, v),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 1.35 (CAMPO-9): una variante dentro del detalle de su
  /// foto: nombre de la versión, su estado y — si falló —
  /// el error traducido por clase (SP-08), nunca el crudo.
  Widget _filaVarianteFoto(BuildContext context, Map<String, dynamic> v) {
    final tipo = '${v['tipo']}';
    final estado = '${v['estado']}';
    final nombre = switch (tipo) {
      'thumb' => 'Miniatura',
      'display' => 'De pantalla',
      'original' => 'Original (grande)',
      _ => tipo,
    };
    // SP-09: la original pendiente sin forzar está en la
    // espera QoS: se dice así, no como fallo de red.
    final esperaQos = estado == 'pendiente' &&
        tipo == 'original' &&
        ((v['forzar_qos'] as num?)?.toInt() ?? 0) != 1;
    final textoEstado = estado == 'error'
        ? fraseErrorFoto(v['ultimo_error'] as String?)
        : estado == 'subiendo'
            ? 'Subiendo'
            : esperaQos
                ? 'Espera a que la cola esté tranquila'
                : 'Pendiente';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            estado == 'error'
                ? Icons.error_outline_rounded
                : estado == 'subiendo'
                    ? Icons.cloud_upload_rounded
                    : Icons.schedule_rounded,
            size: 16,
            color: estado == 'error'
                ? AppColores.error
                : AppColores.textoSecundario(context),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$nombre · $textoEstado',
              style: AppTexto.metadato.copyWith(
                color: estado == 'error'
                    ? AppColores.error
                    : AppColores.textoSecundario(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Muestra el detalle de las fotos con error permanente.
  Future<void> _verFallosFotos(BuildContext context) async {
    List<Map<String, dynamic>> fallos = [];
    try {
      final db = await LocalDb.instance.db;
      fallos = await db.query(
        'fotos_cola',
        columns: ['id', 'tipo', 'intentos', 'ultimo_error', 'actualizado_en'],
        where: "estado = 'error'",
        orderBy: 'actualizado_en DESC',
        limit: 20,
      );
    } catch (_) {}
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Fotos con error',
        iconoTitulo: Icons.error_outline_rounded,
        contenido: fallos.isEmpty
            ? const Text('No hay fotos con error.')
            // UI136-11: hasta 20 filas ruedan en una zona
            // acotada — la Column sin scroll desbordaba el
            // diálogo en pantallas bajas.
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final f in fallos)
                        ListTile(
                      dense: true,
                      leading: const Icon(Icons.photo_rounded,
                          color: AppColores.error),
                      title: Text(
                          'Foto ${f['id']} (${f['tipo']}) — '
                          '${f['intentos']} intentos'),
                          subtitle: Text(
                            // 1.35 (SP-08): también aquí se
                            // pinta la frase por clase, no el
                            // crudo.
                            fraseErrorFoto(f['ultimo_error'] as String?),
                            style: AppTexto.metadato,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// Muestra el detalle completo de una operación al tocarla.
  Future<void> _reenviar(Map<String, dynamic> op) async {
    final uuid = op['op_uuid'] as String;
    // Ronda 17 M6-H1: un no-dueño no reenvía ops ajenas.
    if (!_esDueno &&
        !esOpMia(op, miActor: _miActor, miTelegramId: _miTelegramId)) {
      if (mounted) {
        mostrarSnack(context, 'Solo puedes reenviar tus propias operaciones', significado: SignificadoChip.alerta);
      }
      return;
    }
    // Ronda 17 M6-H2: candado anti-doble-toque.
    if (_opsReintentando.contains(uuid)) return;
    _opsReintentando.add(uuid);
    try {
      // v1.3.1 (E6): limpiar campos de error y disparar sync inmediatamente.
      final db = await LocalDb.instance.db;
      // UPDATE acotado: si la op cambió de estado mientras
      // tanto (p. ej. la aplicó el sync), no se resucita.
      final n = await db.update(
        'ops_queue',
        {
          'estado': 'pendiente',
          'error': null,
          'intentos': 0,
          'proximo_reintento': null,
          'codigo_error': null,
        },
        where: "op_uuid=? AND estado IN ('error','rechazada','necesita_revision')",
        whereArgs: [uuid],
      );
      if (n == 0) {
        if (mounted) {
          mostrarSnack(context, 'La operación ya cambió de estado', significado: SignificadoChip.alerta);
        }
        await _cargar();
        return;
      }
      unawaited(SyncEngine.instance.push());
      if (mounted) {
        mostrarSnack(context, 'Reenviando operación...', significado: SignificadoChip.info);
        _cargar();
      }
    } finally {
      _opsReintentando.remove(uuid);
    }
  }

  void _verDetalle(Map<String, dynamic> op) async {
    final tipo = tituloDeOp(op);
    final estado = '${op['estado']}';
    // SL-8 (G08-6): la fecha del detalle en hora de La
    // Habana y legible (fechaAbsoluta de la casa); antes
    // era el ISO cortado a 16 caracteres EN UTC: la hora
    // del servidor pintada como si fuera la local.
    final fecha = fechaAbsoluta(parseFecha('${op['creada_ts'] ?? ''}'));
    final error = '${op['error'] ?? ''}';
    // 1.28 (M1-C5): UNA sola traducción en lenguaje llano
    // (explicacionOp), la misma que enseñan la fila y el
    // bloque de bloqueadas. Sustituye la traducción
    // artesanal de 3 casos que vivía aquí: el texto técnico
    // crudo ya no llega al diálogo.
    final expl = explicacionOp(
        estado: estado,
        error: error,
        codigoError: '${op['codigo_error'] ?? ''}',
        hayInternet: _hayInternet);
    final mostrarExpl = error.isNotEmpty ||
        estado == 'rechazada' ||
        estado == 'necesita_revision';
    // Detalles del payload según tipo (v1.0.11)
    // D-17 (1.21): _verDetalle es fire-and-forget desde el
    // onTap; un fallo resolviendo detalles dejaba el toque sin
    // respuesta alguna. Ahora se reporta y se sigue sin detalle.
    List<String> detalles;
    try {
      detalles = await _detallesOp(op);
    } catch (e) {
      AppLog.error('cola', 'detalle_op_fallo', d: '$e');
      detalles = const [];
      if (mounted) {
        mostrarSnack(context, 'No se pudo cargar el detalle',
            significado: SignificadoChip.error);
      }
    }
    // 1.36 (136-142, C-3): el gesto de reconocer el rechazo
    // EXPLICADO — solo para una 'rechazada' que trae motivo
    // del servidor y aún no fue reconocida. Una en
    // 'necesita_revision' NO lo ofrece: espera decisión real.
    final motivoServidor = LocalDb.motivoServidorDeOp(op);
    var yaReconocida = false;
    if (estado == 'rechazada') {
      try {
        yaReconocida = (await LocalDb.instance
                .opsRechazadasReconocidas())
            .contains('${op['op_uuid']}');
      } catch (_) {}
    }
    final puedeReconocer = estado == 'rechazada' &&
        motivoServidor != null &&
        !yaReconocida;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: tipo,
        iconoTitulo: _iconoEstado(estado),
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calendar_today_rounded,
                    size: 14,
                    color:
                        AppColores.textoSecundario(context)),
                const SizedBox(width: 8),
                Text(fecha,
                    style:
                        AppTexto.secundario),
              ],
            ),
            const SizedBox(height: 8),
            // F6-05: el estado traducido (la lista ya usa el
            // chip; el diálogo enseñaba el código crudo).
            Text('Estado: ${etiquetaEstadoOp(estado)}'),
            for (final d in detalles) ...[
              const SizedBox(height: 4),
              Text(d),
            ],
            if (mostrarExpl) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16,
                      color: AppColores.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(expl.motivo,
                        style: const TextStyle(
                            color:
                                AppColores.error)),
                  ),
                ],
              ),
              if (expl.accion.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Qué hacer: ${expl.accion}',
                    style: AppTexto.secundario),
              ],
            ],
            if (yaReconocida) ...[
              const SizedBox(height: 8),
              Text(
                'Rechazo ya reconocido: quedó en la bitácora '
                'y no cuenta en el aviso de sincronización.',
                style: AppTexto.secundario,
              ),
            ],
          ],
        ),
        acciones: [
          if (puedeReconocer)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _reconocerRechazada(op);
              },
              child: const Text('Reconocer rechazo'),
            ),
          if (estado == 'rechazada') ...[
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _reenviar(op);
              },
              child: const Text('Reenviar',
                  style:
                      TextStyle(color: AppColores.naranja)),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// 1.36 (136-142, C-3): reconoce el rechazo explicado de
  /// una op: queda en bitácora y sale de la cuenta del aviso
  /// (LocalDb.marcarOpRechazadaReconocida). La op no se
  /// borra ni cambia de estado: solo deja de contar como
  /// trabajo pendiente de decisión.
  Future<void> _reconocerRechazada(Map<String, dynamic> op) async {
    final ok = await LocalDb.instance
        .marcarOpRechazadaReconocida('${op['op_uuid']}');
    if (!mounted) return;
    mostrarSnack(
      context,
      ok
          ? 'Rechazo reconocido: queda en la bitácora y sale '
              'de la cuenta del aviso'
          : 'No se pudo reconocer: la operación no está '
              'rechazada con motivo del servidor',
      significado:
          ok ? SignificadoChip.exito : SignificadoChip.alerta,
    );
    if (ok) _cargar();
  }

  /// Detalles legibles del payload segun el tipo de operacion (v1.0.11).
  /// v1.3.4: delega en la funcion top-level [detallesDeOp].
  Future<List<String>> _detallesOp(Map<String, dynamic> op) =>
      detallesDeOp(op);

  @override
  Widget build(BuildContext context) {
    // Ronda 17 M6-H3 + Yunque 3 (K7-1): el encabezado usa los
    // totales de BD (_totalPendientes y los conteos de
    // LocalDb.conteosHeroeCola en _heroErrorOps/_heroEnLimbo),
    // no la lista visible (limit 30). Antes totalError y
    // enLimbo iteraban _ops: una op rechazada/enviada empujada
    // fuera de la ventana por 30 ops más recientes dejaba de
    // contar y el héroe decía «Todo subió» con la op fallida
    // viva en la BD.
    // 1.36 (136-142): el héroe suma TAMBIÉN lo que vive
    // fuera de ops_queue y no entraba en ningún total:
    // comprobantes en error, fotos de incidencias en error
    // (al error) y comprobantes pendientes (al pendiente).
    // Las rechazadas reconocidas ya salieron de
    // _heroErrorOps en LocalDb.conteosHeroeCola.
    final totalError =
        _heroErrorOps + _fotosError + _compError.length + _fotosIncError.length;
    // v1.2.9+46 (Gemini): 'enviada' = confirmación pendiente (ámbar).
    final enLimbo = _heroEnLimbo;
    final totalPendiente = _totalPendientes +
        _fotosPendientes +
        _fotosSubiendo +
        _compPendientes;
    final errorReciente = _det.error;
    // v1.0.14: tres estados claros en vez de binario ok/error
    // v1.1: icono Material en vez de emoji
    // v1.2.9+46: cinco estados (error, limbo, error reciente, pendiente, ok)
    final String estadoSync;
    // 1.30 (Oleada D2, UI130-07): el héroe ya no es un
    // gradiente semántico: color del estado (franja e
    // icono), su fondo *Fondo y la cifra protagonista
    // del estado (null cuando no hay conteo que decir).
    final Color colorEstado;
    final Color fondoEstado;
    final int? cifraHeroe;
    final IconData iconoEstado;
    final String titulo;
    final String subtitulo;
    if (totalError > 0) {
      estadoSync = 'error';
      colorEstado = AppColores.error;
      fondoEstado = AppColores.errorFondo;
      cifraHeroe = totalError;
      iconoEstado = Icons.warning_amber_rounded;
      titulo = 'Atención requerida';
      subtitulo = totalError == 1
          ? '1 elemento falló y necesita tu revisión'
          : '$totalError elementos fallaron y necesitan tu revisión';
    } else if (enLimbo > 0) {
      estadoSync = 'limbo';
      colorEstado = AppColores.alerta;
      fondoEstado = AppColores.avisoFondo;
      cifraHeroe = enLimbo;
      iconoEstado = Icons.sync_problem_rounded;
      titulo = 'Confirmación pendiente';
      subtitulo = enLimbo == 1
          ? '1 operación se envió pero no se confirmó'
          : '$enLimbo operaciones se enviaron pero no se confirmaron';
    } else if (errorReciente != null && errorReciente.isNotEmpty) {
      estadoSync = 'error';
      colorEstado = AppColores.error;
      fondoEstado = AppColores.errorFondo;
      cifraHeroe = null;
      iconoEstado = Icons.warning_amber_rounded;
      titulo = 'Falló la última sincronización';
      // v1.2.9+46: mensaje en lenguaje natural, no genérico.
      // 1.33: el texto sale de _textoErrorVisible (la
      // composición única de la pantalla): con el registro
      // 1.33 ya no se re-traduce un mensaje — se compone
      // desde el código, con su pierna, sus tablas y su
      // hora, y el matiz A4-D2 aplicado dentro.
      subtitulo = _textoErrorVisible!;
    } else if (totalPendiente > 0) {
      estadoSync = 'pendiente';
      colorEstado = AppColores.alerta;
      fondoEstado = AppColores.avisoFondo;
      cifraHeroe = totalPendiente;
      iconoEstado = Icons.schedule_rounded;
      titulo = 'Pendiente de sincronizar';
      subtitulo = totalPendiente == 1
          ? '1 elemento esperando conexión'
          : '$totalPendiente elementos esperando conexión';
    } else if (_det.ultimaSyncOk == null) {
      // 1.32 (O2F2S, adjudicación de Argón F-3): el verde
      // «Todo al día» EXIGE un sello completo real
      // (last_sync_ok). Un teléfono que nunca completó una
      // corrida — sin error y sin pendientes, como el de la
      // incidencia Duany — no pinta verde por defecto:
      // pinta «sin confirmar», que es la verdad.
      estadoSync = 'sin_confirmar';
      colorEstado = AppColores.alerta;
      fondoEstado = AppColores.avisoFondo;
      cifraHeroe = null;
      iconoEstado = Icons.help_outline_rounded;
      titulo = 'Sin confirmar';
      subtitulo = 'Aún no se ha sincronizado en este teléfono';
    } else {
      estadoSync = 'ok';
      colorEstado = AppColores.exito;
      fondoEstado = AppColores.exitoFondo;
      cifraHeroe = null;
      iconoEstado = Icons.check_circle_rounded;
      titulo = 'Sincronizado';
      subtitulo = 'Todo al día';
    }
    return Scaffold(
      appBar: appBarIron(context, 'Sincronización'),
      body: RefrescoIron(
        // P-7: regla de Jc (refrescoGeneralIron) — la
        // pantalla ya tiene sus botones de sincronizar;
        // el gesto sigue la misma regla que el resto.
        onRefresh: () => refrescoGeneralIron(releer: _cargar),
        child: ListView(
          padding: const EdgeInsets.all(AppEspacio.lg),
          children: [
            // Cabecera de estado visual (v1.0.14: tres estados)
            // 1.30 (Oleada D2, UI130-07): nivel 3 del
            // lenguaje único de sync — héroe NEUTRO:
            // superficie de tarjeta con borde, el color
            // del estado en una franja lateral de 4 dp y
            // en el icono sobre su fondo *Fondo; la cifra
            // del estado en grande y los textos en los
            // colores de siempre. Las acciones son los
            // botones de debajo (Sincronizar ahora / Subir
            // ahora), que no cambian.
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Theme.of(context).dividerColor),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(width: 4, color: colorEstado),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(
                                    AppEspacio.md),
                                decoration: BoxDecoration(
                                  color: fondoEstado,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  iconoEstado,
                                  size: 34,
                                  color: Colors.white,
                                ),
                              ),
                              if (cifraHeroe != null) ...[
                                const SizedBox(height: 8),
                                Text('$cifraHeroe',
                                    style: AppTexto.display),
                              ],
                              const SizedBox(height: 8),
                              Text(
                                titulo,
                                style: AppTexto.displayPequeno,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                subtitulo,
                                style: AppTexto.cuerpo.copyWith(
                                    color: AppColores.textoSecundario(
                                        context)),
                                textAlign: TextAlign.center,
                              ),
                              // v1.0.14: guía contextual según el estado
                              if (estadoSync == 'pendiente') ...[
                                const SizedBox(height: 12),
                                Text(
                                  'Se subirán automáticamente cuando haya conexión. '
                                  'Puedes seguir trabajando sin internet.',
                                  style: AppTexto.metadato.copyWith(
                                      color: AppColores.textoSecundario(
                                          context)),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                              if (estadoSync == 'error') ...[
                                const SizedBox(height: 12),
                                Text(
                                  'Revisa las operaciones marcadas abajo. '
                                  'Puedes reintentarlas o cancelarlas.',
                                  style: AppTexto.metadato.copyWith(
                                      color: AppColores.textoSecundario(
                                          context)),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                              if (_sincronizando) ...[
                                const SizedBox(height: 12),
                                LinearProgressIndicator(
                                  value: (_progresoSync?.actual !=
                                              null &&
                                          _progresoSync?.total !=
                                              null &&
                                          _progresoSync!.total! > 0)
                                      ? _progresoSync!.actual! /
                                          _progresoSync!.total!
                                      : null,
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(
                                          colorEstado),
                                  backgroundColor: colorEstado
                                      .withValues(alpha: 0.15),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Botón sincronizar
            BotonPrimario(
              texto:
                  _sincronizando ? 'Sincronizando…' : 'Sincronizar ahora',
              icono: Icons.sync_rounded,
              onPressed: _sincronizando ? null : _sincronizar,
            ),
            // v1.12.0 (E2): «Subir ahora» libera lo retenido por
            // retenerHasta. Solo se muestra si hay retenidas; el
            // toque pide confirmación explícita y luego corre la
            // sincronización normal (cuyo resumen dice lo que
            // realmente subió, nunca «Subida completada» en
            // silencio).
            if (_retenidas > 0 && !_sincronizando) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.rocket_launch_rounded,
                      size: 18),
                  label: Text('Subir ahora ($_retenidas retenidas)'),
                  onPressed: _subirAhora,
                ),
              ),
            ],
            // v1.4.0: progreso visible bajo el botón (el mensaje va
            // fuera del botón porque dentro se truncaría).
            if (_sincronizando) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              if (_progresoSync != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _progresoSync!.mensaje,
                    textAlign: TextAlign.center,
                    style: AppTexto.secundario.copyWith(
                        color:
                            AppColores.textoSecundario(context)),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            // 1.32 (O2F2S, Pieza 2): puerta al Centro de
            // Sincronización (historial de corridas, cobertura
            // por tabla y avisos de vigilancia, desde el
            // diario M1). La píldora del Mostrador sigue
            // abriendo ESTA pantalla; el Centro cuelga de aquí.
            Tarjeta(
              onTap: () => Navigator.of(context).push(RutaIron(
                  builder: (_) => const CentroSyncScreen())),
              child: Row(
                children: [
                  // Pasada (Argón): la puerta al Centro va
                  // con el badge de módulo de la casa
                  // (naranja), como las demás puertas.
                  IconoModuloBadge.naranja(Icons.radar_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Centro de sincronización',
                            style: AppTexto.subtitulo),
                        Text(
                          'Historial de corridas, qué hay en el '
                          'teléfono por tabla y avisos',
                          style: AppTexto.minuscula.copyWith(
                              color: AppColores.textoSecundario(
                                  context)),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: AppColores.textoSecundario(context)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // G08-4: la sección de la lista y el pliegue de
            // auxiliares son UN solo hijo del ListView (una
            // Column): el ListView perezoso construye el
            // hijo entero al entrar en su margen, así el
            // control de pliegue existe desde el primer
            // frame aunque la lista venga vacía.
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            const Text(
              'Operaciones recientes',
              style: AppTexto.titulo,
            ),
            const SizedBox(height: 8),
            if (_ops.isEmpty)
              const EstadoVacio(
                ilustracion: 'assets/vacio_cable.webp',
                icono: Icons.inbox_rounded,
                titulo: 'Sin operaciones todavía',
                subtitulo:
                    'Las operaciones pendientes aparecerán aquí.',
              )
            else
              ..._ops.map((op) {
                final estado = '${op['estado']}';
                final esPendiente = estado == 'pendiente';
                final esError = estado == 'error';
                // v1.3.1 (E6): rechazada y necesita_revision también
                // son reintentables/cancelables.
                final esBloqueada =
                    estado == 'rechazada' || estado == 'necesita_revision';
                final cancelable = esPendiente || esError || esBloqueada;
                // v1.0.14: tiempo relativo para saber hace cuánto espera
                final creada = '${op['creada_ts'] ?? ''}';
                final hace = tiempoRelativo(creada);
                return Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppEspacio.sm),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColores.superficie(context),
                      borderRadius:
                          BorderRadius.circular(AppRadio.lg),
                      border: Border.all(
                        color: esError
                            ? AppColores.error
                                .withValues(alpha: 0.5)
                            : esPendiente
                                ? AppColores.naranja
                                    .withValues(alpha: 0.5)
                                : AppColores.exito
                                    .withValues(alpha: 0.4),
                        width: 1,
                      ),
                      // 1.29 D-18: valor exacto de la sombra de
                      // tarjeta de la clase deprecada, en el sitio.
                      boxShadow: [
                        BoxShadow(
                          color: (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.black
                                  : Colors.grey)
                              .withValues(
                                  alpha: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? 0.4
                                      : 0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    // 1.29 (Oleada 6): Material propio y
                    // transparente — el ListTile quedaba bajo
                    // el DecoratedBox del Container sin un
                    // Material intermedio: su tinta no se
                    // pintaba y el chequeo del framework lo
                    // marca como error.
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                      leading: Icon(_iconoEstado(estado),
                          size: 26,
                          color: _colorEstado(estado)),
                    title: Text(
                        _titulosOp['${op['op_uuid']}'] ?? tituloDeOp(op)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hace == 'Sin accesos registrados'
                              ? creada.substring(0,
                                      creada.length > 16 ? 16 : creada.length)
                                  .replaceAll('T', ' ')
                              : hace,
                          style: AppTexto.metadato,
                        ),
                        // 1.28 (M1-C5): la fila dice el MOTIVO en
                        // lenguaje llano (explicacionOp), igual que
                        // el bloque de bloqueadas y el detalle —
                        // antes las filas rechazada/revisión no
                        // enseñaban motivo alguno y las de error
                        // solo el mensaje sin la acción.
                        if ((esError || esBloqueada) &&
                            op['error'] != null &&
                            '${op['error']}'.isNotEmpty)
                          Builder(
                            builder: (context) {
                              final expl = explicacionOp(
                                  estado: estado,
                                  error: '${op['error']}',
                                  codigoError:
                                      '${op['codigo_error'] ?? ''}',
                                  hayInternet: _hayInternet);
                              return Padding(
                                padding:
                                    const EdgeInsets.only(
                                        top: AppEspacio.xs),
                                child: Text(
                                  expl.motivo,
                                  style: AppTexto.metadato.copyWith(color: AppColores.error),
                                ),
                              );
                            },
                          ),
                        // 1.29 (Oleada 6, FA-06): en la vista
                        // del dueño, la op pendiente de OTRA
                        // cuenta se etiqueta con su autor:
                        // no sube con su sesión, sube cuando
                        // él entre.
                        if (esPendiente && _esDueno)
                          Builder(builder: (context) {
                            final et = etiquetaOpAjena(op,
                                miActor: _miActor,
                                miTelegramId: _miTelegramId,
                                nombresPorTelegram:
                                    _nombresPorTelegram);
                            if (et == null) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(
                                  top: AppEspacio.xs),
                              child: Text(
                                et,
                                style: AppTexto.secundario.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                            );
                          }),
                        if (esPendiente)
                          Padding(
                            padding:
                                const EdgeInsets.only(top: AppEspacio.xs),
                            child: Text(
                              'Se subirá cuando haya conexión',
                              style: AppTexto.secundario.copyWith(
                                  color: AppColores
                                      .textoSecundario(
                                          context)),
                            ),
                          ),
                      ],
                    ),
                    trailing: cancelable
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (esError || esBloqueada)
                                IconButton(
                                  tooltip: 'Reintentar',
                                  icon: const Icon(Icons.refresh_rounded,
                                      color: AppColores.info),
                                  onPressed: () => _reenviar(op),
                                ),
                              IconButton(
                                tooltip: 'Cancelar',
                                icon: const Icon(Icons.cancel_rounded,
                                    color: AppColores.error),
                                onPressed: () => _cancelar(
                                    '${op['op_uuid']}',
                                    '${op['tipo']}'),
                              ),
                            ],
                          )
                        : _estadoChip(estado),
                    onTap: () => _verDetalle(op),
                    ),
                    ),
                  ),
                );
              }),
            const SizedBox(height: 16),
            // Cierre del lote 1.35: la cola de FOTOS va junto
            // a la lista y ANTES del pliegue — es una cola de
            // trabajo (contrato SP-04…SP-09 del panel 1.35),
            // no un bloque auxiliar: dentro del pliegue sus
            // filas quedaban tras dos pliegues, inalcanzables.
            // v1.2.9+46 (Gemini): visibilidad de la cola de fotos.
            _tarjetaFotos(context),
            // H-12 (1.20): fotos de incidencias en error, si hay.
            if (_fotosIncError.isNotEmpty) ...[
              const SizedBox(height: 16),
              _tarjetaFotosIncidencias(context),
            ],
            const SizedBox(height: 16),
            // SL-8 (G08-4, VIS aprobada por Jc): la LISTA de
            // la cola manda — estadísticas, resumen en
            // sencillo, bajada, banda de error, bloqueadas y
            // la tarjeta de comprobantes van PLEGADOS tras
            // este único control, que resume su estado
            // (regla anti-regueros). Nacen plegados; ninguna
            // función se pierde: todo sigue a un toque, y la
            // puerta al Centro y el botón de sincronizar
            // quedan fuera, accesibles. La cola de FOTOS va
            // fuera del pliegue (cierre del lote: contrato
            // SP-04…SP-09).
            Tarjeta(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InkWell(
                    onTap: () =>
                        setState(() => _auxAbierto = !_auxAbierto),
                    child: Padding(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                const Text('Resumen y detalle',
                                    style: AppTexto.subtitulo),
                                Text(
                                  _resumenAuxiliares(
                                      tituloHeroe: titulo,
                                      totalPendiente: totalPendiente),
                                  style: AppTexto.minuscula.copyWith(
                                      color: AppColores
                                          .textoSecundario(context)),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                              _auxAbierto
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              color: AppColores.textoSecundario(
                                  context)),
                        ],
                      ),
                    ),
                  ),
                  ClipRect(
                    child: Align(
                      key: const ValueKey('sl8-auxiliares'),
                      alignment: Alignment.topCenter,
                      heightFactor: _auxAbierto ? 1.0 : 0.0,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppEspacio.lg,
                            0,
                            AppEspacio.lg,
                            AppEspacio.lg),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.stretch,
                          children: [
            // Tarjetas de estadísticas
            Row(
              children: [
                Expanded(
                  child: _tarjetaStat(
                    Icons.download_rounded,
                    'Bajados',
                    '${_det.bajados}',
                    // v1.3.1 (E5): acumulado histórico + última sync.
                    'Total: ${_det.totalBajados} · ${_hora(_det.ultimaPull)}',
                    AppColores.info,
                    onTap: _abrirDetalleBajados,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _tarjetaStat(
                    Icons.upload_rounded,
                    'Subidos',
                    '${_det.subidos}',
                    // v1.3.1 (E5): acumulado histórico + última sync.
                    'Total: ${_det.totalSubidos} · ${_hora(_det.ultimaPush)}',
                    AppColores.naranja,
                    onTap: _abrirDetalleSubidos,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // v1.12.0 (E1): la cola en sencillo — cuántas, de qué
            // y desde cuándo (totales reales, no solo la lista
            // visible que tiene límite). Sin operaciones, lo dice.
            _tarjetaColaEnSencillo(),
            // Yunque B (YB-SYNC-01/02): la bajada atascada o
            // atrasada, con el nombre de SU tabla.
            if (_atasco.nombre != null || _tablaAtrasada != null) ...[
              const SizedBox(height: 16),
              _tarjetaBajada(),
            ],
            const SizedBox(height: 16),
            if (_det.error != null && _det.error!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(AppEspacio.md),
                decoration: BoxDecoration(
                  color: AppColores.error
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadio.md),
                  border: Border.all(
                      color: AppColores.error
                          .withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 20,
                        color: AppColores.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // 1.33: la banda pinta el MISMO
                        // texto compuesto que el subtítulo
                        // del héroe (_textoErrorVisible),
                        // no el error crudo de detalle().
                        _textoErrorVisible ?? _det.error!,
                        style: AppTexto.secundario.copyWith(color: AppColores.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            // v1.2.5 (D15): bloqueadas que necesitan revisión manual.
            if (_bloqueadas.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(AppEspacio.lg),
                decoration: BoxDecoration(
                  color: AppColores.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadio.lg),
                  border: Border.all(
                      color: AppColores.error.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: AppColores.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${_bloqueadas.length} necesitan revisión',
                            style: AppTexto.titulo.copyWith(
                                color: AppColores.error),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Estas operaciones no se pudieron enviar. '
                      'No se reintentarán solas.',
                      style: AppTexto.secundario,
                    ),
                    const SizedBox(height: 8),
                    for (final b in _bloqueadas)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.block_rounded, size: 20),
                        title: Text(
                            '${b['tipo'] ?? ''}',
                            style: AppTexto.cuerpo),
                        // 1.28 (M1-C5): antes el subtítulo era el
                        // código y el error CRUDOS; ahora motivo y
                        // acción en lenguaje llano (explicacionOp),
                        // para distinguir de un vistazo «cliente
                        // borrado» de «sin conexión».
                        subtitle: Builder(builder: (context) {
                          final e = explicacionOp(
                              estado: '${b['estado'] ?? 'rechazada'}',
                              error: '${b['error'] ?? ''}',
                              codigoError: '${b['codigo_error'] ?? ''}',
                              hayInternet: _hayInternet);
                          return Text(
                              e.accion.isEmpty
                                  ? e.motivo
                                  : '${e.motivo} ${e.accion}',
                              style: AppTexto.secundario,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis);
                        }),
                        trailing: TextButton(
                          onPressed: () => _reintentarBloqueada(
                              b['op_uuid'] as String),
                          child: const Text('Reintentar'),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_compError.isNotEmpty) ...[
              const SizedBox(height: 16),
              _tarjetaComprobantesError(context),
            ],
            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// v1.3.4: abre el detalle ampliable de las ops del último push.
  /// 1.32 (O2F2S, M1): la puerta es el DIARIO (la última
  /// corrida con ops); la meta jubilada queda como respaldo
  /// para instalaciones que aún no han corrido con el diario.
  Future<void> _abrirDetalleSubidos() async {
    var hay = false;
    try {
      hay =
          await DiarioSync.instance.ultimaCorridaConOps() != null;
    } catch (_) {}
    if (!hay) {
      final uuids = parsearUuidsPush(
          await LocalDb.instance.getMeta('ultimo_push_op_uuids'));
      hay = uuids.isNotEmpty;
    }
    if (!hay) {
      if (!mounted) return;
      mostrarSnack(context, 'No hay registros en este ciclo', significado: SignificadoChip.alerta);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(RutaIron(
      builder: (_) =>
          const DetalleSyncScreen(tipo: TipoDetalleSync.subidos)));
  }

  /// v1.3.4: abre el detalle ampliable del último pull.
  /// 1.32 (O2F2S, M1): ídem Subidos — diario primero.
  Future<void> _abrirDetalleBajados() async {
    var hay = false;
    try {
      hay = await DiarioSync.instance.ultimaCorridaConTablas() !=
          null;
    } catch (_) {}
    if (!hay) {
      final detalle = parsearDetallePull(
          await LocalDb.instance.getMeta('ultimo_pull_detalle'));
      hay = detalle.isNotEmpty;
    }
    if (!hay) {
      if (!mounted) return;
      mostrarSnack(context, 'No hay registros en este ciclo', significado: SignificadoChip.alerta);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(RutaIron(
      builder: (_) =>
          const DetalleSyncScreen(tipo: TipoDetalleSync.bajados)));
  }

  /// Tarjeta de estadística (v1.0.9.1).
  /// v1.3.4: `onTap` opcional abre el detalle ampliable (Bajados/Subidos);
  /// cuando está presente se muestra un chevron como affordance.
  Widget _tarjetaStat(IconData icono, String titulo, String valor,
      String subtitulo, Color color,
      {VoidCallback? onTap}) {
    return Tarjeta(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 24, color: color),
              if (onTap != null) ...[
                const Spacer(),
                Icon(Icons.chevron_right_rounded,
                    size: 16,
                    color: AppColores.textoSecundario(context)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            valor,
            style: AppTexto.displayPequeno.copyWith(
              color: color,
            ),
          ),
          Text(
            titulo,
            style: AppTexto.subtitulo,
          ),
          const SizedBox(height: 4),
          Text(
            subtitulo,
            style: AppTexto.minuscula.copyWith(
                color:
                    AppColores.textoSecundario(context)),
          ),
        ],
      ),
    );
  }

  /// Chip de estado para operaciones (v1.0.9.1).
  /// v1.3.4: delega en la funcion top-level [chipEstadoOp].
  Widget _estadoChip(String estado) => chipEstadoOp(estado);


}

/// v1.3.4: tipo de detalle ampliable de sincronización.
enum TipoDetalleSync { subidos, bajados }

/// Etiquetas de negocio por tabla espejo (veredicto Argón A1).
const Map<String, String> kEtiquetasTablaSync = {
  'clientes': 'Clientes actualizados/creados',
  'pagos': 'Pagos de mensualidad',
  'pagos_diarios': 'Pagos diarios',
  'ventas_suplementos': 'Ventas de suplementos',
  'suplementos': 'Inventario de suplementos',
  'categorias_suplemento': 'Categorías de suplementos',
  'turnos': 'Cierres de turno',
  'turnos_cierre': 'Cierres de turno',
  'incidencias': 'Incidencias operativas',
  'liquidaciones_caja': 'Liquidaciones de caja',
  // 1.20 (FIN-21/22 de Argón): tablas nuevas de la versión.
  'suplemento_ajustes': 'Ajustes de stock de suplementos',
  'diferencias_caja': 'Diferencias de caja',
  'nomina_liquidada_snapshot': 'Fotos de nómina liquidada',
  'nomina_confirmaciones': 'Confirmaciones de nómina',
  // 1.21: candado de acceso.
  'acceso_bloqueos': 'Candado de acceso',
};

/// v1.3.4: detalle ampliable de un ciclo de sincronización.
/// Muestra qué se subió en el último push (con estado y motivos de
/// rechazo) o qué se bajó en el último pull (por tabla espejo).
class DetalleSyncScreen extends StatefulWidget {
  final TipoDetalleSync tipo;
  const DetalleSyncScreen({super.key, required this.tipo});

  @override
  State<DetalleSyncScreen> createState() => _DetalleSyncScreenState();
}

class _DetalleSyncScreenState extends State<DetalleSyncScreen> {
  bool _cargando = true;
  // Subidos.
  List<Map<String, dynamic>> _ops = [];
  Map<String, List<String>> _detallesPorOp = {};
  String? _pushTs;
  String? _pushDetalleTs;
  // Bajados.
  Map<String, int> _detallePull = {};
  String? _detalleTs;
  String? _pullTs;
  // 1.32 (O2F2S, M1): fuente primaria = el diario de
  // corridas; las metas de arriba quedan como respaldo para
  // instalaciones que aún no han corrido con el diario.
  List<CorridaOpSync>? _opsDiario;
  List<CorridaTablaSync>? _tablasDiario;
  String? _corridaDiarioTxt;
  // (1.36 H-B4 136-933) fallo de carga del detalle: error
  // con reintento, no el respaldo mudo.
  bool _falloCarga = false;

  Future<void> _recargar() async {
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      if (widget.tipo == TipoDetalleSync.subidos) {
        await _cargarSubidos();
      } else {
        await _cargarBajados();
      }
    } catch (e) {
      AppLog.error('cola', 'detalle_sync_carga_fallo', d: '$e');
      if (mounted) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _recargar();
  }

  /// Cabecera de la corrida del diario (hora Habana).
  String _txtCorrida(CorridaSync c) {
    final h = aHabana(c.inicio);
    String p(int n) => n.toString().padLeft(2, '0');
    // 1.36 H-C2 (136-921): el detalle de «última
    // corrida» dice su desenlace cuando no fue completa
    // — una cortada no se presenta como una normal.
    final desenlace = switch (c.estado) {
      EstadoCorrida.cortada => ' · interrumpida',
      EstadoCorrida.parcial => ' · parcial',
      EstadoCorrida.fallida => ' · fallida',
      _ => '',
    };
    return 'Corrida de ${p(h.hour)}:${p(h.minute)} '
        'del ${p(h.day)}/${p(h.month)}$desenlace';
  }

  Future<void> _cargarSubidos() async {
    // 1.32 (O2F2S, M1): diario primero.
    try {
      final corrida =
          await DiarioSync.instance.ultimaCorridaConOps();
      if (corrida != null) {
        final opsD = await DiarioSync.instance.opsDe(corrida.id);
        if (opsD.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _opsDiario = opsD;
            _corridaDiarioTxt = _txtCorrida(corrida);
            _cargando = false;
          });
          return;
        }
      }
    } catch (_) {}
    final uuids = parsearUuidsPush(
        await LocalDb.instance.getMeta('ultimo_push_op_uuids'));
    final ts = await LocalDb.instance.getMeta('ultimo_push_ts');
    final detalleTs =
        await LocalDb.instance.getMeta('ultimo_push_detalle_ts');
    final ops = await LocalDb.instance.opsPorUuids(uuids);
    // D-17 (1.21): los detalles se resuelven en paralelo, no
    // en serie op a op (las latencias se sumaban).
    final detallesListas = await Future.wait([
      for (final op in ops) detallesDeOp(op),
    ]);
    final detalles = <String, List<String>>{
      for (var i = 0; i < ops.length; i++)
        '${ops[i]['op_uuid']}': detallesListas[i],
    };
    if (!mounted) return;
    setState(() {
      _ops = ops;
      _detallesPorOp = detalles;
      _pushTs = ts;
      _pushDetalleTs = detalleTs;
      _cargando = false;
    });
  }

  Future<void> _cargarBajados() async {
    // 1.32 (O2F2S, M1): diario primero.
    try {
      final corrida =
          await DiarioSync.instance.ultimaCorridaConTablas();
      if (corrida != null) {
        final tablasD =
            await DiarioSync.instance.tablasDe(corrida.id);
        if (tablasD.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _tablasDiario = tablasD;
            _corridaDiarioTxt = _txtCorrida(corrida);
            _cargando = false;
          });
          return;
        }
      }
    } catch (_) {}
    final detalle = parsearDetallePull(
        await LocalDb.instance.getMeta('ultimo_pull_detalle'));
    final detalleTs =
        await LocalDb.instance.getMeta('ultimo_pull_detalle_ts');
    final pullTs = await LocalDb.instance.getMeta('ultimo_pull_ts');
    if (!mounted) return;
    setState(() {
      _detallePull = detalle;
      _detalleTs = detalleTs;
      _pullTs = pullTs;
      _cargando = false;
    });
  }

  /// dd/MM HH:mm, '—' si no hay fecha.
  /// Yunque B (YB-CLI-02): los sellos se guardan con
  /// isoHabana (offset explícito) y parseFecha los devuelve
  /// como instante UTC: imprimirlos crudos enseñaba la hora
  /// UTC (4–5 h por delante). Se delega en horaCortaHabana,
  /// la conversión canónica de esta misma pantalla.
  String _fmtHora(String? iso) => horaCortaHabana(parseFecha(iso));

  /// HH:mm, '—' si no hay fecha.
  /// Yunque B (YB-CLI-02): misma conversión a La Habana.
  String _fmtHoraCorta(String? iso) {
    final d = parseFecha(iso);
    if (d == null) return '—';
    final h = d.isUtc ? aHabana(d) : d;
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(h.hour)}:${p(h.minute)}';
  }

  /// Motivo de rechazo legible para una op rechazada.
  String _motivoOp(Map<String, dynamic> op) {
    dynamic res;
    try {
      res = jsonDecode('${op['resultado_servidor'] ?? ''}');
    } catch (_) {
      res = null;
    }
    final motivo = motivoRechazo(res, op['error'] as String?);
    if (motivo != null && motivo.isNotEmpty) return motivo;
    final err = op['error'] as String?;
    if (err != null && err.isNotEmpty) return err;
    return 'Rechazada por el servidor';
  }

  Widget _placeholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_rounded,
              size: 48,
              color: AppColores.textoSecundario(context)),
          const SizedBox(height: 12),
          Text(
            'Sin registros en este ciclo',
            style: AppTexto.subtitulo.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildSubidos() {
    if (_ops.isEmpty) return _placeholder();
    // v1.3.5 (Argón ajuste 1): si el último chequeo no envió nada,
    // se muestra el lote anterior con nota informativa.
    final pushTs = _pushTs ?? '';
    final detTs = _pushDetalleTs ?? '';
    final mostrarBanner =
        pushTs.isNotEmpty && detTs.isNotEmpty && pushTs != detTs;
    // 1.34 Campo 2 (P-6): builder — antes la pestaña
    // construía TODAS las tarjetas de golpe (ListView con
    // children y spread del lote entero).
    return ListView.builder(
      padding: const EdgeInsets.all(AppEspacio.lg),
      itemCount: 2 + _ops.length,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.xs),
            child: Text(
              'Lote de ${_fmtHora(_pushDetalleTs ?? _pushTs)}',
              style: AppTexto.subtitulo,
            ),
          );
        }
        if (i == 1) {
          return mostrarBanner
              ? Container(
            margin: const EdgeInsets.only(bottom: AppEspacio.md, top: AppEspacio.sm),
            padding: const EdgeInsets.all(AppEspacio.md),
            decoration: BoxDecoration(
              color: AppColores.info.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadio.md),
              border: Border.all(
                  color: AppColores.info.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_rounded,
                    size: 20, color: AppColores.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sin envíos en el último chequeo '
                    '(${_fmtHoraCorta(_pushTs)}). Mostrando datos del lote '
                    'anterior (${_fmtHoraCorta(_pushDetalleTs)}).',
                    style: AppTexto.minuscula,
                  ),
                ),
              ],
            ),
          )
              : const SizedBox(height: 12);
        }
        return _tarjetaOp(_ops[i - 2]);
      },
    );
  }

  Widget _tarjetaOp(Map<String, dynamic> op) {
    final estado = '${op['estado']}';
    final detalles = _detallesPorOp['${op['op_uuid']}'] ?? [];
    final uuid = '${op['op_uuid']}';
    final uuidCorto = uuid.length > 8 ? uuid.substring(0, 8) : uuid;
    final textoDetalles =
        detalles.isEmpty ? 'op $uuidCorto' : detalles.join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: ListTile(
        title: Text(tituloDeOp(op)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(textoDetalles),
            // v1.3.5 (auditoría 2026-10-16): el motivo también se muestra
            // para necesita_revision, no solo rechazada.
            if (estado == 'rechazada' || estado == 'necesita_revision')
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Text(
                  _motivoOp(op),
                  style: AppTexto.minuscula.copyWith(
                      color: estado == 'rechazada'
                          ? AppColores.error
                          : AppColores.alerta),
                ),
              ),
          ],
        ),
        trailing: chipEstadoOp(estado),
      ),
    );
  }

  Widget _buildBajados() {
    final entradas = _detallePull.entries.toList();
    if (entradas.isEmpty) return _placeholder();
    final d = parseFecha(_detalleTs);
    String p(int n) => n.toString().padLeft(2, '0');
    final cabecera = d == null
        ? 'Lote sin fecha registrada'
        : 'Lote de ${p(d.hour)}:${p(d.minute)} del ${p(d.day)}/${p(d.month)}';
    final pullTs = _pullTs ?? '';
    final detTs = _detalleTs ?? '';
    final mostrarBanner =
        pullTs.isNotEmpty && detTs.isNotEmpty && pullTs != detTs;
    // P-6: builder, como _buildSubidos.
    return ListView.builder(
      padding: const EdgeInsets.all(AppEspacio.lg),
      itemCount: 2 + entradas.length,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.xs),
            child: Text(cabecera, style: AppTexto.subtitulo),
          );
        }
        if (i == 1) {
          return mostrarBanner
              ? Container(
            margin: const EdgeInsets.only(bottom: AppEspacio.md, top: AppEspacio.sm),
            padding: const EdgeInsets.all(AppEspacio.md),
            decoration: BoxDecoration(
              color: AppColores.info.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadio.md),
              border: Border.all(
                  color: AppColores.info.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_rounded,
                    size: 20, color: AppColores.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sin cambios en el último chequeo '
                    '(${_fmtHoraCorta(_pullTs)}). Mostrando datos del lote '
                    'anterior (${_fmtHoraCorta(_detalleTs)}).',
                    style: AppTexto.minuscula,
                  ),
                ),
              ],
            ),
          )
              : const SizedBox(height: 12);
        }
        final e = entradas[i - 2];
        return Card(
          margin: const EdgeInsets.only(bottom: AppEspacio.sm),
          child: ListTile(
            leading:
                const Icon(Icons.download_rounded, color: AppColores.info),
            title: Text(kEtiquetasTablaSync[e.key] ?? e.key),
            trailing: Text(
              '${e.value}',
              style: AppTexto.subtitulo.copyWith(color: AppColores.info),
            ),
          ),
        );
      },
    );
  }

  /// 1.32 (O2F2S, M1): Subidos desde el DIARIO — las ops de
  /// la última corrida con ops, con su desenlace y motivo.
  Widget _buildSubidosDiario() {
    final ops = _opsDiario!;
    if (ops.isEmpty) return _placeholder();
    String estadoChip(String resultado) => switch (resultado) {
          'aplicada' => 'aplicada',
          'rechazada' => 'rechazada',
          'revision' => 'necesita_revision',
          'error' => 'error',
          _ => 'pendiente',
        };
    // P-6: builder, como las demás pestañas del detalle.
    return ListView.builder(
      padding: const EdgeInsets.all(AppEspacio.lg),
      itemCount: 1 + ops.length,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          // (1.36 H-B4 136-933) cabecera solo si hay texto.
          if ((_corridaDiarioTxt ?? '').isEmpty) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child:
                Text(_corridaDiarioTxt!, style: AppTexto.subtitulo),
          );
        }
        final op = ops[i - 1];
        return Card(
              margin: const EdgeInsets.only(bottom: AppEspacio.sm),
              child: ListTile(
                title: Text(op.resumen ?? describirTipoOp(op.tipo)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // (1.36 H-B4 136-933) el tipo no se
                    // repite cuando el título ya lo dice.
                    if (op.resumen != null &&
                        op.resumen != describirTipoOp(op.tipo))
                      Text(describirTipoOp(op.tipo)),
                    if (op.motivo != null && op.motivo!.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.only(top: AppEspacio.xs),
                        child: Text(
                          op.motivo!,
                          style: AppTexto.minuscula.copyWith(
                              color: op.resultado == 'rechazada'
                                  ? AppColores.error
                                  : AppColores.alerta),
                        ),
                      ),
                  ],
                ),
                trailing: chipEstadoOp(estadoChip(op.resultado)),
              ),
            );
      },
    );
  }

  /// 1.32 (O2F2S, M1): Bajados desde el DIARIO — por tabla:
  /// nuevas (aplicadas), vistas y eliminadas (tumbas).
  Widget _buildBajadosDiario() {
    final tablas = _tablasDiario!
        .where((t) => t.aplicadas > 0 || t.tumbas > 0)
        .toList();
    if (tablas.isEmpty) return _placeholder();
    // P-6: builder, como las demás pestañas del detalle.
    return ListView.builder(
      padding: const EdgeInsets.all(AppEspacio.lg),
      itemCount: 1 + tablas.length,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          if ((_corridaDiarioTxt ?? '').isEmpty) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child:
                Text(_corridaDiarioTxt!, style: AppTexto.subtitulo),
          );
        }
        final t = tablas[i - 1];
        return Card(
            margin: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: ListTile(
              leading:
                  const Icon(Icons.download_rounded, color: AppColores.info),
              title: Text(kEtiquetasTablaSync[t.tabla] ??
                  SyncEngine.nombreAmigableTabla(t.tabla)),
              // (1.36 H-B4 136-933) las «vistas» también
              // se cuentan (recibidas sin cambio).
              subtitle: (t.recibidas > 0 || t.tumbas > 0)
                  ? Text([
                      if (t.recibidas > 0)
                        '${t.recibidas} ${t.recibidas == 1 ? 'vista' : 'vistas'}',
                      if (t.tumbas > 0)
                        '${t.tumbas} ${t.tumbas == 1 ? 'eliminada' : 'eliminadas'}',
                    ].join(' · '))
                  : null,
              trailing: Text(
                '${t.aplicadas}',
                style:
                    AppTexto.subtitulo.copyWith(color: AppColores.info),
              ),
            ),
          );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final esSubidos = widget.tipo == TipoDetalleSync.subidos;
    return Scaffold(
      appBar: appBarIron(
        context,
        esSubidos ? 'Detalle de subidos' : 'Detalle de bajados',
        acciones: [
          // (1.36 H-B4 136-933) recarga manual del detalle.
          IconButton(
            tooltip: 'Recargar',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargando ? null : _recargar,
          ),
        ],
      ),
      body: _cargando
          // 1.25 T114: esqueleto con la forma de la lista.
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: SkeletonLista(items: 4))
          : _falloCarga
              ? EstadoError(
                  titulo: 'No se pudo cargar el detalle',
                  detalle: 'La lectura del diario falló en este '
                      'teléfono. Reinténtalo.',
                  onReintentar: _recargar,
                )
              : esSubidos
              ? (_opsDiario != null
                  ? _buildSubidosDiario()
                  : _buildSubidos())
              : (_tablasDiario != null
                  ? _buildBajadosDiario()
                  : _buildBajados()),
    );
  }
}
