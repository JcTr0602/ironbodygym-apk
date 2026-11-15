/// Foreground Service de sincronización en segundo plano.
///
/// v1.2.8 (Paso 5): nació para la subida de fotos.
/// 1.23: se ENCIENDE por fin y drena la tubería COMPLETA con
/// los sellos de Argón (veredicto en cola-123):
/// - El arranque vive en SyncEngine.push() (gancho
///   onArrancarSegundoPlano que registra main.dart), al inicio
///   y antes del candado — nunca en la capa de BD.
/// - Este isolate corre SyncEngine.push(desdeForeground: true,
///   esperarIncidencias: true): ops → fotos → comprobantes →
///   2º uploadOps → fotos de incidencias, todo esperado.
/// - CORTACIRCUITOS: la cola de ops no tiene backoff por op;
///   sin progreso en 3 ticks seguidos, el servicio se detiene
///   (no quema el presupuesto dataSync con el WakeLock puesto)
///   y deja la marca del aviso de pendientes para la UI.
/// - Bandera síncrona de arranque: isRunningService es async
///   y dejaba pasar ráfagas de push() solapados.
///
/// API: flutter_foreground_task v8. El handler NO accede a
/// memoria del isolate principal: inicializa su propio
/// Supabase (la sesión persiste en el almacenamiento de la
/// app, compartido entre isolates).

library;

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth.dart';
import 'aviso_pendientes.dart';
import 'config.dart';
import 'fotos_cola.dart';
import 'localdb.dart';
import 'sync.dart';

/// Debe llamarse una vez al arrancar la app.
void initForegroundFotos() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'fotos_upload',
      channelName: 'Subida de fotos',
      channelDescription: 'Subiendo fotos de clientes y suplementos',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

bool _arrancandoFgs = false;
DateTime? _ultimoIntentoArranqueFgs;

/// Arranca el servicio si hay trabajo reclamable (ops por
/// subir o fotos reclamables). Sellos:
/// - Bandera SÍNCRONA: dos push() en ráfaga no duplican el
///   intento (isRunningService es async y llegaba tarde).
/// - Debounce de 400 ms entre intentos.
/// - SOLO en primer plano (resumed): Android 14+ prohíbe
///   arrancar un FGS desde fondo; en los isolates de fondo el
///   lifecycle es null y el arranque se salta solo.
Future<void> iniciarSubidaFotosForeground() async {
  if (_arrancandoFgs) return;
  _arrancandoFgs = true;
  try {
    final ahora = DateTime.now();
    final ultimo = _ultimoIntentoArranqueFgs;
    if (ultimo != null &&
        ahora.difference(ultimo) <
            const Duration(milliseconds: 400)) {
      return;
    }
    _ultimoIntentoArranqueFgs = ahora;
    if (WidgetsBinding.instance.lifecycleState !=
        AppLifecycleState.resumed) {
      return;
    }
    if (await FlutterForegroundTask.isRunningService) return;
    // Argón #8-7 (vigente): contar solo RECLAMABLES o el
    // servicio arrancaba para detenerse al primer tick cuando
    // solo quedaba una 'original' diferida por QoS. 1.23: las
    // ops también son motivo de arranque (el servicio drena
    // la tubería completa, no solo fotos) — y solo las del
    // USUARIO ACTUAL (delta del panel: countPendingOps cuenta
    // también las de otro usuario del mismo teléfono, que este
    // isolate no puede subir, y arrancar por ellas era ruido).
    final fotosReclamables =
        await FotosColaService.instance.contarPendientesReclamables();
    String? uid;
    try {
      uid = AuthService().userId;
    } catch (_) {}
    final conteo =
        await LocalDb.instance.conteoPendientesSync(uid);
    final ops = conteo.porSubir + conteo.conError;
    // Auditoría Definitiva (B-12): el servicio drena la
    // tubería COMPLETA (cabecera de este archivo) pero
    // arrancaba contando solo fotos y ops: con solo
    // comprobantes o fotos de incidencias por subir, nunca
    // arrancaba. Esas dos cuentas también son motivo de
    // arranque (y de parada/progreso en el tick).
    final comprobantesSinSubir =
        await LocalDb.instance.contarComprobantesSinSubir();
    final fotosIncSinSubir = await LocalDb.instance
        .contarFotosIncidenciasPendientes();
    if (fotosReclamables == 0 &&
        ops == 0 &&
        comprobantesSinSubir == 0 &&
        fotosIncSinSubir == 0) {
      return;
    }
    await FlutterForegroundTask.startService(
      notificationTitle: 'Sincronizando Iron Body',
      notificationText: 'Subiendo cambios pendientes…',
      callback: _foregroundCallback,
    );
  } catch (_) {
    // El FGS es una ayuda: si el arranque falla (permiso,
    // fabricante), la sync normal de la app sigue intacta.
  } finally {
    _arrancandoFgs = false;
  }
}

