/// 🎂 Cumpleaños de la semana: la fecha de nacimiento sale del carnet
/// de identidad del cliente (6 primeros dígitos = AAMMDD).
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import 'buscar.dart';
import 'ficha.dart';
import 'widgets.dart';

class CumpleanosScreen extends StatefulWidget {
  const CumpleanosScreen({super.key});
  @override
  State<CumpleanosScreen> createState() => _CumpleanosScreenState();
}

class _CumpleanosScreenState extends State<CumpleanosScreen> {
  List<Map<String, dynamic>> _res = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final r = await cumpleanosProximos(dias: 7);
    if (mounted) setState(() => _res = r);
  }

  String _cuando(int d) {
    if (d == 0) return '¡Hoy! 🎉';
    if (d == 1) return 'Mañana';
    return 'En $d días';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🎂 Cumpleaños de la semana')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _res.isEmpty
                ? const Center(
                    child: Text(
                        'Sin cumpleaños esta semana.\n'
                        'La fecha sale del carnet de identidad.',
                        textAlign: TextAlign.center))
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView.builder(
                      itemCount: _res.length,
                      itemBuilder: (ctx, i) {
                        final c = _res[i];
                        final d = c['_dias_para'] as int? ?? 0;
                        return FilaCliente(
                          cliente: c,
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) => FichaScreen(
                                      clienteId:
                                          (c['id'] as int?) ?? 0)))
                              .then((_) => _cargar()),
                          trailing: Column(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            crossAxisAlignment:
                                CrossAxisAlignment.end,
                            children: [
                              Text(_cuando(d),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              Text('Cumple ${c['_cumple']}',
                                  style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12)),
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
