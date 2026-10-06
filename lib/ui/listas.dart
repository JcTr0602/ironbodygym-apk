/// Listas: vencen hoy, atrasados, por vencer. Con mini foto y pago rápido.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'buscar.dart';
import 'dialogo_pago.dart';
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
  List<Map<String, dynamic>> _porVencer = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _cargar();
  }

  Future<void> _cargar() async {
    final h = await vencenHoy();
    final m30 = await atrasados(masDe30: false);
    final p30 = await atrasados(masDe30: true);
    final pv = await porVencer(dias: 3);
    if (mounted) {
      setState(() {
        _hoy = h;
        _menos30 = m30;
        _mas30 = p30;
        _porVencer = pv;
      });
    }
  }

  Future<void> _pagoRapido(Map<String, dynamic> c) async {
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ Pago de ${c['nombre']} guardado')));
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📋 Listas'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: [
            Tab(text: '📅 Hoy (${_hoy.length})'),
            Tab(text: '🔜 Por vencer (${_porVencer.length})'),
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
                _lista(_porVencer,
                    '🎉 Nadie por vencer en 3 días.'),
                _lista(_menos30,
                    '🎉 Sin atrasados de menos de un mes.'),
                _lista(_mas30,
                    '🎉 Sin atrasados de más de un mes.'),
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
          return FilaCliente(
            cliente: c,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => FichaScreen(
                        clienteId: (c['id'] as int?) ?? 0)))
                .then((_) => _cargar()),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
              ),
              child: const Text('💰'),
              onPressed: () => _pagoRapido(c),
            ),
          );
        },
      ),
    );
  }
}
