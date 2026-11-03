/// Adelantos a entrenadores (v1.8.0, diseño + Argón A1–A4).
///
/// Libro de eventos SIN saldos editables: registros (monto > 0) y
/// reversos (monto < 0 con reverso_de). Todo lo demás se deriva:
/// el libro corrido agrupa por `mes_nomina` (A1: fijado por el
/// servidor al crear; un mes liquidado nunca se reescribe) y
/// arrastra la deuda cuando los adelantos superan lo devengado.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'sync.dart';
import 'tiempo.dart';

/// Un mes del libro corrido de un entrenador.
class MesLibroAdelantos {
  final String mes; // 'YYYY-MM'
  final double bruto;
  final double comisiones;
  final double bonos; // #2 (Argón nómina): bonos del mes, parte
  // de la capacidad: un adelanto cubierto por un bono NO genera
  // deuda saliente (antes el libro no los veía y la deuda era
  // fantasma).
  final double adelantos; // suma con signo del mes (por mes_nomina)
  final double deudaEntrante;
  final List<Map<String, dynamic>> items;
  const MesLibroAdelantos({
    required this.mes,
    required this.bruto,
    required this.comisiones,
    this.bonos = 0,
    required this.adelantos,
    required this.deudaEntrante,
    required this.items,
  });

  /// Lo devengado del mes (bruto + comisiones + bonos).
  double get devengado => bruto + comisiones + bonos;

  /// Neto a pagar: devengado − adelantos − deuda entrante.
  /// Negativo = queda deuda (se paga 0).
  double get neto => devengado - adelantos - deudaEntrante;
  double get aPagar => neto > 0 ? neto : 0;
  double get deudaSaliente => neto < 0 ? -neto : 0;
}

/// Libro corrido: un MesLibro por mes desde el primer mes con
/// datos (evento, bruto o comisión) hasta [hastaMes] inclusive.
/// La deuda se arrastra mes a mes aunque un mes no tenga datos
/// (si hay deuda viva, los meses intermedios aparecen con su
/// deuda entrante para que la cadena sea auditable; sin deuda y
/// sin datos, el mes se omite).
List<MesLibroAdelantos> libroAdelantos({
  required List<Map<String, dynamic>> eventos,
  required Map<String, double> brutoPorMes,
  required Map<String, double> comisionesPorMes,
  Map<String, double> bonosPorMes = const {},
  required String hastaMes,
}) {
  final porMes = <String, List<Map<String, dynamic>>>{};
  for (final e in eventos) {
    final mes = '${e['mes_nomina'] ?? ''}';
    if (mes.length != 7) continue;
    (porMes[mes] ??= []).add(e);
  }
  final meses = <String>{
    ...porMes.keys,
    ...brutoPorMes.keys,
    ...comisionesPorMes.keys,
    ...bonosPorMes.keys,
    hastaMes,
  }.where((m) => m.compareTo(hastaMes) <= 0).toList()
    ..sort();
  if (meses.isEmpty) return const [];
  final out = <MesLibroAdelantos>[];
  var deuda = 0.0;
  var mes = meses.first;
  while (mes.compareTo(hastaMes) <= 0) {
    final items = porMes[mes] ?? const <Map<String, dynamic>>[];
    final adelantos = items.fold<double>(
        0, (s, e) => s + ((e['monto'] as num?)?.toDouble() ?? 0));
    final bruto = brutoPorMes[mes] ?? 0;
    final comisiones = comisionesPorMes[mes] ?? 0;
    final bonos = bonosPorMes[mes] ?? 0;
    if (items.isNotEmpty ||
        bruto != 0 ||
        comisiones != 0 ||
        bonos != 0 ||
        deuda != 0 ||
        mes == hastaMes) {
      final libro = MesLibroAdelantos(
        mes: mes,
        bruto: bruto,
        comisiones: comisiones,
        bonos: bonos,
        adelantos: adelantos,
        deudaEntrante: deuda,
        items: items,
      );
      out.add(libro);
      deuda = libro.deudaSaliente;
    }
    mes = mesSiguiente(mes);
  }
  return out;
}

