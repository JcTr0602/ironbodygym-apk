/// Diario de sincronizaciones (1.32, Oleada 2 Fase 2 — M1 del
/// sistema de detalle de sync, diseño syncdet_ EN FIRME).
///
/// El registro PERSISTENTE de cada corrida de sincronización:
/// qué hizo, cuánto, cuándo, con qué resultado y por qué no
/// selló si no selló. Es la fuente de verdad del Centro de
/// Sincronización (M2/M3) y de la vigilancia proactiva (M4).
///
/// Reglas que este archivo hace cumplir:
/// - M1-R1: la fila nace 'en_curso' al abrir la corrida DENTRO
///   del candado (el motor la abre en `_conLock`) y se cierra
///   una sola vez: el cierre es condicional a seguir 'en_curso'
///   (una corrida zombi jamás resucita ni muta la foto de una
///   corrida que otro ciclo ya cerró como 'cortada').
/// - M1-A4: la huérfana 'en_curso' la cierra como 'cortada' la
///   SIGUIENTE corrida, como primer paso tras adquirir el
///   candado — su foto (tabla_actual/pagina_actual y las filas
///   por tabla ya volcadas) queda congelada.
/// - M1-R2/A3: los conteos por tabla se vuelcan con
///   acumulación ON CONFLICT (la misma corrida puede reintentar
///   el pull hasta 3 veces y hacer 2 pasadas de push).
/// - M1-R3/A2: los chequeos automáticos VACÍOS no ocupan
///   plaza: al cerrar, si la corrida fue automática, terminó
///   'completa' y no movió nada (0 subidos, 0 bajados, 0
///   fotos), su fila se BORRA y solo quedan en meta el sello
///   `ultimo_chequeo_vacio_ts` y el contador
///   `chequeos_vacios_desde_ultima_corrida`.
/// - Retención: 50 corridas o 30 días, con blindaje forense —
///   la última corrida de instalación/bajada completa y las
///   últimas 5 fallidas/cortadas están exentas de la poda por
///   cantidad (solo caducan a los 30 días).
/// - M1-R5: si el diario falla, la sincronización sigue; el
///   motor envuelve cada llamada en try/catch y la corrida sin
///   registro se declara como tal en la UI, nunca se inventa.
///
/// Este archivo es SOLO almacén + reglas puras: quien calcula
/// los conteos y los veredictos es el motor (sync.dart), que
/// ya los tiene en la mano donde ocurren.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'tipos_operacion.dart';

/// Tipos de corrida (columna `tipo` de sync_corridas).
abstract final class TipoCorrida {
  static const completa = 'completa';
  static const soloPush = 'solo_push';
  static const soloPull = 'solo_pull';
  static const scope = 'scope';
  static const bajadaCompleta = 'bajada_completa';
}

/// Orígenes de corrida (columna `origen`).
abstract final class OrigenCorrida {
  static const manual = 'manual';
  static const automatica = 'automatica';

  /// El pull silencioso que sigue a un push dentro de la
  /// misma corrida no abre corrida propia (cuenta en la del
  /// push); este origen queda para corridas cuyo único
  /// trabajo fue ese chequeo tras subida.
  static const trasPush = 'tras_push';

  /// La corrida arranca con el cursor global en 0 (el
  /// teléfono aún no ha completado su primera bajada).
  static const instalacion = 'instalacion';
}

/// Resultados de corrida (columna `estado` al cerrar;
/// 'en_curso' mientras corre).
abstract final class EstadoCorrida {
  static const enCurso = 'en_curso';
  static const completa = 'completa';
  static const parcial = 'parcial';
  static const fallida = 'fallida';
  static const cortada = 'cortada';
}

/// M1-R3 (PURA): ¿esta corrida cerrada NO merece plaza en el
/// diario? Solo los chequeos automáticos (o tras push) que
/// terminaron completos sin mover una sola fila: los que el
/// temporizador de 2 minutos produce ~30 veces por hora.
/// 1.32 (Corte B, H-CB-6 — Hydrogen B-3): los comprobantes
/// de pago subidos también son trabajo — una corrida cuyo
/// único fruto fue subir comprobantes NO es un chequeo
/// vacío y conserva su plaza (antes se borraba del diario
/// y ese trabajo quedaba invisible).
bool corridaSinPlaza({
  required String origen,
  required String estado,
  required int subidos,
  required int bajados,
  required int fotosSubidas,
  required int fotosFallidas,
  required int comprobantesSubidos,
}) {
  if (estado != EstadoCorrida.completa) return false;
  if (origen != OrigenCorrida.automatica &&
      origen != OrigenCorrida.trasPush) {
    return false;
  }
  return subidos == 0 &&
      bajados == 0 &&
      fotosSubidas == 0 &&
      fotosFallidas == 0 &&
      comprobantesSubidos == 0;
}

