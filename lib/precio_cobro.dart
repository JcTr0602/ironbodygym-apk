/// Motor único de precio de cobro (Bloque 2 NÚCLEO, 1.10.0, Argón
/// AMARILLO ajustes 2, 4 y 5).
///
/// REGLA: D1–D3/D5 son insumos de ESTA función, nunca if/else sueltos
/// en la pantalla de Cobro. La pantalla de Cobro (diálogo de pago)
/// llama a [calcularPrecioCobro] (pura, testeable) con los datos ya
/// cargados, o a [precioCobroParaCliente] (carga especial + legacy +
/// precios y luego llama a la pura).
///
/// Precedencia cerrada (ajuste 2 + respuesta 1 de Argón):
///   Casa (0) > especial vigente del cliente para ese método Y ese
///   periodo > menores > Oferta (monto personalizado explícito) >
///   estándar global.
/// - Método en null en la especial → cae al siguiente escalón
///   (menores/Oferta), NUNCA directo al estándar.
/// - Especial vencida (hoy_habana > vigente_hasta) o aún no vigente
///   → NO pre-rellena + aviso no bloqueante, y se sigue evaluando.
/// - Casa con especial → rige Casa (0) + aviso.
/// - Menores con especial → rige la especial + aviso.
/// - Periodo cruzado (especial mensual, cobro semanal) → la especial
///   NO aplica (el periodo debe coincidir).
/// - Tipos personalizados (Oferta): el diálogo los resuelve con su
///   propio monto y NO pasa por aquí; si un llamador pasa
///   [montoOferta], ese es el escalón Oferta de la cadena.
///
/// El monto devuelto es UNITARIO (por periodo); el diálogo multiplica
/// por meses solo en mensual/menores, como siempre.
library;

import 'negocio.dart' show esMenor, preciosVigentes;
import 'tarifa_especial.dart';
import 'tiempo.dart';

/// Escalón que decidió el precio.
class PrecioCobro {
  /// Monto unitario en CUP (0 para Casa).
  final double monto;

  /// 'casa' | 'especial' | 'menores' | 'oferta' | 'estandar'.
  final String escalon;

  /// Avisos NO bloqueantes para mostrar junto al precio
  /// (especial vencida, rige Casa, rige la especial...).
  final List<String> avisos;

  const PrecioCobro(this.monto, this.escalon, [this.avisos = const []]);
}

/// Función pura: toda la precedencia, sin tocar la BD (testeable).
PrecioCobro calcularPrecioCobro({
  required String periodo,
  required String metodo,
  required bool esCasa,
  required bool esMenor,
  required Map<String, double> precios,
  Map<String, dynamic>? especial,
  double? montoOferta,
  required String hoyHabana,
}) {
  // 1. Casa: precio 0 aunque haya especial (con aviso si la hay).
  if (esCasa) {
    final avisos = <String>[];
    if (especial != null) {
      avisos.add('Es Casa y tiene tarifa especial: rige Casa (0 CUP)');
    }
    return PrecioCobro(0, 'casa', avisos);
  }

  // 2. Especial: exige periodo + método + fechas, todo a la vez.
  if (especial != null && '${especial['periodo'] ?? ''}' == periodo) {
    final desde = '${especial['vigente_desde'] ?? ''}';
    final hasta = especial['vigente_hasta'] as String?;
    if (desde.isNotEmpty && hoyHabana.compareTo(desde) < 0) {
      return _siguienteEscalon(
          precios: precios,
          periodo: periodo,
          metodo: metodo,
          esMenor: esMenor,
          montoOferta: montoOferta,
          avisos: ['Especial aún no vigente (desde $desde)']);
    }
    if (hasta != null &&
        hasta.isNotEmpty &&
        hoyHabana.compareTo(hasta) > 0) {
      return _siguienteEscalon(
          precios: precios,
          periodo: periodo,
          metodo: metodo,
          esMenor: esMenor,
          montoOferta: montoOferta,
          avisos: [
            'Especial vencida el $hasta · se aplica tarifa normal'
          ]);
    }
    final montoMetodo = metodo == 'transferencia'
        ? (especial['monto_transferencia'] as num?)?.toDouble()
        : (especial['monto_efectivo'] as num?)?.toDouble();
    if (montoMetodo != null) {
      final avisos = <String>[];
      if (esMenor) {
        avisos.add('Tiene menores y especial: rige la especial');
      }
      return PrecioCobro(montoMetodo, 'especial', avisos);
    }
    // Método en null → cae al siguiente escalón (sin aviso: el
    // cliente simplemente no tiene especial para ese método).
  }

  return _siguienteEscalon(
      precios: precios,
      periodo: periodo,
      metodo: metodo,
      esMenor: esMenor,
      montoOferta: montoOferta);
}

