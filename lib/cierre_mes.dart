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
class PasoCierreMes {
  final String id;
  final String titulo;
  final String detalle;
  final bool verificado;

  /// Manual = lo confirma el dueño con un toque (no hay señal
  /// automática honesta); auto = se lee de los datos.
  final bool esManual;

  const PasoCierreMes({
    required this.id,
    required this.titulo,
    required this.detalle,
    required this.verificado,
    required this.esManual,
  });
}

class EstadoCierreMes {
  final String pref; // YYYY-MM
  final List<PasoCierreMes> pasos;
  final DateTime? cerradoEn;

  const EstadoCierreMes({
    required this.pref,
    required this.pasos,
    required this.cerradoEn,
  });

  bool get listo => pasos.every((p) => p.verificado);
  int get verificados => pasos.where((p) => p.verificado).length;
}

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

/// Confirmación manual de un paso (nomina / respaldo).
Future<void> confirmarPasoCierreMes(String pref, String pasoId) async {
  final p = await _progreso(pref);
  final manuales = Map<String, dynamic>.from(
      (p['manuales'] as Map?) ?? const {});
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
  final manuales =
      Map<String, dynamic>.from((progreso['manuales'] as Map?) ?? const {});
  bool manualOk(String id) => manuales[id] != null;

  // --- Paso 0: sincronización (cola local + teléfonos W5) ---
  // Delta del panel del Bloque 6: este pre-check cierra un
  // mes, así que la lectura de teléfonos NO degrada a verde:
  // si no se puede COMPROBAR que ningún teléfono en turno
  // está atrasado (o sin registro), el paso queda sin
  // verificar. Fail-closed, como manda un cierre.
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
  final pasoSync = PasoCierreMes(
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
  );

  // --- Foto de nómina del mes (pasos 1 a 4) ---
  final foto = await fotoNominaMes(pref);
  final personas = foto.personas;

  final pasoNomina = PasoCierreMes(
    id: 'nomina',
    titulo: 'Nómina revisada',
    detalle: 'Revisa la nómina de este mes en su pantalla '
        '(clientes que pagaron el mes × tarifa, más '
        'comisiones, menos adelantos) y confirma aquí que '
        'cuadra.',
    verificado: manualOk('nomina'),
    esManual: true,
  );

  final faltanLiquidar = <String>[
    for (final e in personas.entries)
      if (foto.liquidadas[e.key] != true) e.value.nombre,
  ];
  final pasoLiquidaciones = PasoCierreMes(
    id: 'liquidaciones',
    titulo: 'Nóminas liquidadas',
    detalle: personas.isEmpty
        ? 'Sin datos de entrenadores para este mes.'
        : faltanLiquidar.isEmpty
            ? 'Todos los entrenadores tienen su nómina de '
                'este mes liquidada.'
            : 'Falta liquidar a: ${faltanLiquidar.join(', ')}.',
    verificado: personas.isNotEmpty && faltanLiquidar.isEmpty,
    esManual: false,
  );

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
    final arq = await pendienteArqueo(tid);
    if (arq.cup != 0 || arq.usd != 0) {
      arqueoPendiente.add(e.value.nombre);
    }
    final ent = await pendienteEntrega(tid);
    final entUsd = await pendienteEntregaUsd(tid);
    if (ent != 0 || entUsd != 0) {
      entregaPendiente.add(e.value.nombre);
    }
  }
  final pasoArqueo = PasoCierreMes(
    id: 'arqueo',
    titulo: 'Arqueo de caja',
    detalle: personas.isEmpty
        ? 'Sin datos de entrenadores para este mes.'
        : sinTelegram.isNotEmpty
            ? 'No se puede verificar el arqueo de: '
                '${sinTelegram.join(', ')} (su usuario no trae '
                'identificador de Telegram).'
            : arqueoPendiente.isEmpty
                ? 'Todo el efectivo cobrado ya pasó por una '
                    'liquidación de caja.'
                : 'Efectivo sin liquidar de: '
                    '${arqueoPendiente.join(', ')}. Haz el '
                    'arqueo con cada uno.',
    verificado: personas.isNotEmpty &&
        arqueoPendiente.isEmpty &&
        sinTelegram.isEmpty,
    esManual: false,
  );
  final pasoEntrega = PasoCierreMes(
    id: 'entrega',
    titulo: 'Pendiente a entregar en cero',
    detalle: personas.isEmpty
        ? 'Sin datos de entrenadores para este mes.'
        : sinTelegram.isNotEmpty
            ? 'No se puede verificar la entrega de: '
                '${sinTelegram.join(', ')} (su usuario no trae '
                'identificador de Telegram).'
            : entregaPendiente.isEmpty
                ? 'Ningún entrenador te debe efectivo por '
                    'entregar.'
                : 'Aún te deben entregar: '
                    '${entregaPendiente.join(', ')}. Confirma '
                    'la entrega con cada uno.',
    verificado: personas.isNotEmpty &&
        entregaPendiente.isEmpty &&
        sinTelegram.isEmpty,
    esManual: false,
  );

  final pasoRespaldo = PasoCierreMes(
    id: 'respaldo',
    titulo: 'Respaldo exportado',
    detalle: 'Exporta el respaldo de la base desde Ajustes '
        '(solo tú puedes) y confirma aquí que quedó guardado '
        'fuera del teléfono.',
    verificado: manualOk('respaldo'),
    esManual: true,
  );

  final cerradoTxt = progreso['cerradoEn'] as String?;
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
  );
}
