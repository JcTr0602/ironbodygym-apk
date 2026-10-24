/// Bloque 2 RESTO (1.11.0): G2 + C + F + H del Panel.
///
/// Veredicto de Argón AMARILLO 2026-10-24 (adenda del diseño, 6 ajustes
/// obligatorios + ajuste 7 del núcleo para G2). Reglas que rigen todo:
///
/// - C1 liquida por DELTA: la op guarda `monto_entregado` exacto y el
///   pendiente es siempre una resta acumulada. NUNCA pendiente = 0.
///   Contablemente es un movimiento propio de custodia
///   (`entrega_efectivo_dueno`): no es gasto, no va a la bolsa de
///   adelantos de nómina, no toca C5 ni C2/C3.
///   Implementación (ver [pendienteDeltaC1]): el pendiente vigente se
///   calcula como `pendienteEntrega()` (espejo sin marcar + cola local
///   − adelantos de gaveta, la regla vigente) MENOS las entregas C1
///   registradas en el libro local `entregas_efectivo`. En el instante
///   de la transición el libro está vacío y el resultado es EXACTO al
///   pendiente viejo: las entregas viejas ya están reflejadas porque
///   sus filas quedaron marcadas entregado=1 y no suman en
///   `pendienteEntrega()`. Un cobro offline que llega DESPUÉS de
///   liquidar suma limpio (entra sin marcar) y nunca se descuenta
///   dos veces (cada entrega resta una sola vez, por su op_uuid).
/// - C5 suma TRANSACCIONES reales del rango (monto congelado de cada
///   fila), nunca el estado actual del cliente. Plus es línea propia.
/// - C6 es la ÚNICA fuente de precios que alimenta a
///   `calcularPrecioCobro()` (vía `preciosVigentes()` → meta ajustes).
///   H1 NO duplica formularios: enlaza a C6 y solo edita métodos
///   aceptados y textos base. Los cambios rigen hacia adelante: C1,
///   C2 y C5 leen montos congelados, nunca recalculan.
/// - G2: entrenadores solo crean «solo para mí»; solo el dueño crea,
///   edita o activa para otros; anti-duplicado con
///   `recordatorio_disparos_log` (PK triple); los masivos se disparan
///   SOLO en el teléfono del dueño (o vía `disparado_en_fecha_habana`
///   sincronizado).
/// - F3: sin «Descartar» para ops de datos. Descarte directo solo
///   para fotos huérfanas de ops rechazadas (regla G5).
/// - F5: «Re-descargar tabla espejo» BLOQUEADA con cola pendiente.
/// - H5: copia en frío con wal_checkpoint previo, solo .db, sin
///   fotos, con aviso fijo y contador de pendientes.
/// - H2: visor de solo lectura + «Copiar resumen en Markdown». La app
///   JAMÁS escribe el archivo maestro.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'localdb.dart';
import 'negocio.dart' show pendienteEntrega;
import 'sync.dart' show SyncEngine;
import 'tiempo.dart';

// ---------------------------------------------------------------------------
// C1 — Arqueo de entrega de efectivo (delta)
// ---------------------------------------------------------------------------

/// Tipo de op nuevo de C1 (CHECK de sync_ops en la 1.11.0).
const String kTipoOpLiquidarEntrega = 'liquidar_entrega_efectivo';

/// Tipo de op nuevo de C6/H1 (CHECK de sync_ops en la 1.11.0).
const String kTipoOpActualizarConfigGym = 'actualizar_config_gym';

/// Tipos de op nuevos de G2 (CHECK de sync_ops en la 1.11.0).
const String kTipoOpUpsertRecordatorio = 'upsert_recordatorio_config';
const String kTipoOpDeleteRecordatorio = 'delete_recordatorio_config';

