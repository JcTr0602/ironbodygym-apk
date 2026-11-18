import 'dart:convert';

import 'app_log.dart';
import 'localdb.dart';
import 'negocio.dart';
import 'nomina_foto.dart';
import 'tiempo.dart';
import 'ultimo_sync.dart';

/// 1.23 (W2): cierre de mes guiado.
///
/// Una ruta paso a paso para cerrar el mes, que GUÍA y
/// VERIFICA con las acciones que ya existen — no mueve dinero
/// por su cuenta: cada paso lo confirma el dueño en su
/// pantalla de siempre, y este asistente solo comprueba el
/// resultado.
///
/// Pasos (el orden es el del diseño):
/// 0. Sincronización (blindaje de Argón: Paso 0): nada
///    pendiente de subir en ESTE teléfono y ningún teléfono
///    del staff en turno atrasado (la medida W5). Cerrar el
///    mes con trabajo sin sincronizar es cerrar sobre datos
///    incompletos.
/// 1. Nómina revisada (manual): el dueño confirma que revisó
///    la nómina del mes en su pantalla.
/// 2. Liquidaciones (auto): la nómina del mes está liquidada
///    para TODOS los entrenadores de la foto.
/// 3. Arqueo (auto): ningún entrenador tiene efectivo cobrado
///    sin pasar por una liquidación de caja.
/// 4. Pendiente a entregar (auto): cero en CUP y USD por
///    entrenador.
/// 5. Respaldo exportado (manual): el dueño confirma que
///    exportó el respaldo desde Ajustes.
///
/// El progreso (confirmaciones manuales y el cierre) se
/// guarda por mes en la meta `cierre_mes_<YYYY-MM>`: si la
/// app se cierra a mitad de ruta, al volver cada paso está
/// como quedó. Los pasos automáticos NO se guardan: se
/// evalúan en vivo cada vez (su verdad es la BD, no la meta).
/// 1.36 H-B3 (136-815): el estado de un paso con nombre —
/// la UI pinta su chip con los tokens de la casa según
/// este enum, no según dos bools sueltos.
enum EstadoPasoCierre { verificado, pendiente, bloqueado, noVerificable }

/// 1.36 H-B3 (136-815): nombres acotados para los
/// detalles: 'A, B, C y 2 más' en vez del join sin límite
/// que desbordaba la tarjeta. PURO.
String resumenNombres(List<String> nombres, {int max = 3}) {
  if (nombres.length <= max) return nombres.join(', ');
  final visibles = nombres.take(max).join(', ');
  return '$visibles y ${nombres.length - max} más';
}

class PasoCierreMes {
  final String id;
  final String titulo;
  final String detalle;
  final bool verificado;

  /// Manual = lo confirma el dueño con un toque (no hay señal
  /// automática honesta); auto = se lee de los datos.
  final bool esManual;

  /// 1.36 H-B3 (136-815): TODOS los bloqueos del paso, uno
  /// por línea — el detalle resume, pero la tarjeta puede
  /// desplegar la lista completa (antes solo se veía el
  /// primer motivo).
  final List<String> bloqueos;

  /// 1.36 H-B3 (136-815): cuándo confirmó el dueño un paso
  /// manual (estaba guardado en la meta y no se exponía).
  final DateTime? confirmadoEn;

  /// 1.36 H-B3 (136-815): el paso no se pudo COMPROBAR
  /// (lectura fallida o entrenador sin identificador): no
  /// es «pendiente», es «no verificable».
  final bool noVerificable;

  /// 1.36 H-B3 (136-815): id de la pantalla que resuelve
  /// el paso (la ruta vive en el modelo, no solo en la UI).
  final String? destinoId;

  const PasoCierreMes({
    required this.id,
    required this.titulo,
    required this.detalle,
    required this.verificado,
    required this.esManual,
    this.bloqueos = const [],
    this.confirmadoEn,
    this.noVerificable = false,
    this.destinoId,
  });

  EstadoPasoCierre get estadoPaso {
    if (verificado) return EstadoPasoCierre.verificado;
    if (noVerificable) return EstadoPasoCierre.noVerificable;
    if (esManual) return EstadoPasoCierre.pendiente;
    return EstadoPasoCierre.bloqueado;
  }
}

