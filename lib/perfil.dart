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
