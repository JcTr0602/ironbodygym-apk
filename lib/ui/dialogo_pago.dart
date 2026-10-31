/// Diálogo unificado de pago (ficha del cliente y Agregar Pago).
///
/// Períodos: semana, quincena, meses y personalizado (días + monto
/// manuales). 1.15 (M5): este diálogo YA NO pide confirmación
/// propia: devuelve el payload al terminar el Paso 1 y la ÚNICA
/// confirmación antes de encolar es PreviewCobroScreen.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../precio_cobro.dart';
import '../tarifa_especial.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Selección de período hecha en el diálogo.
class PeriodoSel {
  final String periodo; // semanal | quincenal | mensual | personalizado
  final int meses;
  final int dias; // solo personalizado
  final double monto; // calculado o manual
  // v1.0.16: id del tipo de pago dinámico elegido (si aplica)
  final String? tipoId;
  // v1.10.0 (Bloque 2, D6): escalón que decidió el monto (ver
  // precio_cobro.dart) y avisos no bloqueantes (especial vencida...).
  final String escalon;
  final List<String> avisos;
  const PeriodoSel(
      {required this.periodo,
      this.meses = 1,
      this.dias = 0,
      required this.monto,
      this.tipoId,
      this.escalon = 'estandar',
      this.avisos = const []});
}

int _diasDe(PeriodoSel s) {
  switch (s.periodo) {
    case 'semanal':
      return 7;
    case 'quincenal':
      return 15;
    case 'personalizado':
      return s.dias;
    default:
      return 30 * s.meses;
  }
}

/// Fecha 'YYYY-MM-DD' de un [DateTime] wall-clock de La Habana
/// (campos tal cual, sin conversión: ya viene de [ahoraHabana()]).
String isoFechaHabana(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 1.15 (C2, pura y probada): fecha calendario de un valor de cobro.
///
/// - 'YYYY-MM-DD' que sea una fecha REAL → tal cual.
/// - ISO con hora y offset/Z → se convierte a hora Habana PRIMERO
///   (vía [aHabana]) y luego se toma el día. NUNCA se toman los
///   primeros 10 caracteres de un timestamp UTC: pueden cambiar
///   el día en Habana (p. ej. 2026-10-26T02:30:00Z es 25-oct en
///   Habana).
/// - ISO con hora SIN offset → se toma su fecha tal cual (se
///   interpreta como wall-clock Habana, no como UTC).
/// - Fecha imposible ('2026-02-30') o texto no interpretable → null.
///
/// Un [DateTime] se lee por sus campos: en este diálogo los
/// DateTime ya son wall-clock Habana (ver [ahoraHabana]).
String? normalizarFechaCobro(dynamic v) {
  if (v is DateTime) return isoFechaHabana(v);
  if (v is! String || v.isEmpty) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
  if (m != null) {
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final dt = DateTime.utc(y, mo, d);
    if (dt.year != y || dt.month != mo || dt.day != d) return null;
    return v;
  }
  final conOffset = v.contains('Z') ||
      RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(v);
  if (conOffset) {
    // Panel Grupo B: DateTime.tryParse NORMALIZA fechas imposibles
    // ('2026-02-30' → 2026-03-02); validar la parte fecha con
    // round-trip ANTES de convertir, igual que la rama YYYY-MM-DD.
    final parte = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v);
    if (parte == null) return null;
    final y = int.parse(parte.group(1)!);
    final mo = int.parse(parte.group(2)!);
    final d = int.parse(parte.group(3)!);
    final chk = DateTime.utc(y, mo, d);
    if (chk.year != y || chk.month != mo || chk.day != d) return null;
  }
  final dt = DateTime.tryParse(v);
  if (dt == null) return null;
  if (conOffset) {
    final h = aHabana(dt);
    return isoFechaHabana(h);
  }
  final fecha = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v);
  if (fecha == null) return null;
  return normalizarFechaCobro(
      '${fecha.group(1)}-${fecha.group(2)}-${fecha.group(3)}');
}