/// Retención (PURA): dada la lista de corridas (cualquier
/// orden), devuelve los ids a PODAR. Reglas:
/// - Toda corrida con inicio anterior al corte de 30 días se
///   poda (también las blindadas: el blindaje es solo contra
///   la poda por CANTIDAD).
/// - Del resto se conservan las 50 más recientes; el exceso
///   se poda EXCEPTO la corrida de instalación/bajada
///   completa más reciente y las 5 fallidas/cortadas más
///   recientes (blindaje forense).
List<String> seleccionarPodaDiario(
  List<
      ({
        String id,
        String tipo,
        String origen,
        String estado,
        int inicioEpoch
      })> corridas, {
  required int ahoraEpoch,
  int maxCorridas = 50,
  int diasRetencion = 30,
}) {
  final corte = ahoraEpoch - diasRetencion * 24 * 3600;
  final ordenadas = [...corridas]
    ..sort((a, b) => b.inicioEpoch.compareTo(a.inicioEpoch));
  final poda = <String>{};
  final vivas = <({
    String id,
    String tipo,
    String origen,
    String estado,
    int inicioEpoch
  })>[];
  for (final c in ordenadas) {
    if (c.inicioEpoch < corte) {
      poda.add(c.id);
    } else {
      vivas.add(c);
    }
  }
  if (vivas.length > maxCorridas) {
    // Blindaje forense (sobre las vivas, de más reciente a
    // más antigua): la última corrida de instalación o de
    // bajada completa y las 5 últimas fallidas/cortadas no
    // se podan por cantidad.
    String? blindadaInstalacion;
    final blindadasFallo = <String>{};
    for (final c in vivas) {
      if (blindadaInstalacion == null &&
          (c.tipo == TipoCorrida.bajadaCompleta ||
              c.origen == OrigenCorrida.instalacion)) {
        blindadaInstalacion = c.id;
      }
      if ((c.estado == EstadoCorrida.fallida ||
              c.estado == EstadoCorrida.cortada) &&
          blindadasFallo.length < 5) {
        blindadasFallo.add(c.id);
      }
    }
    for (var i = maxCorridas; i < vivas.length; i++) {
      final c = vivas[i];
      if (c.id == blindadaInstalacion) continue;
      if (blindadasFallo.contains(c.id)) continue;
      poda.add(c.id);
    }
  }
  return poda.toList();
}

/// Resumen legible de una op para la foto del diario (PURA).
/// Solo etiqueta del tipo + monto: el NOMBRE del cliente no
/// se copia a la foto (la cola viva ya lo enseña con su
/// control de cliente protegido; la foto es un registro de
/// larga vida y minimiza datos personales).
String resumenOpDiario(String tipo, Map<String, dynamic> payload) {
  final base = describirTipoOpConPayload(tipo, payload);
  final monto = payload['monto'];
  if (monto != null) {
    final m = monto is num ? monto : num.tryParse('$monto');
    if (m != null) {
      return '$base · ${m % 1 == 0 ? m.toInt() : m} CUP';
    }
  }
  return base;
}

/// Una corrida del diario, tal como se lee de sync_corridas.
class CorridaSync {
  final String id;
  final String tipo;
  final String origen;
  final String? disparador;
  final int inicioEpoch;
  final int? finEpoch;
  final int? duracionMs;
  final String estado;
  final int subidos;
  final int bajados;
  final int fotosSubidas;
  final int fotosFallidas;
  final int comprobantesSubidos;
  final int? serverSeq;
  final int? watermarkMin;
  final String? motivoNoSello;
  final String? errorCodigo;
  final String? errorDetalle;
  final String? tablaActual;
  final int? paginaActual;
  final String? rol;
  final String? versionApp;

