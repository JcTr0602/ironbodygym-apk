/// Lista de clientes congelados (v1.0.9.1).
///
/// Los clientes congelados no aparecen en las listas normales (vencidos,
/// activos), por eso necesitan su propia pantalla para poder
/// descongelarlos.
library;

import 'package:flutter/material.dart';
import '../cliente_protegido.dart';
import '../errores_sync.dart';
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
import '../congelaciones_gestion.dart';
import '../tiempo.dart';

class CongeladosScreen extends StatefulWidget {
  const CongeladosScreen({super.key});

  @override
  State<CongeladosScreen> createState() =>
      _CongeladosScreenState();
}

class _CongeladosScreenState extends State<CongeladosScreen> {
  List<Map<String, dynamic>> _clientes = [];
  // (1.36 H-B4 136-879) pausa aprobada vigente por cliente.
  final Map<int, CongelacionGestion> _pausaPorCliente = {};
  bool _cargando = true;
  // (136-802) triestado de carga con EstadoError y reintento.
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    // Yunque Exhaustivo 1.35 (C-2): pantalla solo del dueño —
    // sin su sesión ni siquiera se dispara la carga (la lista
    // enseña quién está congelado y hasta cuándo).
    if (AuthService().isOwner) _cargar();
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
      if (mounted) setState(() => _errorCarga = mensajeErrorAmable(e));
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
    // (1.36 H-B4 136-879) pausas aprobadas del espejo de
    // congelaciones (si la lectura falla, la lista sigue
    // con el «Vence» de siempre).
    try {
      final esp = await CongelacionesService.instance.leerEspejo();
      if (esp.ok) {
        _pausaPorCliente.clear();
        for (final f in esp.datos) {
          if (f.esAprobada) _pausaPorCliente[f.clienteId] = f;
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _clientes = congelados;
        _errorCarga = null;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Yunque Exhaustivo 1.35 (C-2): autoprotección en el build,
    // como CongelacionesScreen — sin dueño, texto explicativo y
    // ningún dato, llegue la navegación de donde llegue (los
    // recientes de la Lupa eran la vía real).
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Congelados'),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'La lista de membresías congeladas solo la ve el '
              'dueño.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Congelados'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando congelados…')
          : _errorCarga != null
              ? EstadoError(
                  titulo: 'No se pudieron cargar los congelados',
                  detalle: _errorCarga,
                  onReintentar: () {
                    setState(() {
                      _errorCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
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
                      : RefrescoIron(
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
                                    // (1.36 H-B4 136-890) la
                                    // navegación vive en el
                                    // avatar y el título; la
                                    // tarjeta entera ya no
                                    // navega (Descongelar es la
                                    // acción secundaria, aparte
                                    // y confirmada).
                                    leading: InkWell(
                                      borderRadius:
                                          BorderRadius.circular(24),
                                      onTap: () => _abrirFicha(id),
                                      child: CircleAvatar(
                                        backgroundColor:
                                            AppColores.info
                                                .withValues(
                                                    alpha: 0.15),
                                        child: const Icon(
                                          Icons.ac_unit_rounded,
                                          color: AppColores.info,
                                        ),
                                      ),
                                    ),
                                    title: InkWell(
                                      onTap: () => _abrirFicha(id),
                                      child: Text(
                                        '${c['nombre'] ?? ''}',
                                        style: AppTexto.subtitulo,
                                      ),
                                    ),
                                    subtitle: Text(
                                      _subtituloPausa(c, id),
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

  void _abrirFicha(int id) {
    Navigator.push(
      context,
      RutaIron(builder: (_) => FichaScreen(clienteId: id)),
    ).then((_) => _cargar());
  }

  /// (1.36 H-B4 136-879) «Pausa hasta …» si la congelación
  /// aprobada está en curso; si no, el «Vence …» de siempre.
  String _subtituloPausa(Map<String, dynamic> c, int id) {
    final p = _pausaPorCliente[id];
    if (p != null && p.enCursoEn(ahoraHabana())) {
      final fin = p.finEfectivo;
      if (fin != null) {
        return 'Pausa hasta ${_fmtFecha(fin.toIso8601String())}';
      }
    }
    return 'Vence: ${_fmtFecha(c['pagado_hasta'] as String?)}';
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
    // (1.36 H-B4 136-878) éxito SOLO tras confirmar ambas
    // escrituras (encolar + espejo); un fallo se dice.
    try {
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
    } catch (e) {
      AppLog.error('congelados', 'descongelar_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context, 'No se pudo descongelar a $nombre: $e',
            significado: SignificadoChip.error);
      }
      return;
    }
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