class EstadoCierreMes {
  final String pref; // YYYY-MM
  final List<PasoCierreMes> pasos;
  final DateTime? cerradoEn;

  /// 1.36 H-C2 (136-813): la meta trae un `cerradoEn`
  /// pero NO es una fecha legible: la constancia existe
  /// y está corrupta — no es lo mismo que «mes abierto»
  /// y la UI lo dice en vez de ofrecer cerrar otra vez.
  final bool constanciaInvalida;

  const EstadoCierreMes({
    required this.pref,
    required this.pasos,
    required this.cerradoEn,
    this.constanciaInvalida = false,
  });

  bool get listo => pasos.every((p) => p.verificado);
  int get verificados => pasos.where((p) => p.verificado).length;
}

/// 1.36 H-C2 (136-814): el paso cuya comprobación FALLÓ
/// al leer sus datos: no verificado y «no verificable»,
/// con su motivo — la evaluación devuelve el resultado
/// por paso en vez de tumbar el cierre entero.
PasoCierreMes pasoNoComprobadoCierre(String id, String titulo,
        {bool esManual = false, String? destinoId}) =>
    PasoCierreMes(
      id: id,
      titulo: titulo,
      detalle: 'No se pudo comprobar este paso: la lectura '
          'de sus datos falló. Reintenta la evaluación.',
      verificado: false,
      esManual: esManual,
      bloqueos: const ['La comprobación de este paso falló'],
      noVerificable: true,
      destinoId: destinoId,
    );

/// El mes que se cierra por defecto: el anterior al actual
/// (el cierre se hace en los primeros días del mes siguiente).
String prefMesAnterior([DateTime? ahora]) {
  final h = ahora ?? ahoraHabana();
  final prev = DateTime(h.year, h.month - 1);
  return '${prev.year}-${prev.month.toString().padLeft(2, '0')}';
}

String _claveMeta(String pref) => 'cierre_mes_$pref';

Future<Map<String, dynamic>> _progreso(String pref) async {
  final txt = await LocalDb.instance.getMeta(_claveMeta(pref));
  if (txt == null || txt.isEmpty) return {};
  try {
    final j = jsonDecode(txt);
    return j is Map ? Map<String, dynamic>.from(j) : {};
  } catch (_) {
    return {};
  }
}

Future<void> _guardarProgreso(
    String pref, Map<String, dynamic> p) async {
  await LocalDb.instance.setMeta(_claveMeta(pref), jsonEncode(p));
}

/// Lectura tolerante del mapa de pasos manuales del progreso:
/// si el dato guardado viene con un tipo inesperado (p. ej.
/// una lista o un texto, escribible por fuera de la app), se
/// degrada a «sin pasos confirmados» en vez de lanzar con el
/// cast duro `as Map?` (corrección A1-D2: el cast dejaba la
/// pantalla de cierre en «cargando» para siempre).
Map<String, dynamic> _manualesDe(Map<String, dynamic> progreso) {
  final crudo = progreso['manuales'];
  if (crudo is Map) return Map<String, dynamic>.from(crudo);
  return <String, dynamic>{};
}

/// Confirmación manual de un paso (nomina / respaldo).
Future<void> confirmarPasoCierreMes(String pref, String pasoId) async {
  final p = await _progreso(pref);
  final manuales = _manualesDe(p);
  manuales[pasoId] = isoHabana(ahoraHabana());
  p['manuales'] = manuales;
  await _guardarProgreso(pref, p);
}

/// Marca el mes como cerrado. REEVALÚA el estado en el
/// momento de cerrar (delta del panel del Bloque 6): si algún
/// paso dejó de estar verificado desde que se pintó la
/// pantalla, el cierre se RECHAZA (false) y no se escribe
/// ninguna constancia falsa.
Future<bool> marcarMesCerrado(String pref) async {
  final estado = await evaluarCierreMes(pref);
  if (!estado.listo) return false;
  final p = await _progreso(pref);
  p['cerradoEn'] = isoHabana(ahoraHabana());
  await _guardarProgreso(pref, p);
  return true;
}

