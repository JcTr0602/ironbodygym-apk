import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_log.dart';
import 'auth.dart';
import 'localdb.dart';
import 'sync.dart';

/// 1.21 — Candado de acceso (diseño aprobado por Argón, paquete
/// 121B-02; ajustes CD-01..CD-03 incorporados).
///
/// El dueño puede pausar el acceso a la app (global, por rol o
/// por persona) desde Administración o desde el bot. El estado
/// vive en el servidor (gym.db) y baja por la sync normal hasta
/// el espejo local `acceso_bloqueos`. La capa visual la dibuja
/// main.dart sobre el Navigator cuando [AccesoBloqueoService]
/// reporta un bloqueo vigente para ESTA sesión.
///
/// Reglas (espejo de `evaluar_bloqueo` en el servidor):
/// - El dueño NUNCA se bloquea (exención por sesión, CD/R2).
/// - Cualquier fila activa que case bloquea; la precedencia
///   persona > rol > app > global solo decide qué mensaje y
///   caducidad se muestran (R5: no hay filas de excepción).
/// - La caducidad se juzga contra la hora DEL SERVIDOR anclada
///   en el último pull (CD-02): el reloj del teléfono mandado
///   hacia atrás nunca destraba, y el transcurrido se mide con
///   un reloj monótono desde el ancla.

/// Un bloqueo vigente ya resuelto para esta sesión.
class BloqueoVigente {
  final String alcance;
  final String? objetivo;
  final String mensaje;
  final DateTime? expiraEn;

  const BloqueoVigente({
    required this.alcance,
    required this.objetivo,
    required this.mensaje,
    required this.expiraEn,
  });
}

const String kMensajeCandadoDefecto =
    'Acceso pausado por el dueño. Cuando se reactive, '
    'continuarás normalmente.';

bool _activoDe(dynamic v) => v == 1 || v == true;

DateTime? _parseTs(dynamic v) {
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v);
}

/// Evaluación pura del candado sobre las filas del espejo
/// (forma data-jsonb: los campos van en el mapa de la fila).
/// [ahoraServidor] es la hora estimada del servidor (el llamador
/// la ancla con [AccesoBloqueoService.ahoraServidorEstimada]):
/// una fila cuya caducidad ya pasó para el servidor NO bloquea,
/// aunque siga marcada activa en el espejo.
BloqueoVigente? evaluarBloqueoLocal(
  List<Map<String, dynamic>> filas, {
  required int? telegramId,
  required DateTime ahoraServidor,
}) {
  BloqueoVigente? mejor;
  var mejorPrio = 99;
  for (final f in filas) {
    if (!_activoDe(f['activo'])) continue;
    final app = '${f['app'] ?? 'ambas'}';
    if (app != 'gestion' && app != 'ambas') continue;
    final expira = _parseTs(f['expira_ts']);
    if (expira != null && !ahoraServidor.isBefore(expira)) continue;
    final alcance = '${f['alcance'] ?? ''}';
    final objetivo = f['objetivo']?.toString();
    final int prio;
    switch (alcance) {
      case 'persona':
        if (telegramId == null || objetivo != '$telegramId') continue;
        prio = 1;
      case 'rol':
        if (objetivo != 'entrenador') continue;
        prio = 2;
      case 'app':
        prio = 3;
      case 'global':
        prio = 4;
      default:
        continue;
    }
    if (prio >= mejorPrio) continue;
    mejorPrio = prio;
    final mensajeCrudo = '${f['mensaje'] ?? ''}'.trim();
    mejor = BloqueoVigente(
      alcance: alcance,
      objetivo: objetivo,
      mensaje: mensajeCrudo.isEmpty ? kMensajeCandadoDefecto : mensajeCrudo,
      expiraEn: expira,
    );
  }
  return mejor;
}

/// Servicio del candado para la app de Gestión: evalúa el espejo
/// al arrancar, al cambiar la sesión y tras cada ciclo de sync,
/// y publica el resultado en [vigente] (lo escucha main.dart).
class AccesoBloqueoService {
  AccesoBloqueoService._();
  static final AccesoBloqueoService instance = AccesoBloqueoService._();

  /// Bloqueo vigente para la sesión actual (null = acceso libre).
  final ValueNotifier<BloqueoVigente?> vigente =
      ValueNotifier<BloqueoVigente?>(null);

  static const String _kAnclaServer = 'bloqueo_ancla_server';
  static const String _kAnclaPared = 'bloqueo_ancla_pared';

  bool _iniciado = false;
  bool _despertando = false;
  DateTime? _anclaServer;
  DateTime? _anclaPared;
  Stopwatch? _reloj;
  StreamSubscription<SyncStatus>? _subSync;
  StreamSubscription<dynamic>? _subAuth;