  const CorridaSync({
    required this.id,
    required this.tipo,
    required this.origen,
    this.disparador,
    required this.inicioEpoch,
    this.finEpoch,
    this.duracionMs,
    required this.estado,
    this.subidos = 0,
    this.bajados = 0,
    this.fotosSubidas = 0,
    this.fotosFallidas = 0,
    this.comprobantesSubidos = 0,
    this.serverSeq,
    this.watermarkMin,
    this.motivoNoSello,
    this.errorCodigo,
    this.errorDetalle,
    this.tablaActual,
    this.paginaActual,
    this.rol,
    this.versionApp,
  });

  factory CorridaSync.fromMap(Map<String, dynamic> m) {
    int entero(String k) => (m[k] as num?)?.toInt() ?? 0;
    int? enteroN(String k) => (m[k] as num?)?.toInt();
    return CorridaSync(
      id: '${m['id']}',
      tipo: '${m['tipo'] ?? ''}',
      origen: '${m['origen'] ?? ''}',
      disparador: m['disparador'] as String?,
      inicioEpoch: entero('inicio_epoch'),
      finEpoch: enteroN('fin_epoch'),
      duracionMs: enteroN('duracion_ms'),
      estado: '${m['estado'] ?? ''}',
      subidos: entero('subidos'),
      bajados: entero('bajados'),
      fotosSubidas: entero('fotos_subidas'),
      fotosFallidas: entero('fotos_fallidas'),
      comprobantesSubidos: entero('comprobantes_subidos'),
      serverSeq: enteroN('server_seq'),
      watermarkMin: enteroN('watermark_min'),
      motivoNoSello: m['motivo_no_sello'] as String?,
      errorCodigo: m['error_codigo'] as String?,
      errorDetalle: m['error_detalle'] as String?,
      tablaActual: m['tabla_actual'] as String?,
      paginaActual: enteroN('pagina_actual'),
      rol: m['rol'] as String?,
      versionApp: m['version_app'] as String?,
    );
  }

  DateTime get inicio =>
      DateTime.fromMillisecondsSinceEpoch(inicioEpoch * 1000);
  DateTime? get fin => finEpoch == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(finEpoch! * 1000);
}

/// El desenlace por tabla de una corrida.
class CorridaTablaSync {
  final String tabla;
  final String direccion;
  final int recibidas;
  final int aplicadas;
  final int sinCambio;
  final int tumbas;
  final int fallidas;
  final int paginas;
  final int? wmAntes;
  final int? wmDespues;
  final String estado;
  final String? error;

  const CorridaTablaSync({
    required this.tabla,
    this.direccion = 'bajada',
    this.recibidas = 0,
    this.aplicadas = 0,
    this.sinCambio = 0,
    this.tumbas = 0,
    this.fallidas = 0,
    this.paginas = 0,
    this.wmAntes,
    this.wmDespues,
    this.estado = 'ok',
    this.error,
  });

  factory CorridaTablaSync.fromMap(Map<String, dynamic> m) {
    int entero(String k) => (m[k] as num?)?.toInt() ?? 0;
    int? enteroN(String k) => (m[k] as num?)?.toInt();
    return CorridaTablaSync(
      tabla: '${m['tabla'] ?? ''}',
      direccion: '${m['direccion'] ?? 'bajada'}',
      recibidas: entero('recibidas'),
      aplicadas: entero('aplicadas'),
      sinCambio: entero('sin_cambio'),
      tumbas: entero('tumbas'),
      fallidas: entero('fallidas'),
      paginas: entero('paginas'),
      wmAntes: enteroN('wm_antes'),
      wmDespues: enteroN('wm_despues'),
      estado: '${m['estado'] ?? 'ok'}',
      error: m['error'] as String?,
    );
  }
}

/// La foto resumida de una op de push de la corrida.
class CorridaOpSync {
  final String opUuid;
  final String tipo;
  final String? resumen;
  final String resultado;
  final String? motivo;

  const CorridaOpSync({
    required this.opUuid,
    required this.tipo,
    this.resumen,
    required this.resultado,
    this.motivo,
  });

  factory CorridaOpSync.fromMap(Map<String, dynamic> m) {
    return CorridaOpSync(
      opUuid: '${m['op_uuid'] ?? ''}',
      tipo: '${m['tipo'] ?? ''}',
      resumen: m['resumen'] as String?,
      resultado: '${m['resultado'] ?? 'pendiente'}',
      motivo: m['motivo'] as String?,
    );
  }
}

