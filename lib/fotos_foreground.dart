/// v1.2.8 (Paso 5): Foreground Service para subida de fotos.
/// Correcciones Gemini aplicadas:
/// - Inicializar Supabase dentro del isolate (onStart), no usar el del main.
/// - El handler NO accede a memoria del isolate principal.
/// API: flutter_foreground_task v8.

library;

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'fotos_cola.dart';

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

/// Inicia el servicio si hay fotos en cola.
Future<void> iniciarSubidaFotosForeground() async {
  if (await FlutterForegroundTask.isRunningService) return;
  // Argón #8-7: contar solo reclamables o el servicio arrancaba
  // para detenerse al primer tick cuando solo quedaba una
  // 'original' diferida por QoS.
  final pendientes =
      await FotosColaService.instance.contarPendientesReclamables();
  if (pendientes == 0) return;
  await FlutterForegroundTask.startService(
    notificationTitle: 'Subiendo fotos',
    notificationText: 'Quedan $pendientes fotos...',
    callback: _foregroundCallback,
  );
}

@pragma('vm:entry-point')
void _foregroundCallback() {
  FlutterForegroundTask.setTaskHandler(_FotosTaskHandler());
}

class _FotosTaskHandler extends TaskHandler {
  /// Corrección Gemini ronda 2: flag de reentrancia. onRepeatEvent se
  /// dispara cada 5s; si una subida tarda 15s, habría 3 llamadas
  /// concurrentes saturando hilos y conexiones HTTP.
  bool _procesando = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Corrección Gemini ronda 2: usar Config centralizado, no
    // String.fromEnvironment (puede evaluar a vacío sin --dart-define).
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.anonKey,
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
      await FotosColaService.instance.procesarCola();
      // v1.3.4 (veredicto de Argón, Bug A1.4): la decisión de detener
      // usa pendientes RECLAMABLES. Si solo quedan variantes 'original'
      // diferidas por QoS (no reclamables ahora), el servicio se detiene
      // en vez de mantenerse vivo con WakeLock cada 5 s sin trabajo
      // real. El 'original' diferido se reclama en un ciclo posterior
      // (próximo encolado o push periódico del isolate de UI).
      final pendientes =
          await FotosColaService.instance.contarPendientes();
      final reclamables =
          await FotosColaService.instance.contarPendientesReclamables();
      if (reclamables == 0) {
        await FlutterForegroundTask.stopService();
      } else {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Subiendo fotos',
          notificationText: 'Quedan $pendientes fotos...',
        );
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
