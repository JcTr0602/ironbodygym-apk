/// Panel de Accesos a la App de Clientes (v1.3.9, F2/F8).
/// Solo dueño. Tarjetas de estadísticas arriba + lista de accesos.
/// Todos los sub-indicadores filtran sobre activo == true (Argón).
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'modal_pin_acceso.dart';
import 'widgets.dart';

class PanelAccesosScreen extends StatefulWidget {
  const PanelAccesosScreen({super.key});
  @override
  State<PanelAccesosScreen> createState() =>
      _PanelAccesosScreenState();
}

class _PanelAccesosScreenState extends State<PanelAccesosScreen> {
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    final ok = await AccesoAppCache.instance.cargar();
    if (mounted) {
      setState(() {
        _cargando = false;
        if (!ok) _error = 'Sin conexión. No se pudo cargar la lista.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accesos App'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
            tooltip: 'Recargar',
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            child: _cargando
                ? const Center(
                    child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize:
                              MainAxisSize.min,
                          children: [
                            Text(_error!,
                                style:
                                    AppTexto.secundario),
                            const SizedBox(
                                height: AppEspacio.md),
                            FilledButton.icon(
                              icon: const Icon(
                                  Icons.refresh,
                                  size: 18),
                              label: const Text(
                                  'Reintentar'),
                              onPressed: _cargar,
                            ),
                          ],
                        ),
                      )
                    : _contenido(),
          ),
        ],
      ),
    );
  }

  Widget _contenido() {
    final todos =
        AccesoAppCache.instance.todos ?? [];

    // Semántica exacta (Argón): todo filtra sobre activo == true.
    final activos =
        todos.where((a) => a.activo).toList();
    final ahora = DateTime.now();
    final nuncaEntraron = activos
        .where((a) => a.ultimoAccesoEn == null)
        .length;
    final ultimos7 = activos
        .where((a) =>
            a.ultimoAccesoEn != null &&
            ahora
                    .difference(a.ultimoAccesoEn!)
                    .inDays <
                7)
        .length;
    final bloqueados =
        activos.where((a) => a.estaBloqueado).length;

    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        // Tarjetas de estadísticas.
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppEspacio.sm,
          crossAxisSpacing: AppEspacio.sm,
          childAspectRatio: 1.6,
          children: [
            _tarjetaStat('Activos', '${activos.length}',
                Icons.check_circle, Colors.green),
            _tarjetaStat('Nunca han entrado',
                '$nuncaEntraron', Icons.login, Colors.grey),
            _tarjetaStat('Últimos 7 días', '$ultimos7',
                Icons.schedule, Colors.blue),
            _tarjetaStat('Bloqueados', '$bloqueados',
                Icons.lock, Colors.amber[700]!),
          ],
        ),
        const SizedBox(height: AppEspacio.lg),
        Text('Todos los accesos (${todos.length})',
            style: AppTexto.titulo),
        const SizedBox(height: AppEspacio.sm),
        if (todos.isEmpty)
          const Text(
              'Aún no hay accesos generados.',
              style: AppTexto.secundario),
        for (final a in todos) _filaAcceso(a),
      ],
    );
  }

  Widget _tarjetaStat(
      String etiqueta, String valor, IconData icono, Color color) {
    return Tarjeta(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icono, color: color, size: 24),
          const SizedBox(height: 4),
          Text(valor,
              style: AppTexto.titulo.copyWith(fontSize: 22)),
          Text(etiqueta,
              style: AppTexto.secundario,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _filaAcceso(AccesoCliente a) {
    final estadoChip = !a.activo
        ? Chip(
            label: const Text('Revocado',
                style: TextStyle(
                    color: Colors.white, fontSize: 12)),
            backgroundColor: Colors.grey[600],
          )
        : a.estaBloqueado
            ? Chip(
                label: const Text('Bloqueado',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12)),
                backgroundColor: Colors.amber[700],
              )
            : Chip(
                label: const Text('Activo',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12)),
                backgroundColor: Colors.green[600],
              );

    final ultimo = a.ultimoAccesoEn == null
        ? 'Nunca'
        : 'Último: ${a.ultimoAccesoEn!.day}/${a.ultimoAccesoEn!.month}';

    return Tarjeta(
      child: InkWell(
        // v1.3.9 (ajuste Argón): esperar el retorno y repintar —
        // si se generó/revocó un PIN en la ficha, el panel se actualiza.
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  FichaScreen(clienteId: a.clienteId),
            ),
          );
          if (mounted) setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.sm),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(a.nombre,
                        style: AppTexto.cuerpo.copyWith(
                            fontWeight:
                                FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('${a.telefono} · $ultimo',
                        style: AppTexto.secundario),
                  ],
                ),
              ),
              estadoChip,
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (v) {
                  if (v == 'regenerar') {
                    _regenerarDesdePanel(a);
                  } else if (v == 'revocar') {
                    _revocarDesdePanel(a);
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'regenerar',
                    child: Text('Regenerar PIN'),
                  ),
                  // v1.3.9 (ajuste Argón): revocar solo si está activo.
                  if (a.activo)
                    const PopupMenuItem(
                      value: 'revocar',
                      child: Text('Revocar acceso',
                          style:
                              TextStyle(color: Colors.red)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _regenerarDesdePanel(AccesoCliente a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerar PIN'),
        content: Text(
            'Se generará un nuevo PIN para ${a.nombre}. El anterior quedará invalidado.'),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(true),
              child: const Text('Generar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await Supabase.instance.client
          .rpc('generar_acceso_cliente', params: {
        'p_cliente_id': a.clienteId,
        'p_creado_por': AuthService().username,
      });
      final data = Map<String, dynamic>.from(res as Map);
      final pin = '${data['pin_temporal'] ?? ''}';
      if (pin.isEmpty) throw 'El servidor no devolvió el PIN';
      // Invalidación inmediata del caché (Argón).
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        setState(() {});
        // v1.3.9 (ajuste Argón): modal seguro en vez de SnackBar fugaz.
        mostrarModalPin(context, pin, a.telefono, a.nombre);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _revocarDesdePanel(AccesoCliente a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revocar acceso'),
        content: Text(
            'Se desactivará el acceso de ${a.nombre}. ¿Continuar?'),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.red),
              onPressed: () =>
                  Navigator.of(ctx).pop(true),
              child: const Text('Revocar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Supabase.instance.client
          .rpc('revocar_acceso_cliente', params: {
        'p_cliente_id': a.clienteId,
      });
      // v1.3.9 (ajuste Argón): recargar en vez de eliminar del caché —
      // el servidor pone activo=false, no borra el registro.
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Acceso revocado')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }
}