/// Estados de UNA tabla dentro de una corrida (columna
/// `estado` de sync_corrida_tablas).
abstract final class EstadoTablaDiario {
  static const ok = 'ok';
  static const sinCambios = 'sin_cambios';
  static const sinVerificar = 'sin_verificar';
  static const fallida = 'fallida';
  static const ausente = 'ausente';
}

/// Acumulador en memoria de UNA tabla durante una corrida.
/// El motor anota aquí lo que ya calcula (por intento de
/// pull: `_doPull` reintenta y `_download` se repite, así
/// que la anotación SUMA entre intentos, como manda M1-A3)
/// y el volcado a BD aplica la misma acumulación con
/// ON CONFLICT.
class AcumTablaDiario {
  int recibidas = 0;
  int aplicadas = 0;
  int sinCambio = 0;
  int tumbas = 0;
  int fallidas = 0;
  int paginas = 0;
  int? wmAntes;
  int? wmDespues;
  String estado = 'ok';
  String? error;

  /// Fusiona el desenlace de UN intento de descarga de esta
  /// tabla: conserva el wm_antes ORIGINAL (el de antes del
  /// primer intento) y el estado/error del ÚLTIMO intento.
  void fusionarIntento({
    int recibidas = 0,
    int aplicadas = 0,
    int sinCambio = 0,
    int tumbas = 0,
    int fallidas = 0,
    int paginas = 0,
    int? wmAntes,
    int? wmDespues,
    required String estado,
    String? error,
  }) {
    this.recibidas += recibidas;
    this.aplicadas += aplicadas;
    this.sinCambio += sinCambio;
    this.tumbas += tumbas;
    this.fallidas += fallidas;
    this.paginas += paginas;
    this.wmAntes ??= wmAntes;
    if (wmDespues != null) this.wmDespues = wmDespues;
    this.estado = estado;
    this.error = error;
  }
}

/// El almacén del diario. Todas las operaciones son
/// tolerantes por diseño del llamador (el motor las envuelve
/// en try/catch: M1-R5); aquí no se traga nada para que los
/// tests vean los fallos reales.
class DiarioSync {
  DiarioSync._();
  static final DiarioSync instance = DiarioSync._();

  LocalDb get _db => LocalDb.instance;
  static const _uuid = Uuid();

  /// Abre la fila de la corrida (estado 'en_curso') y
  /// devuelve su id. La llama el motor JUSTO tras adquirir
  /// el candado y tras cerrar las huérfanas.
  Future<String> abrirCorrida({
    required String tipo,
    required String origen,
    String? disparador,
    String? rol,
    String? versionApp,
    int? ahoraEpoch,
  }) async {
    final id = _uuid.v4();
    final d = await _db.db;
    await d.insert('sync_corridas', {
      'id': id,
      'tipo': tipo,
      'origen': origen,
      'disparador': disparador,
      'inicio_epoch':
          ahoraEpoch ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'estado': EstadoCorrida.enCurso,
      'rol': rol,
      'version_app': versionApp,
    });
    return id;
  }

  /// M1-A4: cierra como 'cortada' TODA corrida que siga
  /// 'en_curso' (su dueño murió o perdió el candado). Se
  /// llama dentro del candado, antes de abrir la propia: es
  /// el único instante con exclusividad entre isolates. La
  /// foto queda congelada: las filas por tabla ya volcadas
  /// no se tocan y tabla_actual/pagina_actual conservan el
  /// último progreso anotado. Devuelve cuántas cerró.
  Future<int> cerrarHuerfanasComoCortadas({int? ahoraEpoch}) async {
    final d = await _db.db;
    final fin =
        ahoraEpoch ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 1.36 H-C2 (136-921): la huérfana también deja su
    // DURACIÓN honesta (fin − inicio de cada fila), no
    // solo el estado: antes duracion_ms quedaba null y
    // el historial la enseñaba sin duración.
    return d.rawUpdate(
      'UPDATE sync_corridas SET estado = ?, fin_epoch = ?, '
      'duracion_ms = (? - inicio_epoch) * 1000, '
      'motivo_no_sello = ? WHERE estado = ?',
      [
        EstadoCorrida.cortada,
        fin,
        fin,
        'La sincronización se interrumpió antes de terminar '
            '(la app se cerró o otro proceso tomó el relevo).',
        EstadoCorrida.enCurso,
      ],
    );
  }