PrecioCobro _siguienteEscalon({
  required Map<String, double> precios,
  required String periodo,
  required String metodo,
  required bool esMenor,
  double? montoOferta,
  List<String> avisos = const [],
}) {
  // 3. Menores (solo aplica al periodo mensual).
  if (esMenor && periodo == 'mensual') {
    return PrecioCobro(precios['menores'] ?? 1500, 'menores', avisos);
  }
  // 4. Oferta (monto personalizado explícito del llamador).
  if (montoOferta != null) {
    return PrecioCobro(montoOferta, 'oferta', avisos);
  }
  // 5. Estándar global.
  double std;
  if (periodo == 'semanal') {
    std = precios['semanal'] ?? 600;
  } else if (periodo == 'quincenal') {
    std = precios['quincenal'] ?? 1200;
  } else if (metodo == 'transferencia' && periodo == 'mensual') {
    std = precios['transfer'] ?? 2500;
  } else {
    std = precios['mensual'] ?? 2000;
  }
  return PrecioCobro(std, 'estandar', avisos);
}

/// Carga todo lo que necesita la pura y la llama.
///
/// [cliente] es la fila del espejo (map con cuenta_casa, carnet,
/// tarifa_especial_transferencia legacy...).
/// - Si el cliente tiene CUALQUIER registro en tarifa_especial, la
///   columna legacy se ignora para siempre (ajuste 3).
/// - Si NO tiene ninguno y trae legacy por transferencia, la legacy
///   actúa como especial sintética mensual solo para transferencia.
Future<PrecioCobro> precioCobroParaCliente({
  required Map<String, dynamic> cliente,
  required String periodo,
  required String metodo,
  Map<String, double>? precios,
}) async {
  final pr = precios ?? await preciosVigentes();
  final clienteId = (cliente['id'] as num?)?.toInt() ?? 0;
  final esCasa = cliente['cuenta_casa'] == 1 || cliente['cuenta_casa'] == true;
  final menor = esMenor(cliente['carnet'] as String?);
  Map<String, dynamic>? especial;
  if (clienteId > 0) {
    especial = await tarifaActivaPara(clienteId, periodo);
    if (especial == null &&
        !(await tieneAlgunRegistroTarifa(clienteId)) &&
        metodo == 'transferencia' &&
        periodo == 'mensual') {
      final legacy =
          (cliente['tarifa_especial_transferencia'] as num?)?.toDouble();
      if (legacy != null) {
        especial = {
          'periodo': 'mensual',
          'monto_transferencia': legacy,
          'monto_efectivo': null,
          'vigente_desde': null,
          'vigente_hasta': null,
        };
      }
    }
  }
  return calcularPrecioCobro(
    periodo: periodo,
    metodo: metodo,
    esCasa: esCasa,
    esMenor: menor,
    precios: pr,
    especial: especial,
    hoyHabana: hoyHabanaIso(),
  );
}

/// --- Split B1 (Argón ajuste 4): payloads por dominio -----------.
///
/// BÁSICO (op 'editar_cliente', la de siempre, pero YA sin campos
/// sensibles): nombre, teléfono (8 dígitos, ya validado por la UI),
/// carnet, sexo, notas. Solo se incluyen las claves no null.
/// SENSIBLE (op NUEVA 'update_cliente_sensible', solo dueño; el
/// servidor deberá validarlo después): pagado_hasta, cuenta_casa,
/// permisos, accesos. La UI de hoy solo edita pagado_hasta desde el
/// modal sensible; Casa/permisos/accesos tienen sus flujos dedicados
/// y sus propias ops, pero el contrato del payload ya los admite.
Map<String, dynamic> payloadBasico({
  required int clienteId,
  String? nombre,
  String? telefono,
  String? carnet,
  String? sexo,
  String? notas,
}) {
  final p = <String, dynamic>{'cliente_id': clienteId};
  if (nombre != null) p['nombre'] = nombre;
  if (telefono != null) p['telefono'] = telefono;
  if (carnet != null) p['carnet'] = carnet;
  if (sexo != null) p['sexo'] = sexo;
  if (notas != null) p['notas'] = notas;
  return p;
}

Map<String, dynamic> payloadSensible({
  required int clienteId,
  String? pagadoHasta,
  bool? cuentaCasa,
  Map<String, dynamic>? permisos,
  Map<String, dynamic>? accesos,
}) {
  final p = <String, dynamic>{'cliente_id': clienteId};
  if (pagadoHasta != null) p['pagado_hasta'] = pagadoHasta;
  if (cuentaCasa != null) p['cuenta_casa'] = cuentaCasa ? 1 : 0;
  if (permisos != null) p['permisos'] = permisos;
  if (accesos != null) p['accesos'] = accesos;
  return p;
}

/// --- Extracto E4 (Argón ajuste 5): resumen puro ----------------.
///
/// [filas]: {tipo: 'suplemento'|'servicio', monto, anulada}.
/// Las anuladas NO suman. El total general y los dos subtotales van
/// SIEMPRE juntos en la cabecera del Extracto.
class ResumenExtracto {
  final double total;
  final double suplementos;
  final double servicios;
  const ResumenExtracto(this.total, this.suplementos, this.servicios);
}

ResumenExtracto resumenExtracto(List<Map<String, dynamic>> filas) {
  var total = 0.0;
  var sup = 0.0;
  var ser = 0.0;
  for (final f in filas) {
    if (f['anulada'] == 1 || f['anulada'] == true) continue;
    final monto = (f['monto'] as num?)?.toDouble() ?? 0;
    total += monto;
    if (f['tipo'] == 'servicio') {
      ser += monto;
    } else {
      sup += monto;
    }
  }
  return ResumenExtracto(total, sup, ser);
}
