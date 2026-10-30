/// Auditoría total por persona (v1.8.0) — núcleo puro.
///
/// Vista consultiva (diseño DISENO_AUDITORIA_PERSONA + adenda de
/// Argón P1–P4): NUNCA recalcula nómina ni corrige nada; deriva
/// turnos, dinero y anomalías de los registros existentes.
///
/// Reglas de Argón incorporadas:
/// - P1: la tardanza se mide contra la hora del EVENTO (reloj del
///   dispositivo al abrir), jamás contra la hora de sincronizar.
/// - P2: la cobertura se declara contra la marca de agua GLOBAL
///   del espejo (no por filas del actor): dentro de la ventana
///   sincronizada, 0 filas del actor = 0 actividad real.
/// - P3: prohibido cruzar aperturas ↔ cobros por horas: el dinero
///   se atribuye por `registrado_por`; los arqueos, por quien
///   cerró. Cada bloque lee solo su clave.
/// - P4: resolver de doble clave, solo lectura: manda el id
///   (uuid o telegram_id) cuando la fila lo trae; el nombre SOLO
///   se usa cuando la fila no trae ninguna clave de actor.
library;

import 'turnos_resolucion.dart';

/// Una persona auditable (usuario APK).
class PersonaApk {
  final String id; // uuid del usuario APK
  final int? telegramId;
  final String nombre;
  final bool activo;
  const PersonaApk({
    required this.id,
    required this.telegramId,
    required this.nombre,
    this.activo = true,
  });
}

