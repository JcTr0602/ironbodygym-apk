/// Papelera de reciclaje: clientes inactivos (2–3 meses sin ir).
/// Se pueden recuperar sin volver a inscribir desde cero.
///
/// Nota (punto 45): la app NO tiene botón de borrado definitivo; los
/// entrenadores solo pueden recuperar. Si se agrega un borrado definitivo
/// en el futuro, debe mostrarse únicamente si AuthService().isOwner.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'buscar.dart';
import 'componentes.dart';
import 'dialogo_pago.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class PapeleraScreen extends StatefulWidget {
  const PapeleraScreen({super.key});
  @override
  State<PapeleraScreen> createState() => _PapeleraScreenState();
}

class _PapeleraScreenState extends State<PapeleraScreen> {
  List<Map<String, dynamic>> _res = [];
  final Set<int> _seleccionados = {};
  StreamSubscription<SyncStatus>? _subSync;

  @override
  void initState() {
    super.initState();
    _cargar();
    // v1.3.5 (fix 2026-10-16): recargar cuando un ciclo de sync termina,
    // para que los tombstones aplicados se reflejen sin salir y entrar.
    _subSync = SyncEngine.instance.statusStream.listen((s) {
      if (!mounted) return;
      if (s.phase == SyncPhase.idle) _cargar();
    });
  }

  @override
  void dispose() {
    _subSync?.cancel();
    super.dispose();
  }

  Future<void> _cargar() async {
    final r = await clientesInactivos();
    // v1.3.5 (fix 2026-10-16): filtro anti-zombie. Si un pull intermedio
    // re-inserta un cliente con op eliminar_cliente en vuelo ('pendiente'
    // o 'enviada'), no debe revivir ante los ojos del usuario.
    final zombies = await LocalDb.instance.clientesConBorradoEnVuelo();
    final filtrados = r
        .where((c) => !zombies.contains((c['id'] as int?) ?? 0))
        .toList();
    if (mounted) setState(() => _res = filtrados);
  }