  /// Progreso en vivo de la corrida en curso (lo que la
  /// cortada enseñará congelado): tabla y página actuales.
  /// Una fila por página como máximo: coste despreciable
  /// frente a la transacción de la propia página.
  Future<void> anotarProgreso(
    String corridaId, {
    String? tabla,
    int? pagina,
  }) async {
    final d = await _db.db;
    await d.update(
      'sync_corridas',
      {
        if (tabla != null) 'tabla_actual': tabla,
        if (pagina != null) 'pagina_actual': pagina,
      },
      where: 'id = ? AND estado = ?',
      whereArgs: [corridaId, EstadoCorrida.enCurso],
    );
  }

  /// Vuelca los acumulados por tabla de la corrida con
  /// acumulación ON CONFLICT (M1-A3): si el pull reintentó,
  /// el segundo volcado SUMA sobre el primero conservando el
  /// wm_antes original. UNA transacción para todas las
  /// tablas (el «cierre transaccional» de M3-A1 para las
  /// tablas que no comitearon páginas).
  Future<void> volcarTablas(
    String corridaId,
    Map<String, AcumTablaDiario> acum,
  ) async {
    if (acum.isEmpty) return;
    final d = await _db.db;
    await d.transaction((txn) async {
      for (final e in acum.entries) {
        final a = e.value;
        await txn.rawInsert(
          'INSERT INTO sync_corrida_tablas '
          '(corrida_id, tabla, direccion, recibidas, aplicadas, '
          'sin_cambio, tumbas, fallidas, paginas, wm_antes, '
          'wm_despues, estado, error) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(corrida_id, tabla) DO UPDATE SET '
          'recibidas = recibidas + excluded.recibidas, '
          'aplicadas = aplicadas + excluded.aplicadas, '
          'sin_cambio = sin_cambio + excluded.sin_cambio, '
          'tumbas = tumbas + excluded.tumbas, '
          'fallidas = fallidas + excluded.fallidas, '
          'paginas = paginas + excluded.paginas, '
          'wm_antes = COALESCE(wm_antes, excluded.wm_antes), '
          'wm_despues = excluded.wm_despues, '
          'estado = excluded.estado, '
          'error = excluded.error',
          [
            corridaId,
            e.key,
            'bajada',
            a.recibidas,
            a.aplicadas,
            a.sinCambio,
            a.tumbas,
            a.fallidas,
            a.paginas,
            a.wmAntes,
            a.wmDespues,
            a.estado,
            a.error,
          ],
        );
      }
    });
  }