/// Pendiente tras restar entregas C1 ya registradas.
///
/// [pendienteActual] es el pendiente vigente (espejo sin marcar +
/// cola local − adelantos de gaveta, según `pendienteEntrega()`).
/// [entregasRegistradas] es la suma del libro `entregas_efectivo`.
/// Nunca baja de 0: una entrega no puede entregar más de lo que
/// había pendiente en el momento de confirmarse (la pantalla lo
/// valida antes; esto es el seguro aritmético).
double pendienteTrasEntregas(double pendienteActual, double entregas) {
  final r = pendienteActual - entregas;
  return r < 0 ? 0 : r;
}

/// Payload de la op C1. El servidor la aplica como movimiento propio
/// de custodia `entrega_efectivo_dueno` (otra vía: handler del bot).
Map<String, dynamic> payloadLiquidarEntrega({
  required int entrenadorTelegramId,
  required double montoEntregado,
  required String fechaHoraHabana,
  required int autorDuenoId,
}) =>
    {
      'entrenador_id': entrenadorTelegramId,
      'monto_entregado': montoEntregado,
      'fecha_hora_havana': fechaHoraHabana,
      'autor_dueno_id': autorDuenoId,
      'movimiento': 'entrega_efectivo_dueno',
    };

/// Suma de entregas C1 registradas en el libro local para un entrenador.
Future<double> entregasEfectivoRegistradas(int telegramId) async {
  final d = await LocalDb.instance.db;
  final r = await d.rawQuery(
      'SELECT COALESCE(SUM(monto_entregado), 0) AS t FROM entregas_efectivo '
      'WHERE entrenador_telegram_id = ?',
      [telegramId]);
  return (r.first['t'] as num?)?.toDouble() ?? 0;
}

/// Pendiente delta C1 de un entrenador: pendiente vigente menos las
/// entregas C1 ya registradas. Ver el encabezado del archivo para la
/// demostración de que en la transición coincide con el pendiente
/// viejo y que un cobro tardío suma limpio.
Future<double> pendienteDeltaC1(int telegramId) async {
  final vigente = await pendienteEntrega(telegramId);
  final entregas = await entregasEfectivoRegistradas(telegramId);
  return pendienteTrasEntregas(vigente, entregas);
}

/// Historial de entregas C1 del libro local (más recientes primero).
Future<List<Map<String, dynamic>>> historialEntregasC1(
    int telegramId) async {
  final d = await LocalDb.instance.db;
  return d.query('entregas_efectivo',
      where: 'entrenador_telegram_id = ?',
      whereArgs: [telegramId],
      orderBy: 'creada_ts DESC');
}

/// Registra una entrega C1 (solo dueño): libro local + op
/// `liquidar_entrega_efectivo` en UNA transacción, y push en segundo
/// plano. Lanza si no es dueño, si el monto no es positivo o si
/// supera el pendiente vigente (con 0.01 de tolerancia por redondeo).
Future<String> registrarEntregaEfectivo({
  required int entrenadorTelegramId,
  required double montoEntregado,
  required int autorDuenoId,
}) async {
  if (!AuthService().isOwner) {
    throw Exception('Solo el dueño puede liquidar entregas de efectivo');
  }
  if (montoEntregado <= 0) {
    throw Exception('El monto entregado debe ser positivo');
  }
  final pendiente = await pendienteDeltaC1(entrenadorTelegramId);
  if (montoEntregado - pendiente > 0.01) {
    throw Exception(
        'Lo entregado ($montoEntregado) supera el pendiente ($pendiente)');
  }
  final opUuid = const Uuid().v4();
  final ahora = isoHabana(ahoraHabana());
  final d = await LocalDb.instance.db;
  await d.transaction((txn) async {
    await txn.insert('entregas_efectivo', {
      'op_uuid': opUuid,
      'entrenador_telegram_id': entrenadorTelegramId,
      'monto_entregado': montoEntregado,
      'fecha_habana': hoyHabanaIso(),
      'autor_dueno_id': autorDuenoId,
      'creada_ts': ahora,
    });
    await LocalDb.instance.queueOp(
      opUuid: opUuid,
      tipo: kTipoOpLiquidarEntrega,
      payload: payloadLiquidarEntrega(
        entrenadorTelegramId: entrenadorTelegramId,
        montoEntregado: montoEntregado,
        fechaHoraHabana: ahora,
        autorDuenoId: autorDuenoId,
      ),
      txn: txn,
    );
  });
  // Push en segundo plano (patrón de crearLiquidacion).
  // ignore: discarded_futures
  SyncEngine.instance.push().then((_) {}, onError: (_) {});
  return opUuid;
}

