/// Perfil del entrenador en el teléfono (Ajustes): avatar, móvil, carnet
/// y preferencias. Se guarda localmente con SharedPreferences; el avatar
/// como archivo en el almacenamiento de la app.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PerfilService {
  PerfilService._();
  static final PerfilService instance = PerfilService._();

  Future<SharedPreferences> get _p async =>
      SharedPreferences.getInstance();

  Future<String?> getMovil() async => (await _p).getString('perfil_movil');
  Future<void> setMovil(String v) async =>
      (await _p).setString('perfil_movil', v);

  Future<String?> getCarnet() async => (await _p).getString('perfil_carnet');
  Future<void> setCarnet(String v) async =>
      (await _p).setString('perfil_carnet', v);

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

  /// ¿Usar huella digital para entrar?
  Future<bool> getHuella() async =>
      (await _p).getBool('seg_huella') ?? false;
  Future<void> setHuella(bool v) async =>
      (await _p).setBool('seg_huella', v);

  /// Hash del PIN rápido (4 dígitos). Null = sin PIN.
  ///
  /// v1.0.16: esquema endurecido. Formato `v2$<salt_hex>$<hash_hex>` donde
  /// hash = 10000 iteraciones de SHA-256(salt + pin + anterior).
  /// El esquema viejo (`v1`, sha256('ironbody-pin-$pin') sin salt) se
  /// reconoce por no tener el prefijo `v2$`; al configurar un PIN nuevo
  /// siempre se usa el esquema nuevo.
  Future<String?> getPinHash() async =>
      (await _p).getString('seg_pin_hash');
  Future<void> setPinHash(String? h) async {
    final p = await _p;
    if (h == null) {
      await p.remove('seg_pin_hash');
    } else {
      await p.setString('seg_pin_hash', h);
    }
  }

  /// Salt aleatorio de 16 bytes (hex) para el PIN. Se genera una vez
  /// por instalación y se reutiliza.
  Future<String> getPinSalt() async {
    final p = await _p;
    var salt = p.getString('seg_pin_salt');
    if (salt == null || salt.isEmpty) {
      final rnd = Random.secure();
      final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
      salt = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await p.setString('seg_pin_salt', salt);
    }
    return salt;
  }

  /// Intentos fallidos consecutivos del PIN.
  Future<int> getPinFallos() async =>
      (await _p).getInt('seg_pin_fallos') ?? 0;
  Future<void> _setPinFallos(int n) async =>
      (await _p).setInt('seg_pin_fallos', n);

  /// Timestamp (ms) hasta el que el PIN está bloqueado. 0 = no bloqueado.
  Future<int> getPinBloqueadoHasta() async =>
      (await _p).getInt('seg_pin_bloqueado_hasta') ?? 0;

  /// Verifica un PIN contra el hash guardado.
  ///
  /// Devuelve true si coincide. Aplica límite de intentos: 5 fallos
  /// consecutivos bloquean el PIN por 15 minutos. El contador se
  /// reinicia al acertar.
  Future<bool> verificarPin(String pin) async {
    final ahora = DateTime.now().millisecondsSinceEpoch;
    if (ahora < await getPinBloqueadoHasta()) return false;
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
      await (await _p).setInt('seg_pin_bloqueado_hasta',
          ahora + 15 * 60 * 1000);
      await _setPinFallos(0);
    }
    return false;
  }

  /// Minutos restantes de bloqueo del PIN (0 si no está bloqueado).
  Future<int> pinBloqueoMinutosRestantes() async {
    final hasta = await getPinBloqueadoHasta();
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

  Future<File> avatarFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/avatar.jpg');
  }

  Future<bool> tieneAvatar() async => await (await avatarFile()).exists();
}