  /// Guarda la foto resumida de las ops del push (M1: foto,
  /// no referencia — ops_queue se poda y el historial no
  /// puede quedar con agujeros). El motor construye las
  /// fotos desde la cola al cerrar el push, con el desenlace
  /// ya confirmado.
  Future<void> volcarOps(
    String corridaId,
    List<CorridaOpSync> ops,
  ) async {
    if (ops.isEmpty) return;
    final d = await _db.db;
    await d.transaction((txn) async {
      for (final op in ops) {
        await txn.insert(
          'sync_corrida_ops',
          {
            'corrida_id': corridaId,
            'op_uuid': op.opUuid,
            'tipo': op.tipo,
            'resumen': op.resumen,
            'resultado': op.resultado,
            'motivo': op.motivo,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Cierra la corrida con su veredicto. Devuelve true si la
  /// fila quedó en el diario y false si era un chequeo vacío
  /// sin plaza (M1-R3: fila borrada, solo sellos en meta).
  /// El cierre es CONDICIONAL a seguir 'en_curso': si otro
  /// ciclo ya la cerró como cortada, no se toca (la foto
  /// congelada manda) y se devuelve true.
  Future<bool> cerrarCorrida(
    String corridaId, {
    required String estado,
    required int duracionMs,
    int subidos = 0,
    int bajados = 0,
    int fotosSubidas = 0,
    int fotosFallidas = 0,
    int comprobantesSubidos = 0,
    int? serverSeq,
    int? watermarkMin,
    String? motivoNoSello,
    String? errorCodigo,
    String? errorDetalle,
    int? ahoraEpoch,
  }) async {
    final d = await _db.db;
    final filas = await d.query('sync_corridas',
        columns: ['origen', 'estado'],
        where: 'id = ?',
        whereArgs: [corridaId]);
    if (filas.isEmpty) return false;
    if ('${filas.first['estado']}' != EstadoCorrida.enCurso) {
      return true; // ya cerrada (cortada por el relevo)
    }
    final origen = '${filas.first['origen']}';
    final ahora =
        ahoraEpoch ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (corridaSinPlaza(
      origen: origen,
      estado: estado,
      subidos: subidos,
      bajados: bajados,
      fotosSubidas: fotosSubidas,
      fotosFallidas: fotosFallidas,
      comprobantesSubidos: comprobantesSubidos,
    )) {
      await d.transaction((txn) async {
        await txn.delete('sync_corrida_tablas',
            where: 'corrida_id = ?', whereArgs: [corridaId]);
        await txn.delete('sync_corrida_ops',
            where: 'corrida_id = ?', whereArgs: [corridaId]);
        await txn.delete('sync_corridas',
            where: 'id = ?', whereArgs: [corridaId]);
      });
      final previos = int.tryParse(
              await _db.getMeta('chequeos_vacios_desde_ultima_corrida') ??
                  '0') ??
          0;
      await _db.setMeta(
          'chequeos_vacios_desde_ultima_corrida', '${previos + 1}');
      await _db.setMeta('ultimo_chequeo_vacio_ts', '$ahora');
      return false;
    }
    await d.update(
      'sync_corridas',
      {
        'estado': estado,
        'fin_epoch': ahora,
        'duracion_ms': duracionMs,
        'subidos': subidos,
        'bajados': bajados,
        'fotos_subidas': fotosSubidas,
        'fotos_fallidas': fotosFallidas,
        'comprobantes_subidos': comprobantesSubidos,
        'server_seq': serverSeq,
        'watermark_min': watermarkMin,
        'motivo_no_sello': motivoNoSello,
        'error_codigo': errorCodigo,
        'error_detalle': errorDetalle,
      },
      where: 'id = ? AND estado = ?',
      whereArgs: [corridaId, EstadoCorrida.enCurso],
    );
    await _db.setMeta('chequeos_vacios_desde_ultima_corrida', '0');
    await podarRetencion(ahoraEpoch: ahora);
    return true;
  }

  /// Aplica la retención (50 corridas / 30 días con blindaje
  /// forense) borrando también las filas hijas.
  Future<void> podarRetencion({int? ahoraEpoch}) async {
    final d = await _db.db;
    final filas = await d.query('sync_corridas',
        columns: ['id', 'tipo', 'origen', 'estado', 'inicio_epoch']);
    if (filas.isEmpty) return;
    final ahora =
        ahoraEpoch ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final poda = seleccionarPodaDiario(
      [
        for (final f in filas)
          (
            id: '${f['id']}',
            tipo: '${f['tipo']}',
            origen: '${f['origen']}',
            estado: '${f['estado']}',
            inicioEpoch: (f['inicio_epoch'] as num?)?.toInt() ?? 0,
          ),
      ],
      ahoraEpoch: ahora,
    );
    if (poda.isEmpty) return;
    await d.transaction((txn) async {
      for (final id in poda) {
        await txn.delete('sync_corrida_tablas',
            where: 'corrida_id = ?', whereArgs: [id]);
        await txn.delete('sync_corrida_ops',
            where: 'corrida_id = ?', whereArgs: [id]);
        await txn.delete('sync_corridas',
            where: 'id = ?', whereArgs: [id]);
      }
    });
  }

  // ── Lecturas (Centro M2/M3 y vigilancia M4) ──────────────

  Future<List<CorridaSync>> historial({int limite = 50}) async {
    final d = await _db.db;
    final filas = await d.query('sync_corridas',
        orderBy: 'inicio_epoch DESC', limit: limite);
    return [for (final f in filas) CorridaSync.fromMap(f)];
  }

  Future<CorridaSync?> ultimaCorrida() async {
    final h = await historial(limite: 1);
    return h.isEmpty ? null : h.first;
  }

  /// La última corrida que procesó ops de push (para el
  /// detalle de Subidos: M3 pasa a leer del diario).
  Future<CorridaSync?> ultimaCorridaConOps() async {
    final d = await _db.db;
    final filas = await d.rawQuery(
        'SELECT c.* FROM sync_corridas c WHERE EXISTS '
        '(SELECT 1 FROM sync_corrida_ops o WHERE o.corrida_id = c.id) '
        'ORDER BY c.inicio_epoch DESC LIMIT 1');
    return filas.isEmpty ? null : CorridaSync.fromMap(filas.first);
  }

  /// La última corrida con desenlace por tabla (para el
  /// detalle de Bajados).
  Future<CorridaSync?> ultimaCorridaConTablas() async {
    final d = await _db.db;
    final filas = await d.rawQuery(
        'SELECT c.* FROM sync_corridas c WHERE EXISTS '
        '(SELECT 1 FROM sync_corrida_tablas t WHERE t.corrida_id = c.id) '
        'ORDER BY c.inicio_epoch DESC LIMIT 1');
    return filas.isEmpty ? null : CorridaSync.fromMap(filas.first);
  }

  /// La corrida EN CURSO si la hay (la vista en vivo la lee
  /// tras un reinicio de la app: el stream en memoria murió
  /// con el proceso, la fila no).
  Future<CorridaSync?> corridaEnCurso() async {
    final d = await _db.db;
    final filas = await d.query('sync_corridas',
        where: 'estado = ?',
        whereArgs: [EstadoCorrida.enCurso],
        orderBy: 'inicio_epoch DESC',
        limit: 1);
    return filas.isEmpty ? null : CorridaSync.fromMap(filas.first);
  }

  Future<List<CorridaTablaSync>> tablasDe(String corridaId) async {
    final d = await _db.db;
    final filas = await d.query('sync_corrida_tablas',
        where: 'corrida_id = ?', whereArgs: [corridaId]);
    return [for (final f in filas) CorridaTablaSync.fromMap(f)];
  }

  Future<List<CorridaOpSync>> opsDe(String corridaId) async {
    final d = await _db.db;
    final filas = await d.query('sync_corrida_ops',
        where: 'corrida_id = ?', whereArgs: [corridaId]);
    return [for (final f in filas) CorridaOpSync.fromMap(f)];
  }

  /// Conteos locales por tabla del espejo (para la foto «en
  /// el teléfono: X» del Centro). Una consulta por tabla
  /// sobre la lista pedida.
  ///
  /// SYNC-12 (1.35): el resultado es triestado POR TABLA —
  /// un COUNT que falla (tabla ausente, BD ilegible) deja
  /// null en esa clave («sin leer»), NUNCA un 0 inventado:
  /// 0 es solo el cero real de una tabla leída y vacía.
  /// Antes el catch aplanaba el fallo al mismo 0, y ni el
  /// Centro ni la huella podían distinguir «vacía» de
  /// «ilegible».
  Future<Map<String, int?>> conteosLocales(List<String> tablas) async {
    final d = await _db.db;
    final out = <String, int?>{};
    for (final t in tablas) {
      try {
        final r = await d.rawQuery('SELECT COUNT(*) AS n FROM $t');
        out[t] = (r.first['n'] as num?)?.toInt() ?? 0;
      } catch (_) {
        out[t] = null;
      }
    }
    return out;
  }

  /// Los conteos publicados por el servidor (M5-S) tal como
  /// quedaron guardados en meta al leer sync_estado, si el
  /// puente ya los publica; null si aún no (el Centro enseña
  /// entonces solo el conteo local, sin denominador: nada de
  /// porcentajes inventados).
  ///
  /// SYNC-12 (1.35): un valor null DENTRO del JSON publicado
  /// se CONSERVA como null («el servidor no publicó esta
  /// tabla»): antes se aplanaba a 0 y el Centro fabricaba el
  /// denominador «0 en el servidor».
  Future<Map<String, int?>?> conteosPublicados() async {
    final raw = await _db.getMeta('conteos_espejo_publicados');
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map;
      // 1.36 H-C2 (136-921): un valor ilegible degrada
      // SOLO su clave (a null, «no publicado»): antes un
      // solo cast malo tumbaba TODOS los conteos.
      return {
        for (final e in m.entries)
          '${e.key}': e.value is num ? (e.value as num).toInt() : null,
      };
    } catch (_) {
      return null;
    }
  }
}