// ---------------------------------------------------------------------------
// C5 — Reporte de ingresos por período (transacciones reales, montos
// congelados; Plus como línea propia)
// ---------------------------------------------------------------------------

/// Conceptos del desglose C5. 'plus' = Invitados Plus (1000 CUP por
/// transferencia, línea propia, separada de Mensualidades).
const kConceptosC5 = [
  'mensualidades',
  'diarios',
  'suplementos',
  'dosis',
  'agua',
  'plus',
];

/// Una fila de ingreso: monto CONGELADO de la transacción real.
/// [fechaHabana] es 'YYYY-MM-DD' (se compara lexicográficamente).
class FilaIngreso {
  final String concepto;
  final String metodo; // 'efectivo' | 'transferencia'
  final double monto;
  final String fechaHabana;
  const FilaIngreso(this.concepto, this.metodo, this.monto, this.fechaHabana);
}

class ResumenIngresos {
  final double efectivo;
  final double transferencia;
  final double total;
  final Map<String, double> porConcepto;
  const ResumenIngresos(
      this.efectivo, this.transferencia, this.total, this.porConcepto);
}

/// Suma las filas cuyo [fechaHabana] cae en [desde..hasta] (inclusive,
/// límites en America/Havana, formato YYYY-MM-DD). Las filas fuera
/// del rango o con concepto desconocido se ignoran; el monto NUNCA se
/// recalcula: se lee tal cual (congelado en la transacción).
ResumenIngresos resumenIngresos(
    List<FilaIngreso> filas, String desde, String hasta) {
  var ef = 0.0;
  var tr = 0.0;
  final porConcepto = {for (final c in kConceptosC5) c: 0.0};
  for (final f in filas) {
    if (f.fechaHabana.compareTo(desde) < 0 ||
        f.fechaHabana.compareTo(hasta) > 0) {
      continue;
    }
    if (!porConcepto.containsKey(f.concepto)) continue;
    porConcepto[f.concepto] = porConcepto[f.concepto]! + f.monto;
    if (f.metodo == 'transferencia') {
      tr += f.monto;
    } else {
      ef += f.monto;
    }
  }
  return ResumenIngresos(ef, tr, ef + tr, porConcepto);
}

