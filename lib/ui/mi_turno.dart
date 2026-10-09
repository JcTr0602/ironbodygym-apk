/// Mi turno: resumen del entrenador.
///
/// Cobrado hoy, historial diario, pendiente a entregar con desglose y la
/// aclaración explícita de que el pendiente SOLO se reinicia cuando Jc
/// confirma que recibió el dinero.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
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
  bool _cerrado = false; // v1.1.1: turno actual ya cerrado
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
    // v1.1.1: ¿el turno actual ya se cerró?
    final cerrado = await _turnoCerrado();
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
        _cerrado = cerrado;
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
  /// v1.1.1: id corto para la clave de cierre (mañana/tarde/noche).
  String _turnoId() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return 'manana';
    if (h >= 12 && h < 18) return 'tarde';
    return 'noche';
  }

  /// Clave del cierre del turno actual (por día, turno y entrenador).
  String _claveCierre() =>
      'cierre_turno_${_hoy()}_${_turnoId()}_${_auth.telegramId}';

  Future<bool> _turnoCerrado() async =>
      (await LocalDb.instance.getMeta(_claveCierre())) != null;

  String _turnoActual() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return 'Turno de mañana';
    if (h >= 12 && h < 18) return 'Turno de tarde';
    return 'Turno de noche';
  }

  /// Icono según el turno actual.
  IconData _iconoTurno() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return Icons.wb_sunny_outlined;
    if (h >= 12 && h < 18) return Icons.wb_sunny;
    return Icons.nights_stay_outlined;
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
      color = AppColores.textoSecundarioClaro;
    } else if (antes <= 0) {
      flecha = '↑';
      color = AppColores.exito;
    } else {
      final d = (ahora - antes) / antes;
      if (d > 0.02) {
        flecha = '↑';
        color = AppColores.exito;
      } else if (d < -0.02) {
        flecha = '↓';
        color = AppColores.error;
      } else {
        flecha = '=';
        color = AppColores.textoSecundarioClaro;
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
        title: const Text('Cierre de turno'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fmtFecha(_hoy())),
            Text(_turnoActual()),
            const Divider(),
            Text('Cobrado hoy: ${fmtMonto(_cobrado)} CUP'),
            Text('   Efectivo: ${fmtMonto(_efectivoHoy)} CUP'),
            Text('   Transferencia: ${fmtMonto(_transferHoy)} CUP'),
            Text('   Operaciones: $nOps'),
            const Divider(),
            Text(
              'Total a entregar a Jc: ${fmtMonto(_pendiente)} CUP',
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
            if (_cerrado) ...[
              const SizedBox(height: 8),
              const Row(
                children: [
                  Icon(Icons.check_circle,
                      color: Colors.green, size: 16),
                  SizedBox(width: 6),
                  Text('Este turno ya está cerrado',
                      style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                Text(_cerrado ? 'Cerrar' : 'Cancelar'),
          ),
          if (!_cerrado)
            ElevatedButton.icon(
              icon: const Icon(Icons.done_all, size: 18),
              label: const Text('Confirmar cierre'),
              onPressed: () async {
                await LocalDb.instance.setMeta(
                    _claveCierre(),
                    DateTime.now().toIso8601String());
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) {
                  setState(() => _cerrado = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Turno cerrado. ¡Buen trabajo!')));
                }
              },
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
          title: Text(esDueno ? 'Mis cobros' : 'Mi turno')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Tarjeta(
                    child: Column(
                      children: [
                        const Row(
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          children: [
                            Icon(Icons.payments,
                                color: AppColores.exito,
                                size: 28),
                            SizedBox(
                                width: AppEspacio.sm),
                            Text('Cobrado hoy',
                                style: AppTexto.subtitulo),
                          ],
                        ),
                        const SizedBox(
                            height: AppEspacio.sm),
                        Text('${fmtMonto(_cobrado)} CUP',
                            style: AppTexto.titulo.copyWith(
                                fontSize: 26,
                                color:
                                    AppColores.naranja)),
                        const SizedBox(height: 4),
                        Text(
                          'Efectivo: ${fmtMonto(_efectivoHoy)} · '
                          'Transferencia: ${fmtMonto(_transferHoy)}',
                          style: AppTexto.secundario,
                        ),
                      ],
                    ),
                  ),
                  if (!esDueno) ...[
                    // v1.0.16: turno actual según la hora
                    Center(
                      child: Chip(
                        avatar: Icon(
                            _iconoTurno(),
                            size: 18,
                            color: AppColores.naranja),
                        label: Text(_turnoActual(),
                            style: const TextStyle(
                                fontSize: 13)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // v1.0.16: qué tengo que entregar (idea 2)
                    Tarjeta(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.outbox,
                                  color: AppColores.info,
                                  size: 20),
                              SizedBox(
                                  width: AppEspacio.sm),
                              Text(
                                  'Qué tengo que entregar',
                                  style: AppTexto.subtitulo),
                            ],
                          ),
                          const SizedBox(
                              height: AppEspacio.sm),
                          Text(
                              'Hoy cobraste ${fmtMonto(_cobrado)} CUP en efectivo '
                              '(+ ${fmtMonto(_transferHoy)} por transferencia, que va directo).',
                              style: AppTexto.cuerpo),
                          const SizedBox(height: 4),
                          Text(
                            'Total a entregar a Jc: ${fmtMonto(_pendiente)} CUP',
                            style: AppTexto.subtitulo.copyWith(
                                color: AppColores.naranja),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Tarjeta(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        leading: Icon(
                            _pendiente > 0
                                ? Icons.payments
                                : Icons.check_circle,
                            color: _pendiente > 0
                                ? AppColores.naranja
                                : AppColores.exito,
                            size: 32),
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
                    Tarjeta(
                      color: AppColores.info
                          .withValues(alpha: 0.08),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: AppColores.info),
                          SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: Text(
                              'El "Pendiente a entregar" SOLO se reinicia cuando '
                              'Jc confirma que recibió el dinero. Registrar más '
                              'cobros no lo reduce: lo aumenta.',
                              style: AppTexto.secundario,
                            ),
                          ),
                        ],
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
                          leading: const Icon(Icons.calendar_today, size: 20, color: AppColores.naranja),
                          title: Text(fmtFecha(e.key)),
                          trailing: Text(
                              '${fmtMonto(e.value)} CUP',
                              style: const TextStyle(
                                  fontWeight:
                                      FontWeight.bold)),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Tarjeta(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.inventory_2,
                            size: 28, color: AppColores.info),
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
                    Tarjeta(
                      child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.trending_up,
                                    color:
                                        AppColores.naranja,
                                    size: 20),
                                SizedBox(
                                    width: AppEspacio.sm),
                                Text('Mi tendencia',
                                    style:
                                        AppTexto.subtitulo),
                              ],
                            ),
                            const SizedBox(
                                height: AppEspacio.sm),
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
                    const SizedBox(height: 12),
                    // v1.0.16: mis vencimientos (idea 3)
                    Tarjeta(
                      child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.alarm,
                                    color:
                                        AppColores.alerta,
                                    size: 20),
                                const SizedBox(
                                    width: AppEspacio.sm),
                                Text(
                                    'Mis vencimientos (${_vencimientos.length})',
                                    style:
                                        AppTexto.subtitulo),
                              ],
                            ),
                            const SizedBox(
                                height: AppEspacio.sm),
                            if (_vencimientos.isEmpty)
                              const Text(
                                  'Nada por vencer en 7 días.',
                                  style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 13)),
                            for (final v in _vencimientos
                                .take(10))
                              ListTile(
                                dense: true,
                                contentPadding:
                                    EdgeInsets.zero,
                                leading: Icon(Icons.circle,
                                    size: 12,
                                    color: (v['vencido'] == true)
                                        ? AppColores.error
                                        : AppColores.alerta),
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
                    const SizedBox(height: 12),
                    // v1.0.16: cierre de turno (idea 1)
                    // v1.1.1: cierre real por turno, sin requerir pagos diarios
                    SizedBox(
                      width: double.infinity,
                      child: _cerrado
                          ? OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.check_circle,
                                  color: Colors.green),
                              label: Text(
                                  'Turno cerrado (${_turnoActual().toLowerCase()})'),
                              onPressed: _cierreTurno,
                            )
                          : ElevatedButton.icon(
                              icon:
                                  const Icon(Icons.done_all),
                              label: const Text(
                                  'Cerrar mi turno'),
                              onPressed: _cierreTurno,
                            ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Tarjeta(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: const Icon(Icons.calendar_month,
                          size: 28, color: AppColores.naranja),
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
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppEspacio.xs),
                      child: Tarjeta(
                        padding: EdgeInsets.zero,
                        child: ExpansionTile(
                        leading: const Icon(Icons.calendar_month,
                            size: 22, color: AppColores.naranja),
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
                              leading: const Icon(Icons.calendar_today,
                                  size: 18, color: AppColores.naranja),
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
