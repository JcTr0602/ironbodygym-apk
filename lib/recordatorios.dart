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

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'bloque2_resto.dart';
import 'localdb.dart';
import 'tiempo.dart';

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
  });
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
      'activa': 1,
      'creado_por': _yo,
      'disparado_en_fecha_habana': null,
      'creada_ts': ahora,
      'actualizada_ts': ahora,
    };
    await LocalDb.instance.guardarRecordatorio(fila);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpUpsertRecordatorio,
      payload: {'recordatorio': fila},
    );
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
    final fila = {...cfg, 'activa': activa ? 1 : 0};
    await LocalDb.instance.guardarRecordatorio(fila);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpUpsertRecordatorio,
      payload: {'recordatorio': fila},
    );
  }

  Future<void> eliminar(String id) async {
    final configs = await LocalDb.instance.listarRecordatorios();
    final cfg = configs.firstWhere((c) => c['id'] == id, orElse: () => {});
    if (cfg.isNotEmpty &&
        '${cfg['alcance']}' != 'solo_mio' &&
        !_soyDueno) {
      throw Exception('Solo el dueño puede eliminar recordatorios de otros');
    }
    await LocalDb.instance.borrarRecordatorio(id);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpDeleteRecordatorio,
      payload: {'recordatorio_id': id},
    );
  }

  /// Recordatorios vencidos hoy (para la pantalla G2).
  /// [hoyHabana] es 'YYYY-MM-DD'. Los de alcance 'solo_mio' de otro
  /// creador NO se muestran (son solo para su teléfono).
  Future<List<RecordatorioDebido>> debidosHoy(
      {String? hoyHabana}) async {
    final hoy = hoyHabana ?? hoyHabanaIso();
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
      final disparadoMasivoHoy =
          cfg['disparado_en_fecha_habana'] == hoy;
      if (tipo == 'personalizado') {
        final fechaFija = '${cfg['fecha_fija'] ?? ''}';
        if (fechaFija.length < 10 ||
            fechaFija.substring(0, 10) != hoy) {
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
        final target = 'cliente:$cid';
        bool aplica = false;
        if (tipo == 'cumpleanos') {
          aplica = esCumpleanosHoy(c, mmDd);
        } else if (tipo == 'vencimiento') {
          aplica = venceEnVentana(
              c['pagado_hasta'] as String?, hoy, dias);
        }
        if (!aplica) continue;
        final ya = disparadoMasivoHoy ||
            await LocalDb.instance.yaDisparadoRecordatorio(
                recordatorioId: id, fechaHabana: hoy, targetKey: target);
        out.add(RecordatorioDebido(
          recordatorioId: id,
          titulo: titulo,
          tipo: tipo,
          alcance: alcance,
          targetKey: target,
          clienteId: cid,
          clienteNombre: '${c['nombre'] ?? ''}',
          yaDisparado: ya,
          puedoDisparar: alcance == 'todos'
              ? puedeDispararMasivo(
                  esTelefonoDueno: _soyDueno,
                  disparadoEnFechaHabana:
                      cfg['disparado_en_fecha_habana'] as String?,
                  hoyHabana: hoy)
              : !ya,
        ));
      }
    }
    return out;
  }

  /// Dispara un debido: escribe el log (INSERT OR IGNORE). Si es
  /// masivo y soy el dueño, además marca el estado sincronizado y lo
  /// encola. Devuelve true si el disparo era nuevo.
  Future<bool> disparar(RecordatorioDebido debido,
      {String? hoyHabana}) async {
    final hoy = hoyHabana ?? hoyHabanaIso();
    if (!debido.puedoDisparar) return false;
    final nuevo = await LocalDb.instance.registrarDisparoRecordatorio(
      recordatorioId: debido.recordatorioId,
      fechaHabana: hoy,
      targetKey: debido.targetKey,
    );
    if (!nuevo) return false;
    if (debido.alcance == 'todos' && _soyDueno) {
      await LocalDb.instance.marcarRecordatorioDisparadoMasivo(
          debido.recordatorioId, hoy);
      final configs = await LocalDb.instance.listarRecordatorios();
      final cfg = configs.firstWhere(
          (c) => c['id'] == debido.recordatorioId,
          orElse: () => {});
      if (cfg.isNotEmpty) {
        await LocalDb.instance.queueOp(
          opUuid: const Uuid().v4(),
          tipo: kTipoOpUpsertRecordatorio,
          payload: {'recordatorio': cfg},
        );
      }
    }
    return true;
  }
}
