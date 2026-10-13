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

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'auth.dart';
import 'config.dart';
import 'errores_sync.dart';
import 'fotos_cola.dart';
import 'localdb.dart';
import 'perfil.dart';

enum SyncPhase { idle, uploading, downloading, photos, error }

class SyncStatus {
  final SyncPhase phase;
  final int pending;
  final DateTime? lastOk;
  /// v1.2.9+43: ErrorSync en vez de String crudo (blindaje anti-fugas).
  final ErrorSync? lastError;

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

/// v1.2.8 (Paso 1): scopes de sincronización contextual con DAG real.
/// Corrección Gemini: separa el grafo de dependencias entre tablas
/// (integridad referencial) del catálogo de scopes (agrupación de negocio).
/// El Push SIEMPRE es global; solo el Pull se filtra por scope.
class SyncScope {
  /// Grafo real de dependencias entre tablas (FKs). Para orden topológico.
  static const Map<String, List<String>> _dependenciasTablas = {
    'pagos_diarios': ['clientes'],
    'pagos': ['clientes'],
    'suplementos': ['categorias_suplemento'],
    'ventas_suplementos': ['clientes', 'suplementos'],
    'incidencias': ['incidencia_tipos'],
    'incidencia_eventos': ['incidencias'],
  };

  /// Scopes de pantalla: solo declaran sus tablas objetivo.
  /// Las dependencias se resuelven automáticamente vía _dependenciasTablas.
  static const Map<String, List<String>> _scopes = {
    'pago_diario': ['pagos_diarios'],
    'inscribir': ['clientes'],
    'buscar_cliente': ['clientes', 'pagos'],
    'suplementos': ['suplementos'],
    'ventas': ['ventas_suplementos'],
    'incidencias': ['incidencia_eventos'],
    'gastos': ['gastos'],
  };

  /// Resuelve las tablas del scope en orden topológico (padres primero).
  static List<String> resolver(String scope) {
    final visitadas = <String>{};
    final resultado = <String>[];

    void resolverTopologico(String tabla) {
      if (visitadas.contains(tabla)) return;
      visitadas.add(tabla);
      for (final dep in _dependenciasTablas[tabla] ?? const []) {
        resolverTopologico(dep);
      }
      resultado.add(tabla);
    }

    for (final tabla in _scopes[scope] ?? const []) {
      resolverTopologico(tabla);
    }
    return resultado;
  }
}

/// Detalle de la última sincronización (para la pantalla de Sync).
/// v1.3.0 (Gemini): separados último ciclo vs acumulado histórico.
class SyncDetalle {
  final DateTime? ultimaPull;
  final DateTime? ultimaPush;
  final int subidosUltimo;
  final int bajadosUltimo;
  final int totalSubidos;
  final int totalBajados;
  final String? error;
  const SyncDetalle(
      {this.ultimaPull,
      this.ultimaPush,
      this.subidosUltimo = 0,
      this.bajadosUltimo = 0,
      this.totalSubidos = 0,
      this.totalBajados = 0,
      this.error});

  /// Compatibilidad: subidos/bajados = último ciclo.
  int get subidos => subidosUltimo;
  int get bajados => bajadosUltimo;
}

class SessionExpired implements Exception {
  final String message;
  SessionExpired([this.message = 'sesión vencida, entra de nuevo']);
  @override
  String toString() => message;
}

/// v1.2.9: estado tipado de subida (corrección Gemini #3).
enum EstadoSubida { subida, reintentable, permanente, permitirFallback }

/// v1.2.9: resultado estructurado (corrección Gemini #3).
class ResultadoSubidaFoto {
  final EstadoSubida estado;
  final String? storagePath;
  final String? error;

  const ResultadoSubidaFoto({
    required this.estado,
    this.storagePath,
    this.error,
  });
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

  /// v1.2.9+43: cliente HTTP singleton para reutilizar conexiones TCP/TLS
  /// (Keep-Alive). Evita el handshake de 800ms-2s por cada petición.
  static final _httpClient = http.Client();

  /// v1.2.9+43: timeout adaptativo basado en el tamaño del payload.
  /// Asume throughput mínimo de 2 KB/s (conexión lenta de Cuba).
  /// Rango: 20s mínimo, 120s máximo.
  Duration _timeoutPara(int bytes) {
    const base = Duration(seconds: 20);
    const throughputMinimo = 2048; // 2 KB/s
    final extra = Duration(seconds: (bytes / throughputMinimo).ceil());
    final total = base + extra;
    const maximo = Duration(seconds: 120);
    return total > maximo ? maximo : total;
  }

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
      _reqAuth((t) => _httpClient.get(url, headers: {
            'apikey': AppConfig.anonKey,
            'Authorization': 'Bearer $t',
            'Accept-Encoding': 'gzip',
          }).timeout(timeout));

  Future<http.Response> _postAuth(Uri url,
          {Map<String, String>? headers,
          Object? body,
          Duration timeout = const Duration(seconds: 60)}) =>
      _reqAuth((t) => _httpClient
          .post(url,
              headers: {
                'apikey': AppConfig.anonKey,
                'Authorization': 'Bearer $t',
                'Accept-Encoding': 'gzip',
                ...?headers,
              },
              body: body)
          .timeout(timeout));

  Future<http.Response> _headAuth(Uri url,
          {Duration timeout = const Duration(seconds: 30)}) =>
      _reqAuth((t) => _httpClient.head(url, headers: {
            'apikey': AppConfig.anonKey,
            'Authorization': 'Bearer $t',
            'Tus-Resumable': '1.0.0',
          }).timeout(timeout));

  Future<http.Response> _patchAuth(Uri url,
          {required Map<String, String> headers,
          Object? body,
          Duration timeout = const Duration(seconds: 120)}) =>
      _reqAuth((t) => _httpClient
          .patch(url,
              headers: {
                'apikey': AppConfig.anonKey,
                'Authorization': 'Bearer $t',
                ...headers,
              },
              body: body)
          .timeout(timeout));