/// Convierte una fila espejo en [FilaIngreso] o null si no es un
/// ingreso contable (anulada, Casa en dosis con precio 0, sin fecha).
/// [fuente] es 'pagos' | 'pagos_diarios' | 'ventas_suplementos' |
/// 'servicio_ventas'. El monto sale de la fila tal cual (congelado).
FilaIngreso? filaIngresoDesdeEspejo(
    String fuente, Map<String, dynamic> r) {
  if (r['anulada'] == 1 ||
      r['anulada'] == true ||
      r['anulado'] == 1 ||
      r['anulado'] == true) {
    return null;
  }
  final fechaRaw = '${r['fecha'] ?? ''}';
  if (fechaRaw.length < 10) return null;
  final fecha = fechaRaw.substring(0, 10);
  final metodo = '${r['metodo'] ?? 'efectivo'}';
  switch (fuente) {
    case 'pagos':
      final monto = (r['monto'] as num?)?.toDouble() ?? 0;
      if (monto == 0) return null;
      return FilaIngreso('mensualidades', metodo, monto, fecha);
    case 'pagos_diarios':
      final monto = (r['total'] as num?)?.toDouble() ?? 0;
      if (monto == 0) return null;
      return FilaIngreso('diarios', metodo, monto, fecha);
    case 'ventas_suplementos':
      // Solo CUP: el USD no entra al reporte en CUP (se muestra aparte
      // en la pantalla si hace falta; el total C5 es en CUP).
      if ((r['moneda'] as String?) == 'USD') return null;
      final monto = (r['total'] as num?)?.toDouble() ??
          ((r['precio'] as num?)?.toDouble() ?? 0) *
              ((r['cantidad'] as num?)?.toDouble() ?? 0);
      if (monto == 0) return null;
      return FilaIngreso('suplementos', metodo, monto, fecha);
    case 'servicio_ventas':
      if ((r['casa'] as num?)?.toInt() == 1) return null;
      final precio = (r['precio_unitario'] as num?)?.toDouble() ?? 0;
      final cant = (r['cantidad'] as num?)?.toDouble() ?? 0;
      final monto = precio * cant;
      if (monto == 0) return null;
      // El tipo lo dice la fila: agua_suelta va a 'agua'; las dosis
      // (con o sin agua) van a 'dosis'. El total no depende de esto.
      final concepto =
          '${r['tipo']}' == 'agua_suelta' ? 'agua' : 'dosis';
      return FilaIngreso(concepto, metodo, monto, fecha);
  }
  return null;
}

// ---------------------------------------------------------------------------
// C6/H1 — Precios por método, única fuente
// ---------------------------------------------------------------------------

/// Claves de la meta `ajustes` que C6 edita (única fuente de precios).
/// Los especiales NO están aquí: tienen su pantalla D6 del núcleo.
const kClavesPreciosC6 = [
  'mensualidad',
  'mensualidad_menores',
  'transferencia',
  'pago_diario',
  'pago_semanal',
  'pago_quincenal',
  'precio_app_plus',
];

/// Claves que H1 edita SIN duplicar C6: métodos aceptados y textos
/// base. Los precios y períodos viven solo en C6 (Argón ajuste 3).
const kClavesAjustesH1 = ['metodos_aceptados', 'textos_base'];

/// Guarda un mapa de precios/ajustes en la meta local y encola la op
/// `actualizar_config_gym` para que el cambio baje a los teléfonos de
/// los entrenadores. Solo el dueño. [cambios] se fusiona con lo
/// guardado (no se borran claves que no vienen).
Future<void> guardarConfigGym(Map<String, dynamic> cambios) async {
  if (!AuthService().isOwner) {
    throw Exception('Solo el dueño puede cambiar la configuración');
  }
  final db = LocalDb.instance;
  final actuales = await db.getAjustes();
  final nuevos = {...actuales, ...cambios};
  await db.setAjustes(nuevos);
  await db.queueOp(
    opUuid: const Uuid().v4(),
    tipo: kTipoOpActualizarConfigGym,
    payload: {
      'config': cambios,
      'fecha_hora_havana': isoHabana(ahoraHabana()),
      'autor_dueno_id': AuthService().telegramId,
    },
  );
  // ignore: discarded_futures
  SyncEngine.instance.push().then((_) {}, onError: (_) {});
}

// ---------------------------------------------------------------------------
// G2 — Recordatorios automáticos (candados del ajuste 7 del núcleo)
// ---------------------------------------------------------------------------

/// Alcances de un recordatorio: 'solo_mio' (solo el teléfono que lo
/// creó) o 'todos' (masivo; solo lo crea/edita/activa el dueño y solo
/// se dispara en el teléfono del dueño).
bool puedeCrearParaOtros({required bool esDueno}) => esDueno;

/// Un entrenador solo puede crear recordatorios «solo para mí».
bool alcancePermitido(String alcance, {required bool esDueno}) {
  if (alcance == 'solo_mio') return true;
  if (alcance == 'todos') return esDueno;
  return false;
}

