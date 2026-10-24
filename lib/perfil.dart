/// Perfil del entrenador en el teléfono (Ajustes): avatar, móvil, carnet
/// y preferencias. Se guarda localmente con SharedPreferences; el avatar
/// como archivo en el almacenamiento de la app.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'localdb.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth.dart';

class PerfilService {
  PerfilService._();
  static final PerfilService instance = PerfilService._();

  Future<SharedPreferences> get _p async =>
      SharedPreferences.getInstance();

  String _key(String base) {
    // v1.2.2: guardar por usuario, no por teléfono (Hark #4).
    // Si otro entrenador inicia sesión en el mismo móvil, no ve los datos del anterior.
    final username = AuthService().username;
    return username.isEmpty ? base : '${base}_$username';
  }

  Future<String?> getMovil() async =>
      (await _p).getString(_key('perfil_movil'));
  Future<void> setMovil(String v) async {
    await (await _p).setString(_key('perfil_movil'), v);
    // v1.2.2: sincronizar a Supabase (sobrevive reinstalación)
    _syncPerfilToSupabase();
  }

  Future<String?> getCarnet() async =>
      (await _p).getString(_key('perfil_carnet'));
  Future<void> setCarnet(String v) async {
    await (await _p).setString(_key('perfil_carnet'), v);
    // v1.2.2: sincronizar a Supabase (sobrevive reinstalación)
    _syncPerfilToSupabase();
  }

  /// v1.2.2: sube móvil/carnet a Supabase (tabla sync_usuarios_perfil).
  /// No bloquea si no hay conexión; se reintenta en el próximo cambio.
  Future<bool> _syncPerfilToSupabase() async {
    final p0 = await _p;
    // v1.2.4 (Hark): marca pendiente; se borra solo si la subida funciona.
    // SyncEngine.run() reintenta con [sincronizarSiPendiente].
    await p0.setBool(_key('perfil_sucio'), true);
    try {
      final username = AuthService().username;
      if (username.isEmpty) return false;
      final p = await _p;
      final movil = p.getString(_key('perfil_movil'));
      final carnet = p.getString(_key('perfil_carnet'));
      await Supabase.instance.client.from('sync_usuarios_perfil').upsert({
        'username': usernameToEmail(username).split('@').first,
        'movil': movil,
        'carnet': carnet,
        // NOTA: updated_at lo pone el trigger en Supabase, no el teléfono
      }, onConflict: 'username');
      await p.setBool(_key('perfil_sucio'), false);
      return true;
    } catch (_) {
      // Sin conexión o error: se reintenta en la próxima sincronización
      return false;
    }
  }

  /// v1.2.4: reintenta subir el perfil si quedó pendiente (sin conexión).
  Future<void> sincronizarSiPendiente() async {
    final p = await _p;
    if (p.getBool(_key('perfil_sucio')) ?? false) {
      await _syncPerfilToSupabase();
    }
  }

  /// v1.2.2: descarga el perfil desde Supabase si lo local está vacío.
  /// Llamar al iniciar sesión.
  Future<void> descargarPerfilSiVacio() async {
    try {
      final p = await _p;
      final movilLocal = p.getString(_key('perfil_movil'));
      final carnetLocal = p.getString(_key('perfil_carnet'));
      // v1.2.4: se rellena campo por campo; nunca se pisa un dato local.
      final faltaMovil = movilLocal == null || movilLocal.isEmpty;
      final faltaCarnet = carnetLocal == null || carnetLocal.isEmpty;
      if (!faltaMovil && !faltaCarnet) return;
      final username = AuthService().username;
      if (username.isEmpty) return;
      final emailPrefix = usernameToEmail(username).split('@').first;
      final res = await Supabase.instance.client
          .from('sync_usuarios_perfil')
          .select('movil, carnet')
          .eq('username', emailPrefix)
          .maybeSingle();
      if (res != null) {
        if (faltaMovil && res['movil'] != null) {
          await p.setString(_key('perfil_movil'), res['movil'] as String);
        }
        if (faltaCarnet && res['carnet'] != null) {
          await p.setString(_key('perfil_carnet'), res['carnet'] as String);
        }
      }
    } catch (_) {
      // Sin conexión: se queda con lo local (vacío)
    }
  }

  /// ¿Avisar si lleva +8h sin subir cambios? (punto 10)
  Future<bool> getRecordatorioSync() async =>
      (await _p).getBool('pref_recordatorio_sync') ?? true;
  Future<void> setRecordatorioSync(bool v) async =>
      (await _p).setBool('pref_recordatorio_sync', v);

