/// ⚙️ Ajustes del entrenador: perfil (avatar, móvil, carnet),
/// tema, preferencias y cambio de contraseña.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';

import '../auth.dart';
import '../config.dart';
import '../negocio.dart';
import '../perfil.dart';
import '../theme.dart';
import 'avisos.dart';
import 'widgets.dart';

class AjustesScreen extends StatefulWidget {
  const AjustesScreen({super.key});
  @override
  State<AjustesScreen> createState() => _AjustesScreenState();
}

class _AjustesScreenState extends State<AjustesScreen> {
  final _auth = AuthService();
  final _perfil = PerfilService.instance;
  File? _avatar;
  String? _movil;
  String? _carnet;
  bool _recordatorio = true;
  bool _vincular = false;
  bool _huella = false;
  bool _tienePin = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final av = await _perfil.avatarFile();
    final tiene = await av.exists();
    final movil = await _perfil.getMovil();
    final carnet = await _perfil.getCarnet();
    final rec = await _perfil.getRecordatorioSync();
    final vinc = await _perfil.getVincularDispositivo();
    final hue = await _perfil.getHuella();
    final pin = await _perfil.getPinHash();
    if (mounted) {
      setState(() {
        _avatar = tiene ? av : null;
        _movil = movil;
        _carnet = carnet;
        _recordatorio = rec;
        _vincular = vinc;
        _huella = hue;
        _tienePin = pin != null;
      });
    }
  }

  /// Prueba la huella y devuelve true si el dispositivo la soporta.
  Future<bool> _probarHuella() async {
    try {
      final auth = LocalAuthentication();
      final puede = await auth.canCheckBiometrics;
      if (!puede) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Este dispositivo no tiene huella')));
        }
        return false;
      }
      final ok = await auth.authenticate(
        localizedReason: 'Confirma tu huella para activarla',
      );
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Configura o cambia el PIN rápido (4 dígitos).
  Future<void> _configurarPin() async {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tienePin ? 'Cambiar PIN' : 'Crear PIN rápido'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: c1,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'PIN (4 dígitos)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c2,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Repite el PIN',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          if (_tienePin)
            TextButton(
              onPressed: () async {
                await _perfil.setPinHash(null);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Quitar PIN',
                  style: TextStyle(color: Colors.red)),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      if (ok == true) _cargar();
      return;
    }
    final p1 = c1.text.trim();
    final p2 = c2.text.trim();
    if (p1.length != 4 || p1 != p2 || int.tryParse(p1) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('PIN inválido: 4 dígitos iguales')));
      return;
    }
    // v1.0.16: hash endurecido con salt + 10000 iteraciones
    final hash = await _perfil.hashPinNuevo(p1);
    await _perfil.setPinHash(hash);
    if (mounted) {
      setState(() => _tienePin = true);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN configurado')));
    }
  }

  Future<void> _cambiarAvatar() async {
    final origen = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Foto de perfil'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.photo_camera, size: 24),
              title: const Text('Tomar foto'),
              onTap: () =>
                  Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, size: 24),
              title: const Text('Elegir de la galería'),
              onTap: () =>
                  Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (origen == null || !mounted) return;
    final img = await ImagePicker().pickImage(
        source: origen, maxWidth: 512, imageQuality: 80);
    if (img == null || !mounted) return;
    final destino = await _perfil.avatarFile();
    await File(img.path).copy(destino.path);
    setState(() => _avatar = destino);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto de perfil actualizada')));
    }
  }

  Future<void> _editarCampo(
      {required String titulo,
      required String? valorActual,
      required String etiqueta,
      required bool Function(String) validar,
      required String errorMsg,
      required Future<void> Function(String) guardar}) async {
    final ctrl = TextEditingController(text: valorActual ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly
          ],
          decoration: InputDecoration(
              labelText: etiqueta,
              border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final v = ctrl.text.trim();
    if (v.isNotEmpty && !validar(v)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorMsg)));
      }
      return;
    }
    await guardar(v);
    _cargar();
  }

  /// Cambio de contraseña dentro de la app (punto 40).
  Future<void> _cambiarClave() async {
    final actual = TextEditingController();
    final nueva = TextEditingController();
    final nueva2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cambiar contraseña'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: actual,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Contraseña actual',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(
                  controller: nueva,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Nueva contraseña',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(
                  controller: nueva2,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Repite la nueva',
                      border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cambiar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (nueva.text != nueva2.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Las contraseñas nuevas no coinciden')));
      return;
    }
    if (nueva.text.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('La nueva debe tener al menos 6 caracteres')));
      return;
    }
    try {
      await _auth.changePassword(actual.text, nueva.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Contraseña cambiada')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'No se pudo cambiar: verifica tu contraseña actual')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(' Ajustes')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: GestureDetector(
                    onTap: _cambiarAvatar,
                    child: _avatar != null
                        ? ClipRRect(
                            borderRadius:
                                BorderRadius.circular(50),
                            child: Image.file(_avatar!,
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover),
                          )
                        : const CircleAvatar(
                            radius: 50,
                            child: Text('',
                                style: TextStyle(fontSize: 40))),
                  ),
                ),
                Center(
                  child: TextButton.icon(
                    icon: const Text(''),
                    label: const Text('Cambiar foto'),
                    onPressed: _cambiarAvatar,
                  ),
                ),
                const SizedBox(height: 8),
                _fila('Nombre', _auth.displayName,
                    null),
                _fila('Móvil', _movil ?? '—', () {
                  _editarCampo(
                    titulo: 'Número móvil',
                    valorActual: _movil,
                    etiqueta: 'Móvil (8 dígitos)',
                    validar: validarTelefono,
                    errorMsg:
                        'Móvil inválido: 8 dígitos empezando con 5',
                    guardar: _perfil.setMovil,
                  );
                }),
                _fila('Carnet', _carnet ?? '—', () {
                  _editarCampo(
                    titulo: 'Carnet de identidad',
                    valorActual: _carnet,
                    etiqueta: 'Carnet (6–11 dígitos)',
                    validar: validarCarnet,
                    errorMsg:
                        'Carnet inválido: 6 a 11 dígitos',
                    guardar: _perfil.setCarnet,
                  );
                }),
                const Divider(),
                ValueListenableBuilder<ThemeMode>(
                  valueListenable: ThemeController.mode,
                  builder: (_, mode, __) => SwitchListTile(
                    title: const Text('Tema oscuro'),
                    value: mode == ThemeMode.dark,
                    onChanged: (_) =>
                        ThemeController.toggle(),
                  ),
                ),
                SwitchListTile(
                  title: const Text(
                      '⏰ Avisar si llevo +8h sin sincronizar'),
                  value: _recordatorio,
                  onChanged: (v) async {
                    await _perfil.setRecordatorioSync(v);
                    if (mounted) {
                      setState(() => _recordatorio = v);
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Text('',
                      style: TextStyle(fontSize: 24)),
                  title:
                      const Text('Cambiar contraseña'),
                  trailing:
                      const Icon(Icons.chevron_right),
                  onTap: _cambiarClave,
                ),
                const Divider(),
                ListTile(
                  leading: const Text('',
                      style: TextStyle(fontSize: 24)),
                  title:
                      const Text('Mis avisos'),
                  trailing:
                      const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const AvisosScreen())),
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('Seguridad',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                ),
                SwitchListTile(
                  title: const Text('Vincular a este dispositivo'),
                  subtitle: const Text(
                      'Avisa si entras desde otro teléfono',
                      style: TextStyle(fontSize: 12)),
                  value: _vincular,
                  onChanged: (v) async {
                    await _perfil.setVincularDispositivo(v);
                    if (v) {
                      // Vincula ahora mismo
                      final devId = await _perfil.getDeviceId();
                      await _perfil.setDispositivoVinculado(
                          _auth.username, devId);
                    }
                    if (mounted) {
                      setState(() => _vincular = v);
                    }
                  },
                ),
                SwitchListTile(
                  title: const Text('Entrar con huella digital'),
                  value: _huella,
                  onChanged: (v) async {
                    if (v) {
                      // Verifica que el dispositivo la soporte
                      final ok = await _probarHuella();
                      if (!ok) return;
                    }
                    await _perfil.setHuella(v);
                    if (mounted) {
                      setState(() => _huella = v);
                    }
                  },
                ),
                ListTile(
                  leading: const Text('',
                      style: TextStyle(fontSize: 24)),
                  title: const Text('PIN rápido'),
                  subtitle: Text(
                      _tienePin
                          ? 'Configurado (4 dígitos)'
                          : 'Sin configurar',
                      style: const TextStyle(fontSize: 12)),
                  trailing:
                      const Icon(Icons.chevron_right),
                  onTap: _configurarPin,
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Versión ${AppConfig.appVersion}',
                    style: TextStyle(
                        color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fila(String etiqueta, String valor, VoidCallback? onTap) {
    return ListTile(
      title: Text(etiqueta),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(valor,
              style:
                  const TextStyle(fontWeight: FontWeight.bold)),
          if (onTap != null)
            const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }
}