/// Suma neta de los adelantos VIVOS que descuentan de la gaveta
/// de [telegramId] (panel 1.8.0, Claude): espejo (en_pendiente=1)
/// + las ops registrar_adelanto AÚN encoladas en ESTE teléfono
/// (caja_turno + efectivo + descuenta_a == telegramId), sin
/// duplicar las que ya bajaron al espejo (se cruzan por op_uuid),
/// − las anulaciones encoladas cuyo original sigue pendiente en
/// el espejo. Los reversos del espejo netan solos (monto < 0).
/// Overlay de la cola sobre el espejo de adelantos: correcciones
/// de origen encoladas (la última manda, por adelanto_id) y el
/// conjunto de adelantos con anulación encolada. Lo comparten la
/// SUMA del pendiente (sumaAdelantosPendientes) y la selección de
/// ids al confirmar una entrega (idsPendientesEntrega): ambas
/// deben decidir con el origen EFECTIVO, no con el del espejo
/// (Argón Dinero #5; Panel final 1.21, Terra por Zen).
({Map<int, Map<String, dynamic>> correcciones, Set<int> anuladosEnCola})
    overlayAdelantosEnCola(List<Map<String, dynamic>> opsPendientes) {
  final correcciones = <int, Map<String, dynamic>>{};
  final anuladosEnCola = <int>{};
  for (final op in opsPendientes) {
    final tipo = '${op['tipo']}';
    if (tipo != 'corregir_origen_adelanto' &&
        tipo != 'anular_adelanto') {
      continue;
    }
    try {
      final p = jsonDecode(op['payload'] as String)
          as Map<String, dynamic>;
      final id = (p['adelanto_id'] as num?)?.toInt();
      if (id == null) continue;
      if (tipo == 'corregir_origen_adelanto') {
        correcciones[id] = p;
      } else {
        anuladosEnCola.add(id);
      }
    } catch (_) {}
  }
  return (correcciones: correcciones, anuladosEnCola: anuladosEnCola);
}

double sumaAdelantosPendientes({
  required List<Map<String, dynamic>> espejo,
  required List<Map<String, dynamic>> opsPendientes,
  required int telegramId,
  required int? Function(Object?) normalizarTid,
}) {
  double total = 0;
  final uuidsEspejo = <String>{};
  final porId = <int, Map<String, dynamic>>{};
  // Argón Dinero #5: correcciones de origen AÚN encoladas. Sin
  // este overlay, entre corregir y sincronizar la liquidación
  // se calculaba con el origen VIEJO (el adelanto seguía
  // descontando de la gaveta equivocada) y la lista permitía
  // corregir dos veces con destinos contradictorios. La
  // última corrección encolada manda.
  final correcciones = overlayAdelantosEnCola(opsPendientes).correcciones;
  for (final a in espejo) {
    final id = (a['id'] as num?)?.toInt();
    if (id != null) porId[id] = a;
    final u = a['op_uuid'];
    if (u != null) uuidsEspejo.add('$u');
    if ((a['en_pendiente'] as num?)?.toInt() != 1) continue;
    final corr = id == null ? null : correcciones[id];
    if (corr != null) {
      // Con corrección en curso, manda el origen NUEVO: solo
      // descuenta si pasa a (o sigue en) caja_turno+efectivo y
      // la gaveta es la de este entrenador (descuenta_a de la
      // corrección; si no viene, el del propio adelanto, como
      // hace el servidor).
      final nuevoOrigen = '${corr['nuevo_origen'] ?? ''}';
      final gaveta = normalizarTid(
          corr['descuenta_a'] ?? a['descuenta_a']);
      if (nuevoOrigen == 'caja_turno' &&
          '${a['metodo'] ?? 'efectivo'}' == 'efectivo' &&
          gaveta == telegramId) {
        total += (a['monto'] as num?)?.toDouble() ?? 0;
      }
      continue;
    }
    if (normalizarTid(a['descuenta_a']) == telegramId) {
      total += (a['monto'] as num?)?.toDouble() ?? 0;
    }
  }
  for (final op in opsPendientes) {
    final tipo = '${op['tipo']}';
    if (tipo != 'registrar_adelanto' && tipo != 'anular_adelanto') {
      continue;
    }
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(op['payload'] as String)
          as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (tipo == 'registrar_adelanto') {
      final uuid = op['op_uuid'] ?? op['uuid'];
      if (uuid != null && uuidsEspejo.contains('$uuid')) continue;
      if ('${payload['origen'] ?? 'caja_turno'}' == 'caja_turno' &&
          '${payload['metodo'] ?? 'efectivo'}' == 'efectivo' &&
          normalizarTid(payload['descuenta_a']) == telegramId) {
        total += (payload['monto'] as num?)?.toDouble() ?? 0;
      }
    } else {
      // Anulación encolada: resta lo que el original aún suma.
      // LÍMITE CONOCIDO (auditoría 1.21 B-13): si el original aún
      // es una op pendiente de ESTE teléfono (registrado y anulado
      // antes de sincronizar), no está en el espejo ni la
      // anulación conoce su id de servidor: el pendiente queda
      // sobreestimado hasta que el ciclo de sync espeja ambas
      // ops (ventana de un ciclo, mismo teléfono).
      final origId = (payload['adelanto_id'] as num?)?.toInt();
      final orig = origId == null ? null : porId[origId];
      if (orig != null &&
          normalizarTid(orig['descuenta_a']) == telegramId &&
          (orig['en_pendiente'] as num?)?.toInt() == 1) {
        total -= (orig['monto'] as num?)?.toDouble() ?? 0;
      }
    }
  }
  return total;
}

