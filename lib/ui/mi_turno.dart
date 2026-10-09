/// 📊 Mi turno: resumen del entrenador.
///
/// Cobrado hoy, historial diario, pendiente a entregar con desglose y la
/// aclaración explícita de que el pendiente SOLO se reinicia cuando Jc
/// confirma que recibió el dinero.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import 'pendiente.dart';
import 'widgets.dart';

class MiTurnoScreen extends StatefulWidget {
  const MiTurnoScreen({super.key});
  @override
  State<MiTurnoScreen> createState() => _MiTurnoScreenState();
}

class _MiTurnoScreenState extends State<MiTurnoScreen> {
  double _cobrado = 0;
  double _efectivoHoy = 0;
  double _transferHoy = 0;
  double _pendiente = 0;
  double _cobradoMes = 0;
  Map<String, dynamic>? _ultimaEntrega;
  List<Map<String, dynamic>> _historial = [];
  List<Map<String, dynamic>> _pendMens = [];
  List<Map<String, dynamic>> _pendDiarios = [];
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final tid = _auth.telegramId;
    final t = await miTurnoHoy(tid);
    final hist = await historialTurno(tid);
    final ult = await ultimaEntregaConfirmada(tid);
    final mes = await cobradoMes(tid);
    final (pm, pd) = await detallePendiente(tid);
    double ef = 0, tr = 0;
    if (hist.isNotEmpty) {
      final hoy = hist.firstWhere(
          (h) => h['fecha'] == _hoy(),
          orElse: () => <String, dynamic>{});
      ef = (hoy['efectivo'] as num?)?.toDouble() ?? 0;
      tr = (hoy['transferencia'] as num?)?.toDouble() ?? 0;
    }
    if (mounted) {
      setState(() {
        _cobrado = t.$1;
        _pendiente = t.$2;
        _efectivoHoy = ef;
        _transferHoy = tr;
        _cobradoMes = mes;
        _ultimaEntrega = ult;
        _historial = hist;
        _pendMens = pm;
        _pendDiarios = pd;
      });
    }
  }

  String _hoy() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  /// Pendiente agrupado por día (para el detalle).
  Map<String, double> get _pendPorDia {
    final m = <String, double>{};
    void suma(String? f, double v) {
      final d = (f ?? '').length >= 10 ? f!.substring(0, 10) : '—';
      m[d] = (m[d] ?? 0) + v;
    }

    for (final p in _pendMens) {
      suma(p['fecha'] as String?, (p['monto'] as num?)?.toDouble() ?? 0);
    }
    for (final d in _pendDiarios) {
      suma(d['fecha'] as String?, (d['total'] as num?)?.toDouble() ?? 0);
    }
    final dias = m.keys.toList()..sort((a, b) => b.compareTo(a));
    return {for (final d in dias) d: m[d]!};
  }

  @override
  Widget build(BuildContext context) {
    // v1.0.16: para el dueño es "Mis cobros" (no trabaja turnos);
    // se oculta todo lo de pendiente/entregas que no le aplica.
    final esDueno = _auth.isAdmin;
    return Scaffold(
      appBar: AppBar(
          title: Text(esDueno ? '💵 Mis cobros' : '📊 Mi turno')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: Colors.green.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const ListTile(
                            leading: Text('💵',
                                style: TextStyle(fontSize: 32)),
                            title: Text('Cobrado hoy'),
                          ),
                          Text('${fmtMonto(_cobrado)} CUP',
                              style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            'Efectivo: ${fmtMonto(_efectivoHoy)} · '
                            'Transferencia: ${fmtMonto(_transferHoy)}',
                            style: const TextStyle(
                                fontSize: 13, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!esDueno) ...[
                    const SizedBox(height: 12),
                    Card(
                      color: _pendiente > 0
                          ? Colors.orange.shade50
                          : Colors.green.shade50,
                      child: ListTile(
                        leading: Text(
                            _pendiente > 0 ? '💰' : '✅',
                            style: const TextStyle(
                                fontSize: 32)),
                        title:
                            const Text('Pendiente a entregar'),
                        subtitle: Text(
                            '${fmtMonto(_pendiente)} CUP',
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold)),
                        trailing:
                            const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context)
                            .push(MaterialPageRoute(
                                builder: (_) =>
                                    const PendienteScreen()))
                            .then((_) => _cargar()),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius:
                            BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'ℹ️ El "Pendiente a entregar" SOLO se reinicia cuando '
                        'Jc confirma que recibió el dinero. Registrar más '
                        'cobros no lo reduce: lo aumenta.',
                        style: TextStyle(fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (_pendPorDia.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Text(
                          'Detalle del pendiente por día:',
                          style: TextStyle(
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      for (final e in _pendPorDia.entries)
                        ListTile(
                          dense: true,
                          leading: const Text('📅'),
                          title: Text(fmtFecha(e.key)),
                          trailing: Text(
                              '${fmtMonto(e.value)} CUP',
                              style: const TextStyle(
                                  fontWeight:
                                      FontWeight.bold)),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Card(
                      child: ListTile(
                        leading: const Text('📦',
                            style: TextStyle(fontSize: 28)),
                        title: const Text(
                            'Última entrega confirmada'),
                        subtitle: Text(_ultimaEntrega ==
                                null
                            ? 'Aún no hay entregas confirmadas'
                            : '${fmtFecha(_ultimaEntrega!['fecha'] as String?)}'
                                ' — ${fmtMonto(_ultimaEntrega!['monto'])} CUP'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Text('🗓️',
                          style: TextStyle(fontSize: 28)),
                      title: const Text('Cobrado este mes'),
                      trailing: Text('${fmtMonto(_cobradoMes)} CUP',
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Historial diario:',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const SizedBox(height: 4),
                  if (_historial.isEmpty)
                    const Text(
                        'Sin cobros registrados en los últimos 30 días.',
                        style: TextStyle(color: Colors.grey)),
                  for (final h in _historial)
                    Card(
                      margin:
                          const EdgeInsets.symmetric(vertical: 4),
                      child: ExpansionTile(
                        leading: const Text('📅',
                            style: TextStyle(fontSize: 22)),
                        title: Text(fmtFecha(h['fecha'] as String?),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        trailing: Text(
                            '${fmtMonto(h['cobrado'])} CUP',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        subtitle: Text(
                            'Efectivo: ${fmtMonto(h['efectivo'])} · '
                            'Transf.: ${fmtMonto(h['transferencia'])}',
                            style: const TextStyle(fontSize: 12)),
                        children: [
                          for (final op in (h['ops']
                                  as List<Map<String, String>>))
                            ListTile(
                              dense: true,
                              title: Text(op['etiqueta'] ?? ''),
                              trailing:
                                  Text('${op['monto']} CUP'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
