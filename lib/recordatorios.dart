/// Servicio G2 (1.11.0): recordatorios automáticos.
///
/// Candados del ajuste 7 del veredicto del núcleo (no negociables):
/// - Un entrenador solo crea recordatorios «solo para mí». Solo el
///   dueño crea, edita o activa para otros.
/// - Anti-duplicado: el disparo queda en `recordatorio_disparos_log`
///   (PK triple). Un segundo intento el mismo día para el mismo
///   destino devuelve false y NO vuelve a disparar.
/// - Los masivos (alcance 'todos') se disparan SOLO en el teléfono
///   del dueño; al disparar, el dueño escribe
///   `disparado_en_fecha_habana` y lo sincroniza por la op
///   upsert_recordatorio_config, para que los demás teléfonos vean
///   ese día el recordatorio como ya disparado.
/// - «Solo para mí» se cumple en LECTURA: la config viaja por sync a
///   todos los teléfonos, pero solo se muestra/dispara en el teléfono
///   de quien la creó (`creado_por` == mi telegram_id).
library;

import 'dart:async';

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'bloque2_resto.dart';
import 'cliente_protegido.dart';
import 'localdb.dart';
import 'negocio.dart';
import 'sync.dart';
import 'tiempo.dart';

/// FIN-25 de Argón (1.20): las ops de recordatorios se encolan
/// pero nadie disparaba la subida — el cambio (y sobre todo el
/// «ya disparado hoy» de los masivos) viajaba cuando otra
/// acción sincronizaba. Empuje inmediato tras cada mutación.
void _empujarRecordatorios() {
  unawaited(
      SyncEngine.instance.push().then((_) {}, onError: (_) {}));
}

/// Un recordatorio vencido hoy, listo para disparar (o ya disparado).
class RecordatorioDebido {
  final String recordatorioId;
  final String titulo;
  final String tipo;
  final String alcance;
  final String targetKey;
  final int? clienteId;
  final String? clienteNombre;
  final bool yaDisparado;
  final bool puedoDisparar;

  /// 1.22 R-2: el día Habana para el que se calculó este
  /// debido. disparar/cancelar usan ESTA fecha y no un «hoy»
  /// recalculado al tocar: con la pantalla abierta cruzando
  /// la medianoche, el disparo se asentaba en el día nuevo y
  /// el debido de ayer quedaba «sin disparar» (y al revés, un
  /// disparo podía contar para el día equivocado).
  final String fechaHabana;
  const RecordatorioDebido({
    required this.recordatorioId,
    required this.titulo,
    required this.tipo,
    required this.alcance,
    required this.targetKey,
    this.clienteId,
    this.clienteNombre,
    required this.yaDisparado,
    required this.puedoDisparar,
    required this.fechaHabana,
  });
}

/// 1.22 R-7: gancho que main.dart conecta con
/// AvisosRecordatorios.sincronizar (ese archivo importa este;
/// el gancho evita el import circular). Las mutaciones de
/// recordatorios lo invocan: antes sincronizar solo corría al
/// arrancar y tras un sync, así que pausar un recordatorio a
/// las 07:50 NO cancelaba su alarma de las 08:00.
Future<void> Function()? ganchoSincronizarAvisos;

void _sincronizarAvisos() {
  final g = ganchoSincronizarAvisos;
  if (g == null) return;
  unawaited(g().then((_) {}, onError: (_) {}));
}

/// Estado de un debido POR CLIENTE (Argón #10-1, PURO).
/// El marcador masivo `disparado_en_fecha_habana` de la config NO se
/// consulta aquí: disparar el cumpleaños de un cliente no debe
/// bloquear a los demás del mismo día. Cada cliente se decide por su
/// propio registro en recordatorio_disparos_log. Los masivos solo los
/// dispara el dueño; los «solo_mio» ya vienen filtrados por creador
/// en debidosHoy.
({bool yaDisparado, bool puedoDisparar}) estadoDebidoPorCliente({
  required bool esDueno,
  required String alcance,
  required bool yaEnLog,
}) {
  return (
    yaDisparado: yaEnLog,
    puedoDisparar: alcance == 'todos' ? esDueno && !yaEnLog : !yaEnLog,
  );
}

