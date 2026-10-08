/// Auditoría básica: quién hizo qué y cuándo.
/// Muestra las operaciones recientes con el usuario que las realizó.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';

class AuditoriaScreen extends StatefulWidget {
  const AuditoriaScreen({super.key});

  @override
  State<AuditoriaScreen> createState() => _AuditoriaScreenState();
}

class _AuditoriaScreenState extends State<AuditoriaScreen> {
  List<Map<String, dynamic>> _ops = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    // Obtiene las ops recientes con info del usuario
    final ops = await LocalDb.instance.recentOps(limit: 100);
    if (mounted) {
      setState(() {
        _ops = ops;
        _cargando = false;
      });
    }
  }

  String _nombreTipo(String tipo) {
    switch (tipo) {
      case 'inscribir':
        return '📝 Inscripción';
      case 'pago_mensual':
        return '💰 Pago mensual';
      case 'pago_diario':
        return '💵 Pago diario';
      case 'cambiar_estado':
        return '🔄 Cambio de estado';
      case 'foto':
        return '📷 Foto';
      case 'gasto':
        return '🧾 Gasto';
      default:
        return tipo;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📋 Auditoría'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _ops.isEmpty
              ? const Center(child: Text('Sin operaciones registradas'))
              : RefreshIndicator(
                  onRefresh: _cargar,
                  child: ListView.builder(
                    itemCount: _ops.length,
                    itemBuilder: (ctx, i) {
                      final op = _ops[i];
                      final tipo = '${op['tipo']}';
                      final estado = '${op['estado']}';
                      final fecha =
                          '${op['creada_ts']}'.substring(0, 16).replaceAll('T', ' ');
                      // El usuario está en el payload o en device_tag
                      final payload = op['payload'] as String? ?? '{}';
                      String usuario = 'Desconocido';
                      try {
                        // Intenta extraer el usuario del payload
                        if (payload.contains('registrado_por')) {
                          final m = RegExp(r'"registrado_por"\s*:\s*"([^"]+)"')
                              .firstMatch(payload);
                          if (m != null) usuario = m.group(1)!;
                        }
                      } catch (_) {}

                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(
                              usuario.isNotEmpty
                                  ? usuario[0].toUpperCase()
                                  : '?',
                            ),
                          ),
                          title: Text(_nombreTipo(tipo)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('👤 $usuario'),
                              Text('📅 $fecha'),
                              Text(
                                'Estado: $estado',
                                style: TextStyle(
                                  color: estado == 'aplicada'
                                      ? Colors.green
                                      : estado == 'rechazada'
                                          ? Colors.red
                                          : Colors.orange,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