/// Servicio de adelantos: espejo + ops pendientes (este teléfono)
/// y acciones (solo dueño en el servidor; la UI también gatea).
class AdelantosService {
  AdelantosService._();
  static final AdelantosService instance = AdelantosService._();
  final LocalDb _db = LocalDb.instance;

  /// Eventos de un entrenador (por user_id APK): espejo + los
  /// registrar_adelanto aún pendientes de ESTE teléfono (con
  /// id == null = provisionales) y la marca de anulación
  /// pendiente sobre su original.
  /// Corrección panel 1.12: además de la llave APK, se acepta
  /// el telegram_id del entrenador. Los adelantos F3 aprobados
  /// llevan como clave el telegram_id autenticado (el servidor
  /// no puede resolver el id APK desde telegram_id), así que sin
  /// este segundo criterio no aparecían en su libro de nómina.
  Future<List<Map<String, dynamic>>> eventosDe(String entrenadorId,
      {int? telegramId}) async {
    final espejoCompleto = await _db.allMirror('adelantos');
    // FIN-09 de Argón (1.20): uuids ya espejados, para no
    // duplicar el provisional si el pull bajó el adelanto y la
    // op aún figura en pendingOps (ventana push→pull). Es el
    // mismo cruce que ya hacía sumaAdelantosPendientes.
    final uuidsEspejo = <String>{
      for (final a in espejoCompleto)
        if (a['op_uuid'] != null) '${a['op_uuid']}',
    };
    final filas = [
      for (final a in espejoCompleto)
        if ('${a['entrenador']}' == entrenadorId ||
            (telegramId != null &&
                LocalDb.normalizarTelegramId(
                        a['entrenador_telegram_id']) ==
                    telegramId))
          a,
    ];
    final anulacionesPendientes = <int>{};
    final correccionesPendientes =
        <int, Map<String, dynamic>>{};
    for (final op in await _db.pendingOpsLectura()) {
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if (op['tipo'] == 'anular_adelanto') {
          final id = (p['adelanto_id'] as num?)?.toInt();
          if (id != null) anulacionesPendientes.add(id);
        } else if (op['tipo'] == 'corregir_origen_adelanto') {
          // Argón Dinero #5: la fila muestra el origen EFECTIVO
          // y la marca que bloquea una segunda corrección.
          final id = (p['adelanto_id'] as num?)?.toInt();
          if (id != null) correccionesPendientes[id] = p;
        } else if (op['tipo'] == 'registrar_adelanto' &&
            '${p['entrenador']}' == entrenadorId &&
            !uuidsEspejo.contains('${op['op_uuid']}')) {
          filas.add({
            'id': null,
            'entrenador': entrenadorId,
            'entrenador_nombre': p['entrenador_nombre'],
            'monto': p['monto'],
            'fecha': p['fecha'],
            // Estimación local del mes_nomina: el servidor lo
            // fija al aplicar (puede diferir si el mes ya está
            // liquidado; el espejo manda al sincronizar).
            // Argón Dinero #9: si ESE mes ya está liquidado para
            // este entrenador, el servidor lo rueda al siguiente:
            // la estimación local hace lo mismo, para que el
            // provisional no «caiga» en un mes cerrado (donde la
            // UI ofrecería anular/corregir contra la guarda).
            'mes_nomina': await _mesEstimadoAdelanto(
                '${p['fecha']}'.substring(0, 7), entrenadorId),
            'nota': p['nota'],
            'metodo': p['metodo'],
            'origen': p['origen'],
            'pendiente': 1,
          });
        }
      } catch (_) {}
    }
    for (final f in filas) {
      final id = (f['id'] as num?)?.toInt();
      if (id != null && anulacionesPendientes.contains(id)) {
        f['anulacion_pendiente'] = 1;
      }
      final corr = id == null ? null : correccionesPendientes[id];
      if (corr != null) {
        f['origen_corregido_pendiente'] = 1;
        f['origen'] = '${corr['nuevo_origen'] ?? f['origen'] ?? ''}';
        if (corr['descuenta_a'] != null) {
          f['descuenta_a'] = corr['descuenta_a'];
        }
      }
    }
    filas.sort((a, b) =>
        '${a['fecha']}'.compareTo('${b['fecha']}'));
    return filas;
  }

  /// Mes de nómina estimado para un adelanto provisional:
  /// el de su fecha, rodado al siguiente si ya está liquidado
  /// para el entrenador (Argón Dinero #9; espejo del servidor).
  Future<String> _mesEstimadoAdelanto(
      String mesFecha, String entrenadorId) async {
    if (!await nominaLiquidada(mesFecha, entrenadorId)) {
      return mesFecha;
    }
    final y = int.tryParse(mesFecha.substring(0, 4)) ?? 0;
    final m = int.tryParse(mesFecha.substring(5, 7)) ?? 1;
    final sig = DateTime(y, m + 1);
    return '${sig.year.toString().padLeft(4, '0')}-'
        '${sig.month.toString().padLeft(2, '0')}';
  }

  /// ¿El mes ya está liquidado para el entrenador? (espejo o la
  /// op pendiente de este teléfono).
  Future<bool> nominaLiquidada(
      String mes, String entrenadorId) async {
    // 1.14 (D17): la liquidación puede venir keyada por id APK/UID
    // o consultarse por telegram_id (adelantos aprobados guardan
    // el telegram_id como `entrenador`). Se compara por ambas
    // columnas, en espejo y en ops pendientes.
    bool coincide(Map<String, dynamic> fila) =>
        '${fila['mes']}' == mes &&
        ('${fila['entrenador']}' == entrenadorId ||
            '${fila['entrenador_telegram_id']}' == entrenadorId);
    for (final l in await _db.allMirror('nomina_liquidada')) {
      if (coincide(l)) return true;
    }
    for (final op in await _db.pendingOps()) {
      if (op['tipo'] != 'liquidar_nomina') continue;
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if (coincide(p)) return true;
      } catch (_) {}
    }
    // T22 (1.20): también cuentan las ops ya APLICADAS (el
    // servidor aceptó la liquidación pero el espejo aún no
    // bajó: en esa ventana el botón «Marcar como pagada»
    // reaparecía). opsDeTipo trae pendiente/enviada/aplicada.
    for (final op in await _db.opsDeTipo('liquidar_nomina')) {
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if (coincide(p)) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _queueYEmpujar(String tipo, Map<String, dynamic> payload) async {
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: tipo,
      payload: payload,
    );
    try {
      await SyncEngine.instance.push();
    } catch (_) {}
  }

  Future<void> registrar({
    required String entrenadorId,
    required String entrenadorNombre,
    required int? entrenadorTelegramId,
    required int monto,
    required DateTime fecha,
    String? nota,
    required String metodo,
    required String origen,
    int? descuentaA,
  }) {
    final f = '${fecha.year.toString().padLeft(4, '0')}-'
        '${fecha.month.toString().padLeft(2, '0')}-'
        '${fecha.day.toString().padLeft(2, '0')}';
    return _queueYEmpujar('registrar_adelanto', {
      'entrenador': entrenadorId,
      'entrenador_nombre': entrenadorNombre,
      'entrenador_telegram_id': entrenadorTelegramId,
      'monto': monto,
      'fecha': f,
      'nota': (nota != null && nota.trim().isNotEmpty)
          ? nota.trim()
          : null,
      'metodo': metodo,
      'origen': origen,
      'descuenta_a': origen == 'caja_turno' ? descuentaA : null,
    });
  }

  /// Anula un adelanto (solo dueño en el servidor).
  ///
  /// Fase A 2026-10-25 (M1): si el mes de nómina de ese adelanto
  /// ya está liquidado para su entrenador, se RECHAZA antes de
  /// encolar (la misma fuente de verdad que usa la UI:
  /// [nominaLiquidada], espejo `nomina_liquidada` + op
  /// `liquidar_nomina` pendiente). Sin entrenador/mes explícitos,
  /// se buscan en el espejo por id; si no se encuentran (fila
  /// provisional o espejo incompleto), se deja pasar: el servidor
  /// es la última guarda y la UI ya oculta el botón cuando sabe
  /// que el mes está liquidado.
  Future<void> anular(int adelantoId,
      {String? entrenadorId, String? mesNomina}) async {
    var ent = entrenadorId;
    var mes = mesNomina;
    if (ent == null || mes == null) {
      for (final a in await _db.allMirror('adelantos')) {
        if ((a['id'] as num?)?.toInt() == adelantoId) {
          ent ??= '${a['entrenador'] ?? a['entrenador_telegram_id'] ?? ''}';
          final m = '${a['mes_nomina'] ?? ''}';
          if (mes == null && m.length == 7) mes = m;
          break;
        }
      }
    }
    if (ent != null &&
        ent.isNotEmpty &&
        mes != null &&
        await nominaLiquidada(mes, ent)) {
      throw StateError(
          'La nómina de $mes ya está liquidada: no se puede anular '
          'este adelanto.');
    }
    return _queueYEmpujar('anular_adelanto', {'adelanto_id': adelantoId});
  }

  /// W3 (1.20): corrige el origen de un adelanto (solo dueño
  /// en el servidor). Misma guarda previa que [anular]: si el
  /// mes de nómina ya está liquidado, se rechaza antes de
  /// encolar. [descuentaA] solo aplica al pasar a caja_turno;
  /// si es null, el servidor usa al entrenador del adelanto.
  /// Sin edición optimista del espejo: el cambio se ve al
  /// sincronizar, igual que la anulación.
  Future<void> corregirOrigen(int adelantoId,
      {required String nuevoOrigen,
      int? descuentaA,
      String? entrenadorId,
      String? mesNomina}) async {
    var ent = entrenadorId;
    var mes = mesNomina;
    if (ent == null || mes == null) {
      for (final a in await _db.allMirror('adelantos')) {
        if ((a['id'] as num?)?.toInt() == adelantoId) {
          ent ??= '${a['entrenador'] ?? a['entrenador_telegram_id'] ?? ''}';
          final m = '${a['mes_nomina'] ?? ''}';
          if (mes == null && m.length == 7) mes = m;
          break;
        }
      }
    }
    if (ent != null &&
        ent.isNotEmpty &&
        mes != null &&
        await nominaLiquidada(mes, ent)) {
      throw StateError(
          'La nómina de $mes ya está liquidada: no se puede '
          'corregir el origen de este adelanto.');
    }
    return _queueYEmpujar('corregir_origen_adelanto', {
      'adelanto_id': adelantoId,
      'nuevo_origen': nuevoOrigen,
      if (descuentaA != null) 'descuenta_a': descuentaA,
    });
  }

  Future<void> liquidarNomina({
    required String mes,
    required String entrenadorId,
    required String entrenadorNombre,
    int? entrenadorTelegramId,
    // #3 (Argón nómina): foto de tarifa y neto al liquidar, para
    // que la historia no cambie si la tarifa cambia después.
    double? tarifaPorCliente,
    double? neto,
    // T22 (1.20): desglose completo de la foto (lo que el
    // entrenador verá al confirmar su recepción).
    double? base,
    double? bonos,
    double? comisiones,
    double? adelantos,
    double? deudaEntrante,
  }) =>
      _queueYEmpujar('liquidar_nomina', {
        'mes': mes,
        'entrenador': entrenadorId,
        'entrenador_nombre': entrenadorNombre,
        // 1.14 (D17): el servidor guarda el telegram_id en la
        // liquidación para que el chequeo de mes liquidado
        // funcione también desde la vía de aprobación (que solo
        // conoce el telegram_id).
        if (entrenadorTelegramId != null)
          'entrenador_telegram_id': entrenadorTelegramId,
        if (tarifaPorCliente != null)
          'tarifa_por_cliente': tarifaPorCliente,
        if (neto != null) 'neto': neto,
        if (base != null) 'base': base,
        if (bonos != null) 'bonos': bonos,
        if (comisiones != null) 'comisiones': comisiones,
        if (adelantos != null) 'adelantos': adelantos,
        if (deudaEntrante != null) 'deuda_entrante': deudaEntrante,
      });

  /// T22 (1.20): coincidencia de una fila de nómina (espejo u
  /// op) con un entrenador, por id APK o por telegram_id.
  bool _coincideEntrenador(Map<String, dynamic> fila, String mes,
      String entrenadorId, int? telegramId) {
    if ('${fila['mes']}' != mes) return false;
    if ('${fila['entrenador']}' == entrenadorId) return true;
    final tid = LocalDb.normalizarTelegramId(
        fila['entrenador_telegram_id']);
    return telegramId != null && tid == telegramId;
  }

  /// T22 (1.20): la foto de liquidación de un mes (espejo
  /// nomina_liquidada_snapshot), o null si aún no bajó.
  ///
  /// Autoauditoría 1.22 #1 (2026-11-03): si el espejo aún no
  /// la trae, manda la op `liquidar_nomina` de ESTE teléfono
  /// (pendiente/enviada/aplicada): su payload lleva la misma
  /// foto (base/bonos/comisiones/tarifa) que se encoló al
  /// liquidar. Sin esto, tras liquidar OFFLINE el libro del
  /// mes seguía con tarifa y conteo VIVOS hasta que el
  /// snapshot bajara por pull (en campo esa ventana duró
  /// ~2,5 h el 2026-11-02): nominaLiquidada() ya reconocía la
  /// liquidación en la cola, pero N-5 no la veía y un cambio
  /// de tarifa en la ventana reescribía el mes cerrado en
  /// pantalla, en Mi Nómina y en el Excel.
  Future<Map<String, dynamic>?> snapshotNomina(String mes,
      {required String entrenadorId, int? telegramId}) async {
    for (final s
        in await _db.allMirror('nomina_liquidada_snapshot')) {
      if (_coincideEntrenador(s, mes, entrenadorId, telegramId)) {
        return s;
      }
    }
    for (final op in await _db.opsDeTipo('liquidar_nomina')) {
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if (_coincideEntrenador(p, mes, entrenadorId, telegramId)) {
          return p;
        }
      } catch (_) {}
    }
    return null;
  }

  /// N-5 (1.22): aplica las fotos de liquidación a los mapas
  /// de un libro de adelantos en construcción. Para cada mes
  /// con snapshot de ESTE entrenador, bruto/bonos/comisiones
  /// salen de la FOTO (congelados al liquidar), no del cálculo
  /// vivo: antes, un cambio de tarifa reescribía los meses ya
  /// pagados y el arrastre de la cadena inventaba una deuda
  /// que nunca existió. La foto sin `base` (legado) cae a
  /// conteo × tarifa de la propia foto.
  Future<void> aplicarFotosLibro({
    required Map<String, double> brutoPorMes,
    required Map<String, double> comisionesPorMes,
    required Map<String, double> bonosPorMes,
    required Map<String, int> conteoPorMes,
    required String entrenadorId,
    int? telegramId,
  }) async {
    final meses = <String>{
      ...brutoPorMes.keys,
      ...comisionesPorMes.keys,
      ...bonosPorMes.keys,
    };
    for (final mes in meses) {
      final snap = await snapshotNomina(mes,
          entrenadorId: entrenadorId, telegramId: telegramId);
      if (snap == null) continue;
      final base = (snap['base'] as num?)?.toDouble();
      final tarifaFoto =
          (snap['tarifa_por_cliente'] as num?)?.toDouble();
      if (base != null) {
        brutoPorMes[mes] = base;
      } else if (tarifaFoto != null && conteoPorMes[mes] != null) {
        brutoPorMes[mes] = conteoPorMes[mes]! * tarifaFoto;
      }
      final bonosFoto = (snap['bonos'] as num?)?.toDouble();
      if (bonosFoto != null) bonosPorMes[mes] = bonosFoto;
      final comisionesFoto =
          (snap['comisiones'] as num?)?.toDouble();
      if (comisionesFoto != null) {
        comisionesPorMes[mes] = comisionesFoto;
      }
    }
  }

  /// T22 (1.20): la confirmación de recepción de un mes: la
  /// fila del espejo, o una marca local si la op ya salió de
  /// este teléfono (pendiente/enviada/aplicada) y el espejo
  /// aún no bajó. Null si no hay confirmación.
  Future<Map<String, dynamic>?> confirmacionNomina(String mes,
      {required String entrenadorId, int? telegramId}) async {
    for (final c in await _db.allMirror('nomina_confirmaciones')) {
      if (_coincideEntrenador(c, mes, entrenadorId, telegramId)) {
        return c;
      }
    }
    for (final op
        in await _db.opsDeTipo('nomina_confirmar_recepcion')) {
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if (_coincideEntrenador(p, mes, entrenadorId, telegramId)) {
          return {'mes': mes, 'local': true};
        }
      } catch (_) {}
    }
    return null;
  }

  /// T22 (1.20): el entrenador confirma que recibió su
  /// nómina del mes (el servidor exige que sea él mismo y
  /// que el mes esté liquidado).
  Future<void> confirmarRecepcionNomina({
    required String mes,
    required String entrenadorId,
    required String entrenadorNombre,
    int? entrenadorTelegramId,
  }) =>
      _queueYEmpujar('nomina_confirmar_recepcion', {
        'mes': mes,
        'entrenador': entrenadorId,
        'entrenador_nombre': entrenadorNombre,
        if (entrenadorTelegramId != null)
          'entrenador_telegram_id': entrenadorTelegramId,
      });

  /// El mes en curso ('YYYY-MM') en hora de La Habana.
  static String mesActual() {
    final h = ahoraHabana();
    return '${h.year.toString().padLeft(4, '0')}-'
        '${h.month.toString().padLeft(2, '0')}';
  }
}