/// F4 (1.20): ¿un recordatorio personalizado toca hoy?
/// Sin frecuencia (o 'ninguna'): solo su fecha fija. Con
/// 'semanal': el mismo día de semana de la fecha fija,
/// desde esa fecha. Con 'mensual': el mismo día del mes,
/// con tope al último día del mes (un 31 cae al 30 en los
/// meses de 30, y al 28/29 en febrero). PURO, testeable.
bool recordatorioPersonalizadoTocaHoy(
    Map<String, dynamic> cfg, String hoyIso) {
  final ff = '${cfg['fecha_fija'] ?? ''}';
  if (ff.length < 10 || hoyIso.length < 10) return false;
  final fija = ff.substring(0, 10);
  final frec = '${cfg['frecuencia'] ?? 'ninguna'}';
  if (frec != 'semanal' && frec != 'mensual') {
    return fija == hoyIso;
  }
  if (hoyIso.compareTo(fija) < 0) return false;
  final dF = DateTime.tryParse(fija);
  final dH = DateTime.tryParse(hoyIso);
  if (dF == null || dH == null) return false;
  if (frec == 'semanal') return dF.weekday == dH.weekday;
  // 1.22 R-3: DateTime.utc — el último día del mes en hora
  // LOCAL puede caer corrido en los días de cambio DST (Cuba
  // cambia a las 00:00/01:00 y un DateTime local de medianoche
  // puede no existir o repetir hora).
  final ultimoDia = DateTime.utc(dH.year, dH.month + 1, 0).day;
  final diaObjetivo = dF.day > ultimoDia ? ultimoDia : dF.day;
  return dH.day == diaObjetivo;
}

class RecordatoriosService {
  RecordatoriosService._();
  static final RecordatoriosService instance = RecordatoriosService._();

  int? get _yo => AuthService().telegramId;
  bool get _soyDueno => AuthService().isOwner;

