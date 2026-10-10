/// Lista de clientes congelados (v1.0.9.1).
///
/// Los clientes congelados no aparecen en las listas normales (vencidos,
/// activos), por eso necesitan su propia pantalla para poder
/// descongelarlos.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';
import 'package:uuid/uuid.dart';

class CongeladosScreen extends StatefulWidget {
  const CongeladosScreen({super.key});

  @override
  State<CongeladosScreen> createState() =>
      _CongeladosScreenState();
}

class _CongeladosScreenState extends State<CongeladosScreen> {
  List<Map<String, dynamic>> _clientes = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final todos = await LocalDb.instance.allMirror('clientes');
    final congelados = todos
        .where((c) => '${c['estado'] ?? 'activo'}' == 'congelado')
        .toList();
    congelados.sort((a, b) =>
        '${a['nombre']}'.compareTo('${b['nombre']}'));
    if (mounted) {
      setState(() {
        _clientes = congelados;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Congelados')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const SyncBanner(),
                Expanded(
                  child: _clientes.isEmpty
                      ? const EstadoVacio(
                          icono: Icons.ac_unit,
                          titulo:
                              'No hay clientes congelados',
                          subtitulo:
                              'Desde la ficha de un cliente puedes '
                              'congelar su membresía para pausar el '
                              'vencimiento.',
                        )
                      : RefreshIndicator(
                          onRefresh: _cargar,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppEspacio.md,
                                vertical: AppEspacio.sm),
                            itemCount: _clientes.length,
                            itemBuilder: (ctx, i) {
                              final c = _clientes[i];
                              final id =
                                  (c['id'] as int?) ?? 0;
                              return Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppEspacio.sm),
                                child: Tarjeta(
                                  padding: EdgeInsets.zero,
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor:
                                          AppColores.info
                                              .withValues(
                                                  alpha: 0.15),
                                      child: const Icon(
                                        Icons.ac_unit,
                                        color: AppColores.info,
                                      ),
                                    ),
                                    title: Text(
                                      '${c['nombre'] ?? ''}',
                                      style: AppTexto.subtitulo,
                                    ),
                                    subtitle: Text(
                                      'Vence: ${_fmtFecha(c['pagado_hasta'] as String?)}',
                                      style: AppTexto.secundario
                                          .copyWith(
                                        color: AppColores
                                            .textoSecundario(
                                                context),
                                      ),
                                    ),
                                    trailing: TextButton.icon(
                                      icon: const Icon(
                                          Icons.play_arrow,
                                          size: 18),
                                      label: const Text(
                                          'Descongelar'),
                                      onPressed: () =>
                                          _descongelar(id,
                                              '${c['nombre']}'),
                                    ),
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              FichaScreen(
                                                  clienteId:
                                                      id)),
                                    ).then((_) => _cargar()),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Future<void> _descongelar(int id, String nombre) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Descongelar membresía',
      mensaje: '¿Descongelar a $nombre?\n\n'
          'Volverá a aparecer en las listas normales.',
      aceptar: 'Descongelar',
      icono: Icons.play_arrow,
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': id,
        'estado': 'activo',
      },
    );
    // Actualización optimista del espejo local
    await LocalDb.instance.updateMirrorEstado(id, 'activo');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$nombre descongelado')),
      );
      _cargar();
    }
  }

  String _fmtFecha(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    try {
      final d = DateTime.parse(iso);
      return '${d.day.toString().padLeft(2, '0')}/'
          '${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) {
      return iso;
    }
  }
}
