/// Motor de sincronización offline-first.
///
/// Subida (push): ops de `ops_queue` -> POST /rest/v1/sync_ops (idempotente
///           por op_uuid; un 409 se trata como "ya encolada").
///           Luego consulta `aplicada` de cada op propia (policy
///           "ver propias ops") y marca la cola.
/// Bajada (pull): espejos + borrados con sync_seq > watermark local, aplica
///           y guarda el watermark. También trae `ajustes` (precios).
/// Fotos:    las fotos de inscripciones se suben cuando la op de
///           inscripción ya fue aplicada (se conoce el cliente_id) y se
///           encolan como op tipo 'foto'.
///
/// Cadencia: pull frecuente (ver cambios de otros entrenadores),
/// push cada hora o manual.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'config.dart';
import 'errores_sync.dart';
import 'localdb.dart';
import 'perfil.dart';

enum SyncPhase { idle, uploading, downloading, photos, error }

class SyncStatus {
  final SyncPhase phase;
  final int pending;
  final DateTime? lastOk;
  final String? lastError;

  /// Progreso 0..1 de la fase actual (null = indeterminado).
  final double? progreso;

  /// Detalle legible del progreso, ej. "Subiendo fotos… 2 de 5".
  final String? detalle;

  /// v1.0.15: true si el servidor tiene cambios no bajados
  /// (watermark < server_seq). "Cola vacía" no basta para decir
  /// que los datos están al día.
  final bool hayNovedades;

  /// v1.0.17: resumen discreto de la última sincronización,
  /// ej. "↑ 2 enviados · ↓ 3 nuevos" o "Sin cambios".
  final String? ultimoResumen;

  /// Cuándo se generó ultimoResumen (para mostrarlo solo si es reciente).
  final DateTime? ultimoResumenHora;

  // v1.2.5 (D11): tres dimensiones independientes del estado.
  /// ¿Hay conexión ahora?
  final bool enLinea;

  /// ¿Cuándo se guardó lo último en este teléfono (COMMIT local)?
  final DateTime? ultimoGuardado;

  /// ¿Cuándo confirmó el servidor lo último (ack)?
  final DateTime? ultimoSincronizado;

  const SyncStatus(
      {this.phase = SyncPhase.idle,
      this.pending = 0,
      this.lastOk,
      this.lastError,
      this.progreso,
      this.detalle,
      this.hayNovedades = false,
      this.ultimoResumen,
      this.ultimoResumenHora,
      this.enLinea = true,
      this.ultimoGuardado,
      this.ultimoSincronizado});

  /// v1.2.5 (D11): frase en lenguaje humano según las 3 dimensiones.
  String get frase {
    if (!enLinea && pending > 0) {
      return 'Sin conexión — $pending cambio${pending == 1 ? '' : 's'} '
          'guardado${pending == 1 ? '' : 's'} en este teléfono';
    }
    if (!enLinea) return 'Sin conexión — todo guardado en este teléfono';
    if (pending > 0) {
      return '$pending cambio${pending == 1 ? '' : 's'} por enviar';
    }
    return 'Todo guardado y sincronizado';
  }
}

/// Detalle de la última sincronización (para la pantalla de Sync).
class SyncDetalle {
  final DateTime? ultimaPull;
  final DateTime? ultimaPush;
  final int subidos;
  final int bajados;
  final String? error;
  const SyncDetalle(
      {this.ultimaPull,
      this.ultimaPush,
      this.subidos = 0,
      this.bajados = 0,
      this.error});
}

class SessionExpired implements Exception {
  final String message;
  SessionExpired([this.message = 'sesión vencida, entra de nuevo']);
  @override
  String toString() => message;
}

