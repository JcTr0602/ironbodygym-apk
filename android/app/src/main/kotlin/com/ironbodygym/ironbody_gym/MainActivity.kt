package com.ironbodygym.ironbody_gym

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
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
        // 23/25: alarmas de recordatorios (sin plugins nuevos).
        // programar: agenda una alarma exacta si el sistema lo
        // permite (SCHEDULE_EXACT_ALARM), si no una inexacta.
        // cancelar: anula la alarma con el mismo id. El código del
        // PendingIntent deriva de id.hashCode() (igual que el
        // receptor), así programar/cancelar siempre coinciden.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ironbody/recordatorios"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "programar" -> {
                    val id = call.argument<String>("id") ?: ""
                    val titulo = call.argument<String>("titulo") ?: "Recordatorio"
                    val texto = call.argument<String>("texto") ?: ""
                    val epoch = call.argument<Number>("epochMillis")?.toLong()
                        ?: System.currentTimeMillis()
                    val intento = Intent(this, RecordatorioReceiver::class.java).apply {
                        // Panel Terra A3: identidad única por clave.
                        // Sin data, dos claves con el mismo hashCode
                        // colisionarían en el mismo PendingIntent.
                        data = Uri.parse("ironbody://recordatorios/${Uri.encode(id)}")
                        putExtra(RecordatorioReceiver.EXTRA_ID, id)
                        putExtra(RecordatorioReceiver.EXTRA_TITULO, titulo)
                        putExtra(RecordatorioReceiver.EXTRA_TEXTO, texto)
                    }
                    val pendiente = PendingIntent.getBroadcast(
                        this, RecordatorioReceiver.codigoDe(id), intento,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    val alarmas =
                        getSystemService(Context.ALARM_SERVICE) as AlarmManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        alarmas.canScheduleExactAlarms()
                    ) {
                        alarmas.setExactAndAllowWhileIdle(
                            AlarmManager.RTC_WAKEUP, epoch, pendiente
                        )
                    } else {
                        alarmas.setAndAllowWhileIdle(
                            AlarmManager.RTC_WAKEUP, epoch, pendiente
                        )
                    }
                    result.success(null)
                }
                "cancelar" -> {
                    val id = call.argument<String>("id") ?: ""
                    // La misma data que en "programar": sin ella el
                    // FLAG_NO_CREATE no encuentra el PendingIntent.
                    val intento = Intent(this, RecordatorioReceiver::class.java).apply {
                        data = Uri.parse("ironbody://recordatorios/${Uri.encode(id)}")
                    }
                    val pendiente = PendingIntent.getBroadcast(
                        this, RecordatorioReceiver.codigoDe(id), intento,
                        PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
                    )
                    if (pendiente != null) {
                        val alarmas =
                            getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        alarmas.cancel(pendiente)
                    }
                    // Panel Terra A4: cancelar también borra la
                    // notificación ya mostrada, no solo la alarma.
                    val manager =
                        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    manager.cancel(RecordatorioReceiver.codigoDe(id))
                    result.success(null)
                }
                "tienePermisoNotificacion" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        result.success(true)
                    } else {
                        result.success(
                            checkSelfPermission(
                                android.Manifest.permission.POST_NOTIFICATIONS
                            ) == PackageManager.PERMISSION_GRANTED
                        )
                    }
                }
                "pedirPermisoNotificacion" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        requestPermissions(
                            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                            9101
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