/// Detiene el servicio si corre (lo usa la importación de
/// respaldo: el FGS tiene la MISMA base abierta en su isolate
/// y no puede quedar vivo mientras el archivo se reemplaza).
Future<void> detenerSubidaFotosForeground() async {
  try {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  } catch (_) {}
}

/// Estado REAL de la exención de batería del paquete (la
/// exención es por PAQUETE, no por usuario).
///
/// 1.24.2 (auditoría sync M3-H01/M5-A2): hasta hoy un error al
/// comprobar se disfrazaba de `false` y la app afirmaba «sin
/// exención» sin saberlo. El tercer estado lo separa.
enum EstadoExencionBateria { activa, inactiva, desconocida }

Future<EstadoExencionBateria> estadoExencionBateria() async {
  try {
    final v =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    return v
        ? EstadoExencionBateria.activa
        : EstadoExencionBateria.inactiva;
  } catch (_) {
    return EstadoExencionBateria.desconocida;
  }
}

/// ¿El paquete ya está exento? Solo `true` si se COMPROBÓ.
Future<bool> exencionBateriaActiva() async =>
    await estadoExencionBateria() == EstadoExencionBateria.activa;

/// Resultado de pedir la exención (para que la UI pueda decir
/// qué pasó en vez de callar).
enum ResultadoPedirExencion { yaActiva, pedida, error }

/// Pide la exención de batería y deja la meta local
/// `bateria_exencion_pedida` (sello de Argón: se verifica el
/// estado nativo y se recuerda que ya se pidió, para no
/// repetir el diálogo). NO se llama tras el login: el diálogo
/// del sistema pone la app en pausa y cortaría el arranque;
/// la pide el dueño desde Ajustes, a mano.
///
/// 1.24.2: devuelve el resultado — antes tragaba todo error
/// en un catch vacío y el botón parecía muerto (y faltaba el
/// permiso en el manifiesto, sin el cual el diálogo ni abre).
Future<ResultadoPedirExencion> solicitarExencionBateria() async {
  try {
    await LocalDb.instance.setMeta('bateria_exencion_pedida', '1');
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      return ResultadoPedirExencion.yaActiva;
    }
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    return ResultadoPedirExencion.pedida;
  } catch (_) {
    return ResultadoPedirExencion.error;
  }
}

@pragma('vm:entry-point')
void _foregroundCallback() {
  FlutterForegroundTask.setTaskHandler(_SyncTaskHandler());
}

/// Qué hace el FGS tras un tick de drenado (PURO, testeable).
enum DecisionTickFgs {
  /// Hubo progreso y queda trabajo: seguir, actualizando la
  /// notificación.
  seguir,

  /// No queda trabajo reclamable: detenerse, misión cumplida.
  detenerTerminado,

  /// Sin progreso pero aún bajo el límite del cortacircuitos:
  /// seguir esperando al siguiente tick.
  contarSinProgreso,

  /// Sin progreso hasta el límite: detenerse por
  /// cortacircuitos (y avisar si quedan pendientes propios).
  detenerCortacircuitos,
}

/// La regla del cortacircuitos: [progreso] = ops aplicadas +
/// fotos reclamables que bajaron en el tick; [quedan] = sigue
/// habiendo trabajo reclamable; [ticksSinProgreso] = ticks
/// seguidos sin progreso ANTES de este.
DecisionTickFgs decisionTickFgs({
  required int progreso,
  required bool quedan,
  required int ticksSinProgreso,
  int maxTicksSinProgreso = 3,
}) {
  if (!quedan) return DecisionTickFgs.detenerTerminado;
  if (progreso > 0) return DecisionTickFgs.seguir;
  if (ticksSinProgreso + 1 >= maxTicksSinProgreso) {
    return DecisionTickFgs.detenerCortacircuitos;
  }
  return DecisionTickFgs.contarSinProgreso;
}

