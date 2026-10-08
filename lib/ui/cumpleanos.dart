/// 🎂 Cumpleaños del mes: la fecha de nacimiento sale del carnet
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
  bool _cargando = true;

  static const _meses = [
    '',
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre'
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final r = await cumpleanosDelMes();
    if (mounted) {
      setState(() {
        _res = r;
        _cargando = false;
      });
    }
  }

  String _etiqueta(Map<String, dynamic> c) {
    final hoy = DateTime.now();
    final dia = c['_dia'] as int? ?? 0;
    if (dia == hoy.day) return '¡Hoy! 🎉';
    if (c['_paso'] == true) return 'Ya cumplió';
    return 'Día $dia';
  }

  @override
  Widget build(BuildContext context) {
    final mes = _meses[DateTime.now().month];
    return Scaffold(
      appBar: AppBar(title: Text('🎂 Cumpleaños de $mes')),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_res.length} cumpleañero(s) este mes',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : _res.isEmpty
                    ? const Center(
                        child: Text(
                            'Sin cumpleaños este mes.\n'
                            'La fecha sale del carnet de identidad.',
                            textAlign: TextAlign.center))
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: _res.length,
                          itemBuilder: (ctx, i) {
                            final c = _res[i];
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
                                  Text(_etiqueta(c),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  Text(
                                      '${c['_fecha_cumple']} · Cumple ${c['_cumple']}',
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