  /// Hora estimada del servidor (CD-02): ancla tomada del pull
  /// (la marca más reciente vista en el espejo) más el tiempo
  /// transcurrido. En la misma sesión el transcurrido es
  /// MONÓTONO (Stopwatch): mover el reloj del teléfono no
  /// adelanta la caducidad. Tras un reinicio se usa la diferencia
  /// de pared desde que se guardó el ancla, con suelo en el
  /// propio ancla: un reloj atrasado nunca estima menos que la
  /// última hora de servidor conocida. Sin ancla (nunca hubo
  /// pull con filas) se devuelve la hora del dispositivo en UTC:
  /// sin filas conocidas no hay caducidad que proteger.
  DateTime ahoraServidorEstimada() {
    final ancla = _anclaServer;
    if (ancla == null) return DateTime.now().toUtc();
    final reloj = _reloj;
    if (reloj != null && reloj.isRunning) {
      return ancla.add(reloj.elapsed);
    }
    final pared = _anclaPared;
    if (pared == null) return ancla;
    final diff = DateTime.now().difference(pared);
    return diff.isNegative ? ancla : ancla.add(diff);
  }

  /// Adopta como ancla la marca de servidor más reciente de las
  /// filas (creada_ts/updated_at, en UTC): es una cota inferior
  /// de la hora del servidor al momento del pull.
  void _refrescarAncla(List<Map<String, dynamic>> filas) {
    DateTime? maxTs;
    for (final f in filas) {
      for (final clave in const ['creada_ts', 'updated_at']) {
        final ts = _parseTs(f[clave]);
        if (ts != null && (maxTs == null || ts.isAfter(maxTs))) {
          maxTs = ts;
        }
      }
    }
    if (maxTs == null) return;
    if (_anclaServer != null && !maxTs.isAfter(_anclaServer!)) return;
    _anclaServer = maxTs;
    _anclaPared = DateTime.now();
    _reloj = Stopwatch()..start();
    final db = LocalDb.instance;
    unawaited(db.setMeta(_kAnclaServer, maxTs.toUtc().toIso8601String()));
    unawaited(db.setMeta(
        _kAnclaPared, _anclaPared!.toUtc().toIso8601String()));
  }

  Future<void> _cargarAnclaPersistida() async {
    try {
      final db = LocalDb.instance;
      final s = await db.getMeta(_kAnclaServer);
      final p = await db.getMeta(_kAnclaPared);
      final server = _parseTs(s);
      if (server == null || _anclaServer != null) return;
      _anclaServer = server;
      _anclaPared = _parseTs(p);
      // Argón Acceso #8: arrancar el reloj monotónico AQUÍ con
      // el desplazamiento ya transcurrido capturado una sola
      // vez. Antes _reloj quedaba null tras el reinicio y la
      // hora estimada dependía del reloj de pared (congelada si
      // este retrocedía) hasta que llegara una fila más nueva.
      final paredGuardada = _anclaPared;
      if (paredGuardada != null) {
        final diff = DateTime.now().difference(paredGuardada);
        if (!diff.isNegative) {
          _anclaServer = server.add(diff);
        }
        _anclaPared = DateTime.now();
      }
      _reloj = Stopwatch()..start();
    } catch (_) {
      // Sin ancla persistida: la primera evaluación la siembra.
    }
  }

  /// Arranca las escuchas (idempotente). Lo llama main() tras
  /// inicializar Supabase y la BD.
  void iniciar() {
    if (_iniciado) return;
    _iniciado = true;
    unawaited(_cargarAnclaPersistida());
    _subSync =
        SyncEngine.instance.statusStream.listen((_) => unawaited(reevaluar()));
    try {
      _subAuth = Supabase.instance.client.auth.onAuthStateChange
          .listen((_) => unawaited(reevaluar()));
    } catch (_) {
      // Sin Supabase inicializado (tests): solo evalúa por sync.
    }
    unawaited(reevaluar());
  }

  /// Detiene las escuchas (la app no lo usa: el servicio vive lo
  /// que vive el proceso; queda para tests y cierres ordenados).
  Future<void> detener() async {
    await _subSync?.cancel();
    await _subAuth?.cancel();
    _subSync = null;
    _subAuth = null;
    _iniciado = false;
  }

  /// Reevalúa el espejo contra la sesión actual. Si el candado
  /// cae (transición bloqueado → libre), despierta las ops
  /// retenidas por la pausa y dispara un ciclo inmediato (CD-01).
  Future<void> reevaluar() async {
    try {
      final auth = AuthService();
      BloqueoVigente? nuevo;
      if (auth.loggedIn && !auth.isOwner) {
        final filas = await LocalDb.instance.allMirror('acceso_bloqueos');
        _refrescarAncla(filas);
        nuevo = evaluarBloqueoLocal(
          filas,
          telegramId: auth.telegramId,
          ahoraServidor: ahoraServidorEstimada(),
        );
      }
      final anterior = vigente.value;
      if (anterior != null || nuevo != null) {
        vigente.value = nuevo;
      }
      if (anterior != null && nuevo == null) {
        await _alDesbloquear();
      }
    } catch (e) {
      AppLog.error('candado', 'reevaluar_fallo', d: '$e');
    }
  }

  /// CD-01: al caer el candado, las ops retenidas con
  /// ACCESO_PAUSADO despiertan ya (no a las +6 h de su red de
  /// seguridad) y salen en un ciclo forzado.
  Future<void> _alDesbloquear() async {
    if (_despertando) return;
    _despertando = true;
    try {
      final n = await LocalDb.instance.despertarOpsPausadas();
      if (n > 0) {
        unawaited(SyncEngine.instance.run(forzar: true));
      }
    } catch (e) {
      AppLog.error('candado', 'despertar_fallo', d: '$e');
    } finally {
      _despertando = false;
    }
  }
}
