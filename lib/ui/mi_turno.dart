/// 📊 Mi turno: resumen del entrenador.
///
/// Cobrado hoy, historial diario, pendiente a entregar con desglose y la
/// aclaración explícita de que el pendiente SOLO se reinicia cuando Jc
/// confirma que recibió el dinero.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'ficha.dart';
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
  // v1.0.16: mejoras para entrenadores
  List<Map<String, dynamic>> _vencimientos = [];
  double _cobradoAyer = 0;
  double _semanaAnt = 0;
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final tid = _auth.telegramId;
    final t = await miTurnoHoy(tid);
    final hist = await historialTurno(tid, dias: 60);
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
    // v1.0.16: tendencia (ayer y semana anterior) y vencimientos
    final ayer = _ayerIso();
    double cobradoAyer = 0;
    double semanaAnt = 0;
    final hace8 = DateTime.now().subtract(const Duration(days: 8));
    final hace15 = DateTime.now().subtract(const Duration(days: 15));
    final f8 = _iso(hace8);
    final f15 = _iso(hace15);
    for (final h in hist) {
      final f = '${h['fecha'] ?? ''}';
      final c = (h['cobrado'] as num?)?.toDouble() ?? 0;
      if (f == ayer) cobradoAyer = c;
      if (f.compareTo(f15) >= 0 && f.compareTo(f8) < 0) {
        semanaAnt += c;
      }
    }
    final vencimientos = await _misVencimientos(tid);
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
        _cobradoAyer = cobradoAyer;
        _semanaAnt = semanaAnt;
        _vencimientos = vencimientos;
      });
    }
  }

  /// Clientes que vencen en los próximos 7 días o ya vencidos,
  /// atribuidos al entrenador (los que él inscribió o les cobró).
  Future<List<Map<String, dynamic>>> _misVencimientos(
      int? tid) async {
    if (tid == null) return [];
    final hoy = _hoy();
    final limite = _iso(DateTime.now().add(const Duration(days: 7)));
    // Clientes que el entrenador inscribió o a los que cobró
    final mios = <int>{};
    for (final c in await LocalDb.instance.allMirror('clientes')) {
      if ((c['registrado_por'] as int?) == tid) {
        final id = (c['id'] as num?)?.toInt();
        if (id != null) mios.add(id);
      }
    }
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      if ((p['telegram_user_id'] as int?) == tid) {
        final id = (p['cliente_id'] as num?)?.toInt();
        if (id != null) mios.add(id);
      }
    }
    final out = <Map<String, dynamic>>[];
    for (final c in await LocalDb.instance.allMirror('clientes')) {
      final id = (c['id'] as num?)?.toInt();
      if (id == null || !mios.contains(id)) continue;
      if ('${c['estado'] ?? 'activo'}' != 'activo') continue;
      final ph = '${c['pagado_hasta'] ?? ''}';
      if (ph.isEmpty || ph.compareTo(limite) > 0) continue;
      out.add({
        'id': id,
        'nombre': '${c['nombre'] ?? 'Cliente $id'}',
        'pagado_hasta': ph.substring(0, 10),
        'vencido': ph.compareTo(hoy) < 0,
      });
    }
    out.sort((a, b) =>
        '${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}'));
    return out;
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _ayerIso() =>
      _iso(DateTime.now().subtract(const Duration(days: 1)));

  /// Turno actual según la hora (v1.0.16).
  String _turnoActual() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return '🌅 Turno de mañana';
    if (h >= 12 && h < 18) return '☀️ Turno de tarde';
    return '🌙 Turno de noche';
  }

  /// Total cobrado en los últimos 7 días (incluye hoy).
  double _cobradoSemana() {
    final hace7 = _iso(DateTime.now().subtract(const Duration(days: 7)));
    double t = 0;
    for (final h in _historial) {
      final f = '${h['fecha'] ?? ''}';
      if (f.compareTo(hace7) >= 0) {
        t += (h['cobrado'] as num?)?.toDouble() ?? 0;
      }
    }
    return t;
  }

  /// Fila de tendencia con flecha ↑/↓/= (v1.0.16).
  Widget _filaTendencia(String etiqueta, double antes, double ahora) {
    String flecha;
    Color color;
    String pct = '';
    if (antes <= 0 && ahora <= 0) {
      flecha = '=';
      color = Colors.grey;
    } else if (antes <= 0) {
      flecha = '↑';
      color = Colors.green;
    } else {
      final d = (ahora - antes) / antes;
      if (d > 0.02) {
        flecha = '↑';
        color = Colors.green;
      } else if (d < -0.02) {
        flecha = '↓';
        color = Colors.red;
      } else {
        flecha = '=';
        color = Colors.grey;
      }
      pct = ' (${(d * 100).toStringAsFixed(0)}%)';
    }
    return Row(
      children: [
        Expanded(
            child: Text(etiqueta,
                style: const TextStyle(fontSize: 14))),
        Text('$flecha ${fmtMonto(ahora)} CUP$pct',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color)),
      ],
    );
  }

  /// Diálogo de cierre de turno con resumen del día (v1.0.16, idea 1).
  void _cierreTurno() {
    final nOps = _historial.isNotEmpty
        ? ((_historial
                    .firstWhere((h) => h['fecha'] == _hoy(),
                        orElse: () => <String, dynamic>{})['ops']
                as List?)?.length ??
            0)
        : 0;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🏁 Cierre de turno'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📅 ${fmtFecha(_hoy())}'),
            Text(_turnoActual()),
            const Divider(),
            Text('💵 Cobrado hoy: ${fmtMonto(_cobrado)} CUP'),
            Text('   Efectivo: ${fmtMonto(_efectivoHoy)} CUP'),
            Text('   Transferencia: ${fmtMonto(_transferHoy)} CUP'),
            Text('   Operaciones: $nOps'),
            const Divider(),
            Text(
              '📤 Total a entregar a Jc: ${fmtMonto(_pendiente)} CUP',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'Revisa que todo esté bien antes de irte. '
              'El pendiente solo se reinicia cuando Jc confirme '
              'que recibió el dinero.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
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

  /// Agrupa el historial por semana (lunes a domingo) para vista compacta.
  /// Devuelve lista de {titulo, total, dias}.
  List<Map<String, dynamic>> _agruparPorSemana(
      List<Map<String, dynamic>> hist) {
    final porSemana = <String, List<Map<String, dynamic>>>{};
    for (final h in hist) {
      final f = '${h['fecha'] ?? ''}';
      if (f.length < 10) continue;
      final dt = DateTime.tryParse(f.substring(0, 10));
      if (dt == null) continue;
      final lunes =
          dt.subtract(Duration(days: dt.weekday - 1));
      final clave = _iso(lunes);
      porSemana.putIfAbsent(clave, () => []).add(h);
    }
    final claves = porSemana.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final k in claves)
        {
          'titulo':
              'Semana del ${fmtFecha(k)}',
          'total': porSemana[k]!
              .fold<double>(
                  0,
                  (t, h) =>
                      t +
                      ((h['cobrado'] as num?)?.toDouble() ??
                          0)),
          'dias': porSemana[k]!,
        }
    ];
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
                    // v1.0.16: turno actual según la hora
                    Center(
                      child: Chip(
                        label: Text(_turnoActual(),
                            style: const TextStyle(
                                fontSize: 13)),
                        backgroundColor:
                            Colors.blue.shade50,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // v1.0.16: qué tengo que entregar (idea 2)
                    Card(
                      color: Colors.blue.shade50,
                      child: Padding(
                        padding:
                            const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text(
                                '📤 Qué tengo que entregar',
                                style: TextStyle(
                                    fontWeight:
                                        FontWeight.bold,
                                    fontSize: 15)),
                            const SizedBox(height: 4),
                            Text(
                                'Hoy cobraste ${fmtMonto(_cobrado)} CUP en efectivo '
                                '(+ ${fmtMonto(_transferHoy)} por transferencia, que va directo).'),
                            const SizedBox(height: 4),
                            Text(
                              'Total a entregar a Jc: ${fmtMonto(_pendiente)} CUP',
                              style: const TextStyle(
                                  fontWeight:
                                      FontWeight.bold,
                                  fontSize: 16),
                            ),
                          ],
                        ),
                      ),
                    ),
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
                    const SizedBox(height: 12),
                    // v1.0.16: mi tendencia (idea 4)
                    Card(
                      child: Padding(
                        padding:
                            const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text('📊 Mi tendencia',
                                style: TextStyle(
                                    fontWeight:
                                        FontWeight.bold,
                                    fontSize: 15)),
                            const SizedBox(height: 8),
                            _filaTendencia('Hoy vs ayer',
                                _cobradoAyer, _cobrado),
                            const SizedBox(height: 4),
                            _filaTendencia(
                                'Esta semana vs anterior',
                                _semanaAnt,
                                _cobradoSemana()),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // v1.0.16: mis vencimientos (idea 3)
                    Card(
                      child: Padding(
                        padding:
                            const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                                '⏰ Mis vencimientos (${_vencimientos.length})',
                                style: const TextStyle(
                                    fontWeight:
                                        FontWeight.bold,
                                    fontSize: 15)),
                            const SizedBox(height: 4),
                            if (_vencimientos.isEmpty)
                              const Text(
                                  'Nada por vencer en 7 días. 🎉',
                                  style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 13)),
                            for (final v in _vencimientos
                                .take(10))
                              ListTile(
                                dense: true,
                                contentPadding:
                                    EdgeInsets.zero,
                                leading: Text(
                                    (v['vencido'] == true)
                                        ? '🔴'
                                        : '🟡',
                                    style: const TextStyle(
                                        fontSize: 18)),
                                title: Text(
                                    '${v['nombre']}',
                                    style: const TextStyle(
                                        fontSize: 14)),
                                subtitle: Text(
                                    (v['vencido'] == true)
                                        ? 'Venció: ${fmtFecha(v['pagado_hasta'])}'
                                        : 'Vence: ${fmtFecha(v['pagado_hasta'])}',
                                    style:
                                        const TextStyle(
                                            fontSize: 12)),
                                onTap: () {
                                  final cid =
                                      v['id'] as int?;
                                  if (cid == null) {
                                    return;
                                  }
                                  Navigator.of(context)
                                      .push(MaterialPageRoute(
                                          builder: (_) =>
                                              FichaScreen(
                                                  clienteId:
                                                      cid)));
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // v1.0.16: cierre de turno (idea 1)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.done_all),
                        label: const Text(
                            'Cerrar mi turno'),
                        onPressed: _cierreTurno,
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
                        'Sin cobros registrados en los últimos 60 días.',
                        style: TextStyle(color: Colors.grey)),
                  // v1.0.16: agrupado por semana (idea 8)
                  for (final sem
                      in _agruparPorSemana(_historial))
                    Card(
                      margin:
                          const EdgeInsets.symmetric(vertical: 4),
                      child: ExpansionTile(
                        leading: const Text('🗓️',
                            style: TextStyle(fontSize: 22)),
                        title: Text(sem['titulo'] as String,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        trailing: Text(
                            '${fmtMonto(sem['total'])} CUP',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        subtitle: Text(
                            '${(sem['dias'] as List).length} días con cobros',
                            style: const TextStyle(fontSize: 12)),
                        children: [
                          for (final h in sem['dias']
                              as List<Map<String, dynamic>>)
                            ExpansionTile(
                              dense: true,
                              leading: const Text('📅',
                                  style:
                                      TextStyle(fontSize: 18)),
                              title: Text(
                                  fmtFecha(
                                      h['fecha'] as String?),
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.bold,
                                      fontSize: 14)),
                              trailing: Text(
                                  '${fmtMonto(h['cobrado'])} CUP',
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.bold,
                                      fontSize: 14)),
                              subtitle: Text(
                                  'Efectivo: ${fmtMonto(h['efectivo'])} · '
                                  'Transf.: ${fmtMonto(h['transferencia'])}',
                                  style: const TextStyle(
                                      fontSize: 12)),
                              children: [
                                for (final op in (h['ops']
                                        as List<
                                            Map<String,
                                                String>>))
                                  ListTile(
                                    dense: true,
                                    title: Text(
                                        op['etiqueta'] ?? '',
                                        style:
                                            const TextStyle(
                                                fontSize:
                                                    13)),
                                    trailing: Text(
                                        '${op['monto']} CUP',
                                        style:
                                            const TextStyle(
                                                fontSize:
                                                    13)),
                                  ),
                              ],
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
