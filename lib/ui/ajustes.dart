/// ⚙️ Ajustes: perfil, apariencia, notificaciones, seguridad,
/// datos y acerca de. Organizado por secciones con iconos.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../config.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../novedades.dart';
import '../perfil.dart';
import '../theme.dart';
import 'avisos.dart';
import 'diseno.dart';
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
  String? _nombreVisible;
  String? _movil;
  String? _carnet;
  bool _recordatorio = true;
  int _horasAviso = 8;
  bool _avisoFalloSync = true;
  bool _autoSync = true;
  bool _vincular = false;
  bool _tienePin = false;
  String _tema = 'sistema';
  double _tamanoLetra = 1.0;
  int _bloqueoMinutos = 0;
  String? _espacioTexto;
  bool _buscandoUpdate = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final av = await _perfil.avatarFile();
    final tiene = await av.exists();
    if (!mounted) return;
    setState(() {
      _avatar = tiene ? av : null;
    });
    final nv = await _perfil.getNombreVisible();
    final movil = await _perfil.getMovil();
    final carnet = await _perfil.getCarnet();
    final rec = await _perfil.getRecordatorioSync();
    final horas = await _perfil.getHorasAviso();
    final fallo = await _perfil.getAvisoFalloSync();
    final auto = await _perfil.getAutoSync();
    final vinc = await _perfil.getVincularDispositivo();
    final pin = await _perfil.getPinHash();
    final tema = await _perfil.getTema();
    final letra = await _perfil.getTamanoLetra();
    final bloq = await _perfil.getBloqueoMinutos();
    if (mounted) {
      setState(() {
        _nombreVisible = nv;
        _movil = movil;
        _carnet = carnet;
        _recordatorio = rec;
        _horasAviso = horas;
        _avisoFalloSync = fallo;
        _autoSync = auto;
        _vincular = vinc;
        _tienePin = pin != null;
        _tema = tema;
        _tamanoLetra = letra;
        _bloqueoMinutos = bloq;
      });
    }
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t)));
  }

  // ---------- Perfil ----------

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
    _msg('Foto de perfil actualizada');
  }

  Future<void> _editarTexto({
    required String titulo,
    required String? valorActual,
    required String etiqueta,
    TextInputType teclado = TextInputType.text,
    List<TextInputFormatter>? formato,
    required Future<void> Function(String) guardar,
  }) async {
    final ctrl = TextEditingController(text: valorActual ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: TextField(
          controller: ctrl,
          keyboardType: teclado,
          inputFormatters: formato,
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
    await guardar(ctrl.text.trim());
    _cargar();
  }

  Future<void> _editarCampo({
    required String titulo,
    required String? valorActual,
    required String etiqueta,
    required bool Function(String) validar,
    required String errorMsg,
    required Future<void> Function(String) guardar,
  }) async {
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
      _msg(errorMsg);
      return;
    }
    await guardar(v);
    _cargar();
  }

  String _rolTexto() {
    if (_auth.isOwner) return 'Dueño';
    if (_auth.isAdmin) return 'Administrador';
    return 'Entrenador';
  }

  // ---------- Apariencia ----------

  String _temaEtiqueta(String t) {
    switch (t) {
      case 'claro':
        return 'Claro';
      case 'oscuro':
        return 'Oscuro';
      default:
        return 'Según el sistema';
    }
  }

  /// Selector de tema con vista previa (items 7 y 9).
  Future<void> _elegirTema() async {
    final sel = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tema'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _opcionTema(ctx, 'sistema', Icons.brightness_auto,
                'Según el sistema'),
            _opcionTema(
                ctx, 'claro', Icons.light_mode, 'Claro'),
            _opcionTema(
                ctx, 'oscuro', Icons.dark_mode, 'Oscuro'),
          ],
        ),
      ),
    );
    if (sel != null && mounted) {
      await ThemeController.setTema(sel);
      setState(() => _tema = sel);
    }
  }

  Widget _opcionTema(
      BuildContext ctx, String valor, IconData icono, String titulo) {
    final activo = _tema == valor;
    final oscuro = valor == 'oscuro';
    return ListTile(
      leading: Icon(icono,
          color: activo ? AppColores.naranja : null),
      title: Text(titulo),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mini vista previa del tema (item 9)
          Container(
            width: 44,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: oscuro
                  ? AppColores.carbonProfundo
                  : Colors.grey.shade200,
              border: Border.all(
                  color: Colors.grey.shade500, width: 0.5),
            ),
            child: Center(
              child: Container(
                width: 28,
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: AppColores.naranja,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (activo)
            const Icon(Icons.check,
                color: AppColores.naranja),
        ],
      ),
      onTap: () => Navigator.pop(ctx, valor),
    );
  }

  // ---------- Notificaciones ----------

  Future<void> _elegirHoras() async {
    final sel = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Avisar si llevo sin sincronizar'),
        children: [4, 8, 12, 24]
            .map((h) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, h),
                  child: Row(
                    children: [
                      Text('$h horas'),
                      const Spacer(),
                      if (_horasAviso == h)
                        const Icon(Icons.check,
                            color: AppColores.naranja),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (sel != null) {
      await _perfil.setHorasAviso(sel);
      if (mounted) setState(() => _horasAviso = sel);
    }
  }

  // ---------- Seguridad ----------

  /// Cambio de contraseña dentro de la app.
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
      _msg('Las contraseñas nuevas no coinciden');
      return;
    }
    if (nueva.text.length < 6) {
      _msg('La nueva debe tener al menos 6 caracteres');
      return;
    }
    try {
      await _auth.changePassword(actual.text, nueva.text);
      _msg('Contraseña cambiada');
    } catch (_) {
      _msg('No se pudo cambiar: verifica tu contraseña actual');
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
      _msg('PIN inválido: 4 dígitos iguales');
      return;
    }
    final hash = await _perfil.hashPinNuevo(p1);
    await _perfil.setPinHash(hash);
    if (mounted) {
      setState(() => _tienePin = true);
      _msg('PIN configurado');
    }
  }

  String _bloqueoEtiqueta(int m) {
    if (m <= 0) return 'Nunca';
    if (m == 1) return 'Tras 1 minuto';
    return 'Tras $m minutos';
  }

  /// Bloqueo automático con PIN (item 14).
  Future<void> _elegirBloqueo() async {
    if (!_tienePin) {
      _msg('Primero configura un PIN rápido');
      return;
    }
    final sel = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Bloqueo automático'),
        children: [0, 1, 5, 15, 30]
            .map((m) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, m),
                  child: Row(
                    children: [
                      Text(_bloqueoEtiqueta(m)),
                      const Spacer(),
                      if (_bloqueoMinutos == m)
                        const Icon(Icons.check,
                            color: AppColores.naranja),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (sel != null) {
      await _perfil.setBloqueoMinutos(sel);
      if (mounted) setState(() => _bloqueoMinutos = sel);
    }
  }

  // ---------- Datos ----------

  /// Exportar respaldo de la BD (item 17: solo el dueño).
  Future<void> _exportarRespaldo() async {
    if (!_auth.isOwner) {
      _msg('Solo el dueño puede exportar el respaldo');
      return;
    }
    try {
      final ruta = await LocalDb.instance.dbPath();
      final tmp = await getTemporaryDirectory();
      final fecha =
          DateTime.now().toIso8601String().substring(0, 10);
      final destino =
          '${tmp.path}/ironbody-respaldo-$fecha.db';
      await File(ruta).copy(destino);
      await Share.shareXFiles([XFile(destino)],
          text: 'Respaldo Iron Body Gym $fecha');
    } catch (e) {
      _msg('No se pudo exportar: $e');
    }
  }

  /// Importar respaldo de la BD (item 17: entrenadores también).
  Future<void> _importarRespaldo() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Elige el archivo de respaldo (.db)',
    );
    final ruta = res?.files.single.path;
    if (ruta == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Importar respaldo'),
        content: const Text(
            'Se reemplazarán todos los datos de este teléfono con el respaldo elegido. '
            '¿Continuar?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.error),
              child: const Text('Importar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await LocalDb.instance.close();
      final destino = await LocalDb.instance.dbPath();
      await File(ruta).copy(destino);
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Respaldo importado'),
          content: const Text(
              'Reinicia la app para que los datos importados se apliquen.'),
          actions: [
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Entendido')),
          ],
        ),
      );
    } catch (e) {
      _msg('No se pudo importar: $e');
    }
  }

  String _fmtTamano(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<int> _tamanoDir(Directory d) async {
    var total = 0;
    try {
      await for (final e in d.list(recursive: true)) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// Espacio usado por la BD y las fotos (item 18).
  Future<void> _verEspacio() async {
    try {
      final dbRuta = await LocalDb.instance.dbPath();
      final dbBytes = await File(dbRuta).length();
      final docs = await getApplicationDocumentsDirectory();
      final fotosBytes =
          await _tamanoDir(Directory('${docs.path}/fotos_cache'));
      final total = dbBytes + fotosBytes;
      if (!mounted) return;
      setState(() {
        _espacioTexto =
            'Base de datos: ${_fmtTamano(dbBytes)}\nFotos: ${_fmtTamano(fotosBytes)}\nTotal: ${_fmtTamano(total)}';
      });
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Espacio usado'),
          content: Text(_espacioTexto!),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar')),
          ],
        ),
      );
    } catch (e) {
      _msg('No se pudo calcular: $e');
    }
  }

  /// Limpiar caché de fotos (item 19).
  Future<void> _limpiarCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Limpiar caché de fotos'),
        content: const Text(
            'Se borrarán las fotos guardadas en el teléfono. '
            'Se descargarán de nuevo al sincronizar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Limpiar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/fotos_cache');
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          await e.delete(recursive: true);
        }
      }
      _msg('Caché de fotos limpiado');
    } catch (e) {
      _msg('No se pudo limpiar: $e');
    }
  }

  // ---------- Acerca de ----------

  /// Buscar actualizaciones en GitHub (item 20).
  Future<void> _buscarActualizaciones() async {
    if (_buscandoUpdate) return;
    setState(() => _buscandoUpdate = true);
    try {
      final resp = await http
          .get(Uri.parse(
              'https://api.github.com/repos/JcTr0602/ironbodygym-apk/releases/latest'))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      final tag = RegExp(r'"tag_name"\s*:\s*"([^"]+)"')
          .firstMatch(resp.body)
          ?.group(1);
      final remota =
          (tag ?? '').replaceAll(RegExp(r'^v'), '').trim();
      const actual = AppConfig.appVersion;
      final hayNueva =
          remota.isNotEmpty && remota != actual;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Actualizaciones'),
          content: Text(hayNueva
              ? 'Hay una nueva versión disponible: $remota\nTu versión: $actual'
              : 'Tienes la última versión ($actual)'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar')),
          ],
        ),
      );
    } catch (_) {
      _msg('No se pudo comprobar. Revisa tu conexión.');
    } finally {
      if (mounted) setState(() => _buscandoUpdate = false);
    }
  }

  /// Ver changelog (item 21).
  void _verNovedades() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lo nuevo'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: novedades.length,
            itemBuilder: (_, i) {
              final n = novedades[i];
              return Padding(
                padding:
                    const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text('v${n.version}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColores.naranja)),
                    const SizedBox(height: 4),
                    for (final c in n.cambios)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 2),
                        child: Text('• $c',
                            style: const TextStyle(
                                fontSize: 13)),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
        ],
      ),
    );
  }

  /// Reportar problema por WhatsApp (item 22).
  Future<void> _reportarWhatsApp() async {
    try {
      final pendientes =
          await LocalDb.instance.countPendingOps();
      final texto = 'Hola, tengo un problema con la app Iron Body Gym:\n\n'
          '• Versión: ${AppConfig.appVersion}\n'
          '• Usuario: ${_auth.username}\n'
          '• Pendientes por subir: $pendientes\n'
          '• Fecha: ${DateTime.now().toIso8601String().substring(0, 16)}\n\n'
          'Descripción del problema:\n';
      final url = Uri.parse(
          'https://wa.me/5358191577?text=${Uri.encodeComponent(texto)}');
      final ok = await launchUrl(url,
          mode: LaunchMode.externalApplication);
      if (!ok) _msg('No se pudo abrir WhatsApp');
    } catch (_) {
      _msg('No se pudo abrir WhatsApp');
    }
  }

  /// Restablecer ajustes (item 24).
  Future<void> _restablecer() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restablecer ajustes'),
        content: const Text(
            'Se devolverán todos los ajustes a sus valores por defecto. '
            'No se borran tus datos ni tu PIN.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restablecer')),
        ],
      ),
    );
    if (ok != true) return;
    await _perfil.resetAjustes();
    await ThemeController.setTema('sistema');
    await ThemeController.setFontScale(1.0);
    _cargar();
    _msg('Ajustes restablecidos');
  }

  // ---------- UI ----------

  Widget _seccion(String titulo) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
      child: Text(titulo,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppColores.naranja)),
    );
  }

  Widget _opcion({
    required IconData icono,
    required String titulo,
    String? subtitulo,
    Widget? trailing,
    VoidCallback? onTap,
    Color? colorTitulo,
  }) {
    return ListTile(
      leading: Icon(icono, size: 24),
      title: Text(titulo,
          style: TextStyle(
              color: colorTitulo,
              fontWeight: colorTitulo != null
                  ? FontWeight.bold
                  : null)),
      subtitle: subtitulo != null
          ? Text(subtitulo,
              style: const TextStyle(fontSize: 12))
          : null,
      trailing: trailing ??
          (onTap != null
              ? const Icon(Icons.chevron_right)
              : null),
      onTap: onTap,
    );
  }

  Widget _switch({
    required IconData icono,
    required String titulo,
    String? subtitulo,
    required bool valor,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icono, size: 24),
      title: Text(titulo),
      subtitle: subtitulo != null
          ? Text(subtitulo,
              style: const TextStyle(fontSize: 12))
          : null,
      value: valor,
      onChanged: onChanged,
    );
  }

  String _inicial() {
    final base = _nombreVisible ?? _auth.displayName;
    final t = base.trim();
    return t.isEmpty ? '?' : t[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ----- PERFIL -----
                _seccion('Perfil'),
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
                        : CircleAvatar(
                            radius: 50,
                            backgroundColor:
                                AppColores.naranja.withValues(
                                    alpha: 0.2),
                            child: Text(_inicial(),
                                style: const TextStyle(
                                    fontSize: 40,
                                    color:
                                        AppColores.naranja)),
                          ),
                  ),
                ),
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.photo_camera,
                        size: 16),
                    label: const Text('Cambiar foto'),
                    onPressed: _cambiarAvatar,
                  ),
                ),
                _opcion(
                  icono: Icons.badge_outlined,
                  titulo: 'Nombre visible',
                  subtitulo:
                      _nombreVisible ?? 'Igual que la cuenta',
                  onTap: () => _editarTexto(
                    titulo: 'Nombre visible',
                    valorActual: _nombreVisible,
                    etiqueta: 'Cómo quieres que te llame la app',
                    guardar: _perfil.setNombreVisible,
                  ),
                ),
                _opcion(
                  icono: Icons.person_outline,
                  titulo: 'Cuenta',
                  subtitulo: _auth.displayName,
                ),
                _opcion(
                  icono: Icons.shield_outlined,
                  titulo: 'Rol',
                  subtitulo: _rolTexto(),
                ),
                _opcion(
                  icono: Icons.phone_outlined,
                  titulo: 'Móvil',
                  subtitulo: _movil ?? 'Sin registrar',
                  onTap: () => _editarCampo(
                    titulo: 'Número móvil',
                    valorActual: _movil,
                    etiqueta: 'Móvil (8 dígitos)',
                    validar: validarTelefono,
                    errorMsg:
                        'Móvil inválido: 8 dígitos empezando con 5',
                    guardar: _perfil.setMovil,
                  ),
                ),
                _opcion(
                  icono: Icons.credit_card_outlined,
                  titulo: 'Carnet',
                  subtitulo: _carnet ?? 'Sin registrar',
                  onTap: () => _editarCampo(
                    titulo: 'Carnet de identidad',
                    valorActual: _carnet,
                    etiqueta: 'Carnet (6–11 dígitos)',
                    validar: validarCarnet,
                    errorMsg:
                        'Carnet inválido: 6 a 11 dígitos',
                    guardar: _perfil.setCarnet,
                  ),
                ),

                // ----- APARIENCIA -----
                _seccion('Apariencia'),
                _opcion(
                  icono: Icons.palette_outlined,
                  titulo: 'Tema',
                  subtitulo: _temaEtiqueta(_tema),
                  onTap: _elegirTema,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.format_size,
                          size: 24),
                      const SizedBox(width: 16),
                      const Expanded(
                          child: Text('Tamaño de letra')),
                      Expanded(
                        flex: 2,
                        child: Slider(
                          value: _tamanoLetra,
                          min: 0.85,
                          max: 1.3,
                          divisions: 9,
                          label:
                              '${(_tamanoLetra * 100).round()}%',
                          onChanged: (v) =>
                              setState(() => _tamanoLetra = v),
                          onChangeEnd: (v) =>
                              ThemeController.setFontScale(v),
                        ),
                      ),
                    ],
                  ),
                ),

                // ----- NOTIFICACIONES -----
                _seccion('Notificaciones'),
                _opcion(
                  icono: Icons.notifications_outlined,
                  titulo: 'Mis avisos',
                  subtitulo:
                      'Vencimientos, cumpleaños y sincronización',
                  onTap: () =>
                      Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  const AvisosScreen())),
                ),
                _switch(
                  icono: Icons.sync_outlined,
                  titulo: 'Avisar si llevo sin sincronizar',
                  subtitulo:
                      'Cada $_horasAviso horas sin subir cambios',
                  valor: _recordatorio,
                  onChanged: (v) async {
                    await _perfil.setRecordatorioSync(v);
                    if (mounted) {
                      setState(() => _recordatorio = v);
                    }
                  },
                ),
                if (_recordatorio)
                  _opcion(
                    icono: Icons.schedule_outlined,
                    titulo: 'Cada cuánto avisar',
                    subtitulo: '$_horasAviso horas',
                    onTap: _elegirHoras,
                  ),
                _switch(
                  icono: Icons.sync_problem_outlined,
                  titulo: 'Avisar si falla la sincronización',
                  valor: _avisoFalloSync,
                  onChanged: (v) async {
                    await _perfil.setAvisoFalloSync(v);
                    if (mounted) {
                      setState(() => _avisoFalloSync = v);
                    }
                  },
                ),
                _switch(
                  icono: Icons.cloud_upload_outlined,
                  titulo: 'Sincronizar al abrir la app',
                  subtitulo:
                      'Sube lo pendiente en segundo plano',
                  valor: _autoSync,
                  onChanged: (v) async {
                    await _perfil.setAutoSync(v);
                    if (mounted) {
                      setState(() => _autoSync = v);
                    }
                  },
                ),

                // ----- SEGURIDAD -----
                _seccion('Seguridad'),
                _opcion(
                  icono: Icons.key_outlined,
                  titulo: 'Cambiar contraseña',
                  onTap: _cambiarClave,
                ),
                _switch(
                  icono: Icons.phonelink_lock_outlined,
                  titulo: 'Vincular a este dispositivo',
                  subtitulo:
                      'Avisa si entras desde otro teléfono',
                  valor: _vincular,
                  onChanged: (v) async {
                    await _perfil
                        .setVincularDispositivo(v);
                    if (v) {
                      final devId =
                          await _perfil.getDeviceId();
                      await _perfil
                          .setDispositivoVinculado(
                              _auth.username, devId);
                    }
                    if (mounted) {
                      setState(() => _vincular = v);
                    }
                  },
                ),
                _opcion(
                  icono: Icons.pin_outlined,
                  titulo: 'PIN rápido',
                  subtitulo: _tienePin
                      ? 'Configurado (4 dígitos)'
                      : 'Sin configurar',
                  onTap: _configurarPin,
                ),
                _opcion(
                  icono: Icons.timer_outlined,
                  titulo: 'Bloqueo automático',
                  subtitulo:
                      '${_bloqueoEtiqueta(_bloqueoMinutos)}${_tienePin ? '' : ' (requiere PIN)'}',
                  onTap: _elegirBloqueo,
                ),

                // ----- DATOS -----
                _seccion('Datos'),
                if (_auth.isOwner)
                  _opcion(
                    icono: Icons.cloud_upload_outlined,
                    titulo: 'Exportar respaldo',
                    subtitulo:
                        'Guarda la base de datos para compartirla',
                    onTap: _exportarRespaldo,
                  ),
                _opcion(
                  icono: Icons.cloud_download_outlined,
                  titulo: 'Importar respaldo',
                  subtitulo:
                      'Restaura los datos desde un archivo',
                  onTap: _importarRespaldo,
                ),
                _opcion(
                  icono: Icons.storage_outlined,
                  titulo: 'Espacio usado',
                  subtitulo: _espacioTexto
                          ?.split('\n')
                          .last ??
                      'Toca para ver el detalle',
                  onTap: _verEspacio,
                ),
                _opcion(
                  icono: Icons.cleaning_services_outlined,
                  titulo: 'Limpiar caché de fotos',
                  subtitulo:
                      'Libera espacio; se descargan al sincronizar',
                  onTap: _limpiarCache,
                ),

                // ----- ACERCA DE -----
                _seccion('Acerca de'),
                _opcion(
                  icono: Icons.info_outline,
                  titulo: 'Versión',
                  subtitulo:
                      '${AppConfig.appVersion} · Toca para buscar actualizaciones',
                  trailing: _buscandoUpdate
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(
                                  strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onTap: _buscarActualizaciones,
                ),
                _opcion(
                  icono: Icons.new_releases_outlined,
                  titulo: 'Lo nuevo',
                  subtitulo:
                      'Cambios de cada versión',
                  onTap: _verNovedades,
                ),
                _opcion(
                  icono: Icons.bug_report_outlined,
                  titulo: 'Reportar problema',
                  subtitulo: 'Escríbenos por WhatsApp',
                  onTap: _reportarWhatsApp,
                ),
                _opcion(
                  icono: Icons.restart_alt_outlined,
                  titulo: 'Restablecer ajustes',
                  subtitulo:
                      'Volver a los valores por defecto',
                  onTap: _restablecer,
                ),
                const SizedBox(height: 24),
                const Center(
                  child: Text('© Creado por JcTr0602',
                      style: TextStyle(
                          color: Colors.grey,
                          fontSize: 12)),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
