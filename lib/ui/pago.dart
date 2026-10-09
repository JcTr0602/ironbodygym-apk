/// 💰 Agregar pago: caja rápida de mensualidades.
///
/// Resumen del día arriba (total, cantidad, efectivo vs transferencia),
/// deshacer último pago propio, últimos 10 cobros con hora.
/// La lista de clientes va con vencidos primero y filtro Solo vencidos;
/// el cobro se hace en 2 toques vía el diálogo unificado de pago.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'buscar.dart';
import 'dialogo_pago.dart';
import 'ficha.dart';
import 'widgets.dart';

/// Un cobro del día: viene del espejo (ya sincronizado) o de una op
/// local aún en cola. Se ordenan por hora descendente.
class _Cobro {
  final String nombre;
  final double monto;
  final String metodo; // 'efectivo' | 'transferencia'
  final DateTime ts;
  final String? opUuid; // op local (pendiente/error/enviada)
  final String? estadoOp;
  final int? pagoId; // pago en el espejo (servidor)
  final int? telegramUserId; // quién lo registró (espejo)

  const _Cobro({
    required this.nombre,
    required this.monto,
    required this.metodo,
    required this.ts,
    this.opUuid,
    this.estadoOp,
    this.pagoId,
    this.telegramUserId,
  });

  bool get esLocal => opUuid != null;

  /// Solo se puede deshacer lo que cobré yo: mis ops locales
  /// (la cola es por dispositivo) o mis pagos en el espejo.
  bool esMio(int? miTelegramId) {
    if (esLocal) return true;
    if (miTelegramId == null) return false;
    return telegramUserId == miTelegramId;
  }

  String get hora =>
      '${ts.hour.toString().padLeft(2, '0')}:'
      '${ts.minute.toString().padLeft(2, '0')}';
}

class PagoScreen extends StatefulWidget {
  const PagoScreen({super.key});
  @override
  State<PagoScreen> createState() => _PagoScreenState();
}