class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  final _status = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _status.stream;
  SyncStatus _current = const SyncStatus();
  bool _running = false;

  /// Se llama cuando el servidor rechaza la sesión (401).
  void Function()? onSessionExpired;

  final _auth = AuthService();
  final _db = LocalDb.instance;

  String get _base => AppConfig.supabaseUrl;

  /// Nombre amigable de cada tabla espejo para los mensajes de progreso.
  static String _nombreAmigable(String tabla) {
    switch (tabla) {
      case 'pagos_diarios':
        return 'pagos del día';
      case 'clientes':
        return 'clientes';
      case 'pagos':
        return 'pagos';
      case 'gastos':
        return 'gastos';
      case 'suplementos':
        return 'suplementos';
      case 'ventas_suplementos':
        return 'ventas de suplementos';
      default:
        return tabla.replaceAll('_', ' ');
    }
  }

  /// Petición autenticada con reintento tras refrescar el token.
  ///
  /// Ante un HTTP 401 se intenta `refreshSession()` UNA vez y se reintenta
  /// la petición con el token nuevo; solo si el refresh funciona pero el
  /// reintento sigue dando 401 se declara la sesión vencida. Si el
  /// refresh falla (p. ej. sin internet), se devuelve la respuesta
  /// original: un fallo de red nunca expulsa al login.
  Future<http.Response> _reqAuth(
      Future<http.Response> Function(String token) hacer) async {
    var r = await hacer(_auth.session?.accessToken ?? '');
    if (r.statusCode != 401) return r;
    try {
      final res = await Supabase.instance.client.auth.refreshSession();
      final nuevo = res.session?.accessToken ?? '';
      if (nuevo.isEmpty) return r;
      r = await hacer(nuevo);
    } catch (_) {
      return r; // sin red para refrescar: no es vencimiento real
    }
    if (r.statusCode == 401) throw SessionExpired();
    return r;
  }

  Future<http.Response> _getAuth(Uri url,
          {Duration timeout = const Duration(seconds: 30)}) =>
      _reqAuth((t) => http.get(url, headers: {
            'apikey': AppConfig.anonKey,
            'Authorization': 'Bearer $t',
          }).timeout(timeout));

  Future<http.Response> _postAuth(Uri url,
          {Map<String, String>? headers,
          Object? body,
          Duration timeout = const Duration(seconds: 60)}) =>
      _reqAuth((t) => http
          .post(url,
              headers: {
                'apikey': AppConfig.anonKey,
                'Authorization': 'Bearer $t',
                ...?headers,
              },
              body: body)
          .timeout(timeout));

  Future<http.Response> _headAuth(Uri url,
          {Duration timeout = const Duration(seconds: 30)}) =>
      _reqAuth((t) => http.head(url, headers: {
            'apikey': AppConfig.anonKey,
            'Authorization': 'Bearer $t',
            'Tus-Resumable': '1.0.0',
          }).timeout(timeout));

  Future<http.Response> _patchAuth(Uri url,
          {required Map<String, String> headers,
          Object? body,
          Duration timeout = const Duration(seconds: 120)}) =>
      _reqAuth((t) => http
          .patch(url,
              headers: {
                'apikey': AppConfig.anonKey,
                'Authorization': 'Bearer $t',
                ...headers,
              },
              body: body)
          .timeout(timeout));

  void _emit(SyncPhase phase,
      {String? error,
      double? progreso,
      String? detalle,
      String? resumen}) async {
    final pending = await _db.countPendingOps();
    final lastOk = await _ultimaOk();
    // v1.0.15: detectar si el servidor tiene cambios sin bajar
    bool novedades = false;
    try {
      final wm = await _db.getWatermark();
      final ss =
          int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
      novedades = ss > wm;
    } catch (_) {}
    // v1.0.17: conservar el último resumen salvo que se pase uno nuevo
    final res = resumen ?? _current.ultimoResumen;
    final resHora =
        resumen != null ? DateTime.now() : _current.ultimoResumenHora;
    // v1.2.5 (D11/D12): 3 dimensiones + marcas de guardado/sincronizado.
    bool enLinea = true;
    try {
      enLinea = await _hayInternet();
    } catch (_) {}
    DateTime? guardado;
    DateTime? sincronizado;
    try {
      final g = await _db.getMeta('ultimo_guardado_local');
      if (g != null) guardado = DateTime.tryParse(g);
      final s = await _db.getMeta('ultimo_sincronizado');
      if (s != null) sincronizado = DateTime.tryParse(s);
    } catch (_) {}
    _current = SyncStatus(
        phase: phase,
        pending: pending,
        lastOk: lastOk,
        lastError: error,
        progreso: progreso,
        detalle: detalle,
        hayNovedades: novedades,
        ultimoResumen: res,
        ultimoResumenHora: resHora,
        enLinea: enLinea,
        ultimoGuardado: guardado,
        ultimoSincronizado: sincronizado);
    _status.add(_current);
  }

  /// v1.2.5 (D12): marca "guardado en este teléfono" tras un COMMIT local.
  /// Llamar solo después de confirmar la escritura, nunca optimista.
  Future<void> marcarGuardado() async {
    try {
      await _db.setMeta(
          'ultimo_guardado_local', DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// v1.2.5 (D12): marca "sincronizado" cuando el servidor confirma (ack).
  /// Solo hasta el server_seq confirmado, nunca optimista.
  Future<void> marcarSincronizado() async {
    try {
      await _db.setMeta(
          'ultimo_sincronizado', DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// Verifica si hay internet real resolviendo un dominio confiable.
  /// Timeout corto para no bloquear la sincronización.
  ///
  /// v1.0.14: en Cuba el DNS puede fallar solo para ciertos dominios
  /// mientras WhatsApp sigue funcionando. Ante un error de red, se verifica
  /// con google.com antes de declarar "sin conexión".
  Future<bool> _hayInternet() async {
    try {
      final res = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      return res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Versión del error visible para el usuario: si parece "sin conexión"
  /// pero sí hay internet, es que el servidor no responde.
  /// v1.2.5 (D16): error visible basado en códigos estables, no en texto.
  /// El mismo fallo siempre muestra el mismo mensaje y acción.
  Future<String> _describeErrorVisible(Object e, {int? httpStatus}) async {
    final ec = clasificarError(e, httpStatus: httpStatus);
    // Sin conexión pero hay internet: el servidor no responde.
    if (ec.codigo == 'sin_conexion' && await _hayInternet()) {
      return 'No se pudo contactar el servidor. Tus cambios están a salvo.';
    }
    return ec.mensaje;
  }

  Future<DateTime?> _ultimaOk() async {
    final v = await _db.getMeta('last_sync_ok');
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<void> _marcarOk() =>
      _db.setMeta('last_sync_ok', DateTime.now().toIso8601String());

  Future<SyncDetalle> detalle() async {
    DateTime? pull, push;
    final p1 = await _db.getMeta('last_pull_ok');
    final p2 = await _db.getMeta('last_push_ok');
    if (p1 != null) pull = DateTime.tryParse(p1);
    if (p2 != null) push = DateTime.tryParse(p2);
    return SyncDetalle(
      ultimaPull: pull,
      ultimaPush: push,
      subidos: int.tryParse(await _db.getMeta('last_uploaded') ?? '0') ?? 0,
      bajados: int.tryParse(await _db.getMeta('last_downloaded') ?? '0') ?? 0,
      error: await _db.getMeta('last_sync_error'),
    );
  }

  void _sesionVencida() {
    // v1.2.5: purga de datos sensibles (best-effort, sin await).
    unawaited(LocalDb.purgaAlCerrarSesion());
    _auth.signOut();
    onSessionExpired?.call();
  }

  /// Ciclo completo: push + pull (botón "Sincronizar ahora", al entrar).
  /// Repite el pull hasta que el watermark alcance al server_seq
  /// (pueden llegar cambios nuevos mientras se descarga).
  /// v1.2.5 (D14): [forzar] cancela el backoff ("Sincronizar ahora").
  Future<void> run({bool forzar = false}) async {
    if (_running || !_auth.loggedIn) return;
    _running = true;
    try {
      await _doPush(forzar: forzar);
      // v1.2.4: perfil (móvil/carnet) que no pudo subirse sin conexión.
      try {
        await PerfilService.instance.sincronizarSiPendiente();
      } catch (_) {}
      // Pull repetido: si llegan cambios durante la descarga, seguir.
      bool completo = false;
      for (var i = 0; i < 3; i++) {
        await _doPull();
        final wm = await _db.getWatermark();
        final ss = int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
        if (wm >= ss) {
          completo = true;
          break;
        }
      }
      if (completo) {
        await _marcarOk();
        await _db.setMeta('last_sync_error', '');
      } else {
        // v1.2.4: no ocultar sync incompleto
        final wm = await _db.getWatermark();
        final ss = int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
        final msg = 'Sincronización incompleta: watermark $wm < server_seq $ss tras 3 intentos';
        await _db.setMeta('last_sync_error', msg);
        _emit(SyncPhase.error, error: msg);
        return;
      }
      // v1.0.17: resumen discreto de lo que realmente cambió
      final subidos =
          int.tryParse(await _db.getMeta('last_uploaded') ?? '0') ?? 0;
      final bajados =
          int.tryParse(await _db.getMeta('last_downloaded') ?? '0') ?? 0;
      final resumen = (subidos == 0 && bajados == 0)
          ? 'Sin cambios'
          : [
              if (subidos > 0) '↑ $subidos enviado${subidos == 1 ? '' : 's'}',
              if (bajados > 0) '↓ $bajados nuevo${bajados == 1 ? '' : 's'}',
            ].join(' · ');
      _emit(SyncPhase.idle, resumen: resumen);
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
    } catch (e) {
      final msgVisible = await _describeErrorVisible(e);
      await _db.setMeta('last_sync_error', msgVisible);
      _emit(SyncPhase.error, error: msgVisible);
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
    } finally {
      _running = false;
    }
  }

  bool _forzarFotos = false;

  /// v1.2.4 (C17): sube las fotos pendientes aunque esté el ahorro de datos.
  Future<void> subirFotosAhora() async {
    _forzarFotos = true;
    try {
      await run();
    } finally {
      _forzarFotos = false;
    }
  }

  /// Solo subida (cada hora o manual).
  Future<void> push() async {
    if (_running || !_auth.loggedIn) return;
    _running = true;
    try {
      await _doPush();
      // v1.0.14: limpiar error viejo si el push tuvo éxito
      await _db.setMeta('last_sync_error', '');
      // v1.0.17: pull silencioso tras el push para actualizar el watermark.
      // Sin esto, el server_seq avanza por las ops propias y el banner
      // muestra "Hay cambios nuevos" aunque no haya nada que bajar.
      try {
        await _doPull(silencioso: true);
      } catch (_) {}
    } catch (_) {
      // Llamadas fire-and-forget: el error ya se mostró vía _emit.
    } finally {
      _running = false;
    }
  }

  /// Lógica interna de subida (sin guard _running).
  /// P0 (2026-10-08): propaga la excepción para que run() no marque
  /// "sincronizado" si el push falló por dentro.
  Future<void> _doPush({bool forzar = false}) async {
    try {
      _emit(SyncPhase.uploading);
      final n = await _uploadOps(forzar: forzar);
      // v1.2.4 (C17): con ahorro de datos, las fotos solo se suben
      // cuando el usuario lo pide (subirFotosAhora).
      final ahorro = await PerfilService.instance.getAhorroDatos();
      if (!ahorro || _forzarFotos) {
        _emit(SyncPhase.photos);
        await _uploadFotos();
      }
      await _db.setMeta('last_push_ok', DateTime.now().toIso8601String());
      await _db.setMeta('last_uploaded', '$n');
      // v1.2.5 (D12): el servidor confirmó (ack real, no optimista).
      await marcarSincronizado();
      _emit(SyncPhase.idle);
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
      rethrow;
    } catch (e) {
      _emit(SyncPhase.error, error: await _describeErrorVisible(e));
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
      rethrow;
    }
  }

  /// Solo bajada (frecuente: ver cambios de otros entrenadores).
  Future<void> pull() async {
    if (_running || !_auth.loggedIn) return;
    _running = true;
    try {
      // v1.0.12: cierre remoto de sesión (el dueño lo forzó)
      await _verificarCierreForzado();
      await _doPull();
    } finally {
      _running = false;
    }
  }

  /// Si el dueño forzó el cierre, cierra sesión local (v1.0.12).
  Future<void> _verificarCierreForzado() async {
    try {
      final user = _auth.session?.user;
      final fc = user?.userMetadata?['forzar_cierre'];
      if (fc == null) return;
      final ultimo = int.tryParse(
              await _db.getMeta('forzar_cierre_visto') ?? '0') ??
          0;
      final marca = fc is int ? fc : int.tryParse('$fc') ?? 0;
      if (marca > ultimo) {
        await _db.setMeta('forzar_cierre_visto', '$marca');
        // v1.2.5: purga de datos sensibles antes del cierre forzado.
        await LocalDb.purgaAlCerrarSesion();
        await _auth.signOut();
        onSessionExpired?.call();
      }
    } catch (_) {}
  }

  /// Lógica interna de bajada (sin guard _running).
  /// Si [silencioso] es true, no emite fases de progreso (pull de
  /// mantenimiento tras un push; el usuario no pidió ver el proceso).
  Future<void> _doPull({bool silencioso = false}) async {
    try {
      if (!silencioso) _emit(SyncPhase.downloading);
      final n = await _download(silencioso: silencioso);
      await _db.setMeta('last_pull_ok', DateTime.now().toIso8601String());
      await _db.setMeta('last_downloaded', '$n');
      _emit(SyncPhase.idle);
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
      rethrow;
    } catch (e) {
      _emit(SyncPhase.error, error: await _describeErrorVisible(e));
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
      rethrow;
    }
  }

  // -- subida ----------------------------------------------------------
  /// Devuelve la cantidad de ops que quedaron aplicadas.
  ///
  /// Envío en lote (punto 19): varias ops por petición PostgREST
  /// (bulk + on_conflict para idempotencia), menos viajes de ida y vuelta
  /// con conexiones de alta latencia.
  Future<int> _uploadOps({bool forzar = false}) async {
    var aplicadas = 0;
    // v1.0.16: solo subir las ops del usuario actual. Las de otro
    // usuario quedan en espera hasta que su dueño vuelva a entrar.
    // v1.2.5 (D14): respeta el backoff de reintentos.
    final uid = _auth.userId;
    final ops = await _db.pendientesParaEnvio(uid, forzar: forzar);
    final ajenas = await _db.countOpsAjenas(uid);
    if (ajenas > 0) {
      _emit(SyncPhase.uploading,
          detalle: '$ajenas cambios de otro usuario en espera…');
    }
    // 1) las ya aplicadas se marcan sin reenviar
    final porEnviar = <Map<String, dynamic>>[];
    for (final op in ops) {
      final uuid = op['op_uuid'] as String;
      if (await _opAplicada(uuid)) {
        await _db.markOp(uuid, 'aplicada');
        aplicadas++;
      } else {
        porEnviar.add(op);
      }
    }
    // 2) envío en lotes de 50
    const loteTam = 50;
    for (var i = 0; i < porEnviar.length; i += loteTam) {
      final fin =
          (i + loteTam < porEnviar.length) ? i + loteTam : porEnviar.length;
      final lote = porEnviar.sublist(i, fin);
      _emit(SyncPhase.uploading,
          detalle:
              'Enviando tus cambios… $fin de ${porEnviar.length}',
          progreso: fin / porEnviar.length);
      final body = jsonEncode([
        for (final op in lote)
          {
            'op_uuid': op['op_uuid'],
            'device_tag': 'apk-android',
            'tipo': op['tipo'],
            'payload': jsonDecode(op['payload'] as String),
          }
      ]);
      try {
        final r = await _postAuth(
            Uri.parse('$_base/rest/v1/sync_ops?on_conflict=op_uuid'),
            headers: {
              'Content-Type': 'application/json',
              // duplicados se fusionan: idempotente por op_uuid
              'Prefer': 'resolution=ignore-duplicates,return=minimal',
            },
            body: body);
        if (r.statusCode == 200 ||
            r.statusCode == 201 ||
            r.statusCode == 204 ||
            r.statusCode == 409) {
          // 409 = ya encolada (idempotente)
          for (final op in lote) {
            await _db.markOp(op['op_uuid'] as String, 'enviada');
          }
        } else if (r.statusCode >= 400 && r.statusCode < 500) {
          // error de cliente: reintenta op por op para aislar la
          // culpable en vez de atascar el lote entero
          await _uploadUnaPorUna(lote);
        } else {
          // v1.2.5 (D14/D15): clasifica y aplica backoff o revisión.
          for (final op in lote) {
            await _db.bumpOp(op['op_uuid'] as String,
                'HTTP ${r.statusCode}',
                httpStatus: r.statusCode);
          }
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        for (final op in lote) {
          await _db.bumpOp(op['op_uuid'] as String, e);
        }
      }
    }
    // 3) segunda pasada: marcar aplicadas (incluye las 'enviada')
    for (final op in await _db.unappliedOps()) {
      final uuid = op['op_uuid'] as String;
      if (await _opAplicada(uuid)) {
        await _db.markOp(uuid, 'aplicada');
        // v1.2.4: la incidencia local queda confirmada por el servidor
        if ('${op['tipo']}' == 'incidencia') {
          try {
            final pl = jsonDecode(op['payload'] as String);
            final iid = pl['id'] as String?;
            if (iid != null) await _db.marcarIncidenciaSincronizada(iid);
          } catch (_) {}
        }
        // Limpia la entrada optimista temporal (el registro real
        // llega por el pull) para no duplicar en el historial.
        if ('${op['tipo']}' == 'inscripcion_venta_suplemento') {
          await _db.limpiarOptimista('ventas_suplementos', uuid);
        } else if ('${op['tipo']}' == 'crear_categoria') {
          // v1.2.1: la categoría real llega por el pull; sin esto la
          // fila temporal (id negativo) queda duplicada.
          await _db.limpiarOptimista('categorias_suplemento', uuid);
        }
        aplicadas++;
      }
    }
    return aplicadas;
  }

  /// Reintenta un lote op por op: la que falle con 4xx se marca
  /// 'rechazada' (definitiva y visible en la cola) y NO bloquea a las
  /// demás. Los fallos de red siguen siendo transitorios (reintento).
  Future<void> _uploadUnaPorUna(
      List<Map<String, dynamic>> lote) async {
    for (final op in lote) {
      final uuid = op['op_uuid'] as String;
      final body = jsonEncode({
        'op_uuid': uuid,
        'device_tag': 'apk-android',
        'tipo': op['tipo'],
        'payload': jsonDecode(op['payload'] as String),
      });
      try {
        final r = await _postAuth(
            Uri.parse('$_base/rest/v1/sync_ops?on_conflict=op_uuid'),
            headers: {
              'Content-Type': 'application/json',
              'Prefer':
                  'resolution=ignore-duplicates,return=minimal',
            },
            body: body);
        if (r.statusCode == 200 ||
            r.statusCode == 201 ||
            r.statusCode == 204 ||
            r.statusCode == 409) {
          await _db.markOp(uuid, 'enviada');
        } else if (r.statusCode == 429 ||
            r.statusCode == 408 ||
            r.statusCode >= 500) {
          // v1.2.5 (D14): transitorios con backoff, no se marcan rechazadas.
          await _db.bumpOp(uuid, 'HTTP ${r.statusCode}',
              httpStatus: r.statusCode);
        } else if (r.statusCode >= 400 && r.statusCode < 500) {
          await _db.markOp(uuid, 'rechazada',
              error: 'El servidor la rechazó (HTTP ${r.statusCode}). '
                  'Revisa los datos o cancela la operación.');
        } else {
          await _db.bumpOp(uuid, 'HTTP ${r.statusCode}',
              httpStatus: r.statusCode);
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        await _db.bumpOp(uuid, e);
      }
    }
  }

  Future<bool> _opAplicada(String uuid) async {
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=aplicada'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return false;
      final rows = jsonDecode(r.body) as List;
      return rows.isNotEmpty && rows.first['aplicada'] == true;
    } catch (e) {
      if (e is SessionExpired) rethrow;
      return false;
    }
  }

  Future<int?> _clienteDeOp(String uuid) async {
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=resultado'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return null;
      final res = rows.first['resultado'];
      if (res is Map) {
        // El puente guarda el envelope {"ok":..., "resultado": {...}}.
        final inner = res['resultado'];
        final src = inner is Map ? inner : res;
        final cid = src['cliente_id'];
        return cid is int ? cid : int.tryParse('$cid');
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// v1.2.1 fix auditoría Gemini: resuelve el suplemento_id creado por
  /// una op `crear_suplemento` leyendo el resultado que guarda el puente.
  Future<int?> _suplementoDeOp(String uuid) async {
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=resultado'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return null;
      final res = rows.first['resultado'];
      if (res is Map) {
        // El puente guarda el envelope {"ok":..., "resultado": {...}}.
        final inner = res['resultado'];
        final src = inner is Map ? inner : res;
        final sid = src['suplemento_id'];
        return sid is int ? sid : int.tryParse('$sid');
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // -- bajada ------------------------------------------------------------
  /// Devuelve la cantidad de filas nuevas bajadas.
  ///
  /// Invariante del watermark: solo avanza al final del ciclo, después de
  /// aplicar todos los cambios. Si algo falla a mitad, el watermark no se
  /// mueve y la próxima bajada re-aplica (idempotente) desde el mismo
  /// punto. No hay ningún camino donde el watermark avance sin aplicar.
  Future<int> _download({bool silencioso = false}) async {
    // v1.2.5 (D19): si el manifiesto marcó algún ámbito divergente,
    // re-descarga completa desde cero en este ciclo.
    try {
      final flags = await _db.metasConPrefijo('forzar_redescarga_');
      if (flags.isNotEmpty) {
        await _db.setWatermark(0);
        for (final k in flags) {
          await _db.setMeta(k, '');
        }
      }
    } catch (_) {}
    // ajustes + server_seq (para verificación de sincronización)
    int? serverSeq;
    try {
      final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_estado?id=eq.1'
          '&select=server_seq,ajustes,usuarios,actividad'));
      if (r.statusCode == 200) {
        final rows = jsonDecode(r.body) as List;
        if (rows.isNotEmpty) {
          if (rows.first['ajustes'] is Map) {
            await _db.setAjustes(
                Map<String, dynamic>.from(rows.first['ajustes']));
          }
          // v1.0.12: lista de usuarios APK para gestión
          if (rows.first['usuarios'] is List) {
            await _db.setMeta('usuarios_apk',
                jsonEncode(rows.first['usuarios']));
          }
          // v1.0.15: feed de actividad reciente
          if (rows.first['actividad'] is List) {
            await _db.setMeta('sync_estado_actividad',
                jsonEncode(rows.first['actividad']));
          }
          serverSeq = rows.first['server_seq'] as int?;
          if (serverSeq != null) {
            await _db.setMeta('server_seq', '$serverSeq');
          }
        }
      }
    } catch (_) {}

    var wm = await _db.getWatermark();
    // `since` queda fijo para todo el ciclo: cada tabla consulta desde el
    // watermark inicial y solo al final se consolida el máximo. Así ningún
    // cambio con sync_seq menor que el máximo de otra tabla se omite.
    final since = wm;
    var maxSeq = wm;
    // v1.2.5 (D20): métricas honestas por ámbito.
    var vistas = 0;
    var aplicadas = 0;
    var sinCambios = 0;
    var fallidas = 0;
    const tablas = [
      'clientes',
      'pagos',
      'pagos_diarios',
      'gastos',
      'suplementos',
      'ventas_suplementos',
      'categorias_suplemento', // v1.2.1
    ];
    const supTablas = {
      'clientes': 'sync_clientes',
      'pagos': 'sync_pagos',
      'pagos_diarios': 'sync_pagos_diarios',
      'gastos': 'sync_gastos',
      'suplementos': 'sync_suplementos',
      'ventas_suplementos': 'sync_ventas_suplementos',
      // v1.2.1: si el servidor no tiene la tabla, el pull la omite.
      'categorias_suplemento': 'sync_categorias_suplemento',
    };
    var ti = 0;
    for (final tabla in tablas) {
      ti++;
      final supTabla = supTablas[tabla]!;
      if (!silencioso) {
        _emit(SyncPhase.downloading,
            detalle:
                'Descargando ${_nombreAmigable(tabla)}… $ti de ${tablas.length}',
            progreso: ti / (tablas.length + 1));
      }
      try {
        var pageWm = since;
        while (true) {
          // gastos tiene esquema plano en Supabase (sin columna 'data')
          final select = tabla == 'gastos'
              ? 'id,fecha,concepto,monto,registrado_por,sync_seq'
              : 'id,data,sync_seq';
          final r = await _getAuth(Uri.parse(
              '$_base/rest/v1/$supTabla?select=$select'
              '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=500'));
          if (r.statusCode == 404 || r.statusCode == 400) {
            // v1.2.1: la tabla no existe en Supabase (p. ej.
            // sync_categorias_suplemento aún no creada). Se omite
            // silenciosamente sin abortar el resto del pull.
            break;
          }
          if (r.statusCode != 200) {
            throw Exception('bajada $tabla: HTTP ${r.statusCode}');
          }
          final rows = jsonDecode(r.body) as List;
          if (rows.isEmpty) break;
          for (final row in rows) {
            vistas++;
            try {
              final m = Map<String, dynamic>.from(row as Map);
              final seq = (m['sync_seq'] as int?) ?? 0;
              final id = (m['id'] as int?) ?? 0;
              // gastos usa columnas planas en Supabase (sin 'data' JSON)
              final Map<String, dynamic> data;
              if (tabla == 'gastos') {
                data = {
                  'id': id,
                  'fecha': m['fecha'],
                  'concepto': m['concepto'],
                  'monto': m['monto'],
                  'registrado_por': m['registrado_por'],
                };
              } else {
                data = Map<String, dynamic>.from(m['data'] as Map);
              }
              // v1.2.5 (D20): cuenta aplicadas vs sin cambios de verdad.
              if (await _db.upsertMirror(tabla, id, data, seq)) {
                aplicadas++;
              } else {
                sinCambios++;
              }
              if (seq > maxSeq) maxSeq = seq;
            } catch (_) {
              fallidas++;
            }
          }
          if (rows.length < 500) break;
          pageWm = maxSeq;
        }
      } catch (e) {
        // 404/400 ya se manejan con break arriba (tabla no existe).
        // Cualquier otro error (red, parseo, BD) debe abortar el pull
        // para no dejar el watermark en estado inconsistente.
        rethrow;
      }
    }
    // borrados (tombstones)
    if (!silencioso) {
      _emit(SyncPhase.downloading,
          detalle: 'Descargando eliminados…',
          progreso: tablas.length / (tablas.length + 1));
    }
    var pageWm = since;
    while (true) {
      final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_borrados'
          '?select=entidad,entidad_id,sync_seq'
          '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=500'));
      if (r.statusCode != 200) {
        throw Exception('bajada borrados: HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      for (final row in rows) {
        final m = Map<String, dynamic>.from(row as Map);
        final seq = (m['sync_seq'] as int?) ?? 0;
        final tabla = {
          'clientes': 'clientes',
          'pagos': 'pagos',
          'suplementos': 'suplementos',
          'ventas_suplementos': 'ventas_suplementos',
          // v1.2.1: categorías de suplementos
          'categorias_suplemento': 'categorias_suplemento',
          'categoria_suplemento': 'categorias_suplemento',
        }[m['entidad']] ??
            'pagos_diarios';
        await _db.deleteMirror(tabla, (m['entidad_id'] as int?) ?? -1);
        if (seq > maxSeq) maxSeq = seq;
      }
      if (rows.length < 500) break;
      pageWm = maxSeq;
    }
    // v1.2.4: incidencias (tabla central sync_incidencias)
    try {
      await _downloadIncidencias(silencioso: silencioso);
    } catch (e) {
      // 404/400 = tabla aún no creada en Supabase: se omite sin abortar.
      // Otro error sí aborta para no dejar watermark inconsistente.
      final msg = e.toString();
      if (!msg.contains('404') && !msg.contains('400')) rethrow;
    }
    // v1.2.5: eventos autoritativos de incidencias
    try {
      await _downloadIncidenciaEventos(silencioso: silencioso);
    } catch (e) {
      final msg = e.toString();
      if (!msg.contains('404') && !msg.contains('400')) rethrow;
    }
    if (maxSeq > since) {
      await _db.setWatermark(maxSeq);
    }
    // v1.2.5 (D17): marca por ámbito con HORA DEL SERVIDOR (header Date),
    // no del dispositivo (D18: el reloj local puede estar mal).
    try {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_estado?id=eq.1&select=server_seq'));
      final dateHdr = r.headers['date'];
      final horaServidor = dateHdr != null
          ? HttpDate.parse(dateHdr).toIso8601String()
          : DateTime.now().toUtc().toIso8601String();
      for (final tabla in tablas) {
        await _db.setMeta(
            'last_remote_sync_ok_$tabla', horaServidor);
      }
      await _db.setMeta('last_remote_sync_ok', horaServidor);
    } catch (_) {}
    // Sincronizar estado final de operaciones enviadas (aplicada/rechazada)
    await _syncOpStatus();
    // v1.2.5 (D20): resumen honesto, no "todo bien".
    await _db.setMeta('last_download_stats',
        jsonEncode({
          'vistas': vistas,
          'aplicadas': aplicadas,
          'sinCambios': sinCambios,
          'fallidas': fallidas,
        }));
    return aplicadas;
  }

  /// v1.2.5 (D19): verificación por manifiesto (buckets sensibles al rol).
  ///
  /// Pide al servidor los (id, sync_seq) por bucket y compara contra el
  /// espejo local. Si falta una fila o el servidor tiene sync_seq mayor,
  /// el bucket diverge y se fuerza su re-descarga.
  /// Retorna la cantidad de buckets divergentes (0 = todo coincide).
  Future<int> verificarManifiesto({int nBuckets = 8}) async {
    const tablas = {
      'sync_clientes': 'clientes',
      'sync_pagos': 'pagos',
      'sync_pagos_diarios': 'pagos_diarios',
      'sync_gastos': 'gastos',
      'sync_suplementos': 'suplementos',
      'sync_ventas_suplementos': 'ventas_suplementos',
      'sync_categorias_suplemento': 'categorias_suplemento',
      'sync_incidencias': 'incidencias_mirror',
    };
    var divergentes = 0;
    for (final entry in tablas.entries) {
      final supTabla = entry.key;
      final localTabla = entry.value;
      for (var b = 0; b < nBuckets; b++) {
        try {
          final r = await _postAuth(
              Uri.parse('$_base/rest/v1/rpc/sync_manifiesto'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'p_tabla': supTabla,
                'p_bucket': b,
                'p_n_buckets': nBuckets,
              }));
          if (r.statusCode == 404 || r.statusCode == 400) {
            // RPC aún no aplicado en Supabase: se omite sin abortar.
            break;
          }
          if (r.statusCode != 200) continue;
          final rows = jsonDecode(r.body) as List;
          // v1.2.5-rev2 (ChatGPT): protocolo de saturación. La RPC devuelve
          // hasta 2001 filas; MÁS de 2000 = truncado. Se marca divergente
          // (re-descarga, dirección segura) sin comparar. 2000 exactas =
          // manifiesto completo, se compara normal.
          if (rows.length > 2000) {
            divergentes++;
            await _db.setMeta('forzar_redescarga_$localTabla', '1');
            continue;
          }
          var coincide = true;
          for (final row in rows) {
            final m = Map<String, dynamic>.from(row as Map);
            final rid = m['rid'] as String?;
            final sseq = (m['sseq'] as int?) ?? 0;
            if (rid == null) continue;
            final localSeq = await _db.seqFilaMirror(localTabla, rid);
            // Falta local o el servidor tiene versión más nueva.
            if (localSeq == null || localSeq < sseq) {
              coincide = false;
              break;
            }
          }
          if (!coincide) {
            divergentes++;
            // Fuerza re-descarga del ámbito en el próximo pull.
            await _db.setMeta('forzar_redescarga_$localTabla', '1');
          }
        } catch (_) {
          // Error de red: no cuenta como divergencia, se reintentará.
        }
      }
    }
    return divergentes;
  }

  /// v1.2.5 (D18): verifica que el reloj del dispositivo no esté muy
  /// desfasado respecto al servidor. El orden SIEMPRE es por server_seq
  /// (nunca por hora local); esto solo avisa si el desfase es grande.
  /// Retorna el desfase en minutos (null si no se pudo medir).
  Future<int?> verificarReloj() async {
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_estado?id=eq.1&select=server_seq'));
      final dateHdr = r.headers['date'];
      if (dateHdr == null) return null;
      final serverTime = HttpDate.parse(dateHdr);
      final diffMin =
          DateTime.now().toUtc().difference(serverTime).inMinutes.abs();
      if (diffMin > 5) {
        await _db.setMeta('reloj_desfasado_min', '$diffMin');
      } else {
        await _db.setMeta('reloj_desfasado_min', '');
      }
      return diffMin;
    } catch (_) {
      return null;
    }
  }

  /// Watermark propio (max sync_seq del mirror), independiente del global.
  Future<void> _downloadIncidencias({bool silencioso = false}) async {
    var pageWm = await _db.maxIncidenciaSyncSeq();
    while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias?select=id,tipo,entidad,entidad_id,'
          'descripcion,detalle,estado,creada_por,creada_en,resuelta_por,'
          'resuelta_en,nota_resolucion,visibilidad,version,actualizada_en,sync_seq'
          '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=200'));
      if (r.statusCode == 404 || r.statusCode == 400) {
        // Tabla aún no existe en Supabase: se omite silenciosamente.
        return;
      }
      if (r.statusCode != 200) {
        throw Exception('bajada incidencias: HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      for (final row in rows) {
        final m = Map<String, dynamic>.from(row as Map);
        final seq = (m['sync_seq'] as int?) ?? 0;
        await _db.upsertIncidenciaMirror(m);
        if (seq > pageWm) pageWm = seq;
      }
      if (rows.length < 200) break;
    }
  }

  /// v1.2.5: descarga incremental de eventos autoritativos de incidencias.
  /// Los genera el puente al aceptar cada mutación. RLS en Supabase ya
  /// filtra por visibilidad para no-admin.
  Future<void> _downloadIncidenciaEventos({bool silencioso = false}) async {
    var pageWm = await _db.maxEventoSyncSeq();
    while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencia_eventos?select=id,incidencia_id,'
          'actor_id,actor_nombre,accion,valor_anterior,valor_nuevo,nota,'
          'creada_en,sync_seq'
          '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=200'));
      if (r.statusCode == 404 || r.statusCode == 400) {
        // Tabla aún no existe en Supabase: se omite silenciosamente.
        return;
      }
      if (r.statusCode != 200) {
        throw Exception('bajada eventos incidencia: HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      for (final row in rows) {
        final m = Map<String, dynamic>.from(row as Map);
        final seq = (m['sync_seq'] as int?) ?? 0;
        await _db.upsertEventoMirror(m);
        if (seq > pageWm) pageWm = seq;
      }
      if (rows.length < 200) break;
    }
  }

  /// v1.2.4: reporta una incidencia (offline-first).
  /// 1) Guarda local. 2) Encola op 'incidencia' para el servidor.
  /// Retorna el id local (UUID).
  /// v1.2.5: visibilidad ('compartida' por defecto; 'privada' solo admin —
  /// la UI no ofrece la opción a entrenadores y el puente la valida).
  Future<String> reportarIncidencia({
    required String tipo,
    required String descripcion,
    String? entidad,
    int? entidadId,
    Map<String, dynamic>? detalle,
    String visibilidad = 'compartida',
  }) async {
    const tipos = {'stock', 'rechazo', 'sync', 'foto'};
    if (!tipos.contains(tipo)) throw ArgumentError('tipo inválido');
    if (descripcion.trim().isEmpty) throw ArgumentError('descripción vacía');
    if (visibilidad != 'compartida' && visibilidad != 'privada') {
      throw ArgumentError('visibilidad inválida');
    }
    // Defensa en profundidad: solo admin puede crear privadas.
    if (visibilidad == 'privada' && !_auth.isAdmin) {
      throw StateError('solo el dueño puede crear incidencias privadas');
    }
    final u = _auth.username;
    final creadaPor =
        u.isNotEmpty ? u : (_auth.userId ?? 'desconocido');
    final id = await _db.crearIncidenciaLocal(
      tipo: tipo,
      descripcion: descripcion.trim(),
      creadaPor: creadaPor,
      entidad: entidad,
      entidadId: entidadId,
      detalle: detalle,
      visibilidad: visibilidad,
    );
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'incidencia',
      payload: {
        'id': id,
        'tipo': tipo,
        'descripcion': descripcion.trim(),
        'entidad': entidad,
        'entidad_id': entidadId,
        'detalle': detalle,
        'visibilidad': visibilidad,
      },
    );
    return id;
  }

  /// v1.2.4: solicita cambio de estado de una incidencia.
  /// Encola op 'incidencia_estado'; el servidor valida transición,
  /// permisos y concurrencia. Actualización optimista del mirror local.
  /// v1.2.5 (4.2 adelantado): enforcement en dominio, no solo UI.
  /// Resolver o reabrir exige admin; el servidor revalida al sincronizar.
  Future<void> cambiarEstadoIncidencia({
    required String id,
    required String nuevoEstado,
    String? notaResolucion,
  }) async {
    final mirror = await _db.incidenciasMirror();
    final actual = mirror.where((m) => m['id'] == id).toList();
    if (actual.isEmpty) throw ArgumentError('incidencia no encontrada');
    final row = actual.first;
    final estadoActual = '${row['estado']}';
    final esResolucion = nuevoEstado == 'resuelta';
    final esReapertura =
        estadoActual == 'resuelta' && nuevoEstado != 'resuelta';
    if ((esResolucion || esReapertura) && !_auth.isAdmin) {
      throw StateError(
          'solo el dueño puede ${esResolucion ? 'resolver' : 'reabrir'}');
    }
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'incidencia_estado',
      payload: {
        'id': id,
        'estado': nuevoEstado,
        'nota_resolucion': notaResolucion,
        'version': row['version'],
      },
    );
    // Optimista: refleja el cambio en el mirror; el próximo pull lo
    // confirma o lo corrige según lo que aplique el servidor.
    await _db.upsertIncidenciaMirror({
      ...row,
      'estado': nuevoEstado,
      'nota_resolucion': notaResolucion ?? row['nota_resolucion'],
    });
  }

  /// v1.2.5: registra un evento de auditoría local (hash encadenado) y
  /// encola la op 'auditoria' para el registro autoritativo del puente.
  /// "Quién hizo qué": acciones sensibles del dominio.
  Future<String> registrarAuditoria({
    required String accion,
    required String objetoTipo,
    required String objetoId,
    Map<String, dynamic>? detalle,
  }) async {
    if (accion.trim().isEmpty) throw ArgumentError('acción vacía');
    final actorId = _auth.userId ?? _auth.username;
    final actorNombre = _auth.displayName;
    // v1.2.5: dispositivo_id estable por instalación (perfil.dart).
    final dispositivoId = await _db.getMeta('device_id') ?? 'desconocido';
    final id = await _db.auditoriaInsert(
      actorId: actorId,
      actorNombre: actorNombre,
      accion: accion.trim(),
      objetoTipo: objetoTipo,
      objetoId: objetoId,
      detalle: detalle,
      dispositivoId: dispositivoId,
    );
    // El hash previo/propio viajan para verificación cruzada en servidor.
    final rows = await _db.auditoriaPendientes(limit: 1);
    final ultimo = rows.isEmpty
        ? null
        : rows.firstWhere((r) => r['id'] == id, orElse: () => rows.first);
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'auditoria',
      payload: {
        'id': id,
        'accion': accion.trim(),
        'objeto_tipo': objetoTipo,
        'objeto_id': objetoId,
        'detalle': detalle,
        'hash_previo': ultimo?['hash_previo'],
        'hash_propio': ultimo?['hash_propio'],
      },
    );
    return id;
  }

  /// Marca las auditorías como sincronizadas tras confirmar el servidor.
  Future<void> confirmarAuditorias(List<String> ids) async {
    for (final id in ids) {
      await _db.marcarAuditoriaSincronizada(id);
    }
  }

  /// Baja el estado final de las ops enviadas (el puente las marca como
  /// aplicada/rechazada en Supabase). Actualiza la cola local.
  Future<void> _syncOpStatus() async {
    try {
      final enviadas = await _db.opsByEstado('enviada');
      if (enviadas.isEmpty) return;
      for (final op in enviadas) {
        final uuid = op['op_uuid'] as String;
        final r = await _getAuth(Uri.parse(
            '$_base/rest/v1/sync_ops?select=estado,error&op_uuid=eq.$uuid'));
        if (r.statusCode == 200) {
          final rows = jsonDecode(r.body) as List;
          if (rows.isNotEmpty) {
            final estado = rows.first['estado'] as String?;
            final error = rows.first['error'] as String?;
            if (estado == 'aplicada') {
              await _db.markOp(uuid, 'aplicada');
            } else if (estado == 'rechazada') {
              await _db.markOp(uuid, 'rechazada',
                  error: error ?? 'Rechazada por el servidor.');
            }
          }
        }
      }
    } catch (_) {
      // No bloquea la sincronización si falla
    }
  }

  // -- fotos -------------------------------------------------------------
  /// Reduce la foto a máx. 1024px de ancho (JPEG 80) antes de subirla.
  /// Las fotos de cámara a resolución completa (varios MB) no terminan
  /// de subir con conexiones lentas; así quedan en ~150-300 KB.
  /// Sube la foto de un suplemento al bucket y devuelve su storage_path
  /// (`suplementos/<uuid>.jpg`), o null si falla. La op `foto_suplemento`
  /// enlaza esa ruta en el servidor.
  Future<String?> subirFotoSuplemento(
      String opUuid, Uint8List bytes) async {
    final comprimida = _comprimirFoto(bytes);
    final path = 'suplementos/$opUuid.jpg';
    final tus = await _subirFotoTus(opUuid, path, comprimida);
    final ok = tus ?? await _subirFotoSimple(path, comprimida);
    return ok ? path : null;
  }

  Uint8List _comprimirFoto(Uint8List bytes) {
    try {
      final dec = img.decodeImage(bytes);
      if (dec == null || dec.width <= 1024) return bytes;
      final chica = img.copyResize(dec, width: 1024);
      return Uint8List.fromList(img.encodeJpg(chica, quality: 80));
    } catch (_) {
      return bytes; // si falla, se intenta con la original
    }
  }

  /// Crea una subida tus reanudable. Devuelve la URL de subida o null
  /// si tus no está disponible / fue rechazada.
  Future<String?> _tusCrear(String objectPath, int length) async {
    String meta(String k, String v) =>
        '$k ${base64Encode(utf8.encode(v))}';
    try {
      final r = await _postAuth(
        Uri.parse('$_base/storage/v1/upload/resumable'),
        headers: {
          'Tus-Resumable': '1.0.0',
          'Upload-Length': '$length',
          // v1.2.4: permite re-subir (resincronizar) sin chocar con 409.
          'x-upsert': 'true',
          'Upload-Metadata': [
            meta('filename', objectPath.split('/').last),
            meta('bucketName', AppConfig.bucketFotos),
            meta('objectName', objectPath),
            meta('contentType', 'image/jpeg'),
          ].join(','),
        },
        timeout: const Duration(seconds: 30),
      );
      if (r.statusCode != 200 && r.statusCode != 201) return null;
      final loc = r.headers['location'];
      if (loc == null || loc.isEmpty) return null;
      return loc.startsWith('http') ? loc : '$_base$loc';
    } catch (_) {
      return null;
    }
  }

  /// Cuánto ya se subió según el servidor: >=0 offset, -1 no existe,
  /// -2 no se pudo averiguar.
  Future<int> _tusOffset(String location) async {
    try {
      final r = await _headAuth(Uri.parse(location));
      if (r.statusCode == 404 || r.statusCode == 410) return -1;
      if (r.statusCode != 200) return -2;
      return int.tryParse(r.headers['upload-offset'] ?? '') ?? -2;
    } catch (_) {
      return -2;
    }
  }

  /// Sube la foto por partes con tus (punto 17): si se corta la conexión,
  /// continúa donde quedó en vez de empezar de cero.
  /// Devuelve true si terminó, false si hay que reintentar luego,
  /// null si tus no está disponible (usar el método simple).
  Future<bool?> _subirFotoTus(
      String opUuid, String objectPath, Uint8List bytes) async {
    final locKey = 'tus_loc_$opUuid';
    final offKey = 'tus_offset_$opUuid';
    String? location = await _db.getMeta(locKey);
    if (location != null && location.isEmpty) location = null;
    var offset = int.tryParse(await _db.getMeta(offKey) ?? '0') ?? 0;

    if (location == null) {
      location = await _tusCrear(objectPath, bytes.length);
      if (location == null) return null;
      await _db.setMeta(locKey, location);
      offset = 0;
    } else {
      final remoto = await _tusOffset(location);
      if (remoto == -1) {
        // expiró en el servidor: crear de nuevo
        location = await _tusCrear(objectPath, bytes.length);
        if (location == null) return null;
        await _db.setMeta(locKey, location);
        offset = 0;
      } else if (remoto >= 0) {
        offset = remoto;
      }
      // remoto == -2: no se pudo averiguar; se usa el guardado
    }
    if (offset > bytes.length) offset = 0;
    final url = location;

    const chunk = 256 * 1024;
    while (offset < bytes.length) {
      final fin =
          (offset + chunk < bytes.length) ? offset + chunk : bytes.length;
      var okChunk = false;
      for (var intento = 0; intento < 3 && !okChunk; intento++) {
        try {
          final r = await _patchAuth(
            Uri.parse(url),
            headers: {
              'Tus-Resumable': '1.0.0',
              'Content-Type': 'application/offset+octet-stream',
              'Upload-Offset': '$offset',
            },
            body: bytes.sublist(offset, fin),
          );
          if (r.statusCode == 204 || r.statusCode == 200) {
            offset =
                int.tryParse(r.headers['upload-offset'] ?? '') ?? fin;
            okChunk = true;
          } else if (r.statusCode == 404 || r.statusCode == 410) {
            // la subida murió en el servidor: recrearla luego
            await _db.setMeta(locKey, '');
            await _db.setMeta(offKey, '0');
            return false;
          }
        } catch (_) {
          okChunk = false;
        }
      }
      if (!okChunk) {
        await _db.setMeta(offKey, '$offset');
        return false; // se retoma donde quedó
      }
      await _db.setMeta(offKey, '$offset');
    }
    // limpia el estado tus de esta foto
    await _db.setMeta(locKey, '');
    await _db.setMeta(offKey, '0');
    return true;
  }

  /// Método simple (un solo PUT): respaldo si tus no está disponible.
  Future<bool> _subirFotoSimple(String path, Uint8List bytes) async {
    // v1.2.4 (Hark): antes no se enviaba el cuerpo y quedaban fotos de 0 bytes.
    if (bytes.isEmpty) return false;
    for (var intento = 0; intento < 3; intento++) {
      try {
        final r = await _postAuth(
            Uri.parse('$_base/storage/v1/object/'
                '${AppConfig.bucketFotos}/$path'),
            headers: {
              'Content-Type': 'image/jpeg',
              'x-upsert': 'true',
            },
            body: bytes,
            timeout: const Duration(seconds: 120));
        if (r.statusCode == 200 || r.statusCode == 201) return true;
      } catch (_) {}
    }
    return false;
  }

  /// v1.2.1 fix auditoría Gemini: sube una foto pendiente de suplemento
  /// y encola la op `foto_suplemento` para que el puente la vincule.
  Future<void> _uploadFotoSuplemento(Map<String, dynamic> f, int fid,
      int suplementoId, int i, int total) async {
    if (f['suplemento_id'] == null) {
      await _db.setFotoSuplemento(fid, suplementoId);
    }
    final file = File(f['local_path'] as String);
    if (!await file.exists()) {
      // v1.2.4: antes se marcaba 'lista' y la foto se perdía sin aviso.
      await _db.marcarFotoError(fid, 'Archivo local no encontrado',
          definitivo: true);
      return;
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      await _db.marcarFotoError(fid, 'Archivo local vacío (0 bytes)',
          definitivo: true);
      return;
    }
    final path =
        await subirFotoSuplemento(f['op_uuid'] as String, bytes);
    _emit(SyncPhase.photos,
        detalle: 'Subiendo fotos… $i de $total',
        progreso: (i - 1) / total);
    if (path == null) {
      // sin conexión o rechazo: cuenta el intento; sigue 'pendiente' y con
      // 10+ intentos aparece en Incidencias (fotosConProblema).
      await _db.marcarFotoError(fid, 'No se pudo subir (intento fallido)');
      return;
    }
    _emit(SyncPhase.photos,
        detalle: 'Subiendo fotos… $i de $total',
        progreso: i / total);
    final d = await _db.db;
    await d.insert('ops_queue', {
      'op_uuid': const Uuid().v4(),
      'tipo': 'foto_suplemento',
      'payload': jsonEncode(
          {'suplemento_id': suplementoId, 'storage_path': path}),
      'estado': 'pendiente',
      'creada_ts': DateTime.now().toIso8601String(),
    });
    await _db.markFotoLista(fid);
  }

  Future<void> _uploadFotos() async {
    final fotos = await _db.fotosPendientes();
    var i = 0;
    for (final f in fotos) {
      i++;
      final fid = f['id'] as int;
      var clienteId = f['cliente_id'] as int?;
      // v1.2.1 fix auditoría Gemini: fotos de suplementos.
      var suplementoId = f['suplemento_id'] as int?;
      clienteId ??= await _clienteDeOp(f['op_uuid'] as String);
      suplementoId ??= await _suplementoDeOp(f['op_uuid'] as String);
      if (clienteId == null && suplementoId == null) {
        continue; // la creación aún no se aplica en el servidor
      }
      if (suplementoId != null) {
        await _uploadFotoSuplemento(f, fid, suplementoId, i, fotos.length);
        continue;
      }
      if (f['cliente_id'] == null) {
        await _db.setFotoCliente(fid, clienteId!);
      }
      final file = File(f['local_path'] as String);
      if (!await file.exists()) {
        // v1.2.4: antes se marcaba 'lista' y la foto se perdía sin aviso.
        await _db.marcarFotoError(fid, 'Archivo local no encontrado',
            definitivo: true);
        continue;
      }
      var bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        await _db.marcarFotoError(fid, 'Archivo local vacío (0 bytes)',
            definitivo: true);
        continue;
      }
      bytes = _comprimirFoto(bytes);
      final path = 'pendientes/${f['op_uuid']}.jpg';
      _emit(SyncPhase.photos,
          detalle: 'Subiendo fotos… $i de ${fotos.length}',
          progreso: (i - 1) / fotos.length);
      // reanudable primero; si tus no está disponible, método simple
      final tus =
          await _subirFotoTus(f['op_uuid'] as String, path, bytes);
      final ok = tus ?? await _subirFotoSimple(path, bytes);
      if (!ok) {
        await _db.marcarFotoError(fid, 'No se pudo subir (intento fallido)');
        continue;
      }
      _emit(SyncPhase.photos,
          detalle: 'Subiendo fotos… $i de ${fotos.length}',
          progreso: i / fotos.length);
      // encola la op 'foto' para que el puente la guarde en gym.db
      final d = await _db.db;
      final opUuid = const Uuid().v4();
      await d.insert('ops_queue', {
        'op_uuid': opUuid,
        'tipo': 'foto',
        'payload': jsonEncode(
            {'storage_path': path, 'cliente_id': clienteId}),
        'estado': 'pendiente',
        'creada_ts': DateTime.now().toIso8601String(),
      });
      await _db.markFotoLista(fid);
    }
  }
}