  /// Crea un recordatorio (valida el alcance por rol) y encola la op
  /// de sincronización. Devuelve el id.
  Future<String> crear({
    required String titulo,
    required String tipo,
    required String alcance,
    String targetKey = 'todos',
    int diasAnticipacion = 3,
    String? fechaFija,
    String frecuencia = 'ninguna',
  }) async {
    if (!alcancePermitido(alcance, esDueno: _soyDueno)) {
      throw Exception(
          'Un entrenador solo puede crear recordatorios «solo para mí»');
    }
    final id = const Uuid().v4();
    final ahora = isoHabana(ahoraHabana());
    final fila = {
      'id': id,
      'titulo': titulo,
      'tipo': tipo,
      'alcance': alcance,
      'target_key': targetKey,
      'dias_anticipacion': diasAnticipacion,
      'fecha_fija': fechaFija,
      'frecuencia': frecuencia,
      'activa': 1,
      'creado_por': _yo,
      'disparado_en_fecha_habana': null,
      'creada_ts': ahora,
      'actualizada_ts': ahora,
    };
    // Panel 9/10 (Luna): guardar y encolar en UNA transacción. Dos
    // pasos separados dejaban el cambio local sin op si la app se
    // cerraba entre ambos (el servidor nunca se enteraba).
    final d = await LocalDb.instance.db;
    await d.transaction((txn) async {
      await LocalDb.instance.guardarRecordatorio(fila, txn: txn);
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: kTipoOpUpsertRecordatorio,
        payload: {'recordatorio': fila},
        txn: txn,
      );
    });
    _empujarRecordatorios();
    _sincronizarAvisos();
    return id;
  }

  /// Activa/desactiva. Solo el dueño toca los de otros.
  Future<void> cambiarActiva(String id, bool activa) async {
    final configs = await LocalDb.instance.listarRecordatorios();
    final cfg = configs.firstWhere((c) => c['id'] == id, orElse: () => {});
    if (cfg.isEmpty) throw Exception('Recordatorio no encontrado');
    if ('${cfg['alcance']}' != 'solo_mio' && !_soyDueno) {
      throw Exception('Solo el dueño puede activar recordatorios de otros');
    }
    if ('${cfg['alcance']}' == 'solo_mio' &&
        cfg['creado_por'] != _yo &&
        !_soyDueno) {
      throw Exception('Ese recordatorio no es tuyo');
    }
    final fila = {
      ...cfg,
      'activa': activa ? 1 : 0,
      // Argón #10-6: sin sellar actualizada_ts, un pull con la fila
      // vieja podía pisar el cambio de estado (Last-Write-Wins).
      'actualizada_ts': isoHabana(ahoraHabana()),
    };
    // Panel 9/10 (Luna): guardar y encolar en UNA transacción. Dos
    // pasos separados dejaban el cambio local sin op si la app se
    // cerraba entre ambos (el servidor nunca se enteraba).
    final d = await LocalDb.instance.db;
    await d.transaction((txn) async {
      await LocalDb.instance.guardarRecordatorio(fila, txn: txn);
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: kTipoOpUpsertRecordatorio,
        payload: {'recordatorio': fila},
        txn: txn,
      );
    });
    _empujarRecordatorios();
    _sincronizarAvisos();
  }

  Future<void> eliminar(String id) async {
    final configs = await LocalDb.instance.listarRecordatorios();
    final cfg = configs.firstWhere((c) => c['id'] == id, orElse: () => {});
    if (cfg.isNotEmpty &&
        '${cfg['alcance']}' != 'solo_mio' &&
        !_soyDueno) {
      throw Exception('Solo el dueño puede eliminar recordatorios de otros');
    }
    // Corrección panel 1.11 (MEDIO): mismo bloqueo que
    // cambiarActiva para los «solo_mio» ajenos. Antes el borrado
    // local pasaba (el servidor lo rechazaba y el próximo pull lo
    // devolvía, pero la pantalla engañaba en el medio).
    if (cfg.isNotEmpty &&
        '${cfg['alcance']}' == 'solo_mio' &&
        cfg['creado_por'] != _yo &&
        !_soyDueno) {
      throw Exception('Ese recordatorio no es tuyo');
    }
    // 1.22 R-6: borrado + op en UNA transacción, como
    // crear/cambiarActiva (panel 9/10): dos pasos separados
    // dejaban la config borrada local sin op si la app se
    // cerraba entre ambos, y el próximo pull la resucitaba.
    final d = await LocalDb.instance.db;
    await d.transaction((txn) async {
      await LocalDb.instance.borrarRecordatorio(id, txn: txn);
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: kTipoOpDeleteRecordatorio,
        payload: {'recordatorio_id': id},
        txn: txn,
      );
    });
    _empujarRecordatorios();
    _sincronizarAvisos();
  }

  /// Recordatorios vencidos hoy (para la pantalla G2).
  /// [hoyHabana] es 'YYYY-MM-DD'. Los de alcance 'solo_mio' de otro
  /// creador NO se muestran (son solo para su teléfono).
  Future<List<RecordatorioDebido>> debidosHoy(
      {String? hoyHabana}) async {
    final hoy = hoyHabana ?? hoyHabanaIso();
    // Argón #10-3: honrar los interruptores globales de «Mis avisos».
    // Sin esto, apagar «Cumpleaños» o «Vencimientos» no apagaba nada.
    // Ausente = activado; solo '0' apaga.
    final avisoVenc =
        (await LocalDb.instance.getMeta('aviso_vencimientos')) != '0';
    final avisoCumple =
        (await LocalDb.instance.getMeta('aviso_cumpleanos')) != '0';
    final mmDd = hoy.substring(5, 10);
    final configs = await LocalDb.instance.listarRecordatorios();
    final clientes = await LocalDb.instance.allMirror('clientes');
    final out = <RecordatorioDebido>[];
    for (final cfg in configs) {
      if ((cfg['activa'] as num?)?.toInt() != 1) continue;
      final alcance = '${cfg['alcance'] ?? 'solo_mio'}';
      // Solo para mí: solo en el teléfono del creador.
      if (alcance == 'solo_mio' && cfg['creado_por'] != _yo) continue;
      final id = '${cfg['id']}';
      final tipo = '${cfg['tipo']}';
      final titulo = '${cfg['titulo']}';
      final dias = (cfg['dias_anticipacion'] as num?)?.toInt() ?? 3;
      if (tipo == 'vencimiento' && !avisoVenc) continue;
      if (tipo == 'cumpleanos' && !avisoCumple) continue;
      final disparadoMasivoHoy =
          cfg['disparado_en_fecha_habana'] == hoy;
      if (tipo == 'personalizado') {
        // F4: con frecuencia, el recordatorio toca cada
        // semana o cada mes desde su fecha fija.
        if (!recordatorioPersonalizadoTocaHoy(cfg, hoy)) {
          continue;
        }
        final ya = disparadoMasivoHoy ||
            await LocalDb.instance.yaDisparadoRecordatorio(
                recordatorioId: id, fechaHabana: hoy, targetKey: 'todos');
        out.add(RecordatorioDebido(
          recordatorioId: id,
          titulo: titulo,
          tipo: tipo,
          alcance: alcance,
          targetKey: 'todos',
          fechaHabana: hoy,
          yaDisparado: ya,
          puedoDisparar: alcance == 'todos'
              ? puedeDispararMasivo(
                  esTelefonoDueno: _soyDueno,
                  disparadoEnFechaHabana:
                      cfg['disparado_en_fecha_habana'] as String?,
                  hoyHabana: hoy)
              : !ya,
        ));
        continue;
      }
      // cumpleanos / vencimiento: un debido por cliente.
      for (final c in clientes) {
        final cid = (c['id'] as num?)?.toInt();
        if (cid == null) continue;
        // Argón #10-2: ni eliminados ni protegidos generan avisos
        // para entrenadores (para el dueño esVistaProtegida es
        // false y los sigue viendo todos).
        // Eliminado por cualquiera de las dos señales: el espejo
        // puede traer 'eliminado' (siembra/tests) o estado
        // 'eliminado'/distinto de 'activo' (producción). Solo una
        // de ellas dejaba fuera al cliente 104 del test #10.
        if (c['eliminado'] == true ||
            c['eliminado'] == 1 ||
            esClienteEliminado(c) ||
            (c['estado'] ?? 'activo') != 'activo') {
          continue;
        }
        if (esVistaProtegida(c, esDueno: _soyDueno)) continue;
        // 1.22 R-4: Cuenta a la Casa no paga mensualidad ni
        // vence: fuera de la rama de vencimiento (conserva su
        // pagado_hasta y generaba avisos falsos de «vence
        // pronto»). Su cumpleaños SÍ sigue avisando.
        if (tipo == 'vencimiento' && esCuentaCasa(c)) continue;
        final target = 'cliente:$cid';
        bool aplica = false;
        if (tipo == 'cumpleanos') {
          // Q1 (Argón cumpleaños): el año decide si un 29-feb
          // hace match el 01-mar (solo en año no bisiesto).
          aplica = esCumpleanosHoy(c, mmDd,
              anioHoy: int.tryParse(hoy.substring(0, 4)));
        } else if (tipo == 'vencimiento') {
          aplica = venceEnVentana(
              c['pagado_hasta'] as String?, hoy, dias);
        }
        if (!aplica) continue;
        final yaLog = await LocalDb.instance.yaDisparadoRecordatorio(
            recordatorioId: id, fechaHabana: hoy, targetKey: target);
        // Argón #10-1: el estado por cliente NO consulta el marcador
        // masivo de la config (ver estadoDebidoPorCliente).
        final est = estadoDebidoPorCliente(
          esDueno: _soyDueno,
          alcance: alcance,
          yaEnLog: yaLog,
        );
        out.add(RecordatorioDebido(
          recordatorioId: id,
          titulo: titulo,
          tipo: tipo,
          alcance: alcance,
          targetKey: target,
          clienteId: cid,
          clienteNombre: '${c['nombre'] ?? ''}',
          fechaHabana: hoy,
          yaDisparado: est.yaDisparado,
          puedoDisparar: est.puedoDisparar,
        ));
      }
    }
    return out;
  }

  /// Dispara un debido: escribe el log (INSERT OR IGNORE). Si es
  /// masivo y soy el dueño, además marca el estado sincronizado y lo
  /// encola. Devuelve true si el disparo era nuevo.
  /// Corrección panel 1.11 (ALTO): los tres pasos van en UNA
  /// transacción. Antes, si la app moría entre el log y el
  /// encolado, este teléfono creía haber disparado y el servidor
  /// nunca lo sabía: otros teléfonos podían volver a disparar el
  /// mismo masivo. Si la transacción falla, no queda ningún paso
  /// a medias y el disparo se puede reintentar limpio.
  Future<bool> disparar(RecordatorioDebido debido,
      {String? hoyHabana}) async {
    // 1.22 R-2: manda la fecha del DEBIDO (ver el campo); el
    // parámetro queda solo como respaldo para debidos sin
    // fecha (no ocurre en producción: debidosHoy la sella).
    final hoy = debido.fechaHabana.isNotEmpty
        ? debido.fechaHabana
        : (hoyHabana ?? hoyHabanaIso());
    if (!debido.puedoDisparar) return false;
    final db = await LocalDb.instance.db;
    var nuevo = false;
    await db.transaction((txn) async {
      final id = await txn.rawInsert(
          'INSERT OR IGNORE INTO recordatorio_disparos_log '
          '(recordatorio_id, fecha_habana, target_key, disparada_ts) '
          'VALUES (?, ?, ?, ?)',
          [
            debido.recordatorioId,
            hoy,
            debido.targetKey,
            isoHabana(ahoraHabana()),
          ]);
      nuevo = id != 0;
      if (!nuevo) return;
      // Argón #10-1: el marcador masivo solo se escribe para avisos
      // SIN cliente (targetKey 'todos', personalizados). Un debido
      // por cliente vive solo en su fila del log; escribir el flag
      // aquí bloqueaba a todos los demás clientes del día.
      if (debido.alcance == 'todos' &&
          debido.targetKey == 'todos' &&
          _soyDueno) {
        await txn.update(
            'recordatorio_config',
            {
              'disparado_en_fecha_habana': hoy,
              'actualizada_ts': isoHabana(ahoraHabana()),
            },
            where: 'id = ?',
            whereArgs: [debido.recordatorioId]);
        final filas = await txn.query('recordatorio_config',
            where: 'id = ?', whereArgs: [debido.recordatorioId]);
        if (filas.isNotEmpty) {
          await LocalDb.instance.queueOp(
            opUuid: const Uuid().v4(),
            tipo: kTipoOpUpsertRecordatorio,
            payload: {'recordatorio': filas.first},
            txn: txn,
          );
        }
      }
    });
    if (nuevo) {
      _empujarRecordatorios();
      _sincronizarAvisos();
    }
    return nuevo;
  }
}
