/// Perfil del entrenador en el teléfono (Ajustes): avatar, móvil, carnet
/// y preferencias. Se guarda localmente con SharedPreferences; el avatar
/// como archivo en el almacenamiento de la app.
library;

import 'dart:io';

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

  /// Hash SHA-256 del PIN rápido (4 dígitos). Null = sin PIN.
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
