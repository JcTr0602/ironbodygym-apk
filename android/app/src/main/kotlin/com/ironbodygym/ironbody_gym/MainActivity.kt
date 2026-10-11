package com.ironbodygym.ironbody_gym

import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // v1.2.5-rev6: reloj monotónico para el bloqueo del PIN.
    // SystemClock.elapsedRealtime() no lo afecta cambiar la hora del
    // teléfono (solo se resetea al reiniciar; ese caso lo maneja Dart
    // con fallback al wall clock).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ironbody/seguridad"
        ).setMethodCallHandler { call, result ->
            if (call.method == "elapsedRealtime") {
                result.success(SystemClock.elapsedRealtime())
            } else {
                result.notImplemented()
            }
        }
    }
}
