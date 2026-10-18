// lib/ui/dashboard_adopcion.dart
// v1.3.9 Sprint 1 (#1): dashboard de adopción de la app de clientes.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../acceso_app_cache.dart';
import '../auth.dart';
import 'modal_pin_acceso.dart';

class ClienteSinAcceso {
  final String clienteId;
  final String nombre;
  final String telefono;

  ClienteSinAcceso({
    required this.clienteId,
    required this.nombre,
    required this.telefono,
  });
}

class DashboardAdopcion extends StatefulWidget {
  const DashboardAdopcion({super.key});

  @override
  State<DashboardAdopcion> createState() =>
      _DashboardAdopcionState();
}

class _DashboardAdopcionState extends State<DashboardAdopcion> {
  bool _cargando = true;
  int _totalGenerados = 0;
  int _activos = 0;
  int _conectados7d = 0;
  List<ClienteSinAcceso> _sinAcceso = [];
  List<ClienteSinAcceso> _filtrados = [];
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
    _searchCtrl.addListener(_filtrar);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Normaliza texto (sin tildes, minúsculas) — reutilizado de papelera.dart
  String _normalizar(String s) {
    var n = s.toLowerCase();
    n = n.replaceAll(RegExp(r'[áàäâ]'), 'a');
    n = n.replaceAll(RegExp(r'[éèëê]'), 'e');
    n = n.replaceAll(RegExp(r'[íìïî]'), 'i');
    n = n.replaceAll(RegExp(r'[óòöô]'), 'o');
    n = n.replaceAll(RegExp(r'[úùüû]'), 'u');
    n = n.replaceAll('ñ', 'n');
    return n;
  }

  void _filtrar() {
    final q = _normalizar(_searchCtrl.text.trim());
    setState(() {
      if (q.isEmpty) {
        _filtrados = List.from(_sinAcceso);
      } else {
        _filtrados = _sinAcceso.where((c) {
          return _normalizar(c.nombre).contains(q) ||
              c.telefono.replaceAll(RegExp(r'[^0-9]'), '').contains(
                  q.replaceAll(RegExp(r'[^0-9]'), ''));
        }).toList();
      }
    });
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final client = Supabase.instance.client;

      // Métricas vía RPC (Argón: privado.cliente_app_accesos no es
      // accesible por PostgREST directo)
      var total = 0;
      var activos = 0;
      var conectados = 0;
      final hace7d =
          DateTime.now().subtract(const Duration(days: 7));

      try {
        // Usar el RPC existente que sí tiene SECURITY DEFINER sobre
        // privado.cliente_app_accesos
        final accesosRes =
            await client.rpc('listar_accesos_clientes');
        final lista = (accesosRes as List?) ?? [];
        total = lista.length;
        for (final e in lista) {
          final m = Map<String, dynamic>.from(e as Map);
          if (m['activo'] == true) activos++;
          final ua = m['ultimo_acceso_en'];
          if (ua != null) {
            final dt = DateTime.tryParse(ua.toString());
            if (dt != null && dt.isAfter(hace7d)) conectados++;
          }
        }
      } catch (_) {
        // Fallback real al caché local si falla
        await AccesoAppCache.instance.cargar();
      }

      // Clientes sin acceso (RPC)
      final sinAccesoRes =
          await client.rpc('clientes_sin_acceso');
      final sinAcceso = ((sinAccesoRes as List?) ?? []).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return ClienteSinAcceso(
          clienteId: m['cliente_id']?.toString() ?? '',
          nombre: m['nombre']?.toString() ?? '',
          telefono: m['telefono']?.toString() ?? '',
        );
      }).toList();

      if (mounted) {
        setState(() {
          _totalGenerados = total;
          _activos = activos;
          _conectados7d = conectados;
          _sinAcceso = sinAcceso;
          _filtrados = List.from(sinAcceso);
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  /// Al generar PIN exitosamente, sacar de la lista (Argón)
  void _removerDeLista(String clienteId) {
    setState(() {
      _sinAcceso.removeWhere((c) => c.clienteId == clienteId);
      _filtrar();
      _totalGenerados++;
      _activos++; // Un PIN recién generado nace activo
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adopción App Clientes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Tarjetas de métricas
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      _buildMetrica(
                          'Generados', _totalGenerados, Colors.blue),
                      const SizedBox(width: 8),
                      _buildMetrica(
                          'Activos', _activos, Colors.green),
                      const SizedBox(width: 8),
                      _buildMetrica('En 7 días', _conectados7d,
                          Colors.orange),
                    ],
                  ),
                ),
                // Búsqueda
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText:
                          'Buscar cliente sin PIN...',
                      prefixIcon:
                          const Icon(Icons.search),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon:
                                  const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        '${_filtrados.length} sin PIN',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Lista
                Expanded(
                  child: _filtrados.isEmpty
                      ? const Center(
                          child: Text(
                              'Todos tienen acceso. ¡Buen trabajo!'))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16),
                          itemCount: _filtrados.length,
                          itemBuilder: (ctx, i) {
                            final c = _filtrados[i];
                            return Card(
                              child: ListTile(
                                title: Text(c.nombre,
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.w600)),
                                subtitle: Text(c.telefono.isNotEmpty
                                    ? c.telefono
                                    : 'Sin teléfono'),
                                trailing: TextButton(
                                  onPressed: () =>
                                      _generarPin(c),
                                  child: const Text(
                                      'GENERAR PIN'),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildMetrica(String titulo, int valor, Color color) {
    return Expanded(
      child: Card(
        color: color.withOpacity(0.1),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(
                '$valor',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
              Text(
                titulo,
                style: const TextStyle(fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _generarPin(ClienteSinAcceso cli) async {
    // Confirmar antes de generar
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generar PIN'),
        content: Text(
            'Generar acceso para ${cli.nombre}?'),
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
        'p_cliente_id': int.tryParse(cli.clienteId) ?? 0,
        'p_creado_por': AuthService().username,
      });
      final data = Map<String, dynamic>.from(res as Map);
      final pin = '${data['pin_temporal'] ?? ''}';
      if (pin.isEmpty) throw 'El servidor no devolvió el PIN';
      // Invalidación inmediata del caché
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        mostrarModalPin(context, pin, cli.telefono, cli.nombre);
        _removerDeLista(cli.clienteId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }
}