  // -- seguridad del perfil (v1.0.12) ------------------------------------

  /// ¿Vincular este usuario a este dispositivo?
  Future<bool> getVincularDispositivo() async =>
      (await _p).getBool('seg_vincular_dispositivo') ?? false;
  Future<void> setVincularDispositivo(bool v) async =>
      (await _p).setBool('seg_vincular_dispositivo', v);

  /// ID único de este dispositivo (se genera una vez).
  Future<String> getDeviceId() async {
    final p = await _p;
    var id = p.getString('seg_device_id');
    if (id == null || id.isEmpty) {
      id = DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
          (1000 + (DateTime.now().microsecond % 9000)).toString();
      await p.setString('seg_device_id', id);
    }
    return id;
  }

  /// Dispositivo vinculado al usuario actual (username -> device_id).
  Future<String?> getDispositivoVinculado(String username) async =>
      (await _p).getString('seg_vinculado_$username');
  Future<void> setDispositivoVinculado(
          String username, String deviceId) async =>
      (await _p).setString('seg_vinculado_$username', deviceId);
  Future<void> clearDispositivoVinculado(String username) async =>
      (await _p).remove('seg_vinculado_$username');


  /// Hash del PIN rápido (4 dígitos). Null = sin PIN.
  ///
  /// v1.0.16: esquema endurecido. Formato `v2$<salt_hex>$<hash_hex>` donde
  /// hash = 10000 iteraciones de SHA-256(salt + pin + anterior).
  /// El esquema viejo (`v1`, sha256('ironbody-pin-$pin') sin salt) se
  /// reconoce por no tener el prefijo `v2$`; al configurar un PIN nuevo
  /// siempre se usa el esquema nuevo.
  Future<String?> getPinHash() async =>
      (await _p).getString(_key('seg_pin_hash'));
  Future<void> setPinHash(String? h) async {
    final p = await _p;
    if (h == null) {
      await p.remove(_key('seg_pin_hash'));
    } else {
      await p.setString(_key('seg_pin_hash'), h);
    }
  }

  /// Salt aleatorio de 16 bytes (hex) para el PIN. Se genera una vez
  /// por instalación y se reutiliza.
  Future<String> getPinSalt() async {
    final p = await _p;
    var salt = p.getString(_key('seg_pin_salt'));
    if (salt == null || salt.isEmpty) {
      final rnd = Random.secure();
      final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
      salt = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await p.setString(_key('seg_pin_salt'), salt);
    }
    return salt;
  }

  /// Intentos fallidos consecutivos del PIN.
  Future<int> getPinFallos() async =>
      (await _p).getInt(_key('seg_pin_fallos')) ?? 0;
  Future<void> _setPinFallos(int n) async =>
      (await _p).setInt(_key('seg_pin_fallos'), n);

  /// Timestamp (ms) hasta el que el PIN está bloqueado. 0 = no bloqueado.
  Future<int> getPinBloqueadoHasta() async =>
      (await _p).getInt(_key('seg_pin_bloqueado_hasta')) ?? 0;

  /// Verifica un PIN contra el hash guardado.
  ///
  /// v1.2.5 (4.1): límite persistente con esperas CRECIENTES que sobreviven
  /// reinicios. 5 fallos → bloqueo de 1 min; si vuelve a fallar 5 veces,
  /// 5 min; luego 15, 30, 60. El contador de "ciclos de bloqueo" persiste.
  /// v1.2.5-rev6 (Gemini #4): el bloqueo usa reloj monotónico PERSISTENTE
  /// (elapsedRealtime de Android vía canal nativo: no lo afecta cambiar la
  /// hora del teléfono y sobrevive reinicios de la app). Si el reloj se
  /// adelanta para eludir el bloqueo, el tiempo real transcurrido manda y
  /// se reancla el deadline. Riesgo residual documentado: reiniciar el
  /// teléfono resetea elapsedRealtime; en ese caso se usa el wall clock
  /// como fallback (un atacante tendría que reiniciar Y adelantar el reloj).
  static const _canalSeg = MethodChannel('ironbody/seguridad');
  static final Stopwatch _monoFallback = Stopwatch()..start();

  /// Milisegundos monotónicos (inmunes a cambios del reloj del sistema).
  /// En Android: SystemClock.elapsedRealtime(); fallback: Stopwatch.
  static Future<int> _monoAhora() async {
    try {
      final v = await _canalSeg.invokeMethod<int>('elapsedRealtime');
      if (v != null && v >= 0) return v;
    } catch (_) {}
    return _monoFallback.elapsedMilliseconds;
  }

