/// 💰 Pendiente a entregar / 📥 Pendiente a recoger.
///
/// Entrenadores: ven su propio efectivo pendiente de entregar al dueño.
/// Dueño (v1.0.15): ve el desglose por entrenador (nombre, cantidad de
/// pagos, total) y confirma el recibido de cada uno individualmente.
/// La confirmación encola la op `confirmar_entrega` y se aplica al
/// sincronizar; el espejo local se actualiza en el siguiente pull.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class PendienteScreen extends StatefulWidget {
  const PendienteScreen({super.key});
  @override
  State<PendienteScreen> createState() => _PendienteScreenState();
}

class _PendienteScreenState extends State<PendienteScreen> {
  // Vista entrenador: su propio pendiente.
  List<Map<String, dynamic>> _mens = [];
  List<Map<String, dynamic>> _diarios = [];
  // Vista dueño: desglose por entrenador {id, nombre, total, n}.
  List<Map<String, dynamic>> _porEntrenador = [];
  // Gemini: totales USD separados (no mezclar con CUP).
  double _totalUsd = 0;
  bool _cargando = true;
  bool _confirmando = false;
  late final bool _esDueno;

  @override
  void initState() {
    super.initState();
    _esDueno = AuthService().isOwner;
    _cargar();
  }

  Future<void> _cargar() async {
    final auth = AuthService();
    if (_esDueno) {
      // El dueño no se cuenta a sí mismo en lo pendiente a recoger.
      final porEnt = await pendientePorEntrenador(
          excluirTid: auth.telegramId);
      // Gemini: USD separado del CUP.
      final usd = await pendienteRecogerUsd(
          excluirTelegramId: auth.telegramId);
      if (mounted) {
        setState(() {
          _porEntrenador = porEnt;
          _totalUsd = usd;
          _cargando = false;
        });
      }
    } else {
      final tid = auth.telegramId;
      final (m, d) = await detallePendiente(tid);
      // Gemini: USD separado del CUP.
      final usd = await pendienteEntregaUsd(tid);
      if (mounted) {
        setState(() {
          _mens = m;
          _diarios = d;
          _totalUsd = usd;
          _cargando = false;
        });
      }
    }
  }

  double get _totalEntrenador {
    double t = 0;
    for (final p in _mens) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
    for (final d in _diarios) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
    return t;
  }

  double get _totalDueno {
    double t = 0;
    for (final e in _porEntrenador) {
      t += (e['total'] as num?)?.toDouble() ?? 0;
    }
    return t;
  }

