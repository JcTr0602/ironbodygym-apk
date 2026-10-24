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
/// (iniciales − ventas − salidas), nunca se guarda. El agua es stock
/// común con costo promedio ponderado (CPP). Las ventas NO se
/// insertan en el espejo local: viven en ops_queue hasta que el
/// servidor las confirma y bajan por pull (mismo patrón que
/// ventas_suplementos); los cálculos locales suman espejo + ops
/// pendientes aún no espejadas (por op_uuid, sin doble conteo).
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
int saldoLoteDesde({
  required Map<String, dynamic> lote,
  required List<Map<String, dynamic>> ventasEspejo,
  required List<Map<String, dynamic>> salidasEspejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  var saldo = (lote['dosis_iniciales'] as num?)?.toInt() ?? 0;
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

/// Dosis sin repartir de un bote (espejo): rendimiento − Σ lotes.
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

Future<String> _encolar(String tipo, Map<String, dynamic> payload) async {
  final opUuid = const Uuid().v4();
  await LocalDb.instance
      .queueOp(opUuid: opUuid, tipo: tipo, payload: payload);
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return opUuid;
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
Future<String> registrarVentaServicio({
  required String tipo, // dosis_sin_agua | dosis_con_agua | agua_suelta
  int? loteId,
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
}) async {
  if (!kTiposVentaServicio.contains(tipo)) {
    throw Exception('Tipo de servicio inválido');
  }
  if (cantidad < 1) throw Exception('Cantidad inválida');
  if (tipo != 'agua_suelta' && cantidad != 1) {
    throw Exception('La dosis se vende de una en una');
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
  // Lote y saldo local (bloqueo en el teléfono si el saldo es 0).
  if (tipo != 'agua_suelta') {
    if (loteId == null) throw Exception('Falta el lote de venta');
    final lotes = await db.allMirror('servicio_lotes');
    final lote =
        lotes.where((l) => (l['id'] as num?)?.toInt() == loteId).toList();
    if (lote.isEmpty || '${lote.first['estado']}' != 'activo') {
      throw Exception('El lote no está activo');
    }
    final saldo = await saldoLoteLocal(loteId);
    // Ítem 6 (lote ciego): el bloqueo por saldo local solo aplica
    // cuando vende el DUEÑO (él sí conoce la cantidad de su pomo).
    // Al entrenador no se le bloquea ni se le revela el saldo: el
    // servidor nunca rechaza la venta por stock teórico (A3).
    if (saldo <= 0 && vendedorEsDueno) {
      throw Exception('El lote no tiene dosis disponibles');
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
  return _encolar('venta_servicio', {
    if (tipo != 'agua_suelta') 'lote_id': loteId,
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
    'fecha': hoyHabanaIso(),
  });
}

/// Salida sin venta contra un lote. Cortesía y consumo de staff los
/// impone el servidor como solo-dueño; la UI también los gatea.
Future<String> registrarSalidaServicio({
  required int loteId,
  required int dosis,
  required String motivo, // merma | cortesia | consumo_staff | ajuste
  String? nota,
}) async {
  if (dosis < 1) throw Exception('La salida debe ser de al menos 1 dosis');
  return _encolar('salida_servicio', {
    'lote_id': loteId,
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
Future<String> revertirVentaServicio({required int ventaId}) async {
  return _encolar('revertir_venta_servicio', {'venta_id': ventaId});
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
