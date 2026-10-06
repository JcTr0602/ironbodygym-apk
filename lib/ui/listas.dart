/// Listas: vencen hoy, atrasados <30 días, atrasados 30+ días.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import 'ficha.dart';
import 'widgets.dart';

class ListasScreen extends StatefulWidget {
  const ListasScreen({super.key});
  @override
  State<ListasScreen> createState() => _ListasScreenState();
}

class _ListasScreenState extends State<ListasScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<Map<String, dynamic>> _hoy = [];
  List<Map<String, dynamic>> _menos30 = [];
  List<Map<String, dynamic>> _mas30 = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _cargar();
  }

  Future<void> _cargar() async {
    final h = await vencenHoy();
    final m30 = await atrasados(masDe30: false);
    final p30 = await atrasados(masDe30: true);
    if (mounted) {
      setState(() {
        _hoy = h;
        _menos30 = m30;
        _mas30 = p30;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📋 Listas'),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: '📅 Hoy (${_hoy.length})'),
            Tab(text: '⏳ -30d (${_menos30.length})'),
            Tab(text: '🚨 +30d (${_mas30.length})'),
          ],
        ),
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _lista(_hoy, '🎉 Nadie vence hoy. Todo al día.'),
                _lista(_menos30, '🎉 Sin atrasados de menos de un mes.'),
                _lista(_mas30, '🎉 Sin atrasados de más de un mes.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lista(List<Map<String, dynamic>> rows, String vacio) {
    if (rows.isEmpty) return Center(child: Text(vacio));
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        itemCount: rows.length,
        itemBuilder: (ctx, i) {
          final c = rows[i];
          return ListTile(
            leading:
                const Text('👤', style: TextStyle(fontSize: 28)),
            title: Text('${c['nombre']}'),
            subtitle: Text(
                'Pagado hasta: ${fmtFecha(c['pagado_hasta'] as String?)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) =>
                        FichaScreen(clienteId: (c['id'] as int?) ?? 0)))
                .then((_) => _cargar()),
          );
        },
      ),
    );
  }
}