int? _comoEntero(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// Resolver P4: ¿la fila pertenece a la persona?
/// - Si la fila trae id de usuario (uuid) → decide el uuid.
/// - Si trae telegram_id → decide el telegram_id.
/// - Si no trae ninguna clave → respaldo por nombre normalizado.
bool filaEsDePersona(Map<String, dynamic> fila, PersonaApk p) {
  final uuid = fila['entrenador_id'] ?? fila['actor_id'] ?? fila['user_id'];
  if (uuid is String && uuid.trim().isNotEmpty) {
    return uuid.trim() == p.id;
  }
  final tg = _comoEntero(
      fila['telegram_id'] ?? fila['registrado_por'] ?? fila['cerrado_por']);
  if (tg != null) {
    return p.telegramId != null && tg == p.telegramId;
  }
  final nombre = fila['registrado_por_nombre'] ?? fila['entrenador_nombre'];
  if (nombre is String && nombre.trim().isNotEmpty) {
    return normalizarNombreTurno(nombre) ==
        normalizarNombreTurno(p.nombre);
  }
  return false;
}

/// Un turno programado auditado (o una cobertura fuera de plan).
class TurnoAuditado {
  final DateTime fecha;
  final String franja;
  final bool eraSuyo; // estaba programado para esta persona
  final DateTime? aperturaEn; // hora del EVENTO (P1)
  final int? tardanzaMin; // > 0 si abrió tarde (contra el evento)
  final bool noApertura; // programado y no abrió
  final bool cubrioFueraDePlan; // abrió sin estar programado
  final DateTime? cierreEn;
  final int? duracionMin;
  final double? diferenciaArqueo; // del cierre de ESTA persona (P3b)
  const TurnoAuditado({
    required this.fecha,
    required this.franja,
    required this.eraSuyo,
    this.aperturaEn,
    this.tardanzaMin,
    this.noApertura = false,
    this.cubrioFueraDePlan = false,
    this.cierreEn,
    this.duracionMin,
    this.diferenciaArqueo,
  });

  bool get tarde => (tardanzaMin ?? 0) > 15;
  bool get corto => duracionMin != null && duracionMin! < 30;
}

DateTime? _instante(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

/// Bloque 1 — Turnos del período, con la resolución de Turnos
/// (patrón ⊕ excepciones) y las aperturas/cierres del espejo.
List<TurnoAuditado> auditarTurnosPersona({
  required PersonaApk persona,
  required DateTime desde,
  required DateTime hasta,
  required Map<int, Map<String, String?>> patron,
  required Map<String, Map<String, String?>> excepciones,
  required List<Map<String, dynamic>> aperturas,
  required List<Map<String, dynamic>> cierres,
  required List<PersonaApk> usuarios,
}) {
  final records = [
    for (final u in usuarios)
      (id: u.id, nombre: u.nombre, activo: u.activo),
  ];
  final out = <TurnoAuditado>[];
  var dia = DateTime(desde.year, desde.month, desde.day);
  final ultimo = DateTime(hasta.year, hasta.month, hasta.day);
  while (!dia.isAfter(ultimo)) {
    final fechaIso = isoFechaTurno(dia);
    for (final franja in const ['manana', 'tarde']) {
      final ventana = ventanaFranja(dia, franja);
      if (ventana == null) continue;
      final progNombre = programadoEn(
          fecha: dia,
          franja: franja,
          patron: patron,
          excepciones: excepciones);
      final progId = progNombre == null
          ? null
          : resolverIdPorNombre(progNombre, records);
      final eraSuyo = progId != null && progId == persona.id;
      // Aperturas de ESTA persona en la fecha/franja (la fila ya
      // declara su franja; la identidad manda, no la hora — P3).
      final suyas = [
        for (final a in aperturas)
          if ('${a['fecha_turno'] ?? ''}' == fechaIso &&
              '${a['turno'] ?? ''}'.toLowerCase().contains(
                  franja == 'manana' ? 'ma' : 'tarde') &&
              filaEsDePersona(a, persona))
            a,
      ];
      final cierreSuyo = cierres.where((c) {
        return '${c['fecha'] ?? ''}' == fechaIso &&
            '${c['turno'] ?? ''}'.toLowerCase().contains(
                franja == 'manana' ? 'ma' : 'tarde') &&
            filaEsDePersona(c, persona);
      }).firstOrNull;
      if (suyas.isEmpty && !eraSuyo) continue;
      final ap = suyas.isEmpty ? null : suyas.first;
      final aperturaEn = _instante(ap?['hora_apertura']);
      int? tardanza;
      if (aperturaEn != null) {
        final inicio = DateTime(dia.year, dia.month, dia.day)
            .add(Duration(minutes: ventana.inicio));
        final dif = aperturaEn.difference(inicio).inMinutes;
        tardanza = dif > 0 ? dif : 0;
      }
      final cierreEn = _instante(cierreSuyo?['cerrado_en']);
      out.add(TurnoAuditado(
        fecha: dia,
        franja: franja,
        eraSuyo: eraSuyo,
        aperturaEn: aperturaEn,
        tardanzaMin: aperturaEn == null ? null : tardanza,
        noApertura: eraSuyo && suyas.isEmpty,
        cubrioFueraDePlan: !eraSuyo && suyas.isNotEmpty,
        cierreEn: cierreEn,
        duracionMin: (aperturaEn != null && cierreEn != null)
            ? cierreEn.difference(aperturaEn).inMinutes
            : null,
        diferenciaArqueo:
            (cierreSuyo?['diferencia'] as num?)?.toDouble(),
      ));
    }
    dia = dia.add(const Duration(days: 1));
  }
  return out;
}

/// Bloque 2 — Dinero que movió (P3: cobros por registrado_por;
/// arqueos por cerrado_por; sin cruces por horas).
class DineroAuditado {
  int pagosMes = 0;
  double mensualEfectivo = 0;
  double mensualTransferencia = 0;
  int pagosDiarios = 0;
  double diarioTotal = 0;
  int ventasSuplementos = 0;
  double suplementosTotal = 0;
  int ventasDosis = 0;
  double dosisTotal = 0;
  double comisionDosis = 0;
  double pendienteGenerado = 0; // efectivo cobrado y aún no entregado
  double entregadoConfirmado = 0; // efectivo ya entregado al dueño
  int arqueos = 0;
  double diferenciaArqueos = 0; // suma con signo de SUS cierres

  double get totalCobrado =>
      mensualEfectivo +
      mensualTransferencia +
      diarioTotal +
      suplementosTotal +
      dosisTotal;
}

bool _enPeriodo(Map<String, dynamic> fila, String desde, String hasta) {
  final f = '${fila['fecha'] ?? ''}';
  return f.length >= 10 &&
      f.substring(0, 10).compareTo(desde) >= 0 &&
      f.substring(0, 10).compareTo(hasta) <= 0;
}

DineroAuditado auditarDineroPersona({
  required PersonaApk persona,
  required String desdeIso,
  required String hastaIso,
  required List<Map<String, dynamic>> pagos,
  required List<Map<String, dynamic>> pagosDiarios,
  required List<Map<String, dynamic>> ventasSuplementos,
  required List<Map<String, dynamic>> ventasServicios,
  required List<Map<String, dynamic>> cierres,
}) {
  final d = DineroAuditado();
  for (final p in pagos) {
    if (!_enPeriodo(p, desdeIso, hastaIso)) continue;
    if (!filaEsDePersona(p, persona)) continue;
    final monto = (p['monto'] as num?)?.toDouble() ?? 0;
    d.pagosMes++;
    if ('${p['metodo']}' == 'transferencia') {
      d.mensualTransferencia += monto;
    } else {
      d.mensualEfectivo += monto;
      // «Pendiente a entregar»: solo el efectivo (las
      // transferencias van directo a la cuenta del dueño).
      if ((p['entregado'] as int? ?? 0) == 1) {
        d.entregadoConfirmado += monto;
      } else {
        d.pendienteGenerado += monto;
      }
    }
  }
  for (final p in pagosDiarios) {
    if (!_enPeriodo(p, desdeIso, hastaIso)) continue;
    if (!filaEsDePersona(p, persona)) continue;
    d.pagosDiarios++;
    d.diarioTotal += (p['total'] as num?)?.toDouble() ?? 0;
  }
  for (final v in ventasSuplementos) {
    if (!_enPeriodo(v, desdeIso, hastaIso)) continue;
    if (!filaEsDePersona(v, persona)) continue;
    // Argón P3#3: la columna es `precio` (no `precio_unitario`, que
    // es de servicio_ventas); solo CUP; anuladas fuera por estado
    // o por las claves anulada/anulado.
    if ('${v['estado'] ?? ''}' == 'anulada') continue;
    if ((v['anulada'] as num?)?.toInt() == 1 ||
        (v['anulado'] as num?)?.toInt() == 1 ||
        v['anulada'] == true ||
        v['anulado'] == true) {
      continue;
    }
    if ((v['moneda'] as String?) != null &&
        (v['moneda'] as String?) != 'CUP') {
      continue;
    }
    d.ventasSuplementos++;
    d.suplementosTotal +=
        ((v['total'] as num?)?.toDouble() ??
                ((v['precio'] as num?)?.toDouble() ?? 0) *
                    ((v['cantidad'] as num?)?.toDouble() ?? 0));
  }
  for (final v in ventasServicios) {
    if (!_enPeriodo(v, desdeIso, hastaIso)) continue;
    if (!filaEsDePersona(v, persona)) continue;
    if ((v['casa'] as int? ?? 0) == 1) continue; // Casa no es dinero
    final cant = (v['cantidad'] as num?)?.toDouble() ?? 0;
    d.ventasDosis += cant >= 0 ? 1 : 0;
    d.dosisTotal +=
        ((v['precio_unitario'] as num?)?.toDouble() ?? 0) * cant;
    d.comisionDosis +=
        ((v['comision_unitaria'] as num?)?.toDouble() ?? 0) * cant;
  }
  for (final c in cierres) {
    if (!_enPeriodo(c, desdeIso, hastaIso)) continue;
    if (!filaEsDePersona(c, persona)) continue;
    d.arqueos++;
    d.diferenciaArqueos += (c['diferencia'] as num?)?.toDouble() ?? 0;
  }
  return d;
}

/// Bloque 5 — Resumen del período.
class ResumenAuditoria {
  final int diasTrabajados;
  final int horasRealesMin;
  final double totalCobrado;
  final int accionesSensibles;
  final int anomalias;
  const ResumenAuditoria({
    required this.diasTrabajados,
    required this.horasRealesMin,
    required this.totalCobrado,
    required this.accionesSensibles,
    required this.anomalias,
  });
}

ResumenAuditoria resumirAuditoria({
  required List<TurnoAuditado> turnos,
  required DineroAuditado dinero,
  required int accionesSensibles,
}) {
  final dias = <String>{};
  var minutos = 0;
  var anomalias = 0;
  for (final t in turnos) {
    if (t.aperturaEn != null) dias.add(isoFechaTurno(t.fecha));
    if (t.duracionMin != null) minutos += t.duracionMin!;
    if (t.noApertura || t.tarde || t.corto) anomalias++;
  }
  if (dinero.diferenciaArqueos != 0) anomalias++;
  return ResumenAuditoria(
    diasTrabajados: dias.length,
    horasRealesMin: minutos,
    totalCobrado: dinero.totalCobrado,
    accionesSensibles: accionesSensibles,
    anomalias: anomalias,
  );
}

/// P2 — Texto de cobertura del espejo de aperturas: se decide
/// contra la ventana GLOBAL sincronizada (fecha más vieja del
/// espejo), nunca por las filas de la persona.
String? avisoCoberturaAperturas({
  required String desdeIso,
  required String? minFechaEspejo,
}) {
  if (minFechaEspejo == null) {
    return 'Sin datos de aperturas en el espejo de este teléfono: '
        'sincroniza para auditar turnos.';
  }
  if (desdeIso.compareTo(minFechaEspejo) < 0) {
    return 'El espejo de aperturas de este teléfono llega hasta '
        '$minFechaEspejo: los días anteriores no tienen datos de '
        'aperturas (no significa que no se trabajara).';
  }
  return null;
}