/// 1.15 (C3, pura y probada): días vencidos entre un `pagado_hasta`
/// y una fecha de pago, ambas ya normalizadas a 'YYYY-MM-DD'.
/// null si alguna no es interpretable.
int? diasVencidosCobro(String? pagadoHasta, String fechaPagoIso) {
  final ph = normalizarFechaCobro(pagadoHasta);
  final fp = normalizarFechaCobro(fechaPagoIso);
  if (ph == null || fp == null) return null;
  // Panel Grupo B (DST): medianoches locales truncan un día al
  // cruzar un cambio de hora (un día DST dura 23 h en Habana).
  // Como ph/fp ya son 'YYYY-MM-DD' validados, la diferencia se
  // calcula sobre fechas de calendario en UTC. Solo alimenta el
  // texto «hace N días»; la DECISIÓN de vencido usa compareTo.
  DateTime aUtc(String iso) {
    final p = iso.split('-');
    return DateTime.utc(
        int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  return aUtc(fp).difference(aUtc(ph)).inDays;
}

/// 1.15 (C3, pura y probada): qué pasa con la decisión de
/// «siguió viniendo» cuando cambia la fecha del pago.
///
/// La decisión anterior SIEMPRE se invalida: [base] vuelve null.
/// - Si con la fecha nueva ya NO está vencida → no hay que
///   preguntar ([necesitaPregunta] false) y la base queda null.
/// - Si sigue vencida → hay que volver a preguntar antes de
///   aceptar ([necesitaPregunta] true); la base se fija con la
///   respuesta nueva, nunca con la anterior.
({bool necesitaPregunta, String? base}) recalcularBaseAlCambiarFecha({
  String? pagadoHasta,
  required String fechaPagoIso,
}) {
  final ph = normalizarFechaCobro(pagadoHasta);
  final fp = normalizarFechaCobro(fechaPagoIso);
  if (ph == null || fp == null || ph.compareTo(fp) >= 0) {
    return (necesitaPregunta: false, base: null);
  }
  return (necesitaPregunta: true, base: null);
}

/// 1.15 (C4, pura y probada): id de cliente tolerante para el
/// cobro: num (10.0 → 10) o String numérico ('10'); lo no
/// interpretable es 0 (flujo detenido, nunca encolado).
int idClienteCobro(Map<String, dynamic> cliente) {
  final v = cliente['id'];
  if (v is num) return v.toInt();
  if (v is String) {
    final i = int.tryParse(v.trim());
    if (i != null) return i;
    return double.tryParse(v.trim())?.toInt() ?? 0;
  }
  return 0;
}

/// 1.15 (m8, pura y probada): un pago personalizado es válido
/// solo con 1 <= días <= 3650 y monto positivo y finito.
bool validoPagoPersonalizado({required int dias, required double monto}) =>
    dias >= 1 && dias <= 3650 && monto > 0 && monto.isFinite;

String _etiquetaPeriodo(PeriodoSel s) {
  switch (s.periodo) {
    case 'semanal':
      return 'Semana';
    case 'quincenal':
      return 'Quincena';
    case 'personalizado':
      return '${s.dias} días (personalizado)';
    default:
      return '${s.meses} mes${s.meses == 1 ? '' : 'es'}';
  }
}

/// Métodos aceptados efectivos (panel 1.14, Luna + Kimi; pura y
/// probada): parsea el ajuste H1 (lista o texto por comas) y
/// devuelve (efectivo, transferencia). Sin dato o lista vacía →
/// ambos (no bloquear un cobro). Si el ajuste trae valores pero
/// NINGUNO es reconocido (p. ej. 'tarjeta', o 'transfer' en vez de
/// 'transferencia'), se ofrecen ambos: un ajuste mal escrito no
/// puede dejar el diálogo sin método visible (antes quedaba
/// 'transferencia' oculto como método por defecto).
({bool efectivo, bool transferencia}) metodosAceptadosEfectivos(
    Object? metodosRaw) {
  final metodosAceptados = metodosRaw is List
      ? metodosRaw.map((m) => '$m'.trim().toLowerCase()).toSet()
      : metodosRaw is String
          ? metodosRaw
              .split(',')
              .map((s) => s.trim().toLowerCase())
              .where((s) => s.isNotEmpty)
              .toSet()
          : <String>{};
  if (metodosAceptados.isEmpty) {
    return (efectivo: true, transferencia: true);
  }
  final efectivo = metodosAceptados.contains('efectivo');
  final transferencia = metodosAceptados.contains('transferencia');
  if (!efectivo && !transferencia) {
    return (efectivo: true, transferencia: true);
  }
  return (efectivo: efectivo, transferencia: transferencia);
}

/// Muestra el diálogo de pago para [cliente].
/// Devuelve el payload listo para encolar, o null si se canceló.
Future<Map<String, dynamic>?> pagoDialogo(
    BuildContext context, Map<String, dynamic> cliente) async {
  final aj = await LocalDb.instance.getAjustes();
  final transfer = (aj['transferencia'] as num?)?.toDouble() ?? 2500;
  // 1.14 (D9): respetar los métodos aceptados en Ajustes (H1).
  // Antes el ajuste se guardaba pero nadie lo leía y el diálogo
  // ofrecía transferencia siempre. Sin dato (o lista vacía) se
  // ofrecen ambos para no bloquear un cobro.
  final metodos = metodosAceptadosEfectivos(aj['metodos_aceptados']);
  final aceptaEfectivo = metodos.efectivo;
  final aceptaTransfer = metodos.transferencia;
  if (!context.mounted) return null;

  // v1.0.16: tipos dinámicos; menores ven precio reducido automáticamente
  final menor = esMenor(cliente['carnet'] as String?);
  final tipos = await getTiposPago(paraMenor: menor);
  if (!context.mounted) return null;
  if (tipos.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No hay tipos de pago configurados')));
    return null;
  }

  // Tipo inicial: 'mensual' (o 'menores' si es menor)
  // v1.3.1 (Argón): filtrar tipos arriba del todo para que tipoSel,
  // DropdownButton y orElse trabajen sobre el mismo conjunto.
  final tiposDisp = menor
      ? tipos.where((t) => t.id != 'mensual').toList()
      : tipos;
  // v1.10.0 (Bloque 2, D6): contexto de precio ÚNICO. Se carga una
  // vez (especiales del cliente + precios) y actual() usa la función
  // pura calcularPrecioCobro con la selección vigente. Los 3 puntos
  // de cobro ya bloquean Casa antes de llegar aquí; si aun así llega
  // una Casa, no se cobra (defensa, no camino normal).
  // 1.15 (M6): punto único de verdad, no comparación manual:
  // esCuentaCasa normaliza 1/true/'1' (y el resto es 0).
  final esCasa = esCuentaCasa(cliente);
  if (esCasa) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Una Cuenta a la Casa no paga mensualidad.')));
    }
    return null;
  }
  // 1.15 (C4): id ya convertido y reutilizado en todo el flujo
  // (antes el payload hacía un cast directo a int? sin bloqueo).
  final clienteId = idClienteCobro(cliente);
  var filasEspecial = <Map<String, dynamic>>[];
  if (clienteId > 0) {
    try {
      filasEspecial = await tarifasDeCliente(clienteId);
    } catch (_) {}
  }
  final tieneRegistroEsp = filasEspecial.isNotEmpty;
  double montoTipo(String id, double def) {
    for (final t in tipos) {
      if (t.id == id) return t.monto;
    }
    return def;
  }

  final preciosMapa = <String, double>{
    'mensual': montoTipo('mensual', 2000),
    'menores': montoTipo('menores', 1500),
    'transfer': transfer,
    'semanal': montoTipo('semanal', 600),
    'quincenal': montoTipo('quincenal', 1200),
  };

  /// Especial aplicable a (periodo motor, método): fila activa de ese
  /// periodo, o la legacy sintética (solo si NO hay ningún registro
  /// y es transferencia mensual; ajuste 3).
  Map<String, dynamic>? especialPara(String periodoMotor, String met) {
    for (final f in filasEspecial) {
      if (f['activa'] == 1 && '${f['periodo']}' == periodoMotor) {
        return f;
      }
    }
    if (!tieneRegistroEsp &&
        periodoMotor == 'mensual' &&
        met == 'transferencia') {
      final legacy =
          (cliente['tarifa_especial_transferencia'] as num?)?.toDouble();
      if (legacy != null) {
        return {
          'periodo': 'mensual',
          'monto_transferencia': legacy,
          'monto_efectivo': null,
          'vigente_desde': null,
          'vigente_hasta': null,
        };
      }
    }
    return null;
  }
  TipoPago tipoSel =
      tiposDisp.firstWhere((t) => t.id == (menor ? 'menores' : 'mensual'),
          orElse: () => tiposDisp.first);
  // Decisión Jc 2026-10-25 (MIN): NO se auto-aplica la oferta
  // al menor, pero SÍ es la opción por defecto. El valor inicial
  // de abajo es provisional; tras definir montoEtiqueta se
  // recalcula con tipoInicialPago (menor: opción mensual de
  // 30 días más barata, cambiable en el desplegable).
  int meses = 1;
  String metodo = aceptaEfectivo ? 'efectivo' : 'transferencia';
  final diasCtrl = TextEditingController();
  final montoCtrl = TextEditingController();
  // 1.15 (C1): fecha del pago en hora Habana, no DateTime.now()
  // crudo (la zona del dispositivo no es necesariamente Habana).
  DateTime fechaPago = ahoraHabana(); // v1.1: permite elegir fecha del pago
  // v1.3.1 (Argón regresión 2): sin try/finally con dispose. Esta es una
  // función global, no un StatefulWidget; los controllers locales los
  // recoge el GC. El dispose tras showDialog causaba
  // "TextEditingController was used after being disposed".

  // v1.3.2 (Argón): si el cliente está vencido, preguntar ANTES del paso 1
  // si siguió viniendo. La respuesta define la base del período nuevo:
  // - Sí → se cuenta desde el vencimiento anterior (base = pagado_hasta).
  // - No → comportamiento actual (desde la fecha del pago).
  String? basePago; // null = desde fechaPago (comportamiento actual)
  {
    // 1.15 (C2): vencimiento normalizado a día Habana, nunca el
    // substring crudo de un timestamp con hora.
    final pagadoHasta = normalizarFechaCobro(cliente['pagado_hasta']);
    final fpIso = isoFechaHabana(fechaPago);
    final vencido =
        pagadoHasta != null && pagadoHasta.compareTo(fpIso) < 0;
    if (vencido && context.mounted) {
      final diasVencido = diasVencidosCobro(pagadoHasta, fpIso) ?? 0;
      // Preview con el período por defecto (mensual 30 días) para mostrar
      // la consecuencia de cada opción. El preview exacto se recalcula
      // en el paso 1 con el período elegido.
      final hastaSi = previewHastaDias(pagadoHasta, 30,
          fechaPago: fpIso, base: pagadoHasta);
      final hastaNo =
          previewHastaDias(pagadoHasta, 30, fechaPago: fpIso);
      final r = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Cliente vencido'),
          content: Text(
            'Venció el ${fmtFecha(pagadoHasta)} '
            '(hace $diasVencido día${diasVencido == 1 ? '' : 's'}).\n'
            '¿Siguió viniendo después del vencimiento?\n\n'
            'Sí → nuevo vencimiento: ${fmtFecha(hastaSi)}\n'
            'No → nuevo vencimiento: ${fmtFecha(hastaNo)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No, dejó de venir'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, siguió viniendo'),
            ),
          ],
        ),
      );
      if (r == null || !context.mounted) return null;
      if (r) basePago = pagadoHasta;
    }
  }

  /// Mapea el tipo elegido al período del motor del servidor.
  /// Los 4 fijos usan su período nativo; los personalizados van como
  /// 'personalizado' (días + monto), sin cambios en el servidor.
  /// v1.10.0 (Bloque 2, D6): los 4 fijos pasan por calcularPrecioCobro
  /// (función ÚNICA): especial > menores > Oferta > estándar. Los
  /// tipos personalizados (Oferta) conservan su propio monto.
  PeriodoSel actual() {
    double monto;
    String periodo;
    int dias = 0;
    String escalon = 'estandar';
    List<String> avisos = const [];
    final id = tipoSel.id;
    if (id == 'personalizado') {
      periodo = 'personalizado';
      dias = int.tryParse(diasCtrl.text.trim()) ?? 0;
      monto = double.tryParse(
              montoCtrl.text.trim().replaceAll(',', '.')) ??
          0;
    } else if (id == 'semanal' || id == 'quincenal') {
      periodo = id;
      final r = calcularPrecioCobro(
          periodo: id,
          metodo: metodo,
          esCasa: esCasa,
          esMenor: menor,
          precios: preciosMapa,
          especial: especialPara(id, metodo),
          hoyHabana: hoyHabanaIso());
      monto = r.monto;
      escalon = r.escalon;
      avisos = r.avisos;
    } else if (id == 'mensual' || id == 'menores') {
      periodo = 'mensual';
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: metodo,
          esCasa: esCasa,
          esMenor: menor,
          precios: preciosMapa,
          especial: especialPara('mensual', metodo),
          hoyHabana: hoyHabanaIso());
      monto = r.monto * meses;
      escalon = r.escalon;
      avisos = r.avisos;
    } else {
      // Tipo personalizado de Jc -> motor 'personalizado'
      // Lote 2 Argón (verificado, NO es bug): el monto es fijo por
      // diseño, igual que semanal/quincenal (que tampoco distinguen
      // método). El servidor liquida el monto del payload tal cual
      // para personalizado y tipo: (sync.py: monto_custom validado,
      // sin distinción por método), así que la vista previa y el
      // backend coinciden aunque se cambie el chip de método.
      periodo = 'personalizado';
      dias = tipoSel.dias;
      monto = tipoSel.monto;
      escalon = 'oferta';
    }
    return PeriodoSel(
        periodo: periodo,
        // 1.19 (Argón A2): meses solo tiene sentido en mensual/
        // menores. Antes se arrastraba el contador a semanal,
        // quincenal u oferta (monto de 1 periodo con meses: 2):
        // el objeto quedaba inconsistente aunque el payload actual
        // ya filtrara meses a mensual.
        meses: (id == 'mensual' || id == 'menores') ? meses : 1,
        dias: dias,
        monto: monto,
        tipoId: id == 'personalizado' ? null : id,
        escalon: escalon,
        avisos: avisos);
  }

  /// Precio que mostraría la etiqueta de un tipo en el desplegable
  /// (meses = 1): el mismo que cobraría actual() con ese tipo.
  double montoEtiqueta(TipoPago t) {
    if (t.id == 'mensual' || t.id == 'menores') {
      return calcularPrecioCobro(
              periodo: 'mensual',
              metodo: metodo,
              esCasa: esCasa,
              esMenor: menor,
              precios: preciosMapa,
              especial: especialPara('mensual', metodo),
              hoyHabana: hoyHabanaIso())
          .monto;
    }
    if (t.id == 'semanal' || t.id == 'quincenal') {
      return calcularPrecioCobro(
              periodo: t.id,
              metodo: metodo,
              esCasa: esCasa,
              esMenor: menor,
              precios: preciosMapa,
              especial: especialPara(t.id, metodo),
              hoyHabana: hoyHabanaIso())
          .monto;
    }
    // Lote 2 Argón (verificado, NO es bug): los tipos personalizados
    // devuelven su monto fijo (ver comentario en actual()).
    return t.monto;
  }

  // Default MIN (Jc 2026-10-25): para menores, el tipo inicial es
  // la opción mensual más barata (menores u oferta de 30 días).
  // Es solo el valor preseleccionado: el desplegable sigue
  // permitiendo cambiarlo y nada se cobra sin la vista previa.
  // 1.19 (Argón A1): Casa o especial mensual vigente NO compiten
  // contra ofertas: la preselección es 'menores' (el motor aplica
  // Casa 0 o la especial; una oferta preseleccionada la saltaría).
  // El entrenador sigue pudiendo elegir la oferta a mano.
  if (menor) {
    tipoSel = tipoInicialPago(tiposDisp,
        menor: true,
        monto: montoEtiqueta,
        esCasa: esCasa,
        tieneEspecialMensual:
            especialPara('mensual', metodo) != null);
  }

  // 1.15 (m8): el personalizado delega en la función pura
  // (1 <= días <= 3650, monto positivo y finito).
  bool valido(PeriodoSel s) {
    if (s.periodo == 'personalizado') {
      return validoPagoPersonalizado(dias: s.dias, monto: s.monto);
    }
    return true;
  }

  // Paso 1: período y método.
  final paso1 = await showDialog<PeriodoSel>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final s = actual();
        final fpIso = isoFechaHabana(fechaPago);
        final nuevo = previewHastaDias(
            // 1.15 (C2): vencimiento normalizado a día Habana.
            normalizarFechaCobro(cliente['pagado_hasta']),
            _diasDe(s),
            fechaPago: fpIso, base: basePago);
        return DialogoApp(
          titulo: 'Pago — ${cliente['nombre']}',
          iconoTitulo: Icons.payments,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Vence: ${fmtFecha(cliente['pagado_hasta'] as String?)}'),
                // v1.0.14: aviso de precio reducido para menores
                if (menor)
                  Container(
                    margin:
                        const EdgeInsets.only(top: 8, bottom: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColores.info
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(
                          AppRadio.md),
                      border: Border.all(
                          color: AppColores.info
                              .withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.child_care,
                            color: AppColores.info),
                        const SizedBox(
                            width: AppEspacio.sm),
                        Expanded(
                          child: Text(
                            'Menor de 18: precio especial '
                            '${fmtMonto(tipos.firstWhere((t) => t.id == 'menores', orElse: () => tipos.first).monto)} CUP/mes.',
                            style: const TextStyle(
                                fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                // v1.0.14: aviso claro si paga por adelantado
                Builder(builder: (_) {
                  // 1.15 (C2): vencimiento normalizado a día Habana.
                  final ph =
                      normalizarFechaCobro(cliente['pagado_hasta']);
                  if (ph != null && ph.compareTo(fpIso) > 0) {
                    final diasRest = DateTime.parse(ph)
                        .difference(DateTime.parse(fpIso))
                        .inDays;
                    return Container(
                      margin: const EdgeInsets.only(
                          top: 8, bottom: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColores.exito
                            .withValues(alpha: 0.08),
                        borderRadius:
                            BorderRadius.circular(
                                AppRadio.md),
                        border: Border.all(
                            color: AppColores.exito
                                .withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                              Icons.check_circle,
                              color:
                                  AppColores.exito),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: Text(
                              'Tiene $diasRest día(s) vigentes. '
                              'No se pierden: el nuevo período '
                              'empieza al vencer.',
                              style: const TextStyle(
                                  fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                }),
                const SizedBox(height: 8),
                // Selector de fecha del pago (v1.1)
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: fechaPago,
                      firstDate: DateTime(2020),
                      // 1.15 (C1): límite del selector en fecha Habana.
                      lastDate: ahoraHabana(),
                      helpText: 'Fecha del pago',
                    );
                    if (picked == null) return;
                    // 1.15 (C3): al cambiar la fecha, la decisión
                    // anterior se invalida y se recalcula todo con
                    // la fecha elegida. Si ya no está vencida, la
                    // base queda null; si sigue vencida, se vuelve
                    // a preguntar ANTES de aceptar. Sin respuesta,
                    // se conserva la fecha y la decisión anteriores.
                    final fechaAnterior = fechaPago;
                    final baseAnterior = basePago;
                    final pickedIso = isoFechaHabana(picked);
                    final phNorm =
                        normalizarFechaCobro(cliente['pagado_hasta']);
                    final rec = recalcularBaseAlCambiarFecha(
                        pagadoHasta: phNorm, fechaPagoIso: pickedIso);
                    if (!rec.necesitaPregunta) {
                      if (ctx.mounted) {
                        setS(() {
                          fechaPago = picked;
                          basePago = null;
                        });
                      }
                      return;
                    }
                    final diasV =
                        diasVencidosCobro(phNorm, pickedIso) ?? 0;
                    final hastaSi = previewHastaDias(phNorm, 30,
                        fechaPago: pickedIso, base: phNorm);
                    final hastaNo = previewHastaDias(phNorm, 30,
                        fechaPago: pickedIso);
                    if (!ctx.mounted) return;
                    final r = await showDialog<bool>(
                      context: ctx,
                      barrierDismissible: false,
                      builder: (ctx2) => AlertDialog(
                        title: const Text('Cliente vencido'),
                        content: Text(
                          'Venció el ${fmtFecha(phNorm)} '
                          '(hace $diasV día${diasV == 1 ? '' : 's'}).\n'
                          '¿Siguió viniendo después del vencimiento?\n\n'
                          'Sí → nuevo vencimiento: ${fmtFecha(hastaSi)}\n'
                          'No → nuevo vencimiento: ${fmtFecha(hastaNo)}',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx2, false),
                            child: const Text('No, dejó de venir'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx2, true),
                            child: const Text('Sí, siguió viniendo'),
                          ),
                        ],
                      ),
                    );
                    if (!ctx.mounted) return;
                    if (r == null) {
                      setS(() {
                        fechaPago = fechaAnterior;
                        basePago = baseAnterior;
                      });
                      return;
                    }
                    setS(() {
                      fechaPago = picked;
                      basePago = r ? phNorm : null;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: AppColores.borde(ctx)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Pagado el: ${fechaPago.day.toString().padLeft(2, '0')}/'
                          '${fechaPago.month.toString().padLeft(2, '0')}/'
                          '${fechaPago.year}',
                          style: const TextStyle(fontSize: 15),
                        ),
                        const Spacer(),
                        Icon(Icons.edit,
                            size: 16,
                            color: AppColores.textoSecundario(ctx)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Período:'),
                DropdownButton<String>(
                  value: tipoSel.id,
                  isExpanded: true,
                  items: [
                    // v1.3.1 (Argón): tiposDisp ya excluye 'mensual' si
                    // menor == true; value y items siempre coinciden.
                    for (final t in tiposDisp)
                      DropdownMenuItem(
                          value: t.id,
                          child: Text(
                              '${t.nombre} (${fmtMonto(montoEtiqueta(t))} CUP)')),
                    const DropdownMenuItem(
                        value: 'personalizado',
                        child: Text('Personalizado…')),
                  ],
                  onChanged: (v) => setS(() {
                    // v1.3.1: resetear meses/días al cambiar de tipo.
                    meses = 1;
                    diasCtrl.clear();
                    montoCtrl.clear();
                    if (v == 'personalizado') {
                      tipoSel = const TipoPago(
                          id: 'personalizado',
                          nombre: 'Personalizado',
                          monto: 0,
                          dias: 0);
                    } else {
                      tipoSel = tiposDisp.firstWhere((t) => t.id == v,
                          orElse: () => tiposDisp.first);
                    }
                  }),
                ),
                // Selector de meses para mensual/menores
                if (tipoSel.id == 'mensual' ||
                    tipoSel.id == 'menores') ...[
                  const SizedBox(height: 8),
                  const Text('Meses:'),
                  DropdownButton<int>(
                    value: meses,
                    isExpanded: true,
                    items: [
                      for (final m in [1, 2, 3, 6, 12])
                        DropdownMenuItem(
                            value: m,
                            child: Text(
                                '$m mes${m == 1 ? '' : 'es'}')),
                    ],
                    onChanged: (v) =>
                        setS(() => meses = v ?? 1),
                  ),
                ],
                if (tipoSel.id == 'personalizado') ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: diasCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                    decoration: const InputDecoration(
                        labelText: 'Días',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setS(() {}),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: montoCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(
                            decimal: true),
                    // 1.15 (m8): solo dígitos y un separador
                    // decimal válido (punto o coma; el parseo
                    // posterior convierte la coma y lo inválido
                    // cae a monto 0 → inválido, nunca se cobra).
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9.,]')),
                    ],
                    decoration: const InputDecoration(
                        labelText: 'Monto (CUP)',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setS(() {}),
                  ),
                ],
                const SizedBox(height: 8),
                const Text('Método:'),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (aceptaEfectivo)
                      ChoiceChip(
                          label: const Text('Efectivo'),
                          avatar: const Icon(Icons.payments,
                              size: 18),
                          selected: metodo == 'efectivo',
                          onSelected: (_) =>
                              setS(() => metodo = 'efectivo')),
                    if (aceptaEfectivo && aceptaTransfer)
                      const SizedBox(width: 8),
                    if (aceptaTransfer)
                      ChoiceChip(
                          label: const Text('Transfer.'),
                          avatar: const Icon(
                              Icons.smartphone,
                              size: 18),
                          selected: metodo == 'transferencia',
                          onSelected: (_) => setS(
                              () => metodo = 'transferencia')),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Período: ${_etiquetaPeriodo(s)}'),
                Text('Monto: ${fmtMonto(s.monto)} CUP',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
                // v1.10.0 (Bloque 2, D6): chip + avisos del escalón
                // que decidió el precio (no bloquean, informan).
                if (s.escalon == 'especial')
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Chip(
                      label: Text('Tarifa especial'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                for (final a in s.avisos)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(a,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.orange)),
                  ),
                Text('Nuevo vencimiento: ${fmtFecha(nuevo)}',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed:
                    valido(s) ? () => Navigator.pop(ctx, s) : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Continuar')),
          ],
        );
      },
    ),
  );
  if (paso1 == null || !context.mounted) return null;

  // 1.15 (M5): ELIMINADO el diálogo interno «Confirmar pago»:
  // el payload se devuelve al terminar el Paso 1 y la ÚNICA
  // confirmación antes del encolado es PreviewCobroScreen
  // (cobrarConPreviewYRecibo), que muestra cliente, monto,
  // método, período y vencimiento. La vista previa obligatoria
  // NO se quita: queda como único paso.
  // 1.15 (C4): detener el flujo antes de cobrar si el id no es
  // válido (0 o no interpretable): nunca se encola un cobro
  // sin cliente.
  if (clienteId <= 0) return null;
  final s = paso1;
  final fpIso2 = isoFechaHabana(fechaPago);
  final nuevo = previewHastaDias(
      normalizarFechaCobro(cliente['pagado_hasta']), _diasDe(s),
      fechaPago: fpIso2, base: basePago);

  return {
    'cliente_id': clienteId,
    'periodo': s.periodo,
    // v1.3.1: tipo_id para que el servidor aplique el precio correcto
    // (ej. 2500 con transferencia en vez de 2000).
    if (s.tipoId != null) 'tipo_id': s.tipoId,
    // v1.3.1: meses solo tiene sentido en mensual.
    if (s.periodo == 'mensual') 'meses': s.meses,
    if (s.periodo == 'personalizado') 'dias': s.dias,
    // Monto calculado y vencimiento previsto: los usa la pantalla de
    // confirmación. El servidor los ignora (recalcula él mismo).
    'monto': s.monto,
    'pagado_hasta': nuevo,
    'metodo': metodo,
    // v1.3.2: base explícita si el cliente siguió viniendo vencido.
    // El servidor la respeta en record_payment.
    if (basePago != null) 'base': basePago,
    'siguio_viniendo': basePago != null,
    'fecha': isoFechaHabana(fechaPago),
  };
}