  void _emit(SyncPhase phase,
      {ErrorSync? error,
      double? progreso,
      String? detalle,
      String? resumen}) async {
    final pending = await _db.countPendingOps();
    final lastOk = await _ultimaOk();
    // v1.0.15: detectar si el servidor tiene cambios sin bajar
    bool novedades = false;
    try {
      final wm = await _db.getWatermarkMinimo();
      final ss = int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
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
  /// v1.2.9+43: retorna ErrorSync (no String) para blindaje anti-fugas.
  Future<ErrorSync> _describeErrorVisible(Object e, {int? httpStatus}) async {
    final ec = traducirErrorSync(e, httpStatus: httpStatus);
    // Sin conexión pero hay internet: el servidor no responde.
    if (ec.codigo == 'sin_conexion' && await _hayInternet()) {
      return ErrorSync(
        codigo: 'servidor_no_responde',
        tipo: TipoErrorSync.transitorio,
        mensaje: 'No se pudo contactar el servidor.',
        accionTexto: 'Tus cambios están guardados en el teléfono.',
        accionBoton: AccionBoton.reintentar,
        datosGuardadosLocalmente: true,
        detalleTecnicoOculto: e.toString(),
      );
    }
    return ec;
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
      subidosUltimo:
          int.tryParse(await _db.getMeta('last_uploaded') ?? '0') ?? 0,
      bajadosUltimo:
          int.tryParse(await _db.getMeta('last_downloaded') ?? '0') ?? 0,
      totalSubidos:
          int.tryParse(await _db.getMeta('total_subidos') ?? '0') ?? 0,
      totalBajados:
          int.tryParse(await _db.getMeta('total_bajados') ?? '0') ?? 0,
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
    await _conLock(() async {
      try {
        // v1.2.9+47: errores de push y pull por separado (Gemini).
        String? errPush;
        String? errPull;
        try {
          await _doPush(forzar: forzar);
        } catch (e) {
          errPush = (await _describeErrorVisible(e)).mensaje;
          AppLog.error('sync', 'push_fallo', d: '$e');
        }
        // v1.2.4: perfil (móvil/carnet) que no pudo subirse sin conexión.
        try {
          await PerfilService.instance.sincronizarSiPendiente();
        } catch (_) {}
        // Pull repetido: si llegan cambios durante la descarga, seguir.
        bool completo = false;
        for (var i = 0; i < 3; i++) {
          try {
            await _doPull();
          } catch (e) {
            errPull = (await _describeErrorVisible(e)).mensaje;
            AppLog.error(
                'sync', 'pull_fallo', d: 'intento=$i error=$e');
            continue;
          }
          final wm = await _db.getWatermarkMinimo();
          final ss = int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
          if (wm >= ss) {
            completo = true;
            break;
          }
        }
        // v1.2.9+47: guardar estados separados (Gemini: manejar los 3 casos).
        await _db.setMeta('last_push_error', errPush ?? '');
        await _db.setMeta('last_pull_error', errPull ?? '');
        if (completo) {
          await _marcarOk();
          await _db.setMeta('last_sync_error', '');
        } else if (errPush != null) {
          await _db.setMeta('last_sync_error', errPush);
          _emit(SyncPhase.error,
              error: traducirErrorSync(errPush));
          return;
        } else {
          // Push OK pero pull incompleto.
          await _db.setMeta('last_sync_error',
              'Subida al día · Descarga pendiente');
          // No emitir error crítico: la subida funcionó.
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
        final errSync = await _describeErrorVisible(e);
        await _db.setMeta('last_sync_error', errSync.mensaje);
        _emit(SyncPhase.error, error: errSync);
        await Future.delayed(const Duration(seconds: 2));
        _emit(SyncPhase.idle);
      }
    });
  }

  /// v1.2.8 (Paso 1): sincroniza solo las tablas del scope (pull parcial).
  /// El Push NO se filtra por scope (corrección Gemini): siempre es global
  /// para no violar FKs en el servidor.
  Future<void> sincronizarScope(String scope) async {
    final tablas = SyncScope.resolver(scope);
    if (tablas.isEmpty) return;
    await _conLock(() async {
      try {
        // Push global primero (nunca filtrado por scope).
        await _doPush();
        // Pull solo de las tablas del scope.
        _emit(SyncPhase.downloading);
        final n = await _download(tablasFiltro: tablas);
        await _db.setMeta('last_pull_ok', DateTime.now().toIso8601String());
        await _db.setMeta('last_downloaded', '$n');
        await _db.setMeta('last_scope', scope);
        _emit(SyncPhase.idle,
            resumen: 'Sincronizado: ${tablas.join(', ')}');
      } catch (e) {
        final errSync = await _describeErrorVisible(e);
        _emit(SyncPhase.error, error: errSync);
        await Future.delayed(const Duration(seconds: 2));
        _emit(SyncPhase.idle);
      }
    });
  }

  /// Ejecuta [fn] con el lock de sincronización entre isolates.
  /// Retorna false si otro isolate ya está sincronizando.
  /// NOTA: Solo los 4 puntos de entrada públicos (run, push, pull,
  /// sincronizarScope) usan _conLock. Los métodos internos (_doPush,
  /// _doPull, _download) NUNCA lo adquieren, así evitan auto-bloqueo.
  /// La bandera _running evita reentrada en el mismo isolate.
  /// v1.3-r3: el lock lleva owner UUID para evitar race condition al
  /// liberar (un isolate rezagado no desmonta el lock de otro activo).
  Future<bool> _conLock(Future<void> Function() fn) async {
    if (_running || !_auth.loggedIn) return false;
    // Lock persistente: protege contra Workmanager en otro isolate.
    final owner = await _db.adquirirSyncLock();
    if (owner == null) return false;
    _running = true;
    try {
      await fn();
      return true;
    } finally {
      _running = false;
      await _db.liberarSyncLock(owner);
    }
  }

  /// Solo subida (cada hora o manual).
  Future<void> push() async {
    await _conLock(() async {
      await _doPush();
      // v1.0.14: limpiar error viejo si el push tuvo éxito
      await _db.setMeta('last_sync_error', '');
      // v1.0.17: pull silencioso tras el push para actualizar el watermark.
      // Sin esto, el server_seq avanza por las ops propias y el banner
      // muestra "Hay cambios nuevos" aunque no haya nada que bajar.
      try {
        await _doPull(silencioso: true);
      } catch (_) {}
    });
  }

  /// Lógica interna de subida (sin guard _running).
  /// P0 (2026-10-08): propaga la excepción para que run() no marque
  /// "sincronizado" si el push falló por dentro.
  Future<void> _doPush({bool forzar = false}) async {
    // v1.2.9+46 (AppLog): inicio de push.
    AppLog.info('sync', 'push_ini');
    try {
      _emit(SyncPhase.uploading);
      // A3 (Argón): fotos en push() (no en pull), y rescatar
      // las que quedaron en 'uploading' por cierre forzoso.
      try {
        final db = await _db.db;
        await db.update('incidencias_fotos',
            {'sync_estado': 'retry'},
            where: "sync_estado = 'uploading'");
      } catch (_) {}
      await subirFotosIncidencias();
      // v1.2.9+46 (Gemini): acumular ambos lotes para last_uploaded.
      var totalOps = await _uploadOps(forzar: forzar);
      AppLog.info('sync', 'ops_enviadas', d: 'n=$totalOps');
      // v1.2.9+46: las fotos SIEMPRE se suben en cada sincronización,
      // como en v1.2.3. La puerta de ahorro de datos se eliminó por
      // orden de Jc (2026-10-13): hacía que las fotos nunca se intentaran.
      _emit(SyncPhase.photos);
      // v1.2.9+43: solo intentar el flujo viejo si hay datos legacy.
      // v1.2.9+41: _uploadFotos no debe bloquear procesarCola.
      if (await _db.hayFotosLegacy()) {
        try {
          await _uploadFotos();
        } catch (e) {
          debugPrint('WARN _uploadFotos (viejo) falló: $e');
          AppLog.aviso('sync', 'fotos_legacy_fallo', d: '$e');
        }
      }
      // v1.2.9+42 (Gemini): procesarCola protegido + segundo _uploadOps
      // para enviar las ops de vinculación generadas por las fotos.
      int fotosSubidas = 0;
      try {
        fotosSubidas = await FotosColaService.instance.procesarCola();
        AppLog.info('sync', 'cola_fotos', d: 'subidas=$fotosSubidas');
      } catch (e) {
        debugPrint('ERROR procesarCola falló: $e');
        AppLog.error('sync', 'cola_fotos_fallo', d: '$e');
      }
      // Si se subieron fotos y se generaron ops de vinculación,
      // vaciar ops_queue hacia Supabase de inmediato.
      if (fotosSubidas > 0) {
        // v1.2.9+46 (Gemini): sumar al total para last_uploaded.
        totalOps += await _uploadOps(forzar: forzar);
      }
      await _db.setMeta('last_push_ok', DateTime.now().toIso8601String());
      // v1.3.0: acumulativo (no solo última sincronización).
      final prevSubidos =
          int.tryParse(await _db.getMeta('total_subidos') ?? '0') ?? 0;
      await _db.setMeta(
          'total_subidos', '${prevSubidos + totalOps}');
      await _db.setMeta('last_uploaded', '$totalOps');
      // v1.2.5 (D12): el servidor confirmó (ack real, no optimista).
      await marcarSincronizado();
      _emit(SyncPhase.idle);
      // v1.2.9+46 (AppLog): push completo.
      AppLog.info('sync', 'push_fin', d: 'ops=$totalOps fotos=$fotosSubidas');
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
      // v1.2.9+46 (AppLog): caída de sesión.
      AppLog.error('sync', 'sesion_vencida');
      rethrow;
    } catch (e) {
      _emit(SyncPhase.error, error: await _describeErrorVisible(e));
      // v1.2.9+46 (AppLog): fallo del push.
      AppLog.error('sync', 'push_fallo', d: '$e');
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
      rethrow;
    }
  }

  /// Solo bajada (frecuente: ver cambios de otros entrenadores).
  Future<void> pull() async {
    await _conLock(() async {
      // v1.0.12: cierre remoto de sesión (el dueño lo forzó)
      await _verificarCierreForzado();
      await _doPull();
    });
  }

  /// Si el dueño forzó el cierre, cierra sesión local (v1.0.12).
  Future<void> _verificarCierreForzado() async {
    try {
      final user = _auth.session?.user;
      final fc = user?.userMetadata?['forzar_cierre'];
      if (fc == null) return;
      final ultimo =
          int.tryParse(await _db.getMeta('forzar_cierre_visto') ?? '0') ?? 0;
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
    // v1.2.9+47 (AppLog): instrumentación del pull.
    AppLog.info('sync', 'pull_ini');
    try {
      if (!silencioso) _emit(SyncPhase.downloading);
      final n = await _download(silencioso: silencioso);
      // v1.3.0: acumulativo para bajados.
      final prevBajados =
          int.tryParse(await _db.getMeta('total_bajados') ?? '0') ?? 0;
      await _db.setMeta('total_bajados', '${prevBajados + n}');
      // v1.3.0: pull de incidencias (tipos → incidencias, orden por FK).
      // Fix #11 (Sol): si falla, no se marca last_pull_ok general.
      var incidenciasOk = true;
      try {
        await _pullTiposIncidencia();
        await _pullIncidencias();
        await _db.setMeta('last_pull_incidencias_ok',
            DateTime.now().toIso8601String());
      } catch (e) {
        incidenciasOk = false;
        AppLog.error(
            'sync', 'pull_incidencias_fallo', d: '$e');
        await _db.setMeta(
            'last_pull_incidencias_error', '$e');
      }

      // Fix #11: solo marcar OK si todo (incl. incidencias) funcionó.
      if (incidenciasOk) {
        await _db.setMeta(
            'last_pull_ok', DateTime.now().toIso8601String());
      }
      await _db.setMeta('last_downloaded', '$n');
      _emit(SyncPhase.idle);
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
      rethrow;
    } catch (e) {
      AppLog.error('sync', 'pull_fallo', d: '$e');
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
    // v1.2.9+46 (Gemini): las ops en 'enviada' por más de 2 minutos
    // vuelven a 'pendiente' para reintento idempotente. Evita que
    // queden en limbo perpetuo si la confirmación falló.
    try {
      final db = await _db.db;
      final corte = DateTime.now()
          .subtract(const Duration(minutes: 2))
          .toIso8601String();
      await db.update(
        'ops_queue',
        {'estado': 'pendiente', 'error': null},
        where: "estado = 'enviada' AND creada_ts < ?",
        whereArgs: [corte],
      );
    } catch (_) {}
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
    // v1.2.9+43: batch RPC (1 RTT) en vez de N llamadas individuales.
    // Con fallback al método viejo si el RPC no existe aún.
    final porEnviar = <Map<String, dynamic>>[];
    Set<String> aplicadasSet;
    try {
      final uuids = ops.map((o) => o['op_uuid'] as String).toList();
      aplicadasSet = await _opsAplicadasBatch(uuids);
    } catch (e) {
      // Fallback: RPC no existe o falló — usar método individual
      debugPrint('WARN batch RPC falló, usando fallback individual: $e');
      aplicadasSet = {};
      for (final op in ops) {
        final uuid = op['op_uuid'] as String;
        if (await _opAplicada(uuid)) {
          aplicadasSet.add(uuid);
        }
      }
    }
    for (final op in ops) {
      final uuid = op['op_uuid'] as String;
      if (aplicadasSet.contains(uuid)) {
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
          detalle: 'Enviando tus cambios… $fin de ${porEnviar.length}',
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
        // v1.2.9+43: timeout adaptativo según tamaño del lote
        final r = await _postAuth(
            Uri.parse('$_base/rest/v1/sync_ops?on_conflict=op_uuid'),
            headers: {
              'Content-Type': 'application/json',
              // duplicados se fusionan: idempotente por op_uuid
              'Prefer': 'resolution=ignore-duplicates,return=minimal',
            },
            body: body,
            timeout: _timeoutPara(utf8.encode(body).length));
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
            await _db.bumpOp(op['op_uuid'] as String, 'HTTP ${r.statusCode}',
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
    // Argón B1: marcar tipos y comentarios como synced tras push.
    if (aplicadas > 0) {
      try {
        await _db.marcarTiposComentariosSincronizados();
      } catch (_) {}
    }
    return aplicadas;
  }

  /// Reintenta un lote op por op: la que falle con 4xx se marca
  /// 'rechazada' (definitiva y visible en la cola) y NO bloquea a las
  /// demás. Los fallos de red siguen siendo transitorios (reintento).
  Future<void> _uploadUnaPorUna(List<Map<String, dynamic>> lote) async {
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
              'Prefer': 'resolution=ignore-duplicates,return=minimal',
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

  /// v1.2.9+43: verifica múltiples ops en un solo RTT.
  /// Retorna el set de UUIDs que están en estado 'aplicada'.
  /// Lanza excepción si el RPC falla (el llamador hace fallback).
  Future<Set<String>> _opsAplicadasBatch(List<String> uuids) async {
    if (uuids.isEmpty) return {};
    const maxPorBatch = 100;
    final resultado = <String>{};
    for (var i = 0; i < uuids.length; i += maxPorBatch) {
      final fin = (i + maxPorBatch < uuids.length)
          ? i + maxPorBatch
          : uuids.length;
      final lote = uuids.sublist(i, fin);
      final r = await _postAuth(
        Uri.parse('$_base/rest/v1/rpc/ops_aplicadas_batch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'p_uuids': lote}),
        timeout: const Duration(seconds: 20),
      );
      if (r.statusCode != 200) {
        throw StateError(
            'RPC ops_aplicadas_batch falló: ${r.statusCode}');
      }
      final List<dynamic> data = jsonDecode(r.body);
      resultado.addAll(data.map((e) => e.toString()));
    }
    return resultado;
  }

  Future<bool> _opAplicada(String uuid) async {
    // v1.2.9+39: usar RPC op_aplicada en vez de GET directo.
    // El RLS de SELECT en sync_ops no devuelve filas aunque la política
    // sea correcta; la función SECURITY DEFINER evita el problema.
    try {
      final r = await _postAuth(
          Uri.parse('$_base/rest/v1/rpc/op_aplicada'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'p_op_uuid': uuid}),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return false;
      final result = jsonDecode(r.body);
      if (result is bool) return result;
      if (result is List && result.isNotEmpty) {
        final v = result.first;
        if (v is bool) return v;
        if (v is Map && v.containsKey('op_aplicada')) {
          return v['op_aplicada'] == true;
        }
      }
      return false;
    } catch (e) {
      if (e is SessionExpired) rethrow;
      return false;
    }
  }

  /// v1.2.9: wrapper público para la cola de fotos.
  Future<int?> clienteDeOp(String uuid) => _clienteDeOp(uuid);

  /// v1.2.9: wrapper público para la cola de fotos.
  Future<int?> suplementoDeOp(String uuid) => _suplementoDeOp(uuid);

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
  /// Aplica una fila del pull al espejo local según el esquema de la tabla.
  /// Retorna true si la fila cambió (para métricas honestas).
  ///
  /// v1.2.5-rev6: turnos_cierre usa id TEXT (UUID) y columnas planas en
  /// Supabase; en rev5 el pull pedía `id,data,sync_seq`, respondía 400 y
  /// se omitía silenciosamente (el admin nunca veía cierres remotos).
  /// v1.2.7 (Paso 1 Gemini): prepara los datos de una fila mirror sin
  /// escribir a la BD. Devuelve {'id', 'dataJson', 'esTexto'} o null si
  /// la fila es inválida. La escritura se hace en batch transaccional.
  Map<String, dynamic>? _prepararFilaMirror(
      String tabla, Map<String, dynamic> m) {
    if (tabla == 'turnos_cierre') {
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      final data = <String, dynamic>{
        'id': id,
        'entrenador_id': m['entrenador_id'],
        'entrenador_nombre': m['entrenador_nombre'],
        'telegram_id': m['telegram_id'],
        'fecha': m['fecha'],
        'turno': m['turno'],
        'total_cobrado': m['total_cobrado'],
        'total_esperado': m['total_esperado'],
        'pagos_count': m['pagos_count'],
        'nota': m['nota'],
        'cerrado_en': m['cerrado_en'],
      };
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    final id = (m['id'] as int?) ?? 0;
    if (id == 0) return null;
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
      final rawData = m['data'];
      if (rawData is! Map) return null;
      data = Map<String, dynamic>.from(rawData);
      // FIX (Gemini auditoría funcional): inyectar id siempre, porque
      // los lectores del mirror solo decodifican la columna data.
      data['id'] = id;
      if (tabla == 'clientes') {
        // FIX: default 'activo' si viene null (todo cliente sin estado
        // explícito se considera activo).
        data['estado'] ??= 'activo';
      }
    }
    return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': false};
  }

  /// Devuelve la cantidad de filas nuevas bajadas.
  ///
  /// Invariante del watermark: solo avanza al final del ciclo, después de
  /// aplicar todos los cambios. Si algo falla a mitad, el watermark no se
  /// mueve y la próxima bajada re-aplica (idempotente) desde el mismo
  /// punto. No hay ningún camino donde el watermark avance sin aplicar.
  Future<int> _download({bool silencioso = false, List<String>? tablasFiltro}) async {
    // v1.2.5 (D19): si el manifiesto marcó algún ámbito divergente,
    // re-descarga completa desde cero en este ciclo.
    // v1.2.5-rev5 (Gemini): reseteo GRANULAR por tabla, no nuclear global.
    // Cada flag 'forzar_redescarga_<tabla>' hace que solo esa tabla se
    // re-descargue desde 0; las demás usan el watermark global normal.
    final tablasReseteadas = <String>{};
    try {
      final flags = await _db.metasConPrefijo('forzar_redescarga_');
      for (final k in flags) {
        tablasReseteadas.add(k.replaceFirst('forzar_redescarga_', ''));
        await _db.setMeta(k, '');
      }
    } catch (_) {}
    // ajustes + server_seq (para verificación de sincronización)
    int? serverSeq;
    try {
      final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_estado?id=eq.1'
          '&select=server_seq,ajustes,usuarios,actividad'));
      // v1.2.9+47 (AppLog): estado del servidor.
      AppLog.info('sync', 'pull_estado', d: 'http=${r.statusCode}');
      if (r.statusCode == 200) {
        final rows = jsonDecode(r.body) as List;
        if (rows.isNotEmpty) {
          if (rows.first['ajustes'] is Map) {
            await _db
                .setAjustes(Map<String, dynamic>.from(rows.first['ajustes']));
          }
          // v1.0.12: lista de usuarios APK para gestión
          if (rows.first['usuarios'] is List) {
            await _db.setMeta(
                'usuarios_apk', jsonEncode(rows.first['usuarios']));
          }
          // v1.0.15: feed de actividad reciente
          if (rows.first['actividad'] is List) {
            await _db.setMeta(
                'sync_estado_actividad', jsonEncode(rows.first['actividad']));
          }
          serverSeq = rows.first['server_seq'] as int?;
          if (serverSeq != null) {
            await _db.setMeta('server_seq', '$serverSeq');
          }
        }
      }
    } catch (e) {
      AppLog.error('sync', 'pull_estado_fallo', d: '$e');
    }

    // v1.2.5-rev6 (Gemini #16): watermarks por tabla. Cada espejo tiene su
    // propio cursor (`wm_<tabla>`); el fallo de una tabla no bloquea a
    // las demás ni obliga a re-descargar todo.
    final erroresTablas = <String>[];
    // v1.2.5 (D20): métricas honestas por ámbito.
    var vistas = 0;
    var aplicadas = 0;
    var sinCambios = 0;
    var fallidas = 0;
    // v1.2.8 (Paso 1): si se pasa tablasFiltro (scope), solo esas tablas.
    final todasTablas = [
      'clientes',
      'pagos',
      'pagos_diarios',
      'gastos',
      'suplementos',
      'ventas_suplementos',
      'categorias_suplemento', // v1.2.1
      'turnos_cierre', // v1.2.5-rev5
    ];
    final tablas = tablasFiltro ?? todasTablas;
    const supTablas = {
      'clientes': 'sync_clientes',
      'pagos': 'sync_pagos',
      'pagos_diarios': 'sync_pagos_diarios',
      'gastos': 'sync_gastos',
      'suplementos': 'sync_suplementos',
      'ventas_suplementos': 'sync_ventas_suplementos',
      // v1.2.1: si el servidor no tiene la tabla, el pull la omite.
      'categorias_suplemento': 'sync_categorias_suplemento',
      // v1.2.5-rev5: cierres sincronizados (si no existe, se omite).
      'turnos_cierre': 'sync_turnos_cierre',
    };
    var ti = 0;
    for (final tabla in tablas) {
      ti++;
      // Ajuste preventivo Gemini (veredicto final): si un scope futuro
      // incluye una tabla no declarada en supTablas, saltarla en vez de
      // pedir a .../rest/v1/null.
      final supTabla = supTablas[tabla];
      if (supTabla == null) continue;
      if (!silencioso) {
        _emit(SyncPhase.downloading,
            detalle:
                'Descargando ${_nombreAmigable(tabla)}… $ti de ${tablas.length}',
            progreso: ti / (tablas.length + 1));
      }
      // v1.2.5-rev6: cursor propio de la tabla. Si el manifiesto la marcó
      // divergente, se resetea a 0 (re-descarga solo ella).
      var cursor = await _db.getWatermarkTabla(tabla);
      if (tablasReseteadas.contains(tabla)) {
        cursor = 0;
        await _db.setWatermarkTabla(tabla, 0);
      }
      var pageWm = cursor;
      var tablaMax = cursor;
      try {
        while (true) {
          // gastos y turnos_cierre tienen esquema plano en Supabase
          // (sin columna 'data' JSON).
          final select = switch (tabla) {
            'gastos' => 'id,fecha,concepto,monto,registrado_por,sync_seq',
            'turnos_cierre' =>
              'id,entrenador_id,entrenador_nombre,telegram_id,fecha,'
                  'turno,total_cobrado,total_esperado,pagos_count,nota,'
                  'cerrado_en,sync_seq',
            _ => 'id,data,sync_seq',
          };
          // v1.2.9+47 (AppLog): medir latencia del lote.
          final t0 = DateTime.now();
          final r =
              await _getAuth(Uri.parse('$_base/rest/v1/$supTabla?select=$select'
                  '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=100'));
          final latencia =
              DateTime.now().difference(t0).inMilliseconds;
          // v1.2.9+47 (AppLog): log por lote.
          AppLog.info('sync', 'pull_lote',
              d: '$tabla wm=$pageWm http=${r.statusCode} '
                  'bytes=${r.body.length} ms=$latencia');
          if (r.statusCode == 404 || r.statusCode == 400) {
            AppLog.aviso('sync', 'pull_tabla_ausente',
                d: '$tabla http=${r.statusCode}');
            // v1.2.1: la tabla no existe en Supabase o el rol no puede
            // leerla (p. ej. sync_turnos_cierre antes de aplicar v116,
            // sync_gastos para entrenadores). Se omite sin abortar el
            // resto del pull.
            // v1.2.5-rev6: NO se avanza el cursor (las filas que aparezcan
            // después —p. ej. al aplicar v116— pueden tener sync_seq
            // antiguos y se perderían). Se marca "ausente" para que no
            // bloquee el "sincronizado"; al reaparecer se baja desde el
            // cursor real.
            await _db.setMeta('wm_${tabla}_ausente', '1');
            break;
          }
          // La tabla existe y responde: limpiar marca de ausente.
          await _db.setMeta('wm_${tabla}_ausente', '');
          if (r.statusCode != 200) {
            // v1.2.9+47 (AppLog): fallo HTTP con fragmento sanitizado.
            final frag = r.body.length > 200
                ? r.body.substring(0, 200)
                : r.body;
            AppLog.error('sync', 'pull_lote_fallo',
                d: '$tabla http=${r.statusCode} '
                    'body=${frag.replaceAll('\n', ' ')}');
            throw Exception(
                'bajada $tabla: HTTP ${r.statusCode}');
          }
          final rows = jsonDecode(r.body) as List;
          // v1.2.9+47 (AppLog): lote OK.
          AppLog.info('sync', 'pull_lote_ok',
              d: '$tabla filas=${rows.length}');
          if (rows.isEmpty) break;
          // v1.2.7 (Paso 1 Gemini): commit atómico por página.
          // Se preparan las filas primero (sin escribir), luego en una sola
          // transacción se hace batch insert + actualización del watermark.
          // Si la página falla, no se avanza el cursor y se reintenta limpio.
          final opsPagina = <Map<String, dynamic>>[];
          var paginaMax = pageWm;
          for (final row in rows) {
            vistas++;
            try {
              final m = Map<String, dynamic>.from(row as Map);
              final seq = (m['sync_seq'] as int?) ?? 0;
              final prep = _prepararFilaMirror(tabla, m);
              if (prep != null) {
                // v1.2.5 (D20): cuenta aplicadas vs sin cambios de verdad.
                // v1.2.7 fix Gemini: capturar oldFoto ANTES del batch.
                final verif = await _db.verificarCambioMirror(
                    tabla, prep['id'], prep['dataJson']);
                if (verif['cambio'] as bool) {
                  opsPagina.add({
                    'id': prep['id'],
                    'dataJson': prep['dataJson'],
                    'seq': seq,
                    'esTexto': prep['esTexto'],
                    'oldFoto': verif['oldFoto'],
                  });
                  aplicadas++;
                } else {
                  sinCambios++;
                }
              } else {
                sinCambios++;
              }
              if (seq > paginaMax) paginaMax = seq;
              if (seq > tablaMax) tablaMax = seq;
            } catch (_) {
              fallidas++;
            }
          }
          // Commit atómico: filas + watermark de la página juntos.
          if (opsPagina.isNotEmpty || paginaMax > pageWm) {
            final d = await _db.db;
            await d.transaction((txn) async {
              final batch = txn.batch();
              for (final op in opsPagina) {
                batch.insert(
                    tabla,
                    {
                      'id': op['id'],
                      'data': op['dataJson'],
                      'sync_seq': op['seq']
                    },
                    conflictAlgorithm: ConflictAlgorithm.replace);
              }
              // noResult: true evita instanciar objetos en memoria (Gemini).
              await batch.commit(noResult: true);
              // v1.2.7 fix Gemini: usar insert con replace, no update.
              // update asume que la fila existe; en instalación nueva o
              // tabla nueva, no afectaría filas y el watermark se perdería.
              // v1.2.9+36 (hotfix): columnas correctas k/v (era clave/valor,
              // lo que hacía fallar la transacción y el pull no guardaba nada).
              await txn.insert(
                'meta',
                {'k': 'wm_$tabla', 'v': '$paginaMax'},
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            });
            // FTS es derivado y reconstruible: se actualiza fuera de la txn.
            for (final op in opsPagina) {
              if (tabla == 'clientes') {
                await _db.actualizarFtsCliente(op['id'] as int,
                    op['dataJson'] as String, op['oldFoto'] as String?);
              }
            }
          }
          if (rows.length < 100) break;
          pageWm = paginaMax;
        }
      } catch (e) {
        // 404/400 ya se manejan con break arriba (tabla no existe).
        // Otro error: el cursor de esta tabla no avanza y reintenta en
        // el próximo ciclo; las demás tablas no se bloquean.
        // v1.2.7: el watermark ya se actualiza por página dentro de la
        // transacción atómica, no hace falta actualización final.
        // v1.2.9+47 (AppLog): fallo por tabla.
        AppLog.error(
            'sync', 'pull_tabla_fallo', d: '$tabla error=$e');
        erroresTablas.add('$tabla: $e');
      }
      // FIX (Gemini auditoría funcional BUG 3): si la tabla se descargó
      // sin errores, sincronizar su watermark con serverSeq. Evita que
      // getWatermarkMinimo() devuelva un cursor viejo de una tabla
      // inactiva y cause "Sincronización incompleta" eterno.
      if (serverSeq != null &&
          !erroresTablas.any((e) => e.startsWith('$tabla:'))) {
        final wmActual = await _db.getWatermarkTabla(tabla);
        if (wmActual < serverSeq) {
          await _db.setWatermarkTabla(tabla, serverSeq);
          // v1.2.9+47 (AppLog): watermark persistido.
          AppLog.info('sync', 'pull_wm_guardado',
              d: '$tabla $wmActual->$serverSeq');
        }
      }
      // v1.2.9+47 (AppLog): tabla completa.
      AppLog.info('sync', 'pull_tabla_fin', d: tabla);
    }
    // borrados (tombstones)
    if (!silencioso) {
      _emit(SyncPhase.downloading,
          detalle: 'Descargando eliminados…',
          progreso: tablas.length / (tablas.length + 1));
    }
    // v1.2.5-rev6: los borrados también llevan cursor propio.
    var cursorBorrados = await _db.getWatermarkTabla('borrados');
    var pageWm = cursorBorrados;
    var borradosMax = cursorBorrados;
    var borradosOk = true;
    try {
      while (true) {
        final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_borrados'
            '?select=entidad,entidad_id,sync_seq'
            '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=100'));
        if (r.statusCode != 200) {
          throw Exception('bajada borrados: HTTP ${r.statusCode}');
        }
        final rows = jsonDecode(r.body) as List;
        if (rows.isEmpty) break;
        for (final row in rows) {
          final m = Map<String, dynamic>.from(row as Map);
          final seq = (m['sync_seq'] as int?) ?? 0;
          final entidad = '${m['entidad'] ?? ''}';
          const mapaEntidades = {
            'clientes': 'clientes',
            'pagos': 'pagos',
            'suplementos': 'suplementos',
            'ventas_suplementos': 'ventas_suplementos',
            // v1.2.1: categorías de suplementos
            'categorias_suplemento': 'categorias_suplemento',
            'categoria_suplemento': 'categorias_suplemento',
            // v1.2.5-rev6: cierres (id TEXT)
            'turnos_cierre': 'turnos_cierre',
          };
          final tabla = mapaEntidades[entidad];
          if (tabla == null) {
            // v1.2.5-rev6: entidad desconocida. Antes caía en
            // 'pagos_diarios' por defecto y podía borrar un pago real.
            // Ahora se registra y se avanza sin borrar nada.
            await _db.setMeta('borrados_entidad_desconocida', entidad);
          } else if (tabla == 'turnos_cierre') {
            await _db.deleteMirrorTexto(tabla, '${m['entidad_id'] ?? ''}');
          } else {
            await _db.deleteMirror(tabla, (m['entidad_id'] as int?) ?? -1);
          }
          if (seq > borradosMax) borradosMax = seq;
        }
        if (rows.length < 100) break;
        pageWm = borradosMax;
      }
    } catch (e) {
      borradosOk = false;
      erroresTablas.add('borrados: $e');
    }
    if (borradosOk && borradosMax > cursorBorrados) {
      await _db.setWatermarkTabla('borrados', borradosMax);
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
    if (erroresTablas.isNotEmpty) {
      // Alguna tabla falló: las demás ya guardaron su progreso en sus
      // cursores propios; se reporta para que run() reintente solo lo
      // pendiente.
      throw Exception('bajada incompleta: ${erroresTablas.first}');
    }
    // v1.2.5 (D17): marca por ámbito con HORA DEL SERVIDOR (header Date),
    // no del dispositivo (D18: el reloj local puede estar mal).
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_estado?id=eq.1&select=server_seq'));
      final dateHdr = r.headers['date'];
      final horaServidor = dateHdr != null
          ? HttpDate.parse(dateHdr).toIso8601String()
          : DateTime.now().toUtc().toIso8601String();
      for (final tabla in tablas) {
        await _db.setMeta('last_remote_sync_ok_$tabla', horaServidor);
      }
      await _db.setMeta('last_remote_sync_ok', horaServidor);
    } catch (_) {}
    // Sincronizar estado final de operaciones enviadas (aplicada/rechazada)
    await _syncOpStatus();
    // v1.2.5 (D20): resumen honesto, no "todo bien".
    await _db.setMeta(
        'last_download_stats',
        jsonEncode({
          'vistas': vistas,
          'aplicadas': aplicadas,
          'sinCambios': sinCambios,
          'fallidas': fallidas,
        }));
    // v1.2.9+47 (AppLog): pull completo.
    AppLog.info('sync', 'pull_fin',
        d: 'vistas=$vistas aplicadas=$aplicadas '
            'sinCambios=$sinCambios fallidas=$fallidas');
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
          final r =
              await _postAuth(Uri.parse('$_base/rest/v1/rpc/sync_manifiesto'),
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
    final creadaPor = u.isNotEmpty ? u : (_auth.userId ?? 'desconocido');
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

  /// v1.2.5-rev5 (Gemini): encola el cierre de turno para sincronizar.
  /// El puente lo publica a sync_turnos_cierre; el admin ve el historial
  /// de todos los entrenadores. La marca local en meta se mantiene para
  /// el estado inmediato sin esperar la red.
  /// v1.2.5-rev6: incluye telegram_id (fallback si el servidor no puede
  /// resolverlo del dispositivo; los pagos se atribuyen por telegram_id).
  Future<String> registrarCierreTurno({
    required String fecha,
    required String turno,
    required double totalCobrado,
    double? totalEsperado,
    required int pagosCount,
    String? nota,
  }) async {
    final id = const Uuid().v4();
    await _db.queueOp(
      opUuid: id,
      tipo: 'cierre_turno',
      payload: {
        'id': id,
        'fecha': fecha,
        'turno': turno,
        'total_cobrado': totalCobrado,
        'total_esperado': totalEsperado,
        'pagos_count': pagosCount,
        'nota': nota,
        'telegram_id': _auth.telegramId,
      },
    );
    return id;
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
  Future<String?> subirFotoSuplemento(String opUuid, Uint8List bytes) async {
    final comprimida = _comprimirFoto(bytes);
    final path = 'suplementos/$opUuid.jpg';
    final tus = await _subirFotoTus(opUuid, path, comprimida);
    // v1.2.6: si TUS falla (false) también se intenta el método simple,
    // no solo cuando TUS no está disponible (null).
    final ok = tus == true || await _subirFotoSimple(path, comprimida);
    return ok ? path : null;
  }

  /// v1.2.9: subida para la cola persistente (fotos_cola).
  /// Envuelve _subirFotoTus con claves compuestas op_uuid+tipo (Gemini #1)
  /// y política de fallback estricta (Luna #2, Gemini).
  Future<ResultadoSubidaFoto> subirFotoCola({
    required String opUuid,
    required String tipo,
    required String objectPath,
    required Uint8List bytes,
    required String claveTusLoc,
    required String claveTusOffset,
  }) async {
    if (bytes.isEmpty) {
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.permanente,
        error: 'archivo vacío',
      );
    }
    try {
      final tus = await _subirFotoTusCola(
        claveTusLoc: claveTusLoc,
        claveTusOffset: claveTusOffset,
        objectPath: objectPath,
        bytes: bytes,
      );
      if (tus == true) {
        // Corrección Gemini #6: limpiar claves TUS exactas tras éxito.
        await _db.setMeta(claveTusLoc, '');
        await _db.setMeta(claveTusOffset, '0');
        await _db.setMeta('${claveTusLoc}_path', '');
        return ResultadoSubidaFoto(
          estado: EstadoSubida.subida,
          storagePath: objectPath,
        );
      }
      // tus == false: fallo reintentable (el offset quedó guardado).
      // tus == null: TUS no disponible → fallback permitido.
      if (tus == null) {
        final ok = await _subirFotoSimple(objectPath, bytes);
        if (ok) {
          // Luna #3: tras fallback PUT exitoso, invalidar estado TUS
          // para que un reintento no reanude el upload viejo.
          await _db.setMeta(claveTusLoc, '');
          await _db.setMeta(claveTusOffset, '0');
          await _db.setMeta('${claveTusLoc}_path', '');
          return ResultadoSubidaFoto(
            estado: EstadoSubida.subida,
            storagePath: objectPath,
          );
        }
        return const ResultadoSubidaFoto(
          estado: EstadoSubida.permitirFallback,
          error: 'TUS no disponible y PUT falló',
        );
      }
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.reintentable,
        error: 'TUS falló, se reintentará',
      );
    } on _TusPermanente catch (e) {
      // Luna #1: 403/permisos es PERMANENTE, no reintentable.
      // Limpiar estado TUS para no dejar basura.
      await _db.setMeta(claveTusLoc, '');
      await _db.setMeta(claveTusOffset, '0');
      return ResultadoSubidaFoto(
        estado: EstadoSubida.permanente,
        error: e.message,
      );
    } on SessionExpired {
      // 401: refresh sesión, reintentable (no fallback a PUT).
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.reintentable,
        error: 'sesión expirada',
      );
    } catch (e) {
      return ResultadoSubidaFoto(
        estado: EstadoSubida.reintentable,
        error: '$e',
      );
    }
  }

  /// v1.2.9: variante de _subirFotoTus que acepta claves compuestas.
  /// Correcciones Luna (auditoría pre-Gemini):
  /// - 403 → permanente (no reintentable).
  /// - Validación estricta del offset de respuesta.
  /// - offset > bytes.length → descartar URL y crear nueva (no reset a 0).
  /// - Claves TUS atadas al objectPath (validar antes de reanudar).
  /// Retorna: true=subida, false=reintentable, null=TUS no disponible,
  /// lanza _TusPermanente en 403/permisos.
  Future<bool?> _subirFotoTusCola({
    required String claveTusLoc,
    required String claveTusOffset,
    required String objectPath,
    required Uint8List bytes,
  }) async {
    // Luna #11: atar las claves al objectPath.
    final claveTusPath = '${claveTusLoc}_path';
    final pathGuardado = await _db.getMeta(claveTusPath);

    String? location = await _db.getMeta(claveTusLoc);
    if (location != null && location.isEmpty) location = null;
    // Luna #6: normalizar offset local (no negativos, no mayor que bytes).
    var offset = int.tryParse(await _db.getMeta(claveTusOffset) ?? '0') ?? 0;
    if (offset < 0) offset = 0;
    if (offset > bytes.length) offset = bytes.length;

    // Si el path guardado no coincide, descartar estado TUS viejo.
    if (location != null && pathGuardado != objectPath) {
      location = null;
      offset = 0;
    }

    if (location == null) {
      location = await _tusCrear(objectPath, bytes.length);
      if (location == null) return null; // TUS no disponible
      await _db.setMeta(claveTusLoc, location);
      await _db.setMeta(claveTusPath, objectPath);
      await _db.setMeta(claveTusOffset, '0');
      offset = 0;
    } else {
      final remoto = await _tusOffset(location);
      if (remoto == -1) {
        location = await _tusCrear(objectPath, bytes.length);
        if (location == null) return null;
        await _db.setMeta(claveTusLoc, location);
        await _db.setMeta(claveTusPath, objectPath);
        await _db.setMeta(claveTusOffset, '0');
        offset = 0;
      } else if (remoto >= 0) {
        // Fix Gemini (dead code): verificar ANTES de truncar.
        // Si remoto > bytes.length, el servidor tiene un upload con
        // offset mayor (URL reciclada). Descartar y crear nueva.
        if (remoto > bytes.length) {
          await _db.setMeta(claveTusLoc, '');
          await _db.setMeta(claveTusOffset, '0');
          location = await _tusCrear(objectPath, bytes.length);
          if (location == null) return null;
          await _db.setMeta(claveTusLoc, location);
          await _db.setMeta(claveTusPath, objectPath);
          offset = 0;
        } else {
          offset = remoto;
          if (offset < 0) offset = 0;
        }
      }
    }

    const chunk = 32 * 1024;
    while (offset < bytes.length) {
      final fin =
          (offset + chunk < bytes.length) ? offset + chunk : bytes.length;
      var okChunk = false;
      for (var intento = 0; intento < 3 && !okChunk; intento++) {
        // Fix Gemini: delay entre reintentos (caídas de torre en Cuba).
        if (intento > 0) {
          await Future.delayed(Duration(milliseconds: 400 * intento));
        }
        try {
          final r = await _patchAuth(
            Uri.parse(location!),
            headers: {
              'Tus-Resumable': '1.0.0',
              'Content-Type': 'application/offset+octet-stream',
              'Upload-Offset': '$offset',
            },
            body: bytes.sublist(offset, fin),
          );
          if (r.statusCode == 204 || r.statusCode == 200) {
            // Luna #5: validación estricta del offset de respuesta.
            final nuevoOffset =
                int.tryParse(r.headers['upload-offset'] ?? '');
            if (nuevoOffset == null ||
                nuevoOffset < offset ||
                nuevoOffset > bytes.length) {
              // Respuesta inválida: tratar como error de chunk.
              okChunk = false;
            } else {
              offset = nuevoOffset;
              okChunk = true;
            }
          } else if (r.statusCode == 401) {
            throw SessionExpired();
          } else if (r.statusCode == 404 || r.statusCode == 410) {
            await _db.setMeta(claveTusLoc, '');
            await _db.setMeta(claveTusOffset, '0');
            return false;
          } else if (r.statusCode == 403) {
            // Luna #1: 403 es PERMANENTE (RLS/permisos), no reintentable.
            throw _TusPermanente('403 Forbidden en subida TUS');
          }
        } catch (e) {
          if (e is SessionExpired || e is _TusPermanente) rethrow;
          okChunk = false;
        }
      }
      if (!okChunk) {
        await _db.setMeta(claveTusOffset, '$offset');
        return false;
      }
      await _db.setMeta(claveTusOffset, '$offset');
    }
    return true;
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
    String meta(String k, String v) => '$k ${base64Encode(utf8.encode(v))}';
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
            // Fix Gemini: MIME correcto según extensión.
            meta('contentType', objectPath.endsWith('.webp')
                ? 'image/webp'
                : 'image/jpeg'),
          ].join(','),
        },
        timeout: const Duration(seconds: 30),
      );
      if (r.statusCode != 200 && r.statusCode != 201) {
        // v1.2.9+46: loguear el código real para diagnóstico.
        AppLog.aviso('fotos', 'tus_rechazado',
            d: 'path=$objectPath status=${r.statusCode} body=${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
        return null;
      }
      final loc = r.headers['location'];
      if (loc == null || loc.isEmpty) {
        AppLog.aviso('fotos', 'tus_sin_location', d: 'path=$objectPath');
        return null;
      }
      return loc.startsWith('http') ? loc : '$_base$loc';
    } catch (e) {
      // v1.2.9+46: loguear la excepción real.
      AppLog.aviso('fotos', 'tus_excepcion', d: 'path=$objectPath error=$e');
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

    // v1.2.6: fragmentos de 32KB para conexiones inestables —
    // perder un fragmento pequeño duele menos al reintentar.
    const chunk = 32 * 1024;
    String? ultimoError;
    while (offset < bytes.length) {
      final fin =
          (offset + chunk < bytes.length) ? offset + chunk : bytes.length;
      var okChunk = false;
      for (var intento = 0; intento < 3 && !okChunk; intento++) {
        // Fix Gemini: delay entre reintentos (caídas de torre en Cuba).
        if (intento > 0) {
          await Future.delayed(Duration(milliseconds: 400 * intento));
        }
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
            offset = int.tryParse(r.headers['upload-offset'] ?? '') ?? fin;
            okChunk = true;
          } else if (r.statusCode == 404 || r.statusCode == 410) {
            // la subida murió en el servidor: recrearla luego
            await _db.setMeta(locKey, '');
            await _db.setMeta(offKey, '0');
            return false;
          } else {
            // v1.2.6: registrar el código para diagnóstico
            ultimoError = 'HTTP ${r.statusCode} en fragmento $offset';
          }
        } catch (e) {
          // v1.2.6: no ocultar el error real
          ultimoError = 'Fragmento $offset: $e';
          okChunk = false;
        }
      }
      if (!okChunk) {
        await _db.setMeta(offKey, '$offset');
        // v1.2.6: guardar el motivo para diagnóstico en Incidencias
        if (ultimoError != null) {
          await _db.setMeta('tus_err_$opUuid', ultimoError);
        }
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
    // Fix Gemini: MIME correcto según extensión del path.
    final mime = path.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
    for (var intento = 0; intento < 3; intento++) {
      try {
        final r = await _postAuth(
            Uri.parse('$_base/storage/v1/object/'
                '${AppConfig.bucketFotos}/$path'),
            headers: {
              'Content-Type': mime,
              'x-upsert': 'true',
            },
            body: bytes,
            timeout: const Duration(seconds: 120));
        if (r.statusCode == 200 || r.statusCode == 201) return true;
        // v1.2.9+46: loguear el código real para diagnóstico.
        AppLog.aviso('fotos', 'put_rechazado',
            d: 'path=$path intento=$intento status=${r.statusCode} '
                'body=${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
      } catch (e) {
        // v1.2.9+46: loguear la excepción real.
        AppLog.aviso('fotos', 'put_excepcion',
            d: 'path=$path intento=$intento error=$e');
      }
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
    final path = await subirFotoSuplemento(f['op_uuid'] as String, bytes);
    _emit(SyncPhase.photos,
        detalle: 'Subiendo fotos… $i de $total', progreso: (i - 1) / total);
    if (path == null) {
      // sin conexión o rechazo: cuenta el intento; sigue 'pendiente' y con
      // 10+ intentos aparece en Incidencias (fotosConProblema).
      await _db.marcarFotoError(fid, 'No se pudo subir (intento fallido)');
      return;
    }
    _emit(SyncPhase.photos,
        detalle: 'Subiendo fotos… $i de $total', progreso: i / total);
    final d = await _db.db;
    await d.insert('ops_queue', {
      'op_uuid': const Uuid().v4(),
      'tipo': 'foto_suplemento',
      'payload':
          jsonEncode({'suplemento_id': suplementoId, 'storage_path': path}),
      'estado': 'pendiente',
      'creada_ts': DateTime.now().toIso8601String(),
    });
    await _db.markFotoLista(fid);
  }

  Future<void> _uploadFotos() async {
    final fotos = await _db.fotosPendientes();
    var i = 0;
    for (final f in fotos) {
      // v1.2.9 (Gemini #4): el flujo viejo IGNORA fotos que tengan fila
      // en fotos_cola. La cola persistente es el único camino para fotos
      // nuevas; esto evita doble subida.
      final enCola = await _db.tieneFilaEnCola(f['op_uuid'] as String);
      if (enCola) continue;
      i++;
      final fid = f['id'] as int;
      // v1.2.6: cada foto se aísla en try/catch — un error inesperado
      // en una no aborta la subida de las demás.
      try {
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
        // reanudable primero; si tus falla o no está disponible, método simple
        final fotoOpUuid = f['op_uuid'] as String;
        final tus = await _subirFotoTus(fotoOpUuid, path, bytes);
        // v1.2.6: si TUS falla (false) también se intenta el método simple,
        // no solo cuando TUS no está disponible (null).
        final ok = tus == true || await _subirFotoSimple(path, bytes);
        if (!ok) {
          // v1.2.6: incluir el detalle del error TUS si existe
          final detalleTus = await _db.getMeta('tus_err_$fotoOpUuid');
          final motivo = detalleTus != null
              ? 'No se pudo subir: $detalleTus'
              : 'No se pudo subir (intento fallido)';
          await _db.marcarFotoError(fid, motivo);
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
          'payload':
              jsonEncode({'storage_path': path, 'cliente_id': clienteId}),
          'estado': 'pendiente',
          'creada_ts': DateTime.now().toIso8601String(),
        });
        await _db.markFotoLista(fid);
      } catch (e) {
        await _db.marcarFotoError(fid, 'Error inesperado: $e');
        continue;
      }
    }
  }

  /// v1.3.0: Pull de tipos de incidencia (antes que incidencias, por FK).
  /// Fix #11 (Sol): no silenciar errores; lanzar para que el pull
  /// exterior no marque last_pull_ok.
  Future<void> _pullTiposIncidencia() async {
    final wm =
        await _db.getWatermarkTabla('incidencias_tipos');
    try {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias_tipos?sync_seq=gt.$wm'
          '&order=sync_seq&limit=100'));
      if (r.statusCode != 200) {
        throw Exception(
            'pull_tipos_incidencia HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return;
      final d = await _db.db;
      await d.transaction((txn) async {
        var maxSeq = wm;
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(row as Map);
          final seq =
              (m['sync_seq'] as num?)?.toInt() ?? 0;
          if (seq > maxSeq) maxSeq = seq;
          await txn.insert(
              'incidencias_tipos_mirror', {
            'id': m['id'],
            'nombre': m['nombre'],
            'icono': m['icono'],
            'color': m['color'],
            'activo':
                (m['activo'] == true) ? 1 : 0,
            'orden':
                (m['orden'] as num?)?.toInt() ??
                    0,
            'actualizada_en':
                m['actualizada_en'],
            'sync_seq': seq,
          },
              conflictAlgorithm:
                  ConflictAlgorithm.replace);
          final local = await txn.query(
              'incidencias_tipos',
              where: 'id = ?',
              whereArgs: [m['id']]);
          if (local.isEmpty) {
            await txn
                .insert('incidencias_tipos', {
              'id': m['id'],
              'nombre': m['nombre'],
              'icono': m['icono'],
              'color': m['color'],
              'activo':
                  (m['activo'] == true) ? 1 : 0,
              'orden': (m['orden'] as num?)
                      ?.toInt() ??
                  0,
              'actualizado_en':
                  m['actualizada_en'],
              'sync_estado': 'synced',
            });
          } else if (local.first['sync_estado'] ==
              'synced') {
            await txn.update(
                'incidencias_tipos', {
              'nombre': m['nombre'],
              'icono': m['icono'],
              'color': m['color'],
              'activo':
                  (m['activo'] == true) ? 1 : 0,
              'orden': (m['orden'] as num?)
                      ?.toInt() ??
                  0,
              'actualizado_en':
                  m['actualizada_en'],
            },
                where: 'id = ?',
                whereArgs: [m['id']]);
          }
        }
        await _db.setWatermarkTabla(
            'incidencias_tipos', maxSeq,
            executor: txn);
      });
      AppLog.info('sync', 'pull_tipos_ok',
          d: 'n=${rows.length}');
    } catch (e) {
      AppLog.error(
          'sync', 'pull_tipos_fallo', d: '$e');
      // Argón B2: rethrow para que pull() detecte el fallo.
      rethrow;
    }
  }

  /// v1.3.0: Pull de incidencias con OCC por version.
  /// Fix #11 (Sol): no silenciar errores HTTP.
  Future<void> _pullIncidencias() async {
    final wm =
        await _db.getWatermarkTabla('incidencias');
    try {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias?sync_seq=gt.$wm'
          '&order=sync_seq&limit=100'));
      if (r.statusCode != 200) {
        throw Exception(
            'pull_incidencias HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return;
      final d = await _db.db;
      await d.transaction((txn) async {
        var maxSeq = wm;
        var huboConflicto = false;
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(row as Map);
          final seq =
              (m['sync_seq'] as num?)?.toInt() ?? 0;
          final local = await txn.query(
              'incidencias_local',
              where: 'id = ?',
              whereArgs: [m['id']]);
          if (local.isNotEmpty &&
              local.first['sync_estado'] ==
                  'pending') {
            // Argón: congelar avance de maxSeq ante conflicto,
            // pero seguir aplicando las demás filas.
            huboConflicto = true;
            continue;
          }
          if (!huboConflicto &&
              seq > maxSeq) {
            maxSeq = seq;
          }
          final vRemota =
              (m['version'] as num?)?.toInt() ?? 1;
          final vLocal = local.isEmpty
              ? 0
              : ((local.first['version'] as num?)
                      ?.toInt() ??
                  1);
          if (vRemota > vLocal) {
            if (local.isNotEmpty) {
              // Argón: actualizar también el mirror para no dejarlo
              // desactualizado.
              await txn.insert(
                  'incidencias_mirror',
                  {
                    'id': m['id'],
                    'tipo_id': m['tipo_id'],
                    'descripcion': m['descripcion'],
                    'detalle': m['detalle'],
                    'estado':
                        m['estado'] ?? 'pendiente',
                    'asignado_a': m['asignado_a'],
                    'prioridad': m['prioridad'],
                    'fecha_limite':
                        m['fecha_limite'],
                    'ubicacion': m['ubicacion'],
                    'creada_por': m['creada_por'],
                    'creada_en': m['creada_en'],
                    'resuelta_por':
                        m['resuelta_por'],
                    'resuelta_en':
                        m['resuelta_en'],
                    'nota_resolucion':
                        m['nota_resolucion'],
                    'version': vRemota,
                    'actualizada_en':
                        m['actualizada_en'],
                    'sync_seq': seq,
                  },
                  conflictAlgorithm:
                      ConflictAlgorithm.replace);
              await txn.update(
                  'incidencias_local', {
                'tipo_id': m['tipo_id'],
                'descripcion':
                    m['descripcion'],
                'detalle': m['detalle'],
                'estado':
                    m['estado'] ?? 'pendiente',
                'asignado_a': m['asignado_a'],
                'prioridad': m['prioridad'],
                'fecha_limite':
                    m['fecha_limite'],
                'ubicacion': m['ubicacion'],
                'resuelta_por':
                    m['resuelta_por'],
                'resuelta_en':
                    m['resuelta_en'],
                'nota_resolucion':
                    m['nota_resolucion'],
                'version': vRemota,
                'actualizado_en':
                    m['actualizada_en'],
                'sync_estado': 'synced',
              },
                  where: 'id = ?',
                  whereArgs: [m['id']]);
            } else {
              final vals = {
                'id': m['id'],
                'tipo': m['tipo'] ?? 'sync',
                'tipo_id': m['tipo_id'],
                'descripcion':
                    m['descripcion'],
                'detalle': m['detalle'],
                'estado':
                    m['estado'] ?? 'pendiente',
                'asignado_a': m['asignado_a'],
                'prioridad':
                    m['prioridad'] ?? 'media',
                'fecha_limite':
                    m['fecha_limite'],
                'ubicacion': m['ubicacion'],
                'creada_por':
                    m['creada_por'],
                'creada_en':
                    m['creada_en'],
                'resuelta_por':
                    m['resuelta_por'],
                'resuelta_en':
                    m['resuelta_en'],
                'nota_resolucion':
                    m['nota_resolucion'],
                'version': vRemota,
              };
              await txn.insert(
                  'incidencias_mirror',
                  {
                    ...vals,
                    'actualizada_en':
                        m['actualizada_en'],
                    'sync_seq': seq,
                  },
                  conflictAlgorithm:
                      ConflictAlgorithm.replace);
              // Sol #7: materializar también en local (synced)
              // para que las FK de fotos/comentarios funcionen.
              await txn.insert(
                  'incidencias_local',
                  {
                    ...vals,
                    'sync_estado': 'synced',
                  },
                  conflictAlgorithm:
                      ConflictAlgorithm.replace);
            }
          }
        }
        await _db.setWatermarkTabla(
            'incidencias', maxSeq,
            executor: txn);
      });
      AppLog.info('sync', 'pull_inc_ok',
          d: 'n=${rows.length}');
    } catch (e) {
      AppLog.error(
          'sync', 'pull_inc_fallo', d: '$e');
      // Argón B2: rethrow para que pull() detecte el fallo.
      rethrow;
    }
  }

  /// v1.3.0: Worker de fotos de incidencias (desacoplado).
  /// Se llama con unawaited() tras el push de metadatos.
  /// Fix #13 (Sol): claim atómico, encolado antes de marcar synced,
  /// y reintentos con backoff en vez de 'error' permanente.
  Future<void> subirFotosIncidencias() async {
    final d = await _db.db;
    final pendientes = await d.query(
        'incidencias_fotos',
        where: "sync_estado IN ('pending', 'retry')",
        whereArgs: [],
        limit: 5);
    for (final f in pendientes) {
      final fid = '${f['id']}';
      // Claim atómico: solo si sigue en pending/retry.
      final reclamadas = await d.update(
          'incidencias_fotos',
          {
            'sync_estado': 'uploading',
            'intentos':
                ((f['intentos'] as num?)?.toInt() ?? 0) + 1,
          },
          where: "id = ? AND sync_estado IN ('pending', 'retry')",
          whereArgs: [fid]);
      if (reclamadas == 0) continue; // otro worker la tomó
      try {
        final incidenciaId =
            '${f['incidencia_id']}';
        final localPath =
            '${f['local_path']}';
        final storagePath =
            'incidencias/$incidenciaId/$fid.jpg';
        final file = File(localPath);
        if (!await file.exists()) {
          // Archivo perdido: marcar error definitivo.
          await d.update(
              'incidencias_fotos',
              {'sync_estado': 'error'},
              where: 'id = ?',
              whereArgs: [fid]);
          continue;
        }
        final bytes =
            await file.readAsBytes();
        final ok = await _subirFotoSimple(
            storagePath, bytes);
        if (ok) {
          // Fix #13: encolar metadatos ANTES de marcar synced,
          // todo en una transacción.
          await d.transaction((txn) async {
            await txn.insert('ops_queue', {
              'op_uuid': const Uuid().v4(),
              'tipo': 'registrar_foto_incidencia',
              'payload': jsonEncode({
                'id': fid,
                'incidencia_id': incidenciaId,
                'storage_path': storagePath,
                'tipo': '${f['tipo']}',
              }),
              'estado': 'pendiente',
              'creada_ts':
                  DateTime.now().toIso8601String(),
              'user_id': AuthService().userId,
              'telegram_id': AuthService().telegramId,
            });
            await txn.update(
                'incidencias_fotos', {
              'storage_path': storagePath,
              'sync_estado': 'synced',
            },
                where: 'id = ?',
                whereArgs: [fid]);
          });
          AppLog.info('sync',
              'foto_inc_ok', d: fid);
        } else {
          // Reintentable: volver a pending (con límite).
          final intentos =
              ((f['intentos'] as num?)?.toInt() ?? 0) + 1;
          await d.update(
              'incidencias_fotos',
              {
                'sync_estado':
                    intentos >= 5 ? 'error' : 'retry',
              },
              where: 'id = ?',
              whereArgs: [fid]);
          AppLog.error('sync',
              'foto_inc_http', d: 'fallo subida');
        }
      } catch (e) {
        // Terra #13: respetar límite de intentos también en catch.
        final intentosCatch =
            ((f['intentos'] as num?)?.toInt() ?? 0) + 1;
        await d.update(
            'incidencias_fotos',
            {
              'sync_estado':
                  intentosCatch >= 5 ? 'error' : 'retry',
            },
            where: 'id = ?',
            whereArgs: [fid]);
        AppLog.error(
            'sync', 'foto_inc_fallo', d: '$e');
      }
    }
  }

}

/// v1.2.9: excepción para errores TUS permanentes (Luna #1).
/// Se distingue de los reintentables para no hacer retry infinito.
class _TusPermanente implements Exception {
  final String message;
  _TusPermanente(this.message);
  @override
  String toString() => message;
}
