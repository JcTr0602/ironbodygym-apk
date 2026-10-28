import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'negocio.dart' show fechaNacDeCarnet;
import 'sync.dart';
import 'tiempo.dart';

/// v1.8.0: Servicios por dosis (pre-entreno C4 y futuros) — capa de
/// negocio de Gestión. Diseños 🟢 Argón 2026-10-23.
///
/// Modelo: el dueño abre un BOTE del catálogo y lo reparte en LOTES
/// (pomos) por vendedor. El saldo de un lote SIEMPRE se deriva
/// (iniciales + reposiciones − ventas − salidas), nunca se guarda.
/// El agua es stock común con costo promedio ponderado (CPP). Las
/// ventas NO se insertan en el espejo local: viven en ops_queue hasta
/// que el servidor las confirma y bajan por pull (mismo patrón que
/// ventas_suplementos); los cálculos locales suman espejo + ops
/// pendientes aún no espejadas (por op_uuid, sin doble conteo).
///
/// v1.13.0 (Bloque 4, Argón AMARILLO):
/// - `dosis_repuestas` (reponer_lote, solo dueño) suma al saldo; el
///   «sin repartir» del bote resta las reposiciones de sus lotes.
///   La reposición se refleja optimista en el espejo local al
///   encolar (el espejo ES la fuente del saldo); si el servidor la
///   rechaza, el gancho de rechazo la revierte (ver sync.dart).
/// - Venta múltiple: 1 op por subtipo con `venta_grupo_id` común
///   (dosis_con_agua × M + dosis_sin_agua × (N−M) cuando 0 < M < N).
/// - Deshacer (E3): 15 s exactos + op aún 'pendiente' (la venta de
///   dosis nace retenida 15 s por retenerHastaIso, como el cobro del
///   Bloque 1); si no, solo cabe Reversión (D3, motivo obligatorio).
///
/// 1.15 (pomos, rediseño Argón 🟢 con ajustes): el modelo de LOTES
/// queda como historia (las estadísticas por lote_id se conservan).
/// El stock vivo son POMOS: uno PRINCIPAL del dueño (ya abierto,
/// se alimenta al abrir cada bote) + uno por entrenador. Rellenar =
/// mover dosis del principal al pomo del entrenador (op
/// `reponer_pomo`, solo dueño, atómica en el servidor). El saldo de
/// un pomo SIEMPRE se deriva (asignadas − repartidas − ventas −
/// salidas + rellenos pendientes), NUNCA se escribe la fila espejo
/// en local: el optimista de un relleno pendiente vive SOLO en la
/// derivación desde ops_queue (si el servidor lo rechaza, la
/// derivación deja de contarlo sin tocar el espejo). Los
/// entrenadores NO ven su saldo (ciego, como el lote ciego 1.9.0):
/// solo «Agua común: X pomos» + aviso «menos de 5» que nunca
/// bloquea; el dueño ve todos los saldos exactos.
/// Las ventas viejas con lote_id y pomo_id NULL NO restan de ningún
/// pomo (el servidor tampoco las resta: su saldo ya quedó migrado).
///
/// Reglas de la casa aplicadas aquí (el servidor las re-impone):
/// - En el teléfono se bloquea vender si el saldo local es 0
///   (del lote o del agua); el servidor NUNCA rechaza una venta ya
///   hecha por stock teórico (Argón A3): aplica y marca descuadre.
/// - Comisión 0 en agua suelta y en ventas del dueño (A5).
/// - Casa: solo cliente con cuenta_casa=1 o el dueño beneficiario;
///   precio 0, sin método, fuera de caja y de comisión.
/// - Dosis a cliente identificado menor de 15 años: bloqueada.

const kTiposVentaServicio = {
  'dosis_sin_agua',
  'dosis_con_agua',
  'agua_suelta',
};

// ------------------------------------------------------------------
// Precios vigentes
// ------------------------------------------------------------------

/// Precios y comisión de servicios desde los ajustes (con los
/// defaults de lanzamiento: 600 sin agua / 900 con agua; el agua
/// suelta nace en 0 = «sin fijar» hasta que el dueño la fije).
Future<({
  double sinAgua,
  double conAgua,
  double agua,
  double comision
})> preciosServicios() async {
  final aj = await LocalDb.instance.getAjustes();
  double v(String k, double d) => (aj[k] as num?)?.toDouble() ?? d;
  return (
    sinAgua: v('servicio_precio_sin_agua', 600),
    conAgua: v('servicio_precio_con_agua', 900),
    agua: v('servicio_precio_agua', 0),
    comision: v('servicio_comision_dosis', 0),
  );
}

/// Ítem 7 (post-1.8.0, Argón): nombre de producto en las claves de
/// precios por método — ración = dosis sin agua, combo = dosis con
/// agua, agua = agua suelta.
const kStemServicio = {
  'dosis_sin_agua': 'racion',
  'dosis_con_agua': 'combo',
  'agua_suelta': 'agua',
};

/// Precio vigente de (tipo, método) desde el mapa de ajustes. El
/// servidor publica `servicio_precios_metodo` YA resuelto (cadena:
/// clave del método → clave de efectivo → precio único legacy); si la
/// estructura no está (servidor viejo o ajustes sin sincronizar), se
/// cae al precio único de siempre para ambos métodos. PURO.
double precioServicioMetodo(
    Map<String, dynamic> ajustes, String tipo, String metodo) {
  final pub = ajustes['servicio_precios_metodo'];
  if (pub is Map) {
    final prod = pub[kStemServicio[tipo]];
    if (prod is Map) {
      final v = prod[metodo];
      if (v is num) return v.toDouble();
    }
  }
  double v(String k, double d) => (ajustes[k] as num?)?.toDouble() ?? d;
  return switch (tipo) {
    'dosis_sin_agua' => v('servicio_precio_sin_agua', 600),
    'dosis_con_agua' => v('servicio_precio_con_agua', 900),
    _ => v('servicio_precio_agua', 0),
  };
}

/// ¿El método está habilitado para el producto? Sin la estructura por
/// método, todo habilitado (comportamiento histórico). PURO.
bool metodoServicioActivo(
    Map<String, dynamic> ajustes, String tipo, String metodo) {
  final pub = ajustes['servicio_precios_metodo'];
  if (pub is Map) {
    final prod = pub[kStemServicio[tipo]];
    if (prod is Map) {
      final v = prod['activo_$metodo'];
      if (v is num) return v.toInt() != 0;
      if (v is bool) return v;
    }
  }
  return true;
}

/// 1.15 V5: el checkbox «polvo perdido» de la reversión solo lo
/// ve el dueño (patrón AuthService().isOwner en la pantalla).
/// La regla del servidor no cambia. PURO.
bool mostrarCheckboxPolvoPerdido(bool esDueno) => esDueno;

/// 1.15 V7: totales que muestra el diálogo de venta múltiple.
/// Casa elegible: total cero y comisión cero (mismo trato que la
/// venta simple); en otro caso, la suma por variantes y la
/// comisión unitaria por dosis. PURO.
({double total, double comision}) totalesVentaMultipleServicio({
  required bool esCasa,
  required int dosisN,
  required int pomosM,
  required double precioSinAgua,
  required double precioConAgua,
  required double comisionUnitaria,
}) {
  if (esCasa) return (total: 0.0, comision: 0.0);
  return (
    total: (dosisN - pomosM) * precioSinAgua + pomosM * precioConAgua,
    comision: comisionUnitaria * dosisN,
  );
}

