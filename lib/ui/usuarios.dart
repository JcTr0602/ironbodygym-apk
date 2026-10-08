import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../sync.dart';

/// Gestión de usuarios APK (v1.0.12).
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
      String username, String accion, String titulo) async {
    if (accion == 'eliminar') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠️ Eliminar usuario'),
          content: Text(
              '¿Eliminar a "$username"? Perderá acceso inmediatamente.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Eliminar')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    String? password;
    if (accion == 'reset_pass') {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('🔑 Nueva contraseña para $username'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(
              labelText: 'Contraseña (mín. 6)',
              border: OutlineInputBorder(),
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
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'admin_usuario',
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ "$titulo" encolado para $username')),
    );
    SyncEngine.instance.push();
  }

  Future<void> _crear() async {
    final nombreCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('👤 Crear usuario APK'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nombreCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nombre de usuario',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Contraseña (mín. 6)',
                    border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
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
        const SnackBar(content: Text('✅ Usuario encolado (se sincronizará)')));
    SyncEngine.instance.push();
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('👥 Usuarios APK'),
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
              ? const Center(
                  child: Text(
                    'Sin datos.\nSincroniza para ver la lista.',
                    textAlign: TextAlign.center,
                  ),
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
                      final ultimo =
                          '${u['ultimo_acceso'] ?? ''}'.substring(0, 10);
                      final esDueno = username.toLowerCase() == 'jctr0602';
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: bloqueado
                              ? Colors.red.shade100
                              : Colors.green.shade100,
                          child: Text(
                            username.isNotEmpty
                                ? username[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: bloqueado
                                  ? Colors.red.shade800
                                  : Colors.green.shade800,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Row(
                          children: [
                            Expanded(child: Text(username)),
                            if (esDueno)
                              const Chip(
                                label: Text('👑 Dueño',
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
                        subtitle: Text(
                          ultimo.isNotEmpty && ultimo.length >= 10
                              ? 'Último acceso: $ultimo'
                              : 'Sin accesos registrados',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: esDueno
                            ? null
                            : PopupMenuButton<String>(
                                onSelected: (v) {
                                  final titulos = {
                                    'bloquear': 'Bloquear',
                                    'desbloquear': 'Desbloquear',
                                    'reset_pass': 'Cambiar contraseña',
                                    'eliminar': 'Eliminar',
                                  };
                                  _accion(username, v, titulos[v] ?? v);
                                },
                                itemBuilder: (ctx) => [
                                  if (!bloqueado)
                                    const PopupMenuItem(
                                      value: 'bloquear',
                                      child: Text('🚫 Bloquear'),
                                    ),
                                  if (bloqueado)
                                    const PopupMenuItem(
                                      value: 'desbloquear',
                                      child: Text('✅ Desbloquear'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'reset_pass',
                                    child: Text('🔑 Cambiar contraseña'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'eliminar',
                                    child: Text('🗑️ Eliminar',
                                        style:
                                            TextStyle(color: Colors.red)),
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
