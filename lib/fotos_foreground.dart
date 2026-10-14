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
  final pendientes = await FotosColaService.instance.contarPendientes();
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
      final pendientes =
          await FotosColaService.instance.contarPendientes();
      if (pendientes == 0) {
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
