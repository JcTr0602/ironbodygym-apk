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
  void sumar(String tipo, int cant, double precio, double com,
      String? metodo, bool esCasa) {
    if (esCasa) {
      casaN += cant;
      return;
    }
    switch (tipo) {
      case 'dosis_sin_agua':
        dosisSin += cant;
      case 'dosis_con_agua':
        dosisCon += cant;
      case 'agua_suelta':
        aguas += cant;
    }
    comision += com * cant;
    if (metodo == 'transferencia') {
      transferencia += precio * cant;
    } else {
      efectivo += precio * cant;
    }
  }

  final uuidsEspejo = <String>{};
  for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
    uuidsEspejo.add('${v['op_uuid'] ?? ''}');
    if (LocalDb.normalizarTelegramId(v['registrado_por']) != telegramId) {
      continue;
    }
    if ('${v['fecha'] ?? ''}'.length >= 10 &&
        '${v['fecha']}'.substring(0, 10) == fechaIso) {
      sumar(
        '${v['tipo']}',
        (v['cantidad'] as num?)?.toInt() ?? 0,
        (v['precio_unitario'] as num?)?.toDouble() ?? 0,
        (v['comision_unitaria'] as num?)?.toDouble() ?? 0,
        v['metodo'] as String?,
        (v['casa'] as num?)?.toInt() == 1,
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
    sumar(
      '${p['tipo']}',
      (p['cantidad'] as num?)?.toInt() ?? 1,
      (p['precio_unitario'] as num?)?.toDouble() ?? 0,
      (p['comision_unitaria'] as num?)?.toDouble() ?? 0,
      p['metodo'] as String?,
      p['casa'] == true,
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
  required bool vendedorEsDueno,
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
    if (saldo <= 0) {
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
  final double precio;
  if (casa) {
    precio = 0;
  } else if (tipo == 'dosis_sin_agua') {
    precio = pr.sinAgua;
  } else if (tipo == 'dosis_con_agua') {
    precio = pr.conAgua;
  } else {
    precio = pr.agua;
  }
  if (!casa && precio <= 0) {
    throw Exception(
        'El precio de este servicio aún no está fijado '
        '(Administración → Servicios)');
  }
  // A5: comisión 0 en agua suelta y en ventas del dueño.
  final comision =
      (casa || tipo == 'agua_suelta' || vendedorEsDueno) ? 0.0 : pr.comision;
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
