/// Lista de clientes congelados (v1.0.9.1).
///
/// Los clientes congelados no aparecen en las listas normales (vencidos,
/// activos), por eso necesitan su propia pantalla para poder
/// descongelarlos.
library;

import 'package:flutter/material.dart';
import '../cliente_protegido.dart';
import '../negocio.dart';

import '../auth.dart';
import '../localdb.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';
import 'package:uuid/uuid.dart';
import '../app_log.dart';

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
    setState(() => _cargando = true);
    final todos = await LocalDb.instance.allMirror('clientes');
    final congelados = todos
        .where((c) =>
            '${c['estado'] ?? 'activo'}' == 'congelado' &&
            !esVistaProtegida(c))
        .toList();
    congelados.sort(compararPorNombre);
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
      appBar: appBarIron(context, 'Congelados'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando congelados…')
          : Column(
              children: [
                const SyncBanner(),
                Expanded(
                  child: _clientes.isEmpty
                      ? const EstadoVacio(
                          icono: Icons.ac_unit_rounded,
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
                                        Icons.ac_unit_rounded,
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
                                    // Yunque 2.34 (D-2): el
                                    // botón solo se ofrece al
                                    // dueño (ver _descongelar).
                                    trailing: AuthService().isOwner
                                        ? TextButton.icon(
                                            icon: const Icon(
                                                Icons
                                                    .play_arrow_rounded,
                                                size: 18),
                                            label: const Text(
                                                'Descongelar'),
                                            onPressed: () =>
                                                _descongelar(id,
                                                    '${c['nombre']}'),
                                          )
                                        : null,
                                    onTap: () => Navigator.push(
                                      context,
                                      RutaIron(
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
    // Yunque 2.34 (D-2): esta vía legada encola
    // cambiar_estado, SOLO del dueño en el servidor — la
    // pantalla no tenía puerta de rol propia (la de la ficha
    // de C5-4 no la cubre). El entrenador descongela por el
    // sistema nuevo de pausas, no desde esta lista.
    if (!AuthService().isOwner) {
      if (!mounted) return;
      mostrarSnack(context,
          'Descongelar desde esta lista es solo del dueño.',
          significado: SignificadoChip.alerta);
      return;
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Descongelar membresía',
      mensaje: '¿Descongelar a $nombre?\n\n'
          'Volverá a aparecer en las listas normales.',
      aceptar: 'Descongelar',
      icono: Icons.play_arrow_rounded,
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
      mostrarSnack(context, '$nombre descongelado', significado: SignificadoChip.exito);
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
