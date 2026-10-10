/// ⚙️ Mis avisos: configuración de notificaciones de la app.
/// Permite activar/desactivar tipos de avisos.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import 'diseno.dart';
import 'widgets.dart';

class AvisosScreen extends StatefulWidget {
  const AvisosScreen({super.key});
  @override
  State<AvisosScreen> createState() => _AvisosScreenState();
}

class _AvisosScreenState extends State<AvisosScreen> {
  bool _vencimientos = true;
  bool _cumpleanos = true;
  bool _sync = true;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final v = await LocalDb.instance.getMeta('aviso_vencimientos');
    final c = await LocalDb.instance.getMeta('aviso_cumpleanos');
    final s = await LocalDb.instance.getMeta('aviso_sync');
    if (mounted) {
      setState(() {
        _vencimientos = v != '0';
        _cumpleanos = c != '0';
        _sync = s != '0';
        _cargando = false;
      });
    }
  }

  Future<void> _guardar(String clave, bool valor) async {
    await LocalDb.instance.setMeta(clave, valor ? '1' : '0');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mis avisos')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const SyncBanner(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        'Elige qué avisos quieres recibir en la app.',
                        style: AppTexto.secundario.copyWith(
                            color: AppColores.textoSecundario(context)),
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        secondary: const Icon(Icons.schedule_outlined),
                        title: const Text('Vencimientos'),
                        subtitle: const Text(
                            'Avisar cuando haya clientes por vencer o vencidos'),
                        value: _vencimientos,
                        onChanged: (v) {
                          setState(() => _vencimientos = v);
                          _guardar('aviso_vencimientos', v);
                        },
                      ),
                      const Divider(),
                      SwitchListTile(
                        secondary: const Icon(Icons.cake_outlined),
                        title: const Text('Cumpleaños'),
                        subtitle: const Text(
                            'Avisar de los cumpleaños del mes'),
                        value: _cumpleanos,
                        onChanged: (v) {
                          setState(() => _cumpleanos = v);
                          _guardar('aviso_cumpleanos', v);
                        },
                      ),
                      const Divider(),
                      SwitchListTile(
                        secondary: const Icon(Icons.sync_outlined),
                        title: const Text('Sincronización'),
                        subtitle: const Text(
                            'Avisar cuando haya pendientes por sincronizar'),
                        value: _sync,
                        onChanged: (v) {
                          setState(() => _sync = v);
                          _guardar('aviso_sync', v);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