/// Entradas normalizadas del Historial de Servicios (pantalla
/// ServiciosHistorialScreen, pedido de Jc 2026-10-28): ventas de los
/// 3 tipos (ración = dosis_sin_agua, combo = dosis_con_agua, agua
/// suelta) + salidas sin venta, ordenadas de nuevas a viejas
/// (fecha desc, id desc). PURO. Las ventas reversadas quedan
/// marcadas (yaReversada) y los reversos como tales (esReverso).
/// El llamador ya filtra por rol antes de pasar las listas (el
/// dueño ve todo; el entrenador solo lo suyo; las salidas solo las
/// registra el dueño, así que al entrenador no le llega ninguna).
List<Map<String, dynamic>> entradasHistorialServicios({
  required List<Map<String, dynamic>> ventas,
  required List<Map<String, dynamic>> salidas,
  required Set<int> reversadas,
}) {
  final entradas = <Map<String, dynamic>>[];
  for (final v in ventas) {
    final id = (v['id'] as num?)?.toInt() ?? 0;
    entradas.add({
      'kind': 'venta',
      'id': id,
      'fecha': '${v['fecha'] ?? ''}',
      'hora': '${v['hora'] ?? ''}',
      'tipo': '${v['tipo'] ?? ''}',
      'cantidad': (v['cantidad'] as num?)?.toInt() ?? 1,
      'cliente': '${v['cliente_nombre'] ?? 'Sin identificar'}',
      'vendedorId': v['vendedor_id'],
      'registradoPorId': v['registrado_por'],
      'registradoPor': '${v['registrado_por_nombre'] ?? ''}',
      'monto': ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
          ((v['cantidad'] as num?)?.toDouble() ?? 0),
      'metodo': '${v['metodo'] ?? ''}',
      'casa': (v['casa'] as num?)?.toInt() == 1,
      'esReverso': (v['reverso_de'] as num?) != null,
      'yaReversada': reversadas.contains(id),
    });
  }
  for (final s in salidas) {
    entradas.add({
      'kind': 'salida',
      'id': (s['id'] as num?)?.toInt() ?? 0,
      'fecha': '${s['fecha'] ?? ''}',
      'hora': '',
      'tipo': '${s['tipo_item'] ?? ''}',
      'cantidad': (s['dosis'] as num?)?.toInt() ?? 0,
      'motivo': '${s['motivo'] ?? ''}',
      'monto': 0.0,
      'casa': false,
      'esReverso': false,
      'yaReversada': false,
    });
  }
  String f10(Map<String, dynamic> e) {
    final f = '${e['fecha']}';
    return f.length >= 10 ? f.substring(0, 10) : f;
  }

  entradas.sort((a, b) {
    final porFecha = f10(b).compareTo(f10(a));
    if (porFecha != 0) return porFecha;
    return ((b['id'] as int)).compareTo((a['id'] as int));
  });
  return entradas;
}

/// Primer método habilitado del producto (efectivo antes que
/// transferencia) o null si ambos están deshabilitados. Lo usan el
/// formulario de venta y el speed dial (ítems 5 y 7). PURO.
String? primerMetodoServicioActivo(
    Map<String, dynamic> ajustes, String tipo) {
  for (final m in const ['efectivo', 'transferencia']) {
    if (metodoServicioActivo(ajustes, tipo, m)) return m;
  }
  return null;
}

// ------------------------------------------------------------------
// Cálculos puros (testeables sin BD)
// ------------------------------------------------------------------