/// Evalúa el estado completo del cierre de [pref] en vivo.
Future<EstadoCierreMes> evaluarCierreMes(String pref) async {
  final db = LocalDb.instance;
  final progreso = await _progreso(pref);
  final manuales = _manualesDe(progreso);
  // 1.36 H-C2 (136-813): una confirmación manual solo
  // vale si su sello es una FECHA ISO parseable — un
  // valor corrupto o de otro tipo no confirma nada.
  bool manualOk(String id) {
    final v = manuales[id];
    return v is String && DateTime.tryParse(v) != null;
  }

  // --- Paso 0: sincronización (cola local + teléfonos W5) ---
  // Delta del panel del Bloque 6: este pre-check cierra un
  // mes, así que la lectura de teléfonos NO degrada a verde:
  // si no se puede COMPROBAR que ningún teléfono en turno
  // está atrasado (o sin registro), el paso queda sin
  // verificar. Fail-closed, como manda un cierre.
  late PasoCierreMes pasoSync;
  try {
    final pendientes = await db.countPendingOps();
    var atrasados = 0;
    var sinRegistroEnTurno = 0;
    var telefonosVerificables = true;
    try {
      final evaluados = await evaluarTelefonosSync();
      for (final t in evaluados) {
        if (t.estado == EstadoSyncTelefono.atrasado) atrasados++;
        if (t.enTurno && t.estado == EstadoSyncTelefono.sinRegistro) {
          sinRegistroEnTurno++;
        }
      }
    } catch (e) {
      telefonosVerificables = false;
      AppLog.error('cierre_mes', 'paso0_lectura_fallo', d: '$e');
    }
      pasoSync = PasoCierreMes(
      id: 'sync',
      titulo: 'Sincronización al día',
      detalle: pendientes > 0
          ? 'Este teléfono tiene $pendientes operaciones sin '
              'subir. Sincroniza antes de cerrar: el mes se cierra '
              'sobre los datos completos.'
          : !telefonosVerificables
              ? 'No se pudo COMPROBAR la sincronización de los '
                  'teléfonos del staff. Sincroniza y reintenta: '
                  'el cierre no se firma a ciegas.'
              : atrasados > 0
                  ? 'Hay $atrasados teléfono(s) en turno atrasados '
                      'sin sincronizar: su trabajo puede no haber '
                      'llegado al servidor todavía.'
                  : sinRegistroEnTurno > 0
                      ? 'Hay $sinRegistroEnTurno teléfono(s) EN '
                          'TURNO sin ninguna sincronización '
                          'registrada: no se puede cerrar sin '
                          'saber si su trabajo llegó.'
                      : 'Nada pendiente de subir y ningún '
                          'teléfono en turno atrasado.',
      verificado: pendientes == 0 &&
          telefonosVerificables &&
          atrasados == 0 &&
          sinRegistroEnTurno == 0,
      esManual: false,
      // 1.36 H-B3 (136-815): la checklist completa y el
      // estado «no verificable» cuando la lectura falló.
      bloqueos: [
        if (pendientes > 0)
          '$pendientes operaciones sin subir en este teléfono',
        if (!telefonosVerificables)
          'No se pudo comprobar la sincronización de los teléfonos',
        if (atrasados > 0) '$atrasados teléfono(s) en turno atrasados',
        if (sinRegistroEnTurno > 0)
          '$sinRegistroEnTurno teléfono(s) en turno sin registro de sync',
      ],
      noVerificable: !telefonosVerificables,
      destinoId: 'sync',
    );
  } catch (e) {
    AppLog.error('cierre_mes', 'paso_sync_fallo', d: '$e');
    pasoSync = pasoNoComprobadoCierre('sync',
        'Sincronización al día', destinoId: 'sync');
  }

  // --- Foto de nómina del mes (pasos 1 a 4) ---

  // 1.36 H-B3 (136-815): la hora de confirmación de los
  // pasos manuales sale de la meta (estaba guardada y no
  // se exponía en el modelo).
  DateTime? confirmadoDe(String id) {
    final v = manuales[id];
    return v is String ? DateTime.tryParse(v) : null;
  }

  final pasoNomina = PasoCierreMes(
    id: 'nomina',
    titulo: 'Nómina revisada',
    detalle: 'Revisa la nómina de este mes en su pantalla '
        '(clientes que pagaron el mes × tarifa, más '
        'comisiones, menos adelantos) y confirma aquí que '
        'cuadra.',
    verificado: manualOk('nomina'),
    esManual: true,
    confirmadoEn: confirmadoDe('nomina'),
    destinoId: 'nomina',
  );


  late PasoCierreMes pasoLiquidaciones;
  var personas =
      <String, ({String id, int? telegramId, String nombre})>{};
  var fotoOk = true;
  try {
    final foto = await fotoNominaMes(pref);
    personas = foto.personas;
      final faltanLiquidar = <String>[
      for (final e in personas.entries)
        if (foto.liquidadas[e.key] != true) e.value.nombre,
    ];
      pasoLiquidaciones = PasoCierreMes(
      id: 'liquidaciones',
      titulo: 'Nóminas liquidadas',
      detalle: personas.isEmpty
          ? 'Sin datos de entrenadores para este mes.'
          : faltanLiquidar.isEmpty
              ? 'Todos los entrenadores tienen su nómina de '
                  'este mes liquidada.'
              // 1.36 H-B3 (136-815): nombres acotados.
              : 'Falta liquidar a: ${resumenNombres(faltanLiquidar)}.',
      verificado: personas.isNotEmpty && faltanLiquidar.isEmpty,
      esManual: false,
      bloqueos: [
        for (final n in faltanLiquidar) 'Falta liquidar a $n',
      ],
      destinoId: 'liquidaciones',
    );
  } catch (e) {
    fotoOk = false;
    AppLog.error('cierre_mes', 'paso_foto_fallo', d: '$e');
    pasoLiquidaciones = pasoNoComprobadoCierre(
        'liquidaciones', 'Nóminas liquidadas',
        destinoId: 'liquidaciones');
  }

  late PasoCierreMes pasoArqueo;
  late PasoCierreMes pasoEntrega;
  if (!fotoOk) {
    pasoArqueo = pasoNoComprobadoCierre('arqueo', 'Arqueo de caja',
        destinoId: 'arqueo');
    pasoEntrega = pasoNoComprobadoCierre(
        'entrega', 'Pendiente a entregar en cero',
        destinoId: 'entrega');
  } else {
    try {
    // --- Arqueo y pendiente a entregar por entrenador ---
    // Delta del panel: un entrenador SIN telegramId no se puede
    // verificar (pendienteArqueo/Entrega se indexan por él):
    // omitirlo daba verde regalado. Sin identificador = paso
    // bloqueado con su nombre.
    var arqueoPendiente = <String>[];
    var entregaPendiente = <String>[];
    var sinTelegram = <String>[];
    for (final e in personas.entries) {
      final tid = e.value.telegramId;
      if (tid == null) {
        sinTelegram.add(e.value.nombre);
        continue;
      }
      // (M2-A A8/A11) los ids liquidados se decodifican UNA vez
      // por entrenador y se comparten entre las tres lecturas
      // (antes cada una re-decodificaba todas las liquidaciones,
      // y el libro C1 otra vez por dentro). La comparación
      // contra cero lleva la tolerancia de la casa (0.01): un
      // residuo de redondeo de 0.005 bloqueaba el cierre para
      // siempre, sin ninguna cifra visible que lo explicara.
      final cubiertos = await idsLiquidados(tid);
      final arq = await pendienteArqueo(tid, cubiertosPre: cubiertos);
      if (arq.cup > 0.01 || arq.usd > 0.01) {
        arqueoPendiente.add(e.value.nombre);
      }
      final ent = await pendienteEntrega(tid, cubiertosPre: cubiertos);
      final entUsd = await pendienteEntregaUsd(tid, cubiertosPre: cubiertos);
      if (ent > 0.01 || entUsd > 0.01) {
        entregaPendiente.add(e.value.nombre);
      }
    }
      pasoArqueo = PasoCierreMes(
      id: 'arqueo',
      titulo: 'Arqueo de caja',
      detalle: personas.isEmpty
          ? 'Sin datos de entrenadores para este mes.'
          : sinTelegram.isNotEmpty
              ? 'No se puede verificar el arqueo de: '
                  '${resumenNombres(sinTelegram)} (su usuario no trae '
                  'identificador de Telegram).'
              : arqueoPendiente.isEmpty
                  ? 'Todo el efectivo cobrado ya pasó por una '
                      'liquidación de caja.'
                  : 'Efectivo sin liquidar de: '
                      '${resumenNombres(arqueoPendiente)}. Haz el '
                      'arqueo con cada uno.',
      verificado: personas.isNotEmpty &&
          arqueoPendiente.isEmpty &&
          sinTelegram.isEmpty,
      esManual: false,
      // 1.36 H-B3 (136-815): checklist completa + estado.
      bloqueos: [
        for (final n in sinTelegram)
          '$n: sin identificador de Telegram (no verificable)',
        for (final n in arqueoPendiente)
          '$n: efectivo sin pasar por liquidación de caja',
      ],
      noVerificable: sinTelegram.isNotEmpty,
      destinoId: 'arqueo',
    );
      pasoEntrega = PasoCierreMes(
      id: 'entrega',
      titulo: 'Pendiente a entregar en cero',
      detalle: personas.isEmpty
          ? 'Sin datos de entrenadores para este mes.'
          : sinTelegram.isNotEmpty
              ? 'No se puede verificar la entrega de: '
                  '${resumenNombres(sinTelegram)} (su usuario no trae '
                  'identificador de Telegram).'
              : entregaPendiente.isEmpty
                  ? 'Ningún entrenador te debe efectivo por '
                      'entregar.'
                  : 'Aún te deben entregar: '
                      '${resumenNombres(entregaPendiente)}. Confirma '
                      'la entrega con cada uno.',
      verificado: personas.isNotEmpty &&
          entregaPendiente.isEmpty &&
          sinTelegram.isEmpty,
      esManual: false,
      bloqueos: [
        for (final n in sinTelegram)
          '$n: sin identificador de Telegram (no verificable)',
        for (final n in entregaPendiente)
          '$n: aún debe entregar efectivo',
      ],
      noVerificable: sinTelegram.isNotEmpty,
      destinoId: 'entrega',
    );
    } catch (e) {
      AppLog.error('cierre_mes', 'paso_arqueo_fallo', d: '$e');
      pasoArqueo = pasoNoComprobadoCierre('arqueo', 'Arqueo de caja',
          destinoId: 'arqueo');
      pasoEntrega = pasoNoComprobadoCierre(
          'entrega', 'Pendiente a entregar en cero',
          destinoId: 'entrega');
    }
  }

  final pasoRespaldo = PasoCierreMes(
    id: 'respaldo',
    titulo: 'Respaldo exportado',
    detalle: 'Exporta el respaldo de la base desde Ajustes '
        '(solo tú puedes) y confirma aquí que quedó guardado '
        'fuera del teléfono.',
    verificado: manualOk('respaldo'),
    esManual: true,
    confirmadoEn: confirmadoDe('respaldo'),
    destinoId: 'respaldo',
  );

  // (M2-A A8) lectura tolerante: un cerradoEn corrupto (no
  // texto) tumbaba la evaluación entera con el cast duro.
  final cerradoCrudo = progreso['cerradoEn'];
  final cerradoTxt = cerradoCrudo is String ? cerradoCrudo : null;
  return EstadoCierreMes(
    pref: pref,
    pasos: [
      pasoSync,
      pasoNomina,
      pasoLiquidaciones,
      pasoArqueo,
      pasoEntrega,
      pasoRespaldo,
    ],
    cerradoEn:
        cerradoTxt == null ? null : DateTime.tryParse(cerradoTxt),
    // 136-813: sello presente pero ilegible = constancia
    // corrupta, distinguible del mes abierto.
    constanciaInvalida: cerradoTxt != null &&
        DateTime.tryParse(cerradoTxt) == null,
  );
}