class _SyncTaskHandler extends TaskHandler {
  /// Reentrancia: onRepeatEvent se dispara cada 5 s; un drenado
  /// puede tardar mucho más y no deben solaparse dos corridas.
  bool _procesando = false;

  /// Cortacircuitos: ticks seguidos sin subir ninguna op ni
  /// foto. A los 3, el servicio se rinde (la red no da más) en
  /// vez de girar con WakeLock hasta agotar el presupuesto.
  int _ticksSinProgreso = 0;
  static const _maxTicksSinProgreso = 3;

  /// C-6: ticks seguidos en que push() no corrió por falta de
  /// sesión. Al llegar al mismo límite del cortacircuitos, el
  /// servicio se detiene: sin sesión no hay cura esperando.
  int _ticksSinSesion = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 1.35 (campo 1.34 nº 7): este isolate es de FONDO y no
    // es dueño del refresco — el pipeline de sesión
    // (AuthService) solo constatará la sesión persistida y
    // diferirá sin rotar jamás el token compartido.
    AuthService.esIsolateDeFondo = true;
    WidgetsFlutterBinding.ensureInitialized();
    try {
      // 1.32 (O2F2S, AP-5 — residual del Foreground
      // Service): MISMA forma que el isolate de
      // WorkManager (main.dart). Este isolate inicializaba
      // Supabase con las opciones por defecto
      // (autoRefreshToken: true): al recuperar la sesión
      // persistida podía refrescar y ROTAR el refresh
      // token compartido, dejando al isolate principal con
      // el token viejo en memoria — fuera del intervalo de
      // reutilización, el servidor revoca la familia
      // entera y mueren todas las sesiones (AP-5,
      // verificado contra gotrue 2.27.2).
      // - Con la sesión persistida caducada (o a ≤120 s)
      //   NO se inicializa ni se refresca: los ticks verán
      //   «sin sesión» y el cortacircuitos C-6 detiene el
      //   servicio; el refresco queda para el primer
      //   plano, dueño del token.
      // - Con sesión vigente, se inicializa SIN
      //   auto-refresco y se adopta la sesión tal cual.
      if (await sesionPersistidaCaducadaParaFondo()) return;
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.anonKey,
        authOptions:
            const FlutterAuthClientOptions(autoRefreshToken: false),
      );
    } catch (_) {
      // Si ya estaba inicializado, continuar.
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // v8: onRepeatEvent es void, delegamos al async.
    _procesar();
  }

  Future<void> _procesar() async {
    if (_procesando) return;
    _procesando = true;
    try {
      // Barrera de mantenimiento (importación de respaldo):
      // este isolate no toca la base mientras se reemplaza.
      if (await LocalDb.instance.mantenimientoActivo()) {
        await FlutterForegroundTask.stopService();
        return;
      }
      // Auditoría Definitiva (B-11): el progreso de fotos se
      // mide por el delta de COMPLETADAS, no de reclamables —
      // una foto que entra en backoff deja de ser reclamable
      // sin haber subido y «progresaba» en falso, reiniciando
      // el cortacircuitos con la red caída. (B-12): los
      // comprobantes y las fotos de incidencias cuentan para
      // progreso y para la parada, como en el arranque.
      final completadasAntes =
          await FotosColaService.instance.contarCompletadas();
      final comprobantesAntes =
          await LocalDb.instance.contarComprobantesSinSubir();
      final fotosIncAntes = await LocalDb.instance
          .contarFotosIncidenciasPendientes();
      SyncResultado? res;
      Object? fallo;
      try {
        res = await SyncEngine.instance.push(
            desdeForeground: true, esperarIncidencias: true);
      } catch (e) {
        // push() propaga el fallo de red: cuenta como un tick
        // sin progreso para el cortacircuitos.
        fallo = e;
      }
      // Delta del panel: un push que NO CORRIÓ (otro isolate
      // tiene el candado, no hay sesión o hay mantenimiento)
      // NO es un fallo de red: este tick no cuenta para el
      // cortacircuitos, no detiene el servicio y no deja
      // aviso. Se espera al siguiente tick.
      if (res != null && !res.corrio) {
        // Auditoría Definitiva (C-6): la excepción es la falta
        // de sesión PERSISTENTE — ese estado no se cura
        // esperando (nadie va a entrar desde el isolate de
        // fondo) y el servicio seguiría despertando cada 5 s
        // para siempre. Tras los mismos ticks del
        // cortacircuitos seguidos sin sesión, se detiene; el
        // próximo arranque en primer plano lo relanza si hay
        // sesión y trabajo.
        if (res.motivoNoCorrio == SyncMotivoNoCorrio.sinSesion) {
          _ticksSinSesion++;
          if (_ticksSinSesion >= _maxTicksSinProgreso) {
            await FlutterForegroundTask.stopService();
          }
        } else {
          _ticksSinSesion = 0;
        }
        return;
      }
      _ticksSinSesion = 0;
      final reclamablesDespues = await FotosColaService.instance
          .contarPendientesReclamables();
      final completadasDespues =
          await FotosColaService.instance.contarCompletadas();
      final comprobantesDespues =
          await LocalDb.instance.contarComprobantesSinSubir();
      final fotosIncDespues = await LocalDb.instance
          .contarFotosIncidenciasPendientes();
      // Deltas con suelo en 0: la limpieza de huérfanos puede
      // BORRAR filas completadas entre las dos lecturas, y ese
      // descenso no es progreso negativo ni positivo.
      int delta(int antes, int despues, {bool invertido = false}) {
        final d = invertido ? antes - despues : despues - antes;
        return d > 0 ? d : 0;
      }

      final fotosSubidas =
          delta(completadasAntes, completadasDespues);
      final progreso = (res?.subidos ?? 0) +
          fotosSubidas +
          delta(comprobantesAntes, comprobantesDespues,
              invertido: true) +
          delta(fotosIncAntes, fotosIncDespues, invertido: true);
      final quedanReclamables = reclamablesDespues > 0 ||
          comprobantesDespues > 0 ||
          fotosIncDespues > 0 ||
          (res != null && (res.porSubir > 0 || res.conError > 0));
      final decision = decisionTickFgs(
        progreso: progreso,
        // Si push() lanzó, el estado de las ops se desconoce:
        // se asume que queda trabajo y manda el cortacircuitos,
        // no una parada inmediata disfrazada de «terminado».
        quedan: res == null || quedanReclamables,
        ticksSinProgreso: _ticksSinProgreso,
        maxTicksSinProgreso: _maxTicksSinProgreso,
      );
      switch (decision) {
        case DecisionTickFgs.detenerTerminado:
          await FlutterForegroundTask.stopService();
        case DecisionTickFgs.seguir:
          _ticksSinProgreso = 0;
          await FlutterForegroundTask.updateService(
            notificationTitle: 'Sincronizando Iron Body',
            notificationText: reclamablesDespues > 0
                ? 'Quedan $reclamablesDespues fotos y cambios…'
                : 'Subiendo cambios pendientes…',
          );
        case DecisionTickFgs.contarSinProgreso:
          _ticksSinProgreso++;
        case DecisionTickFgs.detenerCortacircuitos:
          // Sello de Argón: SOLO aquí — cortacircuitos con
          // pendientes PROPIOS reclamables — nace el aviso. El
          // FGS no tiene canal de notificaciones: deja la marca
          // y la UI la muestra al volver a primer plano.
          final propios = (res?.porSubir ?? 0) + (res?.conError ?? 0);
          if (propios > 0) {
            String? uidAviso;
            try {
              uidAviso = AuthService().userId;
            } catch (_) {}
            await AvisoPendientesSync.dejarMarca(propios,
                userId: uidAviso);
          }
          if (fallo != null) {
            debugPrint(
                '[Foreground] cortacircuitos tras fallo: $fallo');
          }
          await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('[Foreground] error: $e');
    } finally {
      _procesando = false;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {}
}