  Future<void> _recuperar(Map<String, dynamic> c) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Recuperar cliente',
      mensaje:
          '¿Reactivar a ${c['nombre']}? Volverá a aparecer en las listas.',
      aceptar: 'Recuperar',
      icono: Icons.restore_from_trash,
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': (c['id'] as int?) ?? 0,
        'estado': 'activo'
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${c['nombre']} recuperado')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Recupera y de una vez registra la renovación (punto 30).
  Future<void> _recuperarYRenovar(Map<String, dynamic> c) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Recuperar y renovar',
      mensaje:
          '¿Reactivar a ${c['nombre']} y registrar su pago ahora?',
      aceptar: 'Continuar',
      icono: Icons.autorenew,
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': (c['id'] as int?) ?? 0,
        'estado': 'activo'
      },
    );
    if (!mounted) return;
    final payload =
        await pagoDialogo(context, {...c, 'estado': 'activo'});
    if (payload == null || !mounted) {
      _cargar();
      SyncEngine.instance.push();
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${c['nombre']} renovado')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Elimina definitivamente los seleccionados (solo dueño, v1.0.7).
  /// Requiere doble confirmación.
  Future<void> _eliminarDefinitivo() async {
    if (_seleccionados.isEmpty) return;
    final nombres = _res
        .where((c) => _seleccionados.contains((c['id'] as int?) ?? 0))
        .map((c) => c['nombre'] as String)
        .take(3)
        .join(', ');
    final mas = _seleccionados.length > 3
        ? ' y ${_seleccionados.length - 3} más'
        : '';
    // Primera confirmación
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Eliminar definitivamente',
      mensaje: '¿Borrar PARA SIEMPRE a $nombres$mas?\n\n'
          'Esta acción no se puede deshacer. Solo el dueño puede hacerlo.',
      aceptar: 'Eliminar para siempre',
      icono: Icons.delete_forever,
      peligro: true,
    );
    if (ok != true || !mounted) return;
    // Segunda confirmación
    final ok2 = await DialogoApp.confirmar(
      context,
      titulo: '¿Seguro?',
      mensaje:
          'Última oportunidad. Los datos se borrarán permanentemente.',
      aceptar: 'Sí, eliminar',
      icono: Icons.warning,
      peligro: true,
    );
    if (ok2 != true || !mounted) return;
    // v1.3.5 (fix 2026-10-16): borrado optimista atómico. Se encola la op
    // y se borra el espejo local en la MISMA transacción: la UI refleja
    // el borrado de inmediato sin esperar el viaje
    // push → servidor → puente → Supabase → pull (varios minutos).
    // Los pagos NO se tocan en local: los borra el servidor y bajan por
    // sus tombstones (si la op se rechazara, el pull no restauraría
    // pagos borrados localmente porque su sync_seq no cambió).
    final db = await LocalDb.instance.db;
    await db.transaction((txn) async {
      for (final id in _seleccionados) {
        await LocalDb.instance.queueOp(
          opUuid: const Uuid().v4(),
          tipo: 'eliminar_cliente',
          payload: {'cliente_id': id, 'definitivo': true},
          txn: txn,
        );
        await LocalDb.instance.deleteMirror('clientes', id, txn: txn);
      }
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${_seleccionados.length} eliminados definitivamente')));
    setState(() => _seleccionados.clear());
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    final esDueno = AuthService().isOwner;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Papelera'),
        actions: _seleccionados.isNotEmpty
            ? [
                TextButton(
                  onPressed: () =>
                      setState(() => _seleccionados.clear()),
                  // Hereda el blanco del AppBarTheme (oscuro en ambos temas).
                  child: const Text('Limpiar'),
                ),
              ]
            : null,
      ),
      body: Column(
        children: [
          const SyncBanner(alcance: 'papelera'),
          Padding(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: Text(
              'Clientes inactivos. Al recuperarlos no hay que inscribirlos de nuevo.',
              style: AppTexto.secundario.copyWith(
                  color:
                      AppColores.textoSecundario(context)),
              textAlign: TextAlign.center,
            ),
          ),
          if (_seleccionados.isNotEmpty)
            Container(
              color: AppColores.naranja
                  .withValues(alpha: 0.12),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.lg,
                  vertical: AppEspacio.sm),
              child: Row(
                children: [
                  Text('${_seleccionados.length} seleccionados',
                      style: AppTexto.subtitulo),
                  const Spacer(),
                  if (esDueno)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.delete_forever,
                          size: 18),
                      label: const Text('Eliminar'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor:
                              AppColores.error,
                          foregroundColor: Colors.white),
                      onPressed: _eliminarDefinitivo,
                    ),
                ],
              ),
            ),
          Expanded(
            child: _res.isEmpty
                ? const EstadoVacio(
                    icono: Icons.delete_outline,
                    titulo: 'Papelera vacía',
                  )
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView.builder(
                      itemCount: _res.length,
                      itemBuilder: (ctx, i) {
                        final c = _res[i];
                        final id = (c['id'] as int?) ?? 0;
                        final seleccionado =
                            _seleccionados.contains(id);
                        return FilaCliente(
                          cliente: c,
                          onTap: () {
                            // Toque simple: abre ficha. Toque con selección activa: alterna.
                            if (_seleccionados.isNotEmpty) {
                              setState(() {
                                if (seleccionado) {
                                  _seleccionados.remove(id);
                                } else {
                                  _seleccionados.add(id);
                                }
                              });
                            } else {
                              Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          FichaScreen(clienteId: id)));
                            }
                          },
                          onLongPress: () {
                            // Mantener presionado inicia la selección múltiple
                            setState(() {
                              if (seleccionado) {
                                _seleccionados.remove(id);
                              } else {
                                _seleccionados.add(id);
                              }
                            });
                          },
                          leading: Checkbox(
                            value: seleccionado,
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _seleccionados.add(id);
                                } else {
                                  _seleccionados.remove(id);
                                }
                              });
                            },
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                child: const Icon(
                                    Icons.restore_from_trash),
                                onPressed: () =>
                                    _recuperar(c),
                              ),
                              TextButton(
                                child: const Text('Renovar'),
                                onPressed: () =>
                                    _recuperarYRenovar(c),
                              ),
                            ],
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
}