Map<String, dynamic> _payloadDeOp(Map<String, dynamic> op) {
  try {
    final p = jsonDecode(op['payload'] as String);
    return p is Map<String, dynamic> ? p : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

/// Saldo derivado de un lote: espejo + ops pendientes cuyo op_uuid
/// aún no aparece en el espejo (las ya espejadas no se descuentan
/// dos veces). PURO.
/// v1.13.0: el saldo suma `dosis_repuestas` (espejo; la reposición
/// optimista local ya vive en la fila del espejo, así que las ops
/// `reponer_lote` pendientes NO se suman aquí: doble conteo si se
/// hiciera). Los reversos pendientes restauran por venta espejo.
int saldoLoteDesde({
  required Map<String, dynamic> lote,
  required List<Map<String, dynamic>> ventasEspejo,
  required List<Map<String, dynamic>> salidasEspejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  var saldo = (lote['dosis_iniciales'] as num?)?.toInt() ?? 0;
  saldo += (lote['dosis_repuestas'] as num?)?.toInt() ?? 0;
  final uuidsEspejo = <String>{
    for (final v in ventasEspejo) '${v['op_uuid'] ?? ''}',
    for (final s in salidasEspejo) '${s['op_uuid'] ?? ''}',
  };
  for (final v in ventasEspejo) {
    saldo -= (v['cantidad'] as num?)?.toInt() ?? 0;
  }
  for (final s in salidasEspejo) {
    saldo -= (s['dosis'] as num?)?.toInt() ?? 0;
  }
  final loteId = (lote['id'] as num?)?.toInt();
  // Para resolver reversos pendientes: venta espejo por id.
  final ventaPorId = <int, Map<String, dynamic>>{
    for (final v in ventasEspejo)
      if ((v['id'] as num?) != null) (v['id'] as num).toInt(): v,
  };
  for (final op in opsPendientes) {
    final uuid = '${op['op_uuid'] ?? ''}';
    if (uuidsEspejo.contains(uuid)) continue;
    final p = _payloadDeOp(op);
    switch ('${op['tipo']}') {
      case 'venta_servicio':
        if ((p['lote_id'] as num?)?.toInt() == loteId) {
          saldo -= (p['cantidad'] as num?)?.toInt() ?? 1;
        }
      case 'salida_servicio':
        if ((p['lote_id'] as num?)?.toInt() == loteId) {
          saldo -= (p['dosis'] as num?)?.toInt() ?? 0;
        }
      case 'revertir_venta_servicio':
        final orig = ventaPorId[(p['venta_id'] as num?)?.toInt()];
        if (orig != null &&
            (orig['lote_id'] as num?)?.toInt() == loteId) {
          saldo += (orig['cantidad'] as num?)?.toInt() ?? 0;
        }
    }
  }
  return saldo;
}

/// 1.15 (pomos): saldo derivado de un pomo — espejo + ops
/// pendientes cuyo op_uuid aún no aparece en el espejo. PURO.
/// Base: asignadas − repartidas (el principal reparte; el pomo del
/// entrenador nace con repartidas 0). Las ventas/salidas del espejo
/// filtran por pomo_id (las viejas con pomo_id NULL no restan: su
/// saldo ya quedó migrado). El relleno pendiente se deriva: al
/// principal le resta, al destino le suma; si el servidor lo
/// rechaza, la op desaparece de pendientes y la derivación deja de
/// contarla SIN tocar la fila espejo (ajuste Argón MEDIO).
int saldoPomoDesde({
  required Map<String, dynamic> pomo,
  required List<Map<String, dynamic>> ventasEspejo,
  required List<Map<String, dynamic>> salidasEspejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  var saldo = (pomo['dosis_asignadas'] as num?)?.toInt() ?? 0;
  saldo -= (pomo['dosis_repartidas'] as num?)?.toInt() ?? 0;
  final pomoId = (pomo['id'] as num?)?.toInt();
  // A diferencia de saldoLoteDesde (que recibe listas ya filtradas),
  // aquí el filtro vive DENTRO: una lista sin filtrar jamás debe
  // drenar el pomo. Las ventas viejas con pomo_id NULL y las de
  // otro pomo quedan fuera por construcción.
  final ventas = ventasEspejo
      .where((v) => (v['pomo_id'] as num?)?.toInt() == pomoId)
      .toList();
  final salidas = salidasEspejo
      .where((v) => (v['pomo_id'] as num?)?.toInt() == pomoId)
      .toList();
  final uuidsEspejo = <String>{
    for (final v in ventas) '${v['op_uuid'] ?? ''}',
    for (final s in salidas) '${s['op_uuid'] ?? ''}',
  };
  for (final v in ventas) {
    saldo -= (v['cantidad'] as num?)?.toInt() ?? 0;
  }
  for (final s in salidas) {
    saldo -= (s['dosis'] as num?)?.toInt() ?? 0;
  }
  final esPrincipal = (pomo['es_principal'] as num?)?.toInt() == 1;
  final ventaPorId = <int, Map<String, dynamic>>{
    for (final v in ventas)
      if ((v['id'] as num?) != null) (v['id'] as num).toInt(): v,
  };
  for (final op in opsPendientes) {
    final uuid = '${op['op_uuid'] ?? ''}';
    if (uuidsEspejo.contains(uuid)) continue;
    final p = _payloadDeOp(op);
    switch ('${op['tipo']}') {
      case 'venta_servicio':
        if ((p['pomo_id'] as num?)?.toInt() == pomoId) {
          saldo -= (p['cantidad'] as num?)?.toInt() ?? 1;
        }
      case 'salida_servicio':
        if ((p['pomo_id'] as num?)?.toInt() == pomoId) {
          saldo -= (p['dosis'] as num?)?.toInt() ?? 0;
        }
      case 'revertir_venta_servicio':
        final orig = ventaPorId[(p['venta_id'] as num?)?.toInt()];
        if (orig != null &&
            (orig['pomo_id'] as num?)?.toInt() == pomoId) {
          saldo += (orig['cantidad'] as num?)?.toInt() ?? 0;
        }
      case 'reponer_pomo':
        final dosis = (p['dosis'] as num?)?.toInt() ?? 0;
        // Solo el principal DEL MISMO producto: sin este chequeo,
        // un relleno pendiente de otro producto drenaba este
        // principal en local (el servidor deriva por destino y no
        // tiene el problema, pero el pre-chequeo local sí).
        // Delta Luna: el id del payload DEBE ser no nulo; null ==
        // null es true en Dart y restaría sin producto.
        final supOp = (p['suplemento_id'] as num?)?.toInt();
        if (esPrincipal &&
            supOp != null &&
            supOp == (pomo['suplemento_id'] as num?)?.toInt()) {
          saldo -= dosis;
        } else if ((p['pomo_destino_id'] as num?)?.toInt() == pomoId) {
          saldo += dosis;
        }
    }
  }
  return saldo;
}

/// v1.8.1 (idea de Jc 2026-10-23): acumulado de servicios de UN
/// cliente para su ficha — detectar frecuentes («este cliente ha
/// comprado 15 raciones de pre-entreno») y hacerles ofertas o
/// regalos Casa. PURO. Los reversos llevan cantidad NEGATIVA
/// (convención del servidor), así que todo netea sumando con
/// signo. El importe excluye las filas Casa (no son compra); las
/// cantidades Casa SÍ cuentan como consumo recibido.
({int dosis, int pomos, double importe}) resumenServiciosDeCliente(
    List<Map<String, dynamic>> ventas) {
  var dosis = 0;
  var pomos = 0;
  var importe = 0.0;
  for (final v in ventas) {
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final tipo = '${v['tipo']}';
    if (tipo == 'agua_suelta') {
      pomos += cant;
    } else if (tipo == 'dosis_sin_agua' || tipo == 'dosis_con_agua') {
      dosis += cant;
    }
    if ((v['casa'] as num?)?.toInt() != 1) {
      importe +=
          ((v['precio_unitario'] as num?)?.toDouble() ?? 0) * cant;
    }
  }
  return (dosis: dosis, pomos: pomos, importe: importe);
}

/// (saldo, CPP) del agua común: replay de movimientos espejo en
/// orden de id + ops pendientes en orden de cola. El CPP sigue la
/// fórmula de Argón E1: al entrar agua, CPP = (saldo×CPP +
/// cant×costo) / (saldo + cant); con saldo ≤ 0, CPP = costo nuevo.
/// PURO.
({int saldo, double cpp}) aguaDesde({
  required List<Map<String, dynamic>> movimientosEspejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  var saldo = 0;
  var cpp = 0.0;
  final uuidsEspejo = <String>{
    for (final m in movimientosEspejo) '${m['op_uuid'] ?? ''}',
  };
  final movs = [...movimientosEspejo]
    ..sort((a, b) => ((a['id'] as num?)?.toInt() ?? 0)
        .compareTo((b['id'] as num?)?.toInt() ?? 0));
  void entrada(int cant, double costo) {
    if (cant <= 0) return;
    cpp = saldo <= 0 ? costo : (saldo * cpp + cant * costo) / (saldo + cant);
    saldo += cant;
  }

  void salida(int cant) {
    // Solo para ops pendientes, donde la cantidad viaja POSITIVA.
    saldo -= cant;
  }

  for (final m in movs) {
    final cant = (m['cantidad'] as num?)?.toInt() ?? 0;
    if ('${m['tipo']}' == 'entrada') {
      entrada(cant, (m['costo_unitario'] as num?)?.toDouble() ?? 0);
    } else {
      // CONVENCIÓN DEL ESPEJO: las salidas ya traen la cantidad en
      // NEGATIVO (así las guarda gym.db); se suman tal cual.
      saldo += cant;
    }
  }
  for (final op in opsPendientes) {
    final uuid = '${op['op_uuid'] ?? ''}';
    if (uuidsEspejo.contains(uuid)) continue;
    final p = _payloadDeOp(op);
    switch ('${op['tipo']}') {
      case 'reponer_agua':
        entrada((p['cantidad'] as num?)?.toInt() ?? 0,
            (p['costo_unitario'] as num?)?.toDouble() ?? 0);
      case 'venta_servicio':
        // El subtipo de la venta viaja en el campo 'tipo' del
        // PAYLOAD (el 'tipo' de la fila ops_queue es 'venta_servicio').
        final subtipo = '${p['tipo'] ?? ''}';
        if (subtipo == 'dosis_con_agua' || subtipo == 'agua_suelta') {
          salida((p['cantidad'] as num?)?.toInt() ?? 1);
        }
      case 'salida_servicio':
        // Ítem 11: la salida de AGUA pendiente resta del stock común
        // (las de dosis no llevan tipo_item y no tocan el agua).
        if ('${p['tipo_item'] ?? ''}' == 'agua') {
          salida((p['cantidad'] as num?)?.toInt() ?? 0);
        }
    }
  }
  return (saldo: saldo, cpp: cpp);
}

/// v1.13.0 (Bloque 4, Argón ajuste 1): bloqueo de stock SEPARADO
/// dosis vs pomos — nunca un interruptor único. PURO.
///
/// - Dosis sin agua: se apaga solo si el DUEÑO ve saldo 0 («No
///   quedan dosis en tu pomo»). Al entrenador ciego NUNCA se le
///   bloquea por saldo del pomo (regla pomo ciego, antes lote ciego
///   1.9.0 ítem 6: el servidor nunca rechaza por stock teórico);
///   su botón solo se apaga sin pomo o sin precio.
/// - Dosis con agua: igual que sin agua, y además se apaga sin pomos
///   («Sin pomos de agua en stock») para todos.
/// - Agua suelta: solo depende de los pomos (para todos).
/// Sin precio fijado, cualquier botón se apaga («Precio sin fijar»).
({bool habilitado, String? motivo}) estadoBotonVentaServicio({
  required String tipo,
  required bool tienePomo,
  required int dosisRestantes,
  required int pomos,
  required bool esDueno,
  required double precio,
}) {
  if (precio <= 0) {
    return (habilitado: false, motivo: 'Precio sin fijar');
  }
  if (tipo == 'agua_suelta') {
    if (pomos <= 0) {
      return (habilitado: false, motivo: 'Sin pomos de agua en stock');
    }
    return (habilitado: true, motivo: null);
  }
  if (!tienePomo) {
    return (habilitado: false, motivo: 'Sin pomo activo');
  }
  if (esDueno && dosisRestantes <= 0) {
    return (
      habilitado: false,
      motivo: 'No quedan dosis en tu pomo',
    );
  }
  if (tipo == 'dosis_con_agua' && pomos <= 0) {
    return (habilitado: false, motivo: 'Sin pomos de agua en stock');
  }
  return (habilitado: true, motivo: null);
}

/// v1.13.0: desglose del saldo de un lote para la tarjeta del dueño
/// (iniciales + reposiciones − ventas − salidas). PURO: recibe las
/// filas del espejo ya filtradas por lote.
({int iniciales, int repuestas, int ventas, int salidas, int saldo})
    desgloseLote({
  required Map<String, dynamic> lote,
  required List<Map<String, dynamic>> ventasEspejo,
  required List<Map<String, dynamic>> salidasEspejo,
}) {
  var ventas = 0;
  for (final v in ventasEspejo) {
    ventas += (v['cantidad'] as num?)?.toInt() ?? 0;
  }
  var salidas = 0;
  for (final s in salidasEspejo) {
    salidas += (s['dosis'] as num?)?.toInt() ?? 0;
  }
  final iniciales = (lote['dosis_iniciales'] as num?)?.toInt() ?? 0;
  final repuestas = (lote['dosis_repuestas'] as num?)?.toInt() ?? 0;
  return (
    iniciales: iniciales,
    repuestas: repuestas,
    ventas: ventas,
    salidas: salidas,
    saldo: iniciales + repuestas - ventas - salidas,
  );
}

/// 1.15 (pomos): desglose del saldo de un pomo para la tarjeta del
/// dueño (asignadas − repartidas − ventas − salidas). PURO: filtra
/// por pomo_id dentro (las viejas con NULL no cuentan).
({int asignadas, int repartidas, int ventas, int salidas, int saldo})
    desglosePomo({
  required Map<String, dynamic> pomo,
  required List<Map<String, dynamic>> ventasEspejo,
  required List<Map<String, dynamic>> salidasEspejo,
}) {
  // Filtro interno por pomo_id (igual que saldoPomoDesde): las
  // ventas viejas con pomo_id NULL no cuentan en ningún pomo.
  final pomoId = (pomo['id'] as num?)?.toInt();
  var ventas = 0;
  for (final v in ventasEspejo) {
    if ((v['pomo_id'] as num?)?.toInt() != pomoId) continue;
    ventas += (v['cantidad'] as num?)?.toInt() ?? 0;
  }
  var salidas = 0;
  for (final s in salidasEspejo) {
    if ((s['pomo_id'] as num?)?.toInt() != pomoId) continue;
    salidas += (s['dosis'] as num?)?.toInt() ?? 0;
  }
  final asignadas = (pomo['dosis_asignadas'] as num?)?.toInt() ?? 0;
  final repartidas = (pomo['dosis_repartidas'] as num?)?.toInt() ?? 0;
  return (
    asignadas: asignadas,
    repartidas: repartidas,
    ventas: ventas,
    salidas: salidas,
    saldo: asignadas - repartidas - ventas - salidas,
  );
}

/// v1.13.0 (E3): ¿sigue abierta la ventana de Deshacer? 15 segundos
/// exactos desde el cobro. PURO. La segunda condición (op aún
/// 'pendiente', synced == 0) la verifica [deshacerVentaServicio]
/// contra ops_queue: una op ya subida o con retención forzada no se
/// puede deshacer aunque no hayan pasado los 15 s.
bool puedeDeshacerVenta(DateTime cobradoEn, DateTime ahora) =>
    ahora.difference(cobradoEn) <= const Duration(seconds: 15) &&
    !ahora.isBefore(cobradoEn);

// ------------------------------------------------------------------
// Lecturas locales (espejo + pendientes)
// ------------------------------------------------------------------

Future<List<Map<String, dynamic>>> _opsServicioPendientes() async {
  final ops = await LocalDb.instance.pendingOps();
  const tipos = {
    'venta_servicio',
    'salida_servicio',
    'revertir_venta_servicio',
    'reponer_agua',
    'crear_lote_servicio',
    'reponer_pomo', // 1.15 (pomos)
    'abrir_bote_servicio',
    'cerrar_lote_servicio',
    'cerrar_bote_servicio',
  };
  return ops.where((o) => tipos.contains('${o['tipo']}')).toList();
}

Future<int> saldoLoteLocal(int loteId) async {
  final lotes = await LocalDb.instance.allMirror('servicio_lotes');
  final lote = lotes.where((l) => (l['id'] as num?)?.toInt() == loteId);
  if (lote.isEmpty) return 0;
  final ventas = (await LocalDb.instance.allMirror('servicio_ventas'))
      .where((v) => (v['lote_id'] as num?)?.toInt() == loteId)
      .toList();
  final salidas = (await LocalDb.instance.allMirror('servicio_salidas'))
      .where((s) => (s['lote_id'] as num?)?.toInt() == loteId)
      .toList();
  return saldoLoteDesde(
    lote: lote.first,
    ventasEspejo: ventas,
    salidasEspejo: salidas,
    opsPendientes: await _opsServicioPendientes(),
  );
}

Future<({int saldo, double cpp})> stockAguaLocal() async {
  final movs =
      await LocalDb.instance.allMirror('servicio_agua_movimientos');
  return aguaDesde(
    movimientosEspejo: movs,
    opsPendientes: await _opsServicioPendientes(),
  );
}

/// Lotes activos con su saldo local, del responsable indicado
/// (o todos si [responsableId] es null).
Future<List<Map<String, dynamic>>> lotesActivosLocal(
    {int? responsableId}) async {
  final lotes = await LocalDb.instance.allMirror('servicio_lotes');
  final ventas = await LocalDb.instance.allMirror('servicio_ventas');
  final salidas = await LocalDb.instance.allMirror('servicio_salidas');
  final ops = await _opsServicioPendientes();
  final out = <Map<String, dynamic>>[];
  for (final l in lotes) {
    if ('${l['estado']}' != 'activo') continue;
    if (responsableId != null &&
        LocalDb.normalizarTelegramId(l['responsable_id']) !=
            responsableId) {
      continue;
    }
    final id = (l['id'] as num?)?.toInt();
    if (id == null) continue;
    final saldo = saldoLoteDesde(
      lote: l,
      ventasEspejo:
          ventas.where((v) => (v['lote_id'] as num?)?.toInt() == id).toList(),
      salidasEspejo: salidas
          .where((s) => (s['lote_id'] as num?)?.toInt() == id)
          .toList(),
      opsPendientes: ops,
    );
    out.add({...l, 'saldo_local': saldo});
  }
  return out;
}

/// Saldo local de un pomo (espejo + pendientes).
Future<int> saldoPomoLocal(int pomoId) async {
  final pomos = await LocalDb.instance.allMirror('servicio_pomos');
  final pomo = pomos.where((l) => (l['id'] as num?)?.toInt() == pomoId);
  if (pomo.isEmpty) return 0;
  final ventas = (await LocalDb.instance.allMirror('servicio_ventas'))
      .where((v) => (v['pomo_id'] as num?)?.toInt() == pomoId)
      .toList();
  final salidas = (await LocalDb.instance.allMirror('servicio_salidas'))
      .where((s) => (s['pomo_id'] as num?)?.toInt() == pomoId)
      .toList();
  return saldoPomoDesde(
    pomo: pomo.first,
    ventasEspejo: ventas,
    salidasEspejo: salidas,
    opsPendientes: await _opsServicioPendientes(),
  );
}

/// Pomos activos con su saldo local, del titular indicado
/// (o todos si [titularId] es null). El principal viaja con
/// es_principal = 1; los de entrenador, con su titular_telegram_id.
Future<List<Map<String, dynamic>>> pomosActivosLocal(
    {int? titularId}) async {
  final pomos = await LocalDb.instance.allMirror('servicio_pomos');
  final ventas = await LocalDb.instance.allMirror('servicio_ventas');
  final salidas = await LocalDb.instance.allMirror('servicio_salidas');
  final ops = await _opsServicioPendientes();
  final out = <Map<String, dynamic>>[];
  for (final l in pomos) {
    if ((l['activo'] as num?)?.toInt() != 1) continue;
    if (titularId != null &&
        LocalDb.normalizarTelegramId(l['titular_telegram_id']) !=
            titularId) {
      continue;
    }
    final id = (l['id'] as num?)?.toInt();
    if (id == null) continue;
    final saldo = saldoPomoDesde(
      pomo: l,
      ventasEspejo:
          ventas.where((v) => (v['pomo_id'] as num?)?.toInt() == id).toList(),
      salidasEspejo: salidas
          .where((s) => (s['pomo_id'] as num?)?.toInt() == id)
          .toList(),
      opsPendientes: ops,
    );
    out.add({...l, 'saldo_local': saldo});
  }
  return out;
}

/// Dosis sin repartir de un bote (espejo): rendimiento − Σ lotes.
/// v1.13.0: las reposiciones también salen del «sin repartir» del
/// mismo bote (el lote repuesto crece a costa del pool sin asignar).
Future<int> sinRepartirLocal(int boteId) async {
  final botes = await LocalDb.instance.allMirror('servicio_botes');
  final bote =
      botes.where((b) => (b['id'] as num?)?.toInt() == boteId).toList();
  if (bote.isEmpty) return 0;
  final rend = (bote.first['dosis_rendimiento'] as num?)?.toInt() ?? 0;
  var repartidas = 0;
  for (final l in await LocalDb.instance.allMirror('servicio_lotes')) {
    if ((l['bote_id'] as num?)?.toInt() == boteId) {
      repartidas += (l['dosis_iniciales'] as num?)?.toInt() ?? 0;
      repartidas += (l['dosis_repuestas'] as num?)?.toInt() ?? 0;
      // Los sobrantes de lotes cerrados vuelven a «sin repartir».
      repartidas -= (l['conteo_cierre'] as num?)?.toInt() ?? 0;
    }
  }
  return rend - repartidas;
}

/// Ventas de servicios de un cliente (ficha, solo lectura),
/// recientes primero.
Future<List<Map<String, dynamic>>> historialServiciosCliente(
    int clienteId) async {
  final ventas = await LocalDb.instance.allMirror('servicio_ventas');
  final out = ventas
      .where((v) => (v['cliente_id'] as num?)?.toInt() == clienteId)
      .toList()
    ..sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
  return out;
}

/// Cuadre corto del día de un vendedor (diseño base §5): ventas del
/// día desde el espejo + sus ops de venta aún pendientes (las ops en
/// cola son del usuario del dispositivo por definición).
Future<Map<String, dynamic>> cuadreServiciosDia(
    int telegramId, String fechaIso) async {
  var dosisSin = 0, dosisCon = 0, aguas = 0, casaN = 0;
  var efectivo = 0.0, transferencia = 0.0, comision = 0.0;
  // Ítem 8: el cuadre se reparte por ROLES — las ventas cuentan al
  // VENDEDOR, el efectivo a entregar al RESPONSABLE y la comisión a
  // quien la gana. Sin columnas de roles (filas previas al ítem 8)
  // todo recae en quien registró, como antes.
  void sumar(
      String tipo,
      int cant,
      double precio,
      double com,
      double? montoCom,
      String? metodo,
      bool esCasa,
      int? vendedor,
      int? responsable,
      int? comisionero) {
    if (esCasa) {
      if (vendedor == telegramId) casaN += cant;
      return;
    }
    if (vendedor == telegramId) {
      switch (tipo) {
        case 'dosis_sin_agua':
          dosisSin += cant;
        case 'dosis_con_agua':
          dosisCon += cant;
        case 'agua_suelta':
          aguas += cant;
      }
      if (metodo == 'transferencia') {
        transferencia += precio * cant;
      }
    }
    if (metodo != 'transferencia' && responsable == telegramId) {
      efectivo += precio * cant;
    }
    if (comisionero == telegramId) {
      comision += montoCom ?? com * cant;
    }
  }

  final uuidsEspejo = <String>{};
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    uuidsEspejo.add('${v['op_uuid'] ?? ''}');
    if ('${v['fecha'] ?? ''}'.length >= 10 &&
        '${v['fecha']}'.substring(0, 10) == fechaIso) {
      final reg = LocalDb.normalizarTelegramId(v['registrado_por']);
      sumar(
        '${v['tipo']}',
        (v['cantidad'] as num?)?.toInt() ?? 0,
        (v['precio_unitario'] as num?)?.toDouble() ?? 0,
        (v['comision_unitaria'] as num?)?.toDouble() ?? 0,
        (v['comision_monto'] as num?)?.toDouble(),
        v['metodo'] as String?,
        (v['casa'] as num?)?.toInt() == 1,
        LocalDb.normalizarTelegramId(v['vendedor_id']) ?? reg,
        LocalDb.normalizarTelegramId(v['responsable_efectivo_id']) ??
            reg,
        LocalDb.normalizarTelegramId(v['comision_entrenador_id']) ??
            reg,
      );
    }
  }
  for (final op in await _opsServicioPendientes()) {
    if ('${op['tipo']}' != 'venta_servicio') continue;
    if (uuidsEspejo.contains('${op['op_uuid'] ?? ''}')) continue;
    final p = _payloadDeOp(op);
    if ('${p['fecha'] ?? ''}' != '' && '${p['fecha']}' != fechaIso) {
      continue;
    }
    final reg = (op['telegram_id'] as num?)?.toInt();
    final vend = (p['vendedor_id'] as num?)?.toInt() ?? reg;
    sumar(
      '${p['tipo']}',
      (p['cantidad'] as num?)?.toInt() ?? 1,
      (p['precio_unitario'] as num?)?.toDouble() ?? 0,
      (p['comision_unitaria'] as num?)?.toDouble() ?? 0,
      (p['comision_monto'] as num?)?.toDouble(),
      p['metodo'] as String?,
      p['casa'] == true,
      vend,
      (p['responsable_efectivo_id'] as num?)?.toInt() ?? vend,
      vend,
    );
  }
  return {
    'dosis_sin_agua': dosisSin,
    'dosis_con_agua': dosisCon,
    'agua_suelta': aguas,
    'casa': casaN,
    'efectivo': efectivo,
    'transferencia': transferencia,
    'comision': comision,
  };
}

// ------------------------------------------------------------------
// Acciones (encolan la op y disparan push)
// ------------------------------------------------------------------

Future<String> _encolar(String tipo, Map<String, dynamic> payload,
    {String? retenerHastaIso}) async {
  final opUuid = const Uuid().v4();
  await LocalDb.instance.queueOp(
      opUuid: opUuid,
      tipo: tipo,
      payload: payload,
      retenerHastaIso: retenerHastaIso);
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return opUuid;
}

/// v1.13.0 (E3): Deshacer de una venta de dosis (simple o múltiple).
/// Borra TODAS las ops del grupo de la cola si y solo si: no pasaron
/// 15 s exactos desde el cobro Y cada op sigue 'pendiente'
/// (synced == 0: aún no subió; la retención de 15 s lo garantiza
/// salvo «Subir ahora» forzado). Si alguna ya subió, no se toca
/// nada y solo cabe Reversión (D3). Devuelve true si deshizo.
Future<bool> deshacerVentaServicio(
    List<String> opUuids, DateTime cobradoEn) async {
  if (!puedeDeshacerVenta(cobradoEn, ahoraHabana())) return false;
  final db = LocalDb.instance;
  for (final uuid in opUuids) {
    final op = await db.opEnCola(uuid);
    if (op == null || '${op['estado']}' != 'pendiente') return false;
  }
  for (final uuid in opUuids) {
    await db.deleteOp(uuid);
  }
  return true;
}

/// Solo dueño (lo impone el servidor): abre un bote del catálogo.
Future<String> abrirBoteServicio({
  required int suplementoId,
  required int dosisRendimiento,
  double? costoBote,
}) async {
  if (dosisRendimiento < 1) {
    throw Exception('El rendimiento debe ser al menos 1 dosis');
  }
  return _encolar('abrir_bote_servicio', {
    'suplemento_id': suplementoId,
    'dosis_rendimiento': dosisRendimiento,
    if (costoBote != null) 'costo_bote': costoBote,
  });
}

/// Solo dueño: reparte dosis de un bote a un responsable.
Future<String> crearLoteServicio({
  required int boteId,
  required int dosis,
  required String responsableTipo, // 'entrenador' | 'dueno'
  required int responsableId,
}) async {
  if (dosis < 1) throw Exception('El lote debe tener al menos 1 dosis');
  final sinRepartir = await sinRepartirLocal(boteId);
  if (dosis > sinRepartir) {
    throw Exception('Solo quedan $sinRepartir dosis sin repartir');
  }
  return _encolar('crear_lote_servicio', {
    'bote_id': boteId,
    'dosis': dosis,
    'responsable_tipo': responsableTipo,
    'responsable_id': responsableId,
  });
}

/// Edad del cliente identificado desde su carnet (null si no se
/// puede saber). Única fuente: [fechaNacDeCarnet] de negocio.dart.
int? _edadCliente(Map<String, dynamic> cliente) {
  final nac = fechaNacDeCarnet(cliente['carnet'] as String?);
  if (nac == null) return null;
  final hoy = ahoraHabana();
  var edad = hoy.year - nac.year;
  if (hoy.month < nac.month ||
      (hoy.month == nac.month && hoy.day < nac.day)) {
    edad--;
  }
  return edad;
}

/// Registra una venta de servicio (o consumo Casa). Único punto de
/// venta de servicios de la app, como manda el patrón de la casa.
///
/// v1.13.0: [cantidad] > 1 en dosis solo con [ventaGrupoId] (venta
/// múltiple B2: 1 op por subtipo con el mismo grupo). Las ventas de
/// dosis nacen RETENIDAS 15 s (retenerHastaIso, como el cobro del
/// Bloque 1): es la ventana de Deshacer E3; al vencer, el push las
/// Payload de una venta de servicio: TODAS las validaciones y
/// lecturas, SIN escribir nada. La venta múltiple calcula los
/// payloads de sus subventas primero (si uno falla, no se encola
/// ninguno) y luego encola todos en UNA transacción.
/// Corrección panel 1.13 (2º intento): la 1ª versión pasaba la
/// transacción a registrarVentaServicio, pero sus lecturas por
/// `LocalDb.instance.db` dentro del callback se bloqueaban con
/// la transacción abierta (deadlock de sqflite: el test de
/// bloque4 se quedó colgado sin CPU). Las lecturas van FUERA
/// de la transacción; dentro solo van los queueOp.
Future<({Map<String, dynamic> payload, String? retener})>
    _payloadVentaServicio({
  required String tipo, // dosis_sin_agua | dosis_con_agua | agua_suelta
  int? pomoId,
  int cantidad = 1,
  int? clienteId,
  String? metodo, // 'efectivo' | 'transferencia' (no Casa)
  bool casa = false,
  String? beneficiario, // 'dueno' si Casa para el dueño
  // Ítem 8: «vendedorEsDueno» describe al VENDEDOR (no a quien
  // registra): true si quien vende es el dueño. Los demás roles
  // solo los envía el dueño al vender «a nombre de» otro.
  required bool vendedorEsDueno,
  int? vendedorId,
  int? responsableEfectivoId,
  double? comisionUnitaria,
  // v1.13.0 (B2): grupo de venta múltiple; obligatorio si cantidad
  // > 1 en dosis. Viaja en el payload para Deshacer y servidor.
  String? ventaGrupoId,
}) async {
  if (!kTiposVentaServicio.contains(tipo)) {
    throw Exception('Tipo de servicio inválido');
  }
  if (cantidad < 1) throw Exception('Cantidad inválida');
  if (tipo != 'agua_suelta' && cantidad != 1 && ventaGrupoId == null) {
    throw Exception(
        'La dosis se vende de una en una; para varias usa venta múltiple');
  }
  final db = LocalDb.instance;
  Map<String, dynamic>? cliente;
  if (clienteId != null) {
    final filas = await db.mirrorPorIds('clientes', [clienteId]);
    if (filas.isEmpty) throw Exception('Cliente no encontrado');
    cliente = filas.first;
  }
  // Bloqueo <15 en dosis identificada (regla de venta responsable).
  if (tipo != 'agua_suelta' && cliente != null) {
    final edad = _edadCliente(cliente);
    if (edad != null && edad < 15) {
      throw Exception(
          'Venta bloqueada: ${cliente['nombre']} tiene $edad años '
          '(no se vende pre-entreno a menores de 15)');
    }
  }
  if (casa) {
    // Panel Grupo B V7: beneficiario 'dueno' solo sin cliente y
    // vendiendo el dueño (defensa en profundidad: la UI ya lo
    // impide, pero el helper no debe confiar en el llamador).
    if (beneficiario == 'dueno' &&
        (cliente != null || !vendedorEsDueno)) {
      throw Exception(
          'Casa para el dueño: sin cliente y solo la marca el dueño');
    }
    final esCasaCliente =
        cliente != null && (cliente['cuenta_casa'] as num?)?.toInt() == 1;
    if (beneficiario != 'dueno' && !esCasaCliente) {
      throw Exception(
          'La Cuenta a la Casa solo aplica a clientes con la cuenta '
          'otorgada o al dueño');
    }
  } else {
    if (metodo != 'efectivo' && metodo != 'transferencia') {
      throw Exception('Elige el método de cobro');
    }
  }
  // Pomo y saldo local (bloqueo en el teléfono si el saldo es 0).
  if (tipo != 'agua_suelta') {
    if (pomoId == null) throw Exception('Falta el pomo de venta');
    final pomos = await db.allMirror('servicio_pomos');
    final pomo =
        pomos.where((l) => (l['id'] as num?)?.toInt() == pomoId).toList();
    if (pomo.isEmpty || (pomo.first['activo'] as num?)?.toInt() != 1) {
      throw Exception('El pomo no está activo');
    }
    final saldo = await saldoPomoLocal(pomoId);
    // Ítem 6 (pomo ciego): el bloqueo por saldo local solo aplica
    // cuando vende el DUEÑO (él sí conoce la cantidad de su pomo).
    // Al entrenador no se le bloquea ni se le revela el saldo: el
    // servidor nunca rechaza la venta por stock teórico (A3).
    if (saldo <= 0 && vendedorEsDueno) {
      throw Exception('El pomo no tiene dosis disponibles');
    }
  }
  // Agua común: se bloquea la variante si no hay pomos.
  if (tipo == 'dosis_con_agua' || tipo == 'agua_suelta') {
    final agua = await stockAguaLocal();
    if (agua.saldo < cantidad) {
      throw Exception('Sin pomos de agua en el stock común');
    }
  }
  final pr = await preciosServicios();
  // Ítem 7: el precio sale del (producto, método) vigente y viaja
  // como snapshot en la op — si el dueño cambia precios o deshabilita
  // el método después, el servidor acepta la venta tal cual se cobró.
  final aj = await LocalDb.instance.getAjustes();
  if (!casa && !metodoServicioActivo(aj, tipo, metodo!)) {
    throw Exception(
        'Ese método de cobro está deshabilitado para este producto');
  }
  final double precio =
      casa ? 0 : precioServicioMetodo(aj, tipo, metodo!);
  if (!casa && precio <= 0) {
    throw Exception(
        'El precio de este servicio aún no está fijado '
        '(Administración → Servicios)');
  }
  // A5: comisión 0 en agua suelta y cuando el VENDEDOR es el dueño.
  // Ítem 8: la UI del dueño puede fijar otra comisión para esta
  // venta «a nombre de» (comisionUnitaria ya la trae calculada).
  final comision = comisionUnitaria ??
      ((casa || tipo == 'agua_suelta' || vendedorEsDueno)
          ? 0.0
          : pr.comision);
  // v1.13.0 (E3): la venta de dosis nace retenida 15 s exactos para
  // la ventana de Deshacer; el agua suelta sube de inmediato (sin
  // Deshacer especificado para ella).
  final retener = tipo == 'agua_suelta'
      ? null
      : isoHabana(ahoraHabana().add(const Duration(seconds: 15)));
  // v1.13.0 (Estadísticas C): la hora Habana de la venta viaja en el
  // payload para la agrupación por franja (las ventas viejas no la
  // traen y caen en «Sin hora registrada»).
  final ahora = ahoraHabana();
  final horaTxt =
      '${ahora.hour.toString().padLeft(2, '0')}:${ahora.minute.toString().padLeft(2, '0')}';
  return (
    payload: {
      if (tipo != 'agua_suelta') 'pomo_id': pomoId,
      'tipo': tipo,
      'cantidad': cantidad,
      if (clienteId != null) 'cliente_id': clienteId,
      if (casa) 'casa': true,
      if (casa && beneficiario != null) 'beneficiario': beneficiario,
      if (!casa) 'metodo': metodo,
      'precio_unitario': precio,
      'comision_unitaria': comision,
      if (vendedorId != null) 'vendedor_id': vendedorId,
      if (responsableEfectivoId != null)
        'responsable_efectivo_id': responsableEfectivoId,
      if (ventaGrupoId != null) 'venta_grupo_id': ventaGrupoId,
      'fecha': hoyHabanaIso(),
      'hora': horaTxt,
    },
    retener: retener,
  );
}

/// toma normal. Devuelve el op_uuid de la op encolada.
Future<String> registrarVentaServicio({
  required String tipo,
  int? pomoId,
  int cantidad = 1,
  int? clienteId,
  String? metodo,
  bool casa = false,
  String? beneficiario,
  required bool vendedorEsDueno,
  int? vendedorId,
  int? responsableEfectivoId,
  double? comisionUnitaria,
  String? ventaGrupoId,
}) async {
  final calc = await _payloadVentaServicio(
    tipo: tipo,
    pomoId: pomoId,
    cantidad: cantidad,
    clienteId: clienteId,
    metodo: metodo,
    casa: casa,
    beneficiario: beneficiario,
    vendedorEsDueno: vendedorEsDueno,
    vendedorId: vendedorId,
    responsableEfectivoId: responsableEfectivoId,
    comisionUnitaria: comisionUnitaria,
    ventaGrupoId: ventaGrupoId,
  );
  final opUuid = const Uuid().v4();
  await LocalDb.instance.queueOp(
      opUuid: opUuid,
      tipo: 'venta_servicio',
      payload: calc.payload,
      retenerHastaIso: calc.retener);
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return opUuid;
}

/// v1.13.0 (B2): venta múltiple de dosis desde Servicios.
/// N dosis (2 ≤ N ≤ topeDosis) con M pomos (0 ≤ M ≤ N, topado a
/// topePomos). En sync_ops es UN grupo transaccional con
/// `venta_grupo_id` común: 1 op si M == 0 (sin agua × N) o M == N
/// (con agua × N); 2 ops si 0 < M < N (con agua × M + sin agua ×
/// (N−M)). Deshacer E3 borra el grupo completo. Devuelve los
/// op_uuids del grupo.
Future<List<String>> registrarVentaMultipleServicio({
  required int pomoId,
  required int dosisN,
  required int pomosM,
  int? clienteId,
  String? metodo,
  bool casa = false,
  String? beneficiario,
  required bool vendedorEsDueno,
  int? vendedorId,
  int? responsableEfectivoId,
  double? comisionUnitaria,
  required int topeDosis,
  required int topePomos,
}) async {
  if (dosisN < 2) {
    throw Exception('La venta múltiple es de 2 dosis en adelante');
  }
  if (dosisN > topeDosis) {
    throw Exception('Solo quedan $topeDosis dosis en el pomo');
  }
  if (pomosM < 0 || pomosM > dosisN) {
    throw Exception('Los pomos van de 0 a $dosisN');
  }
  if (pomosM > topePomos) {
    throw Exception('Solo quedan $topePomos pomos de agua');
  }
  final grupo = const Uuid().v4();
  // Corrección panel 1.13 (BLOQUEANTE): primero se calculan los
  // payloads de las subventas (lecturas + validaciones, sin
  // escribir); si uno falla, no se encola ninguno. Luego los
  // queueOp van en UNA transacción y el push una sola vez al
  // final. Antes cada subventa encolaba y empujaba por su lado:
  // una caída entre ambas dejaba el grupo a medias y el Deshacer
  // no podía garantizar borrarlo completo.
  Future<({Map<String, dynamic> payload, String? retener})> una(
      String tipo, int cant) {
    return _payloadVentaServicio(
      tipo: tipo,
      pomoId: pomoId,
      cantidad: cant,
      clienteId: clienteId,
      metodo: metodo,
      casa: casa,
      beneficiario: beneficiario,
      vendedorEsDueno: vendedorEsDueno,
      vendedorId: vendedorId,
      responsableEfectivoId: responsableEfectivoId,
      comisionUnitaria: comisionUnitaria,
      ventaGrupoId: grupo,
    );
  }

  final List<({Map<String, dynamic> payload, String? retener})> calcs;
  if (pomosM == 0) {
    calcs = [await una('dosis_sin_agua', dosisN)];
  } else if (pomosM == dosisN) {
    calcs = [await una('dosis_con_agua', dosisN)];
  } else {
    calcs = [
      await una('dosis_con_agua', pomosM),
      await una('dosis_sin_agua', dosisN - pomosM),
    ];
  }
  final uuids = <String>[];
  final db = await LocalDb.instance.db;
  await db.transaction((txn) async {
    for (final c in calcs) {
      final opUuid = const Uuid().v4();
      await LocalDb.instance.queueOp(
          opUuid: opUuid,
          tipo: 'venta_servicio',
          payload: c.payload,
          retenerHastaIso: c.retener,
          txn: txn);
      uuids.add(opUuid);
    }
  });
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return uuids;
}

/// Salida sin venta contra un pomo. Cortesía y consumo de staff los
/// impone el servidor como solo-dueño; la UI también los gatea.
Future<String> registrarSalidaServicio({
  required int pomoId,
  required int dosis,
  required String motivo, // merma | cortesia | consumo_staff | ajuste
  String? nota,
}) async {
  if (dosis < 1) throw Exception('La salida debe ser de al menos 1 dosis');
  return _encolar('salida_servicio', {
    'pomo_id': pomoId,
    'dosis': dosis,
    'motivo': motivo,
    if (nota != null && nota.isNotEmpty) 'nota': nota,
    'fecha': hoyHabanaIso(),
  });
}

/// Ítem 11 (post-1.8.0, Argón): salida sin venta del stock común de
/// AGUA (merma, rotura, cortesía...). Solo el dueño — el servidor lo
/// re-impone. La op viaja con tipo_item='agua' y sin lote_id: el
/// servidor la registra en servicio_salidas (lote NULL) enlazada a su
/// movimiento de kardex.
Future<String> registrarSalidaAguaServicio({
  required int cantidad,
  required String motivo, // merma | cortesia | consumo_staff | ajuste
  String? nota,
}) async {
  if (cantidad < 1) throw Exception('La salida debe ser de al menos 1 pomo');
  return _encolar('salida_servicio', {
    'tipo_item': 'agua',
    'cantidad': cantidad,
    'motivo': motivo,
    if (nota != null && nota.isNotEmpty) 'nota': nota,
    'fecha': hoyHabanaIso(),
  });
}

/// Reverso auditable de una venta ya espejada (la UI solo lo ofrece
/// sobre filas del espejo; el servidor valida el resto).
///
/// v1.13.0 (D3, Híbrido A de la 1.9.0): [motivo] OBLIGATORIO y viaja
/// en el payload (el servidor lo guarda con el reverso). El servidor
/// debe: descontar caja, restar la comisión (50 × cantidad), devolver
/// la dosis al lote activo y el pomo al agua común, y BLOQUEAR el
/// reverso si el pomo ya fue desactivado por el dueño (la UI también lo
/// bloquea con el motivo visible). Si [polvoPerdido] es true, la
/// dosis no volvió físicamente: tras el reverso se encola una salida
/// no vendida (merma) por la misma cantidad, así el lote queda neto
/// en cero y la pérdida queda registrada.
Future<List<String>> revertirVentaServicio({
  required int ventaId,
  required String motivo,
  bool polvoPerdido = false,
  // Solo para polvoPerdido: pomo y cantidad de la venta original
  // (la UI los tiene de la fila del espejo).
  int? pomoId,
  int? cantidad,
}) async {
  if (motivo.trim().isEmpty) {
    throw Exception('La reversión exige un motivo');
  }
  // Corrección panel 1.13 (BLOQUEANTE/ALTO): validar ANTES de
  // encolar. Antes el reverso se encolaba (y empujaba) primero y
  // la validación de lote/cantidad venía después: si faltaban,
  // la excepción dejaba el reverso encolado sin su merma.
  if (polvoPerdido &&
      (pomoId == null || cantidad == null || cantidad < 1)) {
    throw Exception(
        'Para registrar la pérdida hace falta el pomo y la cantidad');
  }
  final uuids = <String>[
    await _encolar('revertir_venta_servicio', {
      'venta_id': ventaId,
      'motivo': motivo.trim(),
      if (polvoPerdido) 'polvo_perdido': true,
    }),
  ];
  if (polvoPerdido) {
    uuids.add(await _encolar('salida_servicio', {
      'pomo_id': pomoId,
      'dosis': cantidad,
      'motivo': 'merma',
      'nota': 'Pérdida física tras reversión de venta #$ventaId',
      'fecha': hoyHabanaIso(),
      // Corrección panel 1.13: la merma va ligada a su venta.
      // El servidor la rechaza si el reverso aún no se aplicó
      // (lote cerrado entre tanto, reverso rechazado): sin este
      // enlace, la merma podía aplicarse sola, fantasma.
      'venta_id': ventaId,
    }));
  }
  return uuids;
}

/// v1.13.0 (Bloque 4, Argón ajuste 3): reponer un lote SOLO el dueño,
/// desde el «sin repartir» del MISMO bote. Op nueva `reponer_lote`
/// (CHECK previo, otra vía) + reflejo optimista inmediato en el
/// espejo local: la fila del lote suma X a `dosis_repuestas`, así el
/// saldo y el «sin repartir» se actualizan sin esperar al pull.
/// Op y espejo se escriben en UNA transacción (si el proceso muere
/// entre ambos, no queda ni op sin espejo ni espejo sin op). Si el
/// servidor rechaza la op, el gancho de rechazo (sync.dart)
/// revierte el optimismo.
Future<String> reponerLoteServicio({
  required int loteId,
  required int dosis,
}) async {
  if (dosis < 1) throw Exception('La reposición debe ser de al menos 1 dosis');
  final db = LocalDb.instance;
  final lotes = await db.allMirror('servicio_lotes');
  final lote =
      lotes.where((l) => (l['id'] as num?)?.toInt() == loteId).toList();
  if (lote.isEmpty || '${lote.first['estado']}' != 'activo') {
    throw Exception('El lote no está activo');
  }
  final boteId = (lote.first['bote_id'] as num?)?.toInt();
  if (boteId == null) throw Exception('El lote no tiene bote');
  final sinRepartir = await sinRepartirLocal(boteId);
  if (dosis > sinRepartir) {
    throw Exception('Solo quedan $sinRepartir dosis sin repartir');
  }
  final opUuid = const Uuid().v4();
  final conn = await db.db;
  await conn.transaction((txn) async {
    await db.queueOp(
      opUuid: opUuid,
      tipo: 'reponer_lote',
      payload: {
        'lote_id': loteId,
        'bote_id': boteId,
        'dosis': dosis,
        'fecha': hoyHabanaIso(),
      },
      txn: txn,
    );
    await db.actualizarDosisRepuestasLote(loteId, dosis, txn: txn);
  });
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return opUuid;
}

/// 1.15 (pomos): rellenar el pomo de un entrenador SOLO el dueño.
/// Op `reponer_pomo` (CHECK 87): el servidor mueve N dosis del
/// principal al destino en una transacción y rechaza si el
/// principal no alcanza. SIN reflejo optimista en el espejo: el
/// saldo local deriva el relleno pendiente desde ops_queue
/// (saldoPomoDesde), así un rechazo no deja espejo que revertir.
/// La pre-comprobación local replica el rechazo del servidor para
/// avisar al dueño antes de encolar (mismo mensaje exacto).
Future<String> reponerPomoServicio({
  required int pomoDestinoId,
  required int dosis,
}) async {
  if (dosis < 1) throw Exception('El relleno debe ser de al menos 1 dosis');
  final db = LocalDb.instance;
  final pomos = await db.allMirror('servicio_pomos');
  final destino = pomos
      .where((l) => (l['id'] as num?)?.toInt() == pomoDestinoId)
      .toList();
  if (destino.isEmpty || (destino.first['activo'] as num?)?.toInt() != 1) {
    throw Exception('El pomo destino no está activo');
  }
  if ((destino.first['es_principal'] as num?)?.toInt() == 1) {
    throw Exception('No se rellena el propio principal');
  }
  final suplementoId = (destino.first['suplemento_id'] as num?)?.toInt();
  final principal = pomos
      .where((l) =>
          (l['es_principal'] as num?)?.toInt() == 1 &&
          (l['suplemento_id'] as num?)?.toInt() == suplementoId)
      .toList();
  if (principal.isEmpty) {
    throw Exception('No hay pomo principal para este producto');
  }
  final saldoPrincipal =
      await saldoPomoLocal((principal.first['id'] as num).toInt());
  if (dosis > saldoPrincipal) {
    throw Exception('El principal solo tiene $saldoPrincipal dosis');
  }
  return _encolar('reponer_pomo', {
    'pomo_destino_id': pomoDestinoId,
    'dosis': dosis,
    // Panel Luna: sin el producto, un relleno pendiente restaba
    // del principal de CUALQUIER producto al derivar saldos.
    'suplemento_id': suplementoId,
    'fecha': hoyHabanaIso(),
  });
}

/// Solo dueño: repone el stock común de agua con su costo (CPP).
Future<String> reponerAguaServicio({
  required int cantidad,
  required double costoUnitario,
}) async {
  if (cantidad < 1) throw Exception('La reposición debe ser de al menos 1 pomo');
  if (costoUnitario <= 0) throw Exception('El costo debe ser mayor que 0');
  return _encolar('reponer_agua', {
    'cantidad': cantidad,
    'costo_unitario': costoUnitario,
  });
}

/// Solo dueño: cierra el lote con conteo físico (Argón A1).
Future<String> cerrarLoteServicio({
  required int loteId,
  required int conteoFisico,
}) async {
  if (conteoFisico < 0) throw Exception('El conteo no puede ser negativo');
  return _encolar('cerrar_lote_servicio', {
    'lote_id': loteId,
    'conteo_fisico': conteoFisico,
  });
}

/// Solo dueño: sella el bote (Argón A2).
Future<String> cerrarBoteServicio({required int boteId}) async {
  return _encolar('cerrar_bote_servicio', {'bote_id': boteId});
}

/// post-1.8.0 (ítem 9, Argón): ranking de compradores de Servicios.
/// PURO (testeable): recibe las filas del espejo `servicio_ventas`.
///
/// Reglas: solo ventas identificadas (`cliente_id` no nulo); los
/// reversos (cantidad negativa) netean contra su cliente; queda
/// fuera quien netee ≤ 0 CUP; orden por monto neto desc y, a
/// igualdad, por unidades netas desc. Las columnas cuentan UNIDADES
/// netas por subtipo: raciones solas, combos y agua suelta (en la
/// ficha del cliente el combo cuenta además como dosis + pomo: son
/// dos lecturas distintas, no una discrepancia).
/// [desde] (prefijo 'YYYY-MM-DD') limita a ventas con fecha >= desde.
/// 1.14 (D13): [nombresPorId] es el padrón local (espejo clientes)
/// para resolver el nombre cuando la fila de venta no lo trae: sin
/// él, las ventas viejas (anteriores al enriquecimiento del puente)
/// quedaban como «Cliente 121» anónimo. Patrón de
/// detalle_entrenador.dart. Las fotos en el ranking quedan para
/// después (lista de Argón): aquí solo se arregla el nombre.
/// Ventas de servicio sin reversos ni ventas ya reversadas (Argón #9,
/// ALTO parcial). El servidor crea el reverso con cantidad NEGATIVA y
/// el mismo lote_id, así que las sumas de una misma ventana ya netean
/// solas; pero un reverso cae en su propio día (fecha = hoy), no en
/// el de la venta original: en estadísticas por periodo/semana/día y
/// en el extracto, la ventana de la original quedaba sobreestimada
/// (y la del reverso, en negativo sola). Para estadísticas, una
/// venta reversada es como si no hubiera ocurrido: fuera la fila de
/// reverso (reverso_de != null) y fuera la original reversada.
/// PURO. La pista de auditoría completa sigue viva en ServiciosScreen
/// (fila original + fila «Reverso»).
List<Map<String, dynamic>> ventasServicioSinReversos(
    List<Map<String, dynamic>> ventas) {
  final reversadas = <int>{
    for (final v in ventas)
      if ((v['reverso_de'] as num?) != null)
        (v['reverso_de'] as num).toInt(),
  };
  return ventas.where((v) {
    if ((v['reverso_de'] as num?) != null) return false;
    final id = (v['id'] as num?)?.toInt();
    if (id != null && reversadas.contains(id)) return false;
    return true;
  }).toList();
}

List<Map<String, dynamic>> rankingServicios(
  List<Map<String, dynamic>> ventas, {
  String? desde,
  Map<int, String>? nombresPorId,
}) {
  String nombreDe(int cid, Map<String, dynamic> v) {
    final propio = '${v['cliente_nombre'] ?? ''}'.trim();
    if (propio.isNotEmpty) return propio;
    final local = nombresPorId?[cid];
    if (local != null && local.trim().isNotEmpty) return local;
    return 'Cliente $cid';
  }

  final porCliente = <int, Map<String, dynamic>>{};
  for (final v in ventas) {
    final cid = (v['cliente_id'] as num?)?.toInt();
    if (cid == null) continue;
    // Argón #9 (BAJO): el ranking mide compradores COMERCIALES.
    // Las cortesías Casa (casa == 1, precio 0) no suman unidades ni
    // raciones/combos: un cliente con compras + cortesías veía sus
    // cortesías inflando el ranking. (resumenServiciosDeCliente sí
    // las cuenta como consumo recibido; aquí no.)
    if ((v['casa'] as num?)?.toInt() == 1) continue;
    if (desde != null && '${v['fecha'] ?? ''}'.compareTo(desde) < 0) {
      continue;
    }
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final monto =
        ((v['precio_unitario'] as num?)?.toDouble() ?? 0) * cant;
    final e = porCliente.putIfAbsent(cid, () => {
          'cliente_id': cid,
          'cliente_nombre': nombreDe(cid, v),
          'monto': 0.0,
          'unidades': 0,
          'raciones': 0,
          'combos': 0,
          'aguas': 0,
        });
    e['monto'] = (e['monto'] as double) + monto;
    e['unidades'] = (e['unidades'] as int) + cant;
    switch ('${v['tipo']}') {
      case 'dosis_con_agua':
        e['combos'] = (e['combos'] as int) + cant;
      case 'agua_suelta':
        e['aguas'] = (e['aguas'] as int) + cant;
      default:
        e['raciones'] = (e['raciones'] as int) + cant;
    }
    // La fila propia manda si trae nombre; si no, el padrón local
    // rescata una fila que nació anónima — pero una fila vacía
    // jamás debe tapar un nombre ya resuelto con «Cliente $cid».
    final propio = '${v['cliente_nombre'] ?? ''}'.trim();
    if (propio.isNotEmpty) {
      e['cliente_nombre'] = propio;
    } else {
      final local = nombresPorId?[cid]?.trim() ?? '';
      if (local.isNotEmpty && e['cliente_nombre'] == 'Cliente $cid') {
        e['cliente_nombre'] = local;
      }
    }
  }
  final lista = porCliente.values
      .where((e) => (e['monto'] as double) > 0)
      .toList()
    ..sort((a, b) {
      final c = (b['monto'] as double).compareTo(a['monto'] as double);
      if (c != 0) return c;
      return (b['unidades'] as int).compareTo(a['unidades'] as int);
    });
  return lista;
}