  /// Limpia todo el estado de bloqueo (expiró o se reinició).
  Future<void> _limpiarBloqueoPin(SharedPreferences p) async {
    // v1.3.2 (Argón #19): claves por usuario.
    await p.setInt(_key('seg_pin_bloqueado_hasta'), 0);
    await p.setInt(_key('seg_pin_duracion_ms'), 0);
    await p.setInt(_key('seg_pin_mono_ancla'), 0);
  }

  Future<bool> verificarPin(String pin) async {
    final p = await _p;
    final ahora = DateTime.now().millisecondsSinceEpoch;
    final hasta = p.getInt(_key('seg_pin_bloqueado_hasta')) ?? 0;
    // v1.2.5 (4.1): si el reloj retrocedió (ahora < última vez visto),
    // mantener el bloqueo por seguridad.
    final ultimaVez = p.getInt(_key('seg_pin_ultima_vez')) ?? 0;
    if (ahora < ultimaVez - 60000 && hasta > 0) {
      // Retroceso >1 min con bloqueo activo: no acortar.
      return false;
    }
    await p.setInt(_key('seg_pin_ultima_vez'), ahora);
    if (hasta > 0) {
      // Hay bloqueo activo: decidir con el reloj monotónico.
      final durMs = p.getInt(_key('seg_pin_duracion_ms')) ?? 0;
      final ancla = p.getInt(_key('seg_pin_mono_ancla')) ?? 0;
      final mono = await _monoAhora();
      if (durMs > 0 && ancla > 0) {
        final transcurrido = mono - ancla;
        if (transcurrido >= durMs) {
          await _limpiarBloqueoPin(p); // expiró en tiempo real
        } else if (transcurrido < 0) {
          // elapsedRealtime se reseteó (reinicio del teléfono):
          // fallback al wall clock.
          if (ahora < hasta) return false;
          await _limpiarBloqueoPin(p);
        } else {
          // Aún no expira en tiempo real aunque el wall clock diga lo
          // contrario (adelanto detectado): reanclar el deadline.
          final restante = durMs - transcurrido;
          await p.setInt(
              _key('seg_pin_bloqueado_hasta'), ahora + restante);
          return false;
        }
      } else {
        // Sin ancla monotónica (bloqueo viejo): wall clock + retroceso.
        if (ahora < hasta) return false;
        await _limpiarBloqueoPin(p);
      }
    }
    final guardado = await getPinHash();
    if (guardado == null || guardado.isEmpty) return false;
    final ok = _pinCoincide(pin, guardado, await getPinSalt());
    if (ok) {
      await _setPinFallos(0);
      return true;
    }
    final fallos = await getPinFallos() + 1;
    await _setPinFallos(fallos);
    if (fallos >= 5) {
      // Esperas crecientes: 1, 5, 15, 30, 60 min según ciclos previos.
      final ciclos = p.getInt(_key('seg_pin_ciclos_bloqueo')) ?? 0;
      const minutos = [1, 5, 15, 30, 60];
      final minBloqueo = minutos[ciclos.clamp(0, minutos.length - 1)];
      final durMs = minBloqueo * 60 * 1000;
      await p.setInt(_key('seg_pin_bloqueado_hasta'), ahora + durMs);
      // v1.2.5-rev6: ancla monotónica persistente (sobrevive reinicios).
      await p.setInt(_key('seg_pin_duracion_ms'), durMs);
      await p.setInt(_key('seg_pin_mono_ancla'), await _monoAhora());
      await p.setInt(_key('seg_pin_ciclos_bloqueo'), ciclos + 1);
      await _setPinFallos(0);
    }
    return false;
  }

  /// Reinicia los ciclos de bloqueo (al cambiar el PIN o "Olvidé mi PIN").
  Future<void> reiniciarBloqueoPin() async {
    final p = await _p;
    await p.setInt(_key('seg_pin_fallos'), 0);
    await p.setInt(_key('seg_pin_ciclos_bloqueo'), 0);
    await _limpiarBloqueoPin(p); // v1.2.5-rev6: también el ancla monotónica
  }

