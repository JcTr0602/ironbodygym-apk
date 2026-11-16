/// ⚙️ Mis avisos: configuración de notificaciones de la app.
/// Permite activar/desactivar tipos de avisos.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import 'app_bar.dart';
import 'diseno.dart';
import 'widgets.dart';
import 'componentes.dart';
import '../app_log.dart';

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
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
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

  /// SL-10 G04-8: el interruptor solo cambia en
  /// pantalla cuando el guardado ATERRIZA; si setMeta
  /// falla, el estado visible no se mueve y se avisa
  /// (antes quedaba «activado» sin estarlo, en silencio).
  Future<void> _guardar(
      String clave, bool valor, void Function(bool) aplicar) async {
    try {
      await LocalDb.instance.setMeta(clave, valor ? '1' : '0');
      if (mounted) setState(() => aplicar(valor));
    } catch (e) {
      AppLog.error('avisos', 'guardar_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(
            context, 'No se pudo guardar el cambio. Inténtalo de nuevo.',
            significado: SignificadoChip.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Mis avisos'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando avisos…')
          : Column(
              children: [
                const SyncBanner(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    children: [
                      Text(
                        'Elige qué avisos quieres recibir en la app.',
                        style: AppTexto.secundario.copyWith(
                            color: AppColores.textoSecundario(context)),
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        secondary: const Icon(Icons.schedule_rounded),
                        title: const Text('Vencimientos'),
                        subtitle: const Text(
                            'Avisar cuando haya clientes por vencer o vencidos'),
                        value: _vencimientos,
                        onChanged: (v) => _guardar(
                            'aviso_vencimientos', v,
                            (nv) => _vencimientos = nv),
                      ),
                      const Divider(),
                      SwitchListTile(
                        secondary: const Icon(Icons.cake_rounded),
                        title: const Text('Cumpleaños'),
                        subtitle: const Text(
                            'Avisar de los cumpleaños del mes'),
                        value: _cumpleanos,
                        onChanged: (v) => _guardar(
                            'aviso_cumpleanos', v,
                            (nv) => _cumpleanos = nv),
                      ),
                      const Divider(),
                      SwitchListTile(
                        secondary: const Icon(Icons.sync_rounded),
                        title: const Text('Sincronización'),
                        subtitle: const Text(
                            'Avisar cuando haya pendientes por sincronizar'),
                        value: _sync,
                        onChanged: (v) => _guardar(
                            'aviso_sync', v, (nv) => _sync = nv),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
