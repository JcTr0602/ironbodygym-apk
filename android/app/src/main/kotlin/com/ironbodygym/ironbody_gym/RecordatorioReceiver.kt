package com.ironbodygym.ironbody_gym

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

// 23/25: receptor de alarmas de recordatorios. La alarma la programa
// MainActivity (canal ironbody/recordatorios) con AlarmManager; al
// disparar, este receptor muestra la notificación del sistema. Sin
// plugins nuevos: solo APIs del SDK de Android.
// El requestCode/id de la notificación derivan de id.hashCode()
// (String.hashCode de Java: determinista entre ejecuciones), así
// que programar y cancelar usan siempre el mismo código.
class RecordatorioReceiver : BroadcastReceiver() {
    companion object {
        const val CANAL_ID = "recordatorios"
        const val EXTRA_TITULO = "titulo"
        const val EXTRA_TEXTO = "texto"
        const val EXTRA_ID = "id"

        fun codigoDe(id: String): Int = id.hashCode()
    }

    override fun onReceive(context: Context, intent: Intent) {
        val titulo = intent.getStringExtra(EXTRA_TITULO) ?: "Recordatorio"
        val texto = intent.getStringExtra(EXTRA_TEXTO) ?: "Toca para ver tus avisos"
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val canal = NotificationChannel(
                CANAL_ID,
                "Recordatorios",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "Avisos de cumpleaños, vencimientos y recordatorios" }
            manager.createNotificationChannel(canal)
        }
        val abrir = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK }
        val pendiente = if (abrir != null) {
            PendingIntent.getActivity(
                context, codigoDe(id), abrir,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            null
        }
        val noti = NotificationCompat.Builder(context, CANAL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(titulo)
            .setContentText(texto)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(pendiente)
            .build()
        manager.notify(codigoDe(id), noti)
    }
}