  /// Minutos restantes de bloqueo del PIN (0 si no está bloqueado).
  /// v1.2.5-rev6: usa el reloj monotónico si hay ancla (inmune a adelantos).
  Future<int> pinBloqueoMinutosRestantes() async {
    final p = await _p;
    final hasta = p.getInt(_key('seg_pin_bloqueado_hasta')) ?? 0;
    if (hasta <= 0) return 0;
    final durMs = p.getInt(_key('seg_pin_duracion_ms')) ?? 0;
    final ancla = p.getInt(_key('seg_pin_mono_ancla')) ?? 0;
    if (durMs > 0 && ancla > 0) {
      final transcurrido = await _monoAhora() - ancla;
      if (transcurrido < 0) {
        // Reinicio: fallback al wall clock.
        final ahora = DateTime.now().millisecondsSinceEpoch;
        if (ahora >= hasta) return 0;
        return ((hasta - ahora) / 60000).ceil();
      }
      final restante = durMs - transcurrido;
      if (restante <= 0) return 0;
      return (restante / 60000).ceil();
    }
    final ahora = DateTime.now().millisecondsSinceEpoch;
    if (ahora >= hasta) return 0;
    return ((hasta - ahora) / 60000).ceil();
  }

  /// Compara un PIN en claro contra un hash guardado (v1 o v2).
  bool _pinCoincide(String pin, String guardado, String salt) {
    if (guardado.startsWith('v2\$')) {
      final partes = guardado.split('\$');
      if (partes.length != 3) return false;
      final s = partes[1];
      final esperado = partes[2];
      return _hashPinV2(pin, s) == esperado;
    }
    // v1 (legado): sha256('ironbody-pin-$pin')
    final bytes = utf8.encode('ironbody-pin-$pin');
    return sha256.convert(bytes).toString() == guardado;
  }