class _PagoScreenState extends State<PagoScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _res = [];
  bool _busco = false;
  bool _soloVencidos = false;
  List<_Cobro> _cobros = [];
  bool _cargandoCobros = true;

  static const naranja = Color(0xFFE8821A);
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _buscar();
    _cargarDatos();
  }

  String _hoyStr() {
    final hoy = DateTime.now();
    return '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
  }

  /// Cobros del día: espejo + ops locales pago_mensual aún no aplicadas.
  /// Incluye las pendientes aunque no haya internet (caja offline).
  Future<void> _cargarDatos() async {
    final hoyStr = _hoyStr();
    final cobros = <_Cobro>[];

    // 1) Espejo: pagos con fecha de hoy (ya pasaron por el servidor).
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final f = '${p['fecha'] ?? ''}';
      if (!f.startsWith(hoyStr)) continue;
      final cid = (p['cliente_id'] as int?) ?? 0;
      String nombre = '¿?';
      try {
        final c = await clientePorId(cid);
        nombre = '${c?['nombre'] ?? '¿?'}';
      } catch (_) {}
      DateTime ts;
      try {
        ts = DateTime.parse('${p['created_at']}').toLocal();
      } catch (_) {
        ts = DateTime.now();
      }
      cobros.add(_Cobro(
        nombre: nombre,
        monto: (p['monto'] as num?)?.toDouble() ?? 0,
        metodo: '${p['metodo'] ?? 'efectivo'}',
        ts: ts,
        pagoId: p['id'] as int?,
        telegramUserId: (p['telegram_user_id'] as num?)?.toInt(),
      ));
    }

    // 2) Cola local: pago_mensual de hoy en pendiente/error/enviada.
    //    Una op aplicada ya está en el espejo (sin duplicados).
    final ops = [
      ...await LocalDb.instance.pendingOps(),
      ...await LocalDb.instance.opsByEstado('enviada'),
    ];
    for (final op in ops) {
      if ('${op['tipo']}' != 'pago_mensual') continue;
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(op['payload'] as String);
      } catch (_) {
        continue;
      }
      if (!'${payload['fecha'] ?? ''}'.startsWith(hoyStr)) continue;
      final cid = (payload['cliente_id'] as num?)?.toInt() ?? 0;
      String nombre = '¿?';
      try {
        final c = await clientePorId(cid);
        nombre = '${c?['nombre'] ?? '¿?'}';
      } catch (_) {}
      DateTime ts;
      try {
        ts = DateTime.parse('${op['creada_ts']}').toLocal();
      } catch (_) {
        ts = DateTime.now();
      }
      cobros.add(_Cobro(
        nombre: nombre,
        monto: (payload['monto'] as num?)?.toDouble() ?? 0,
        metodo: '${payload['metodo'] ?? 'efectivo'}',
        ts: ts,
        opUuid: '${op['op_uuid']}',
        estadoOp: '${op['estado']}',
      ));
    }

    cobros.sort((a, b) => b.ts.compareTo(a.ts));
    if (mounted) {
      setState(() {
        _cobros = cobros;
        _cargandoCobros = false;
      });
    }
  }

  double get _totalHoy =>
      _cobros.fold(0.0, (t, c) => t + c.monto);
  double get _efectivoHoy => _cobros
      .where((c) => c.metodo == 'efectivo')
      .fold(0.0, (t, c) => t + c.monto);
  double get _transferHoy => _totalHoy - _efectivoHoy;

  /// El último cobro propio del día (el que se puede deshacer).
  _Cobro? get _ultimoMio {
    final miTid = _auth.telegramId;
    for (final c in _cobros) {
      if (c.esMio(miTid)) return c;
    }
    return null;
  }

  Future<void> _buscar() async {
    var r = await listaClientes(_q.text);
    // Vencidos primero, luego por vencer.
    r.sort((a, b) {
      final da = _diasRestantes(a);
      final db = _diasRestantes(b);
      return da.compareTo(db);
    });
    if (_soloVencidos) {
      r = r.where((c) => _diasRestantes(c) < 0).toList();
    }
    if (mounted) {
      setState(() {
        _res = r;
        _busco = true;
      });
    }
  }

  int _diasRestantes(Map<String, dynamic> c) {
    try {
      final ph = '${c['pagado_hasta'] ?? ''}';
      if (ph.length < 10) return 999;
      final v = DateTime.parse(ph.substring(0, 10));
      final hoy = DateTime.now();
      final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
      return v.difference(hoyDia).inDays;
    } catch (_) {
      return 999;
    }
  }

  Future<void> _pagar(Map<String, dynamic> c) async {
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    // v1.0.15: vibración de confirmación (caja rápida).
    HapticFeedback.lightImpact();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ Pago de ${c['nombre']} guardado')));
    SyncEngine.instance.push();
    _cargarDatos();
    _buscar();
  }

  /// Deshace el último cobro propio del día.
  ///
  /// - Op local pendiente/error: nunca llegó al servidor → se elimina
  ///   de la cola (deleteOp solo borra esos estados, es seguro).
  /// - Pago en espejo: se encola 'anular_pago' (op ya soportada por
  ///   el servidor).
  /// - Op 'enviada' (en camino): no se toca, se avisa que espere.
  Future<void> _deshacerUltimo() async {
    final u = _ultimoMio;
    if (u == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('↩️ Deshacer último pago'),
        content: Text(
            '¿Anular el cobro de ${u.nombre} por '
            '${fmtMonto(u.monto)} CUP (${u.hora})?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, deshacer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    if (u.esLocal && u.opUuid != null) {
      if (u.estadoOp == 'pendiente' || u.estadoOp == 'error') {
        // Nunca se envió: borrar la op es seguro.
        await LocalDb.instance.deleteOp(u.opUuid!);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('↩️ Pago deshecho (no había sido enviado)')));
      } else {
        // 'enviada': ya va en camino al servidor, no se puede borrar.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                '⏳ Ese pago se está sincronizando, intenta en unos segundos')));
        return;
      }
    } else if (u.pagoId != null) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_pago',
        payload: {'pago_id': u.pagoId},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Pago anulado (se sincronizará)')));
      SyncEngine.instance.push();
    } else {
      return;
    }
    _cargarDatos();
    _buscar();
  }

  Widget _resumenDia() {
    final ultimo = _ultimoMio;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  Text(
                    '${fmtMonto(_totalHoy)} CUP',
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: naranja),
                  ),
                  const Text('Cobrado hoy',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
              Column(
                children: [
                  Text(
                    '${_cobros.length}',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const Text('Pagos hoy',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('💵 ${fmtMonto(_efectivoHoy)}',
                      style: const TextStyle(fontSize: 13)),
                  Text('📱 ${fmtMonto(_transferHoy)}',
                      style: const TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ),
          if (ultimo != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Text('↩️'),
                label: Text(
                    'Deshacer último (${fmtMonto(ultimo.monto)} CUP)'),
                onPressed: _deshacerUltimo,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _ultimosCobros() {
    if (_cargandoCobros) return const SizedBox.shrink();
    final items = _cobros.take(10).toList();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        leading: const Text('🕐', style: TextStyle(fontSize: 20)),
        title: Text('Últimos cobros (${items.length})',
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.bold)),
        children: items.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Aún no hay cobros hoy.',
                      style:
                          TextStyle(fontSize: 13, color: Colors.grey)),
                ),
              ]
            : items.map((c) {
                final mio = c.esMio(_auth.telegramId);
                return ListTile(
                  dense: true,
                  leading: Text(
                      c.metodo == 'efectivo' ? '💵' : '📱',
                      style: const TextStyle(fontSize: 18)),
                  title: Text(c.nombre,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              mio ? FontWeight.bold : FontWeight.normal)),
                  subtitle: Text(
                      '${c.hora}'
                      '${c.esLocal && c.estadoOp != 'enviada' ? ' · ⏳ por subir' : ''}'
                      '${c.esLocal && c.estadoOp == 'enviada' ? ' · ⬆️ subiendo' : ''}',
                      style: const TextStyle(fontSize: 12)),
                  trailing: Text('${fmtMonto(c.monto)} CUP',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: naranja)),
                );
              }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💰 Agregar pago')),
      body: Column(
        children: [
          const SyncBanner(),
          _resumenDia(),
          _ultimosCobros(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    decoration: const InputDecoration(
                        labelText: 'Nombre, carnet o teléfono',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search)),
                    onChanged: (_) => _buscar(),
                    onSubmitted: (_) => _buscar(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                    onPressed: _buscar, child: const Text('Buscar')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Solo vencidos'),
                  selected: _soloVencidos,
                  onSelected: (v) {
                    setState(() => _soloVencidos = v);
                    _buscar();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _res.isEmpty
                ? Center(
                    child: Text(_busco
                        ? 'Sin resultados'
                        : 'Cargando…'))
                : ListView.builder(
                    itemCount: _res.length,
                    itemBuilder: (ctx, i) {
                      final c = _res[i];
                      return FilaCliente(
                        cliente: c,
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => FichaScreen(
                                    clienteId:
                                        (c['id'] as int?) ??
                                            0))),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ElevatedButton(
                              child: const Text('💰 Pagar'),
                              onPressed: () => _pagar(c),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
