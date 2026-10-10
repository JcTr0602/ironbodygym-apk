import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../config.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'diseno.dart';
import 'componentes.dart';

/// Gestión de usuarios APK (v1.0.12, mejoras v1.0.14).
/// Lista desde sync_estado (publicada por el puente), acciones directas
/// sin escribir nombres a mano.
class UsuariosScreen extends StatefulWidget {
  const UsuariosScreen({super.key});

  @override
  State<UsuariosScreen> createState() => _UsuariosScreenState();
}

class _UsuariosScreenState extends State<UsuariosScreen> {
  List<Map<String, dynamic>> _usuarios = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    // Refrescar desde el servidor y leer caché local
    try {
      await SyncEngine.instance.pull();
    } catch (_) {}
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    final lista = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final u in jsonDecode(raw) as List) {
          lista.add(Map<String, dynamic>.from(u as Map));
        }
      } catch (_) {}
    }
    lista.sort((a, b) => '${a['username']}'.compareTo('${b['username']}'));
    if (mounted) {
      setState(() {
        _usuarios = lista;
        _cargando = false;
      });
    }
  }

  Future<void> _accion(
      String username, String accion, String titulo,
      {String? rol}) async {
    if (accion == 'eliminar') {
      final ok = await DialogoApp.confirmar(
        context,
        titulo: 'Eliminar usuario',
        mensaje:
            '¿Eliminar a "$username"? Perderá acceso inmediatamente.',
        aceptar: 'Eliminar',
        peligro: true,
        icono: Icons.delete_outline,
      );
      if (ok != true || !mounted) return;
    }
    String? password;
    if (accion == 'reset_pass') {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Nueva contraseña para $username',
          iconoTitulo: Icons.key,
          contenido: CampoTexto(
            controller: ctrl,
            etiqueta: 'Contraseña (mín. 6)',
            obscure: true,
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppRadio.md),
                  ),
                ),
                child: const Text('Cambiar')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      password = ctrl.text.trim();
      if (password.length < 6) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Contraseña muy corta (mín. 6 caracteres)')));
        return;
      }
    }
    final payload = <String, dynamic>{
      'accion': accion,
      'username': username,
    };
    if (password != null) payload['password'] = password;
    if (rol != null) payload['rol'] = rol;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'admin_usuario',
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"$titulo" encolado para $username')),
    );
    // v1.0.14: ofrecer compartir credenciales tras crear/resetear
    if ((accion == 'crear' || accion == 'reset_pass') &&
        password != null) {
      _compartirCredenciales(username, password);
    }
    SyncEngine.instance.push();
  }

  /// v1.0.14: texto listo para compartir credenciales por WhatsApp.
  void _compartirCredenciales(String username, String password) {
    final texto = '''🏋️ *Iron Body Gym*

Hola $username, estas son tus credenciales para la app del gym:

👤 *Usuario:* $username
🔑 *Contraseña:* $password

📲 Descarga la APK e inicia sesión con estos datos.
⚠️ No compartas tu contraseña con nadie.''';
    showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Compartir credenciales',
        iconoTitulo: Icons.share,
        contenido: SingleChildScrollView(child: Text(texto)),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copiar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadio.md),
              ),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: texto));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Copiado, pégalo en WhatsApp')),
              );
            },
          ),
        ],
      ),
    );
  }

  /// v1.0.14: historial de accesos del usuario.
  void _verHistorial(Map<String, dynamic> u) {
    final username = '${u['username'] ?? '?'}';
    final accesos = (u['accesos'] as List?)?.cast<String>() ?? [];
    showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Accesos de $username',
        iconoTitulo: Icons.history,
        contenido: SizedBox(
          width: double.maxFinite,
          child: accesos.isEmpty
              ? const Text('Sin accesos registrados.''\n'
                  'El historial se genera con el uso de la APK.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: accesos.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1),
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.login, size: 18),
                    title: Text(tiempoRelativo(accesos[i]),
                        style: const TextStyle(fontSize: 14)),
                    subtitle: Text(fmtFecha(accesos[i]),
                        style: const TextStyle(fontSize: 12)),
                  ),
                ),
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// v1.0.14: avatar con foto del usuario si existe.
  Widget _avatar(String username, bool bloqueado, bool esAdmin) {
    final path = 'usuarios/${username.toLowerCase()}.jpg';
    return FutureBuilder<File?>(
      future: FotoCache.instance.enCache(path),
      builder: (ctx, snap) {
        final file = snap.data;
        if (file != null) {
          return CircleAvatar(
            backgroundImage: FileImage(file),
            backgroundColor: AppColores.borde(ctx),
          );
        }
        return CircleAvatar(
          backgroundColor: bloqueado
              ? AppColores.error.withValues(alpha: 0.15)
              : esAdmin
                  ? AppColores.info.withValues(alpha: 0.15)
                  : AppColores.exito.withValues(alpha: 0.15),
          child: Text(
            username.isNotEmpty ? username[0].toUpperCase() : '?',
            style: TextStyle(
              color: bloqueado
                  ? AppColores.error
                  : esAdmin
                      ? AppColores.info
                      : AppColores.exito,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      },
    );
  }

  /// v1.0.14: foto del entrenador (bucket fotos-clientes/usuarios/).
  Future<void> _cambiarFoto(String username) async {
    final picker = ImagePicker();
    final img = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      imageQuality: 80,
    );
    if (img == null || !mounted) return;
    final path = 'usuarios/${username.toLowerCase()}.jpg';
    try {
      final bytes = await File(img.path).readAsBytes();
      await AuthService().storage
          .from(AppConfig.bucketFotos)
          .uploadBinary(path, bytes,
              fileOptions:
                  const FileOptions(upsert: true));
      // Invalidar caché local para que se vea la nueva
      await FotoCache.instance.invalidar(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto actualizada')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo subir: $e')),
      );
    }
  }

  /// v1.0.14: cambiar rol desde la lista.
  Future<void> _cambiarRol(
      String username, String rolActual) async {
    final nuevoRol =
        rolActual == 'admin' ? 'entrenador' : 'admin';
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cambiar rol',
      mensaje: '"$username" pasará de "$rolActual" a "$nuevoRol".\n\n'
          '${nuevoRol == 'admin' ? 'Tendrá acceso a Administración, finanzas y auditoría.' : 'Solo verá las funciones de entrenador.'}',
      aceptar: 'Cambiar a $nuevoRol',
      icono: Icons.manage_accounts,
    );
    if (ok == true && mounted) {
      await _accion(username, 'cambiar_rol', 'Cambiar rol', rol: nuevoRol);
      _cargar();
    }
  }

  Future<void> _crear() async {
    final nombreCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Crear usuario APK',
        iconoTitulo: Icons.person_add,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: nombreCtrl,
                etiqueta: 'Nombre de usuario'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: passCtrl,
                etiqueta: 'Contraseña (mín. 6)',
                obscure: true),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Crear')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nombre = nombreCtrl.text.trim();
    final pass = passCtrl.text;
    if (nombre.isEmpty || pass.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nombre vacío o contraseña muy corta (mín. 6)')));
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'admin_usuario',
      payload: {'accion': 'crear', 'username': nombre, 'password': pass},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Usuario encolado (se sincronizará)')));
    SyncEngine.instance.push();
    _compartirCredenciales(nombre, pass);
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Usuarios APK'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _crear,
        icon: const Icon(Icons.person_add),
        label: const Text('Crear'),
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _usuarios.isEmpty
              ? EstadoVacio(
                  icono: Icons.people_outline,
                  titulo: 'Sin datos',
                  subtitulo: 'Sincroniza para ver la lista.',
                  textoAccion: 'Actualizar',
                  onAccion: _cargar,
                )
              : RefreshIndicator(
                  onRefresh: _cargar,
                  child: ListView.separated(
                    itemCount: _usuarios.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final u = _usuarios[i];
                      final username = '${u['username'] ?? '?'}';
                      final bloqueado = u['bloqueado'] == true;
                      // v1.0.14: tiempo relativo legible
                      final ultimoRel =
                          tiempoRelativo('${u['ultimo_acceso'] ?? ''}');
                      final dispositivo =
                          '${u['dispositivo'] ?? ''}';
                      final rol = '${u['rol'] ?? 'entrenador'}';
                      final esAdmin = rol == 'admin';
                      final esDueno = username.toLowerCase() == 'jctr0602';
                      return ListTile(
                        leading: _avatar(username, bloqueado, esAdmin),
                        title: Row(
                          children: [
                            Expanded(
                                child: Text(username,
                                    overflow:
                                        TextOverflow.ellipsis)),
                            if (esDueno)
                              const Chip(
                                label: Text('Dueño',
                                    style: TextStyle(fontSize: 10)),
                                visualDensity: VisualDensity.compact,
                              )
                            else if (esAdmin)
                              const Chip(
                                label: Text('Admin',
                                    style: TextStyle(fontSize: 10)),
                                visualDensity: VisualDensity.compact,
                              ),
                            if (bloqueado && !esDueno)
                              const Chip(
                                label: Text('Bloqueado',
                                    style: TextStyle(fontSize: 10)),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Último acceso: $ultimoRel',
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (dispositivo.isNotEmpty)
                              Text(
                                dispositivo,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppColores.textoSecundario(
                                        context)),
                              ),
                          ],
                        ),
                        onTap: () => _verHistorial(u),
                        trailing: esDueno
                            ? null
                            : PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'cambiar_rol') {
                                    _cambiarRol(username, rol);
                                    return;
                                  }
                                  if (v == 'foto') {
                                    _cambiarFoto(username);
                                    return;
                                  }
                                  if (v == 'historial') {
                                    _verHistorial(u);
                                    return;
                                  }
                                  final titulos = {
                                    'bloquear': 'Bloquear',
                                    'desbloquear': 'Desbloquear',
                                    'forzar_cierre':
                                        'Cerrar sesión a distancia',
                                    'reset_pass': 'Cambiar contraseña',
                                    'eliminar': 'Eliminar',
                                  };
                                  _accion(username, v, titulos[v] ?? v);
                                },
                                itemBuilder: (ctx) => [
                                  const PopupMenuItem(
                                    value: 'cambiar_rol',
                                    child: Text(
                                        'Cambiar rol (entrenador ↔ admin)'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'foto',
                                    child: Text('Cambiar foto'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'historial',
                                    child: Text('Ver historial de accesos'),
                                  ),
                                  if (!bloqueado)
                                    const PopupMenuItem(
                                      value: 'bloquear',
                                      child: Text('Bloquear'),
                                    ),
                                  if (bloqueado)
                                    const PopupMenuItem(
                                      value: 'desbloquear',
                                      child: Text('Desbloquear'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'forzar_cierre',
                                    child:
                                        Text('Cerrar sesión a distancia'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'reset_pass',
                                    child: Text('Cambiar contraseña'),
                                  ),
                                  PopupMenuItem(
                                    value: 'eliminar',
                                    child: Text('Eliminar',
                                        style: TextStyle(
                                            color: AppColores.error)),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
    );
  }
}