/// ¿Puede este teléfono disparar un recordatorio masivo hoy?
/// Solo el teléfono del dueño, y solo si aún no quedó registrado
/// como disparado hoy (ni en el log local ni en el estado
/// sincronizado `disparado_en_fecha_habana`).
bool puedeDispararMasivo({
  required bool esTelefonoDueno,
  required String? disparadoEnFechaHabana,
  required String hoyHabana,
}) {
  if (!esTelefonoDueno) return false;
  if (disparadoEnFechaHabana == hoyHabana) return false;
  return true;
}

/// Cumpleaños hoy desde carnet de 6 dígitos (AAMMDD → MM-DD) o desde
/// fecha_nac 'YYYY-MM-DD' si viene. [hoyMmDd] es 'MM-DD'.
bool esCumpleanosHoy(Map<String, dynamic> cliente, String hoyMmDd) {
  final fn = '${cliente['fecha_nac'] ?? ''}';
  if (fn.length >= 10) return fn.substring(5, 10) == hoyMmDd;
  final carnet = '${cliente['carnet'] ?? ''}';
  if (carnet.length == 6) {
    return '${carnet.substring(2, 4)}-${carnet.substring(4, 6)}' ==
        hoyMmDd;
  }
  return false;
}

/// ¿Vence dentro de la ventana? [diasAnticipacion] incluye hoy (0).
/// Comparación lexicográfica sobre 'YYYY-MM-DD'.
bool venceEnVentana(
    String? pagadoHasta, String hoyHabana, int diasAnticipacion) {
  if (pagadoHasta == null || pagadoHasta.length < 10) return false;
  final hasta = pagadoHasta.substring(0, 10);
  if (hasta.compareTo(hoyHabana) < 0) return false;
  final hoy = DateTime.tryParse(hoyHabana);
  final ven = DateTime.tryParse(hasta);
  if (hoy == null || ven == null) return false;
  return ven.difference(hoy).inDays <= diasAnticipacion;
}

// ---------------------------------------------------------------------------
// F5 — Herramientas de mantenimiento (lista cerrada)
// ---------------------------------------------------------------------------

/// «Re-descargar tabla espejo» solo si NO hay ops pendientes de subir.
/// Con cola pendiente, pisar la tabla local en frío borraría de la
/// vista los cobros hechos sin conexión (Argón ajuste 4).
bool puedeRedescargarEspejo(int opsPendientes) => opsPendientes == 0;

/// Fotos huérfanas de ops rechazadas (regla G5): filas de fotos_cola
/// en error cuyo op_uuid padre está en estado 'rechazada'. Solo esas
/// se pueden descartar sin reconciliar, y el descarte borra SOLO la
/// fila de la cola (nunca al cliente ni a su foto).
Future<List<Map<String, dynamic>>> fotosHuerfanasDeOpsRechazadas() async {
  final d = await LocalDb.instance.db;
  return d.rawQuery(
      'SELECT f.* FROM fotos_cola f JOIN ops_queue o ON o.op_uuid = f.op_uuid '
      "WHERE o.estado = 'rechazada'");
}

/// Descarta una foto huérfana: borra solo su fila de fotos_cola.
Future<void> descartarFotoHuerfana(int fotoColaId) async {
  final d = await LocalDb.instance.db;
  await d.delete('fotos_cola', where: 'id = ?', whereArgs: [fotoColaId]);
}

/// Ops de datos con error o rechazadas (lo que muestra F3).
Future<List<Map<String, dynamic>>> opsConError() async {
  final d = await LocalDb.instance.db;
  return d.query('ops_queue',
      where: "estado IN ('error', 'rechazada')",
      orderBy: 'creada_ts DESC');
}

/// Tamaño de la BD local en bytes (page_count × page_size).
Future<int> tamanoBdLocal() async {
  final d = await LocalDb.instance.db;
  final pc = await d.rawQuery('PRAGMA page_count');
  final ps = await d.rawQuery('PRAGMA page_size');
  final count = (pc.first.values.first as num?)?.toInt() ?? 0;
  final size = (ps.first.values.first as num?)?.toInt() ?? 0;
  return count * size;
}