  /// Hash v2: 10000 iteraciones de SHA-256(salt + pin + anterior).
  static String _hashPinV2(String pin, String saltHex) {
    List<int> actual = utf8.encode(saltHex + pin);
    final pinBytes = utf8.encode(pin);
    for (var i = 0; i < 10000; i++) {
      actual =
          List<int>.from(sha256.convert([...actual, ...pinBytes]).bytes);
    }
    return actual.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Genera el valor a guardar con `setPinHash` para un PIN nuevo
  /// (siempre esquema v2).
  Future<String> hashPinNuevo(String pin) async {
    final salt = await getPinSalt();
    return 'v2\$$salt\${_hashPinV2(pin, salt)}';
  }

  /// Última versión de la app de la que ya se mostró "Lo Nuevo".
  Future<String?> getUltimaVersionVista() async =>
      (await _p).getString('ultima_version_vista');
  Future<void> setUltimaVersionVista(String v) async =>
      (await _p).setString('ultima_version_vista', v);

  /// Nombre visible (item 5): override local del displayName.
  Future<String?> getNombreVisible() async =>
      (await _p).getString('nombre_visible');
  Future<void> setNombreVisible(String? v) async {
    final p = await _p;
    if (v == null || v.trim().isEmpty) {
      await p.remove('nombre_visible');
    } else {
      await p.setString('nombre_visible', v.trim());
    }
  }

  /// Horas sin sincronizar antes de avisar (item 10). Por defecto 8.
  Future<int> getHorasAviso() async =>
      (await _p).getInt('horas_aviso_sync') ?? 8;
  Future<void> setHorasAviso(int h) async =>
      (await _p).setInt('horas_aviso_sync', h);

  /// v1.3.0 (Jc): pago por cliente al entrenador. Por defecto 150 CUP.
  /// Fix #20 (Sol): usa tabla config_negocio (preparada para sync;
  /// el push/pull completo viene en próxima iteración).
  /// SharedPreferences queda como caché offline.
  Future<int> getPagoEntrenador() async {
    // 1. Intentar desde la tabla sincronizada.
    try {
      final v = await LocalDb.instance
          .getConfigNegocio('pago_entrenador_por_cliente');
      if (v != null) {
        final n = int.tryParse(v);
        if (n != null && n > 0) {
          // Actualizar caché.
          (await _p).setInt('pago_entrenador', n);
          return n;
        }
      }
    } catch (_) {}
    // 2. Fallback a caché local.
    return (await _p).getInt('pago_entrenador') ?? 150;
  }

  Future<void> setPagoEntrenador(int monto) async {
    // Guardar en ambos: tabla (para sync) y prefs (caché).
    try {
      await LocalDb.instance.setConfigNegocio(
        'pago_entrenador_por_cliente',
        '$monto',
        'dueno',
      );
    } catch (_) {}
    await (await _p).setInt('pago_entrenador', monto);
  }

  /// Avisar cuando una sincronización falla (item 11).
  Future<bool> getAvisoFalloSync() async =>
      (await _p).getBool('aviso_fallo_sync') ?? true;
  Future<void> setAvisoFalloSync(bool v) async =>
      (await _p).setBool('aviso_fallo_sync', v);

  /// Sincronizar automáticamente al abrir la app (item 12).
  Future<bool> getAutoSync() async =>
      (await _p).getBool('auto_sync_abrir') ?? true;
  Future<void> setAutoSync(bool v) async =>
      (await _p).setBool('auto_sync_abrir', v);

  /// v1.2.5 (3.2): vibración háptica tras confirmaciones. Opcional,
  /// respeta los ajustes del sistema. Por defecto activada.
  Future<bool> getVibracion() async =>
      (await _p).getBool('vibracion_haptica') ?? true;
  Future<void> setVibracion(bool v) async =>
      (await _p).setBool('vibracion_haptica', v);

  /// Tema: 'sistema' | 'claro' | 'oscuro' (item 7).
  Future<String> getTema() async =>
      (await _p).getString('tema') ?? 'sistema';
  Future<void> setTema(String v) async =>
      (await _p).setString('tema', v);

  /// v1.2.5 (3.4): alto contraste (objetivo WCAG AA).
  Future<bool> getAltoContraste() async =>
      (await _p).getBool('alto_contraste') ?? false;

  /// Bloque 1: acción al deslizar una fila en Buscar cliente.
  /// Lista CERRADA: 'ninguna' | 'cobrar' | 'diario' | 'venta' |
  /// 'editar'. Local por teléfono, sin sincronizar (aprobado).
  Future<String> getSwipeBuscarDer() async =>
      (await _p).getString('buscar_swipe_der') ?? 'cobrar';
  Future<void> setSwipeBuscarDer(String v) async =>
      (await _p).setString('buscar_swipe_der', v);
  Future<String> getSwipeBuscarIzq() async =>
      (await _p).getString('buscar_swipe_izq') ?? 'ninguna';
  Future<void> setSwipeBuscarIzq(String v) async =>
      (await _p).setString('buscar_swipe_izq', v);
  Future<void> setAltoContraste(bool v) async =>
      (await _p).setBool('alto_contraste', v);

  /// Escala de letra 0.85–1.30 (item 8).
  Future<double> getTamanoLetra() async =>
      (await _p).getDouble('tamano_letra') ?? 1.0;
  Future<void> setTamanoLetra(double v) async =>
      (await _p).setDouble('tamano_letra', v.clamp(0.85, 1.3));

  /// Bloqueo automático con PIN tras X minutos inactiva (item 14).
  /// 0 = nunca.
  Future<int> getBloqueoMinutos() async =>
      (await _p).getInt('bloqueo_minutos') ?? 0;
  Future<void> setBloqueoMinutos(int m) async =>
      (await _p).setInt('bloqueo_minutos', m);
  Future<int> getUltimaActividad() async =>
      (await _p).getInt('ultima_actividad') ?? 0;
  Future<void> setUltimaActividad(int ts) async =>
      (await _p).setInt('ultima_actividad', ts);

  /// Restablece todos los ajustes a sus valores por defecto (item 24).
  /// No toca el avatar, el PIN ni la vinculación de dispositivo.
  Future<void> resetAjustes() async {
    final p = await _p;
    for (final k in [
      'nombre_visible',
      'horas_aviso_sync',
      'aviso_fallo_sync',
      'auto_sync_abrir',
      'tema',
      'tamano_letra',
      'bloqueo_minutos',
      'ultima_actividad',
      // v1.3.1: usar _key() para claves por usuario.
      _key('perfil_movil'),
      _key('perfil_carnet'),
      'pref_recordatorio_sync',
      'metricas_home',
      'vibracion_haptica',
      'alto_contraste',
    ]) {
      await p.remove(k);
    }
  }

  /// Métricas visibles en la tarjeta de resumen del Home (item 8).
  /// Claves: clientes, pagaron, cobrado, vencen, atrasados, aldia.
  Future<List<String>> getMetricasHome() async {
    final p = await _p;
    final raw = p.getStringList('metricas_home');
    if (raw == null || raw.isEmpty) {
      return [
        'clientes',
        'pagaron',
        'cobrado',
        'vencen',
        'atrasados',
        'aldia'
      ];
    }
    return raw;
  }

  Future<void> setMetricasHome(List<String> v) async =>
      (await _p).setStringList('metricas_home', v);

  Future<File> avatarFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/avatar.jpg');
  }

  Future<bool> tieneAvatar() async => await (await avatarFile()).exists();
}