  /// El dueño confirma que recibió el dinero de un entrenador.
  /// Encola `confirmar_entrega` con ese trainer_telegram_id.
  Future<void> _confirmarRecibido(
      int trainerId, String nombre, double total) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirmar recibido de $nombre'),
        content: Text(
            '¿Confirmas que recibiste ${fmtMonto(total)} CUP de $nombre?\n\n'
            'Se marcarán como entregados todos sus pagos pendientes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Gemini-2: bandera anti doble-tap (ya existía _confirmando, se agrega
    // try-finally para no quedar bloqueado si algo lanza excepción).
    if (_confirmando) return;
    setState(() => _confirmando = true);
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'confirmar_entrega',
        // v1.2.1: incluir nombre del entrenador (antes solo el telegram_id,
        // que se mostraba como "entrenador 1403501391").
        payload: {
          'trainer_telegram_id': trainerId,
          'trainer_nombre': nombre
        },
      );
      SyncEngine.instance.push();
    } finally {
      if (mounted) setState(() => _confirmando = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Recibido de $nombre confirmado '
            '(se aplicará al sincronizar)')));
    await _cargar();
  }

  /// Detalle expandible de los pagos pendientes de un entrenador.
  Widget _detalleEntrenador(int trainerId) {
    return FutureBuilder<
        (List<Map<String, dynamic>>, List<Map<String, dynamic>>)>(
      future: detallePendiente(trainerId),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2))),
          );
        }
        final (mens, diarios) = snap.data!;
        if (mens.isEmpty && diarios.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Sin detalle disponible.',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          );
        }
        return Column(
          children: [
            for (final p in mens)
              ListTile(
                dense: true,
                leading: const Text(''),
                title: Text('${fmtMonto(p['monto'])} CUP'),
                subtitle: Text(
                    '${fmtFecha(p['fecha'] as String?)} · ${p['meses'] ?? 1} mes(es)'),
              ),
            for (final d in diarios)
              ListTile(
                dense: true,
                leading: const Text(''),
                title: Text('${fmtMonto(d['total'])} CUP'),
                subtitle: Text(
                    '${fmtFecha(d['fecha'] as String?)} · ${d['turno'] ?? ''} x${d['cantidad'] ?? '?'}'),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              _esDueno ? 'Pendiente a recoger' : 'Pendiente a entregar')),
      body: Column(
        children: [
          const SyncBanner(),
          if (!_cargando) _tarjetaTotal(),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: _esDueno
                        ? _listaDueno()
                        : _listaEntrenador(),
                  ),
          ),
        ],
      ),
    );
  }

  /// v1.2.1: rediseñada al estilo oscuro/naranja de la app
  /// (antes fondo beige que no combinaba).
  /// Gemini: muestra CUP y USD por separado (no mezclar monedas).
  Widget _tarjetaTotal() {
    final total = _esDueno ? _totalDueno : _totalEntrenador;
    final hayPendiente = total > 0 || _totalUsd > 0;
    final subtitulo = _esDueno
        ? (hayPendiente
            ? 'por recoger de los entrenadores'
            : 'al día, nada que recoger')
        : (hayPendiente
            ? 'por entregar al dueño'
            : 'al día, nada pendiente');
    final colorAcento =
        hayPendiente ? AppColores.naranja : AppColores.exito;
    // Gemini: montos por moneda, sin mezclar.
    final montos = <String>[];
    if (total > 0) montos.add('${fmtMonto(total)} CUP');
    if (_totalUsd > 0) montos.add('${_totalUsd.toStringAsFixed(2)} USD');
    final textoMonto =
        montos.isEmpty ? '0 CUP' : montos.join(' · ');
    return Padding(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  hayPendiente
                      ? Icons.account_balance_wallet_outlined
                      : Icons.check_circle_outline,
                  color: colorAcento,
                  size: 28,
                ),
                const SizedBox(width: AppEspacio.sm),
                Flexible(
                  child: Text(textoMonto,
                      textAlign: TextAlign.center,
                      style: AppTexto.display.copyWith(
                        color: colorAcento,
                        fontWeight: FontWeight.bold,
                      )),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(subtitulo,
                style: AppTexto.secundario.copyWith(
                    color:
                        AppColores.textoSecundario(context))),
          ],
        ),
      ),
    );
  }

  /// Vista entrenador: sin cambios (su propio pendiente).
  Widget _listaEntrenador() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (_mens.isNotEmpty) ...[
          const Text('Mensualidades en efectivo:',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final p in _mens)
            ListTile(
              dense: true,
              leading: const Text(''),
              title:
                  Text('${fmtMonto(p['monto'])} CUP — ${p['metodo']}'),
              subtitle: Text(
                  '${fmtFecha(p['fecha'] as String?)} · ${p['meses'] ?? 1} mes(es)'),
            ),
          const SizedBox(height: 12),
        ],
        if (_diarios.isNotEmpty) ...[
          const Text('Pagos diarios:',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final d in _diarios)
            ListTile(
              dense: true,
              leading: const Text(''),
              title: Text('${fmtMonto(d['total'])} CUP'),
              subtitle: Text(
                  '${fmtFecha(d['fecha'] as String?)} · ${d['turno'] ?? ''} x${d['cantidad'] ?? '?'}'),
            ),
        ],
        if (_mens.isEmpty && _diarios.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Text(
                'Sin pagos pendientes de entrega.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ),
      ],
    );
  }

  /// Vista dueño: desglose por entrenador con confirmación individual.
  Widget _listaDueno() {
    if (_porEntrenador.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: const [
          Padding(
            padding: EdgeInsets.only(top: 32),
            child: Text(
                'Nada pendiente de recoger.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      );
    }
    return ListView.builder(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: _porEntrenador.length,
      itemBuilder: (ctx, i) {
        final e = _porEntrenador[i];
        final tid = e['id'] as int;
        final nombre = '${e['nombre']}';
        final n = e['n'] as int;
        final total = (e['total'] as num).toDouble();
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ExpansionTile(
            leading: CircleAvatar(
              backgroundColor: Colors.orange.shade100,
              child: Text(
                nombre.isNotEmpty ? nombre[0].toUpperCase() : '?',
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.deepOrange),
              ),
            ),
            title: Text(nombre,
                style:
                    const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('$n pago${n == 1 ? '' : 's'} sin entregar'),
            trailing: Text(
              '${fmtMonto(total)} CUP',
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.deepOrange,
                  fontSize: 15),
            ),
            children: [
              _detalleEntrenador(tid),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Text(''),
                    label: const Text('Confirmar recibido'),
                    onPressed: _confirmando
                        ? null
                        : () =>
                            _confirmarRecibido(tid, nombre, total),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