/// Registra una herramienta de F5 en la auditoría local.
Future<void> registrarAccionMantenimiento(
    String accion, Map<String, dynamic> detalle) async {
  final auth = AuthService();
  await LocalDb.instance.auditoriaInsert(
    actorId: '${auth.telegramId ?? 0}',
    actorNombre: 'Dueño',
    accion: accion,
    objetoTipo: 'mantenimiento_panel',
    objetoId: 'F5',
    detalle: detalle,
    dispositivoId: '${auth.userId ?? 'local'}',
  );
}

// ---------------------------------------------------------------------------
// H5 — Copia de seguridad (exportar solo, copia en frío)
// ---------------------------------------------------------------------------

/// Aviso fijo de H5 (texto del veredicto, sin recortar).
const kAvisoCopiaFria = 'Esta copia es para resguardo o rescate técnico '
    'externo; la app no tiene botón de restaurar en esta versión. Si '
    'tienes operaciones pendientes de subir, sincroniza antes de exportar';

// ---------------------------------------------------------------------------
// H2 — Registro mensual: visor + copiar resumen en Markdown
// ---------------------------------------------------------------------------

/// Bloque Markdown del mes, con los números exactos que la app sabe.
/// La app nunca escribe el archivo maestro: el dueño lo pega donde
/// quiera (botón «Copiar resumen en Markdown»).
String resumenMensualMarkdown({
  required String mes,
  required ResumenIngresos ingresos,
  required int pagaron,
  int? altas,
  int? bajas,
}) {
  final b = StringBuffer()
    ..writeln('# Registro mensual — $mes')
    ..writeln()
    ..writeln('## Ingresos')
    ..writeln('- Efectivo: ${ingresos.efectivo.toStringAsFixed(0)} CUP')
    ..writeln(
        '- Transferencia: ${ingresos.transferencia.toStringAsFixed(0)} CUP')
    ..writeln('- Total: ${ingresos.total.toStringAsFixed(0)} CUP');
  for (final c in kConceptosC5) {
    b.writeln(
        '- ${c[0].toUpperCase()}${c.substring(1)}: ${ingresos.porConcepto[c]!.toStringAsFixed(0)} CUP');
  }
  b
    ..writeln()
    ..writeln('## Clientes')
    ..writeln('- Pagaron el mes: $pagaron')
    // Altas/bajas: la app no guarda fecha de alta en el espejo, así
    // que no se inventa un número: se deja al archivo maestro.
    ..writeln(
        '- Altas: ${altas ?? '— (se dicta en el archivo maestro)'}')
    ..writeln(
        '- Bajas: ${bajas ?? '— (se dicta en el archivo maestro)'}');
  return b.toString();
}

/// Mes 'YYYY-MM' de hoy en Habana (para C2/H2 por defecto).
String mesHabanaActual() => hoyHabanaIso().substring(0, 7);

/// Convierte un ISO/fecha a 'YYYY-MM-DD' o '' si no se puede.
/// (Nombre distinto de `fechaCorta` de negocio.dart, que recorta a N
/// caracteres arbitrarios.)
String fechaCorta10(String? v) =>
    (v != null && v.length >= 10) ? v.substring(0, 10) : '';

/// Serializa un mapa de ajustes para mostrarlo en H1 (sin secretos).
String ajustesParaMostrar(Map<String, dynamic> ajustes) {
  final b = StringBuffer();
  for (final e in ajustes.entries) {
    b.writeln('${e.key}: ${e.value}');
  }
  return b.toString();
}

/// Helper JSON tolerante (las filas espejo llegan como mapas).
Map<String, dynamic> mapaSeguro(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, e) => MapEntry('$k', e));
  if (v is String) {
    try {
      return jsonDecode(v) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
  return {};
}
