import 'dart:async';

import 'package:flutter/services.dart';

import 'auth.dart';
import 'localdb.dart';
import 'tiempo.dart';

/// 1.23 (sync en 2º plano, sello de Argón — fusión 1+4): el
/// aviso «quedaron operaciones sin subir».
///
/// SOLO se muestra cuando el Foreground Service aborta por su
/// cortacircuitos (ticks sin progreso en una red mala) quedando
/// pendientes RECLAMABLES del usuario actual. Nada de avisar
/// en cada pausa de la app (spam) ni por pendientes ajenos o
/// no reclamables (ceguera de canal).
///
/// Mecánica: el FGS corre en un isolate SIN canal de
/// notificaciones propio, así que al abortar deja una marca en
/// la meta `aviso_sync_pendientes` («<userId>|<n>|<iso>»). El
/// isolate de UI, al volver a primer plano, la consume y
/// programa la notificación por el canal nativo de
/// recordatorios con el canal de importancia BAJA y
/// onlyAlertOnce (no suena dos veces por lo mismo). Un push
/// posterior que deje la cola propia en cero la CANCELA.
///
/// Blindajes del delta del panel:
/// - La marca va LIGADA al usuario que la dejó: si quien abre
///   la app es otra cuenta del mismo teléfono, la marca se
///   limpia sin mostrar nada.
/// - Antes de programar se REVALIDA que sigan existiendo
///   pendientes propios: una marca vieja no avisa de una cola
///   que ya se vació.
/// - mostrarSiPendiente y cancelar corren SERIALIZADOS por
///   una misma cadena: una cancelación no puede quedar
///   pisada por una programación que ya había leído la marca.
class AvisoPendientesSync {
  static const _canal = MethodChannel('ironbody/recordatorios');
  static const _claveAviso = 'sync_pendientes_fgs';
  static const _metaMarca = 'aviso_sync_pendientes';

  /// Cadena de serialización de las operaciones del aviso.
  static Future<void> _cadena = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() op) {
    final resultado = _cadena.then((_) => op());
    _cadena = resultado.then<void>((_) {}, onError: (_) {});
    return resultado;
  }

  /// Lo invoca el FGS al abortar: deja la marca para la UI,
  /// ligada a la cuenta que tenía los pendientes.
  static Future<void> dejarMarca(int pendientesPropios,
      {required String? userId}) async {
    try {
      await LocalDb.instance.setMeta(
          _metaMarca,
          '${userId ?? ''}|$pendientesPropios|'
          '${ahoraUtcReal().toIso8601String()}');
    } catch (_) {}
  }

  /// Lo invoca la UI al volver a primer plano: si hay marca
  /// DEL USUARIO ACTUAL y la cola propia sigue con pendientes,
  /// programa la notificación (importancia baja, una sola
  /// alerta) para dentro de un minuto. En cualquier otro caso
  /// limpia la marca en silencio.
  static Future<void> mostrarSiPendiente() {
    return _serial(() async {
      try {
        final marca = await LocalDb.instance.getMeta(_metaMarca);
        if (marca == null || marca.isEmpty) return;
        final partes = marca.split('|');
        final duenoMarca = partes.length >= 3 ? partes[0] : '';
        final n = partes.length >= 3
            ? (int.tryParse(partes[1]) ?? 0)
            : (int.tryParse(partes.first) ?? 0);
        // La marca se consume siempre: mostrarla o descartarla.
        await LocalDb.instance.setMeta(_metaMarca, '');
        String? uid;
        try {
          uid = AuthService().userId;
        } catch (_) {}
        if (uid == null || uid.isEmpty || duenoMarca != uid) {
          // Sin sesión o la marca es de OTRA cuenta: no se
          // muestra nada (y ya quedó limpia).
          return;
        }
        // Revalidación: ¿siguen existiendo pendientes propios?
        final conteo =
            await LocalDb.instance.conteoPendientesSync(uid);
        final propios = conteo.porSubir + conteo.conError;
        if (propios <= 0) return;
        final destino =
            ahoraUtcReal().add(const Duration(minutes: 1));
        await _canal.invokeMethod('programar', {
          'id': _claveAviso,
          'titulo': 'Sincronización pendiente',
          'texto': 'Quedaron ${n > 0 ? n : propios} operación(es) '
              'sin subir por falta de conexión. Abre la app con '
              'internet y se envían solas.',
          'epochMillis': destino.millisecondsSinceEpoch,
          'baja': true,
        });
      } catch (_) {
        // Sin canal en este isolate o sin permiso: silencio.
      }
    });
  }

  /// Un push limpio (cola propia en cero) cancela el aviso si
  /// estaba programado y limpia cualquier marca sin consumir.
  /// Serializado con mostrarSiPendiente: el orden de llegada
  /// manda, nunca se pisan.
  static Future<void> cancelar() {
    return _serial(() async {
      try {
        await LocalDb.instance.setMeta(_metaMarca, '');
      } catch (_) {}
      try {
        await _canal.invokeMethod('cancelar', {'id': _claveAviso});
      } catch (_) {}
    });
  }
}
