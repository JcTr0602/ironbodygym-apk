import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';

/// Reservas v2 — bandeja del gimnasio.
///
/// Lee el espejo `reservas` (proyección que publica el puente
/// desde gym.db, la autoridad) y actúa con ops de la cola:
/// confirmar_reserva / rechazar_reserva / cancelar_reserva /
/// cobrar_reserva (las 4 mapeadas a can_vender_suplementos en
/// el servidor). El estado que se muestra es SIEMPRE el del
/// servidor: nada de escrituras optimistas en el espejo — si
/// una reserva tiene una op encolada, su tarjeta lo dice y los
/// botones se bloquean hasta que la sincronización la resuelva.

// ------------------------------------------------------------------
// Helpers puros (tests en test/reservas_test.dart)
// ------------------------------------------------------------------

class ReservaVista {
  final int id;
  final int clienteId;
  final String clienteNombre;
  final int suplementoId;
  final String suplementoNombre;
  final int cantidad;
  final double precioUnitario;
  final double? precioVigente;
  final String estado;
  final String creadaTs;
  final String? expiraEn;
  final String? notaResolucion;

  const ReservaVista({
    required this.id,
    required this.clienteId,
    required this.clienteNombre,
    required this.suplementoId,
    required this.suplementoNombre,
    required this.cantidad,
    required this.precioUnitario,
    required this.precioVigente,
    required this.estado,
    required this.creadaTs,
    required this.expiraEn,
    required this.notaResolucion,
  });

  double get totalFoto => cantidad * precioUnitario;

  /// Diferencia total contra el precio vigente del catálogo
  /// (null si el suplemento ya no está en el espejo).
  double? get diferenciaTotal => precioVigente == null
      ? null
      : (precioVigente! - precioUnitario) * cantidad;
}

class BandejaReservas {
  final List<ReservaVista> solicitadas;
  final List<ReservaVista> reservadas;
  final List<ReservaVista> historial;
  const BandejaReservas(this.solicitadas, this.reservadas, this.historial);
}

int _entero(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
double _doble(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// Arma la bandeja desde los espejos: solicitadas en orden de
/// llegada (FIFO), reservadas por vencimiento más cercano,
/// historial (terminales) reciente primero, tope 30.
BandejaReservas construirBandeja(
  List<Map<String, dynamic>> reservas,
  List<Map<String, dynamic>> clientes,
  List<Map<String, dynamic>> suplementos,
) {
  final nombreCliente = {
    for (final c in clientes) _entero(c['id']): (c['nombre'] ?? '') as String,
  };
  final suplPorId = {
    for (final s in suplementos) _entero(s['id']): s,
  };
  ReservaVista vista(Map<String, dynamic> r) {
    final sid = _entero(r['suplemento_id']);
    final supl = suplPorId[sid];
    return ReservaVista(
      id: _entero(r['id']),
      clienteId: _entero(r['cliente_id']),
      clienteNombre:
          nombreCliente[_entero(r['cliente_id'])] ?? 'Cliente #${r['cliente_id']}',
      suplementoId: sid,
      suplementoNombre:
          (supl?['nombre'] as String?) ?? 'Suplemento #$sid',
      cantidad: _entero(r['cantidad']),
      precioUnitario: _doble(r['precio_unitario']),
      precioVigente:
          supl == null ? null : _doble(supl['precio_oficial']),
      estado: (r['estado'] ?? '') as String,
      creadaTs: (r['creada_ts'] ?? '') as String,
      expiraEn: r['expira_en'] as String?,
      notaResolucion: r['nota_resolucion'] as String?,
    );
  }

  final todas = [for (final r in reservas) vista(r)];
  final solicitadas = [
    for (final v in todas)
      if (v.estado == 'solicitada') v
  ]..sort((a, b) => a.creadaTs.compareTo(b.creadaTs));
  final reservadas = [
    for (final v in todas)
      if (v.estado == 'reservada') v
  ]..sort((a, b) => (a.expiraEn ?? '9999').compareTo(b.expiraEn ?? '9999'));
  final historial = [
    for (final v in todas)
      if (v.estado != 'solicitada' && v.estado != 'reservada') v
  ]..sort((a, b) => b.creadaTs.compareTo(a.creadaTs));
  return BandejaReservas(
      solicitadas, reservadas, historial.take(30).toList());
}

const tiposOpReserva = {
  'confirmar_reserva',
  'rechazar_reserva',
  'cancelar_reserva',
  'cobrar_reserva',
};

/// Ids de reservas con una op encolada (pendiente o en error):
/// su tarjeta se bloquea hasta que la sincronización resuelva.
Set<int> reservasConOpPendiente(List<Map<String, dynamic>> ops) {
  final ids = <int>{};
  for (final op in ops) {
    if (!tiposOpReserva.contains(op['tipo'])) continue;
    try {
      final payload = jsonDecode(op['payload'] as String) as Map;
      final rid = _entero(payload['reserva_id']);
      if (rid > 0) ids.add(rid);
    } catch (_) {
      // Payload ilegible: no bloquea nada.
    }
  }
  return ids;
}

/// Texto de vencimiento de un apartado/solicitud.
String textoVenceEn(String? expiraEnIso, DateTime ahora) {
  if (expiraEnIso == null || expiraEnIso.isEmpty) return '';
  final vence = DateTime.tryParse(expiraEnIso);
  if (vence == null) return '';
  final dif = vence.difference(ahora);
  if (dif.isNegative) return 'Vencida — se libera sola';
  if (dif.inHours >= 24) {
    final d = dif.inDays;
    final h = dif.inHours - d * 24;
    return 'Vence en $d d${h > 0 ? ' $h h' : ''}';
  }
  if (dif.inHours >= 1) return 'Vence en ${dif.inHours} h';
  return 'Vence en ${dif.inMinutes} min';
}

String etiquetaEstadoReserva(String estado) {
  switch (estado) {
    case 'solicitada':
      return 'Solicitada';
    case 'reservada':
      return 'Reservada';
    case 'pagada':
      return 'Pagada';
    case 'rechazada':
      return 'Rechazada';
    case 'cancelada':
      return 'Cancelada';
    case 'expirada':
      return 'Expirada';
    default:
      return estado;
  }
}

// ------------------------------------------------------------------
// Pantalla
// ------------------------------------------------------------------

class ReservasScreen extends StatefulWidget {
  const ReservasScreen({super.key});

  @override
  State<ReservasScreen> createState() => _ReservasScreenState();
}

class _ReservasScreenState extends State<ReservasScreen> {
  BandejaReservas? _bandeja;
  Set<int> _conOpPendiente = {};
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final reservas = await LocalDb.instance.allMirror('reservas');
    final clientes = await LocalDb.instance.allMirror('clientes');
    final suplementos = await LocalDb.instance.allMirror('suplementos');
    final ops = await LocalDb.instance.pendingOps();
    if (!mounted) return;
    setState(() {
      _bandeja = construirBandeja(reservas, clientes, suplementos);
      _conOpPendiente = reservasConOpPendiente(ops);
      _cargando = false;
    });
  }

  Future<void> _refrescar() async {
    await SyncEngine.instance.sincronizarScope('suplementos');
    await _cargar();
  }

  Future<void> _encolar(String tipo, Map<String, dynamic> payload,
      String mensajeOk) async {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: tipo,
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(mensajeOk)));
    await _refrescar();
  }

  Future<void> _confirmar(ReservaVista r) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar reserva',
      mensaje: '${r.clienteNombre} aparta ${r.cantidad} × '
          '${r.suplementoNombre} a ${fmtMonto(r.precioUnitario)} CUP '
          '(${fmtMonto(r.totalFoto)} CUP en total).\n\n'
          'El apartado dura 72 horas: ese stock no se puede vender '
          'a nadie más hasta que pague o venza.',
      aceptar: 'Confirmar',
      icono: Icons.bookmark_added,
    );
    if (ok && mounted) {
      await _encolar('confirmar_reserva', {'reserva_id': r.id},
          'Reserva #${r.id} confirmada — se sincroniza ahora');
    }
  }

  Future<void> _rechazar(ReservaVista r) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Rechazar reserva',
        iconoTitulo: Icons.bookmark_remove,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${r.clienteNombre} · ${r.cantidad} × '
                '${r.suplementoNombre}'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional, lo ve el cliente)',
                border: OutlineInputBorder(),
              ),
              maxLength: 200,
            ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      final nota = ctrl.text.trim();
      await _encolar(
          'rechazar_reserva',
          {'reserva_id': r.id, if (nota.isNotEmpty) 'nota': nota},
          'Reserva #${r.id} rechazada — se sincroniza ahora');
    }
    ctrl.dispose();
  }

  Future<void> _cancelar(ReservaVista r) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cancelar reserva',
      mensaje: 'Se cancela la reserva de ${r.clienteNombre} '
          '(${r.cantidad} × ${r.suplementoNombre})'
          '${r.estado == 'reservada' ? ' y el apartado se libera' : ''}.',
      aceptar: 'Cancelar reserva',
      icono: Icons.bookmark_remove,
      peligro: true,
    );
    if (ok && mounted) {
      await _encolar('cancelar_reserva', {'reserva_id': r.id},
          'Reserva #${r.id} cancelada — se sincroniza ahora');
    }
  }

  Future<void> _cobrar(ReservaVista r) async {
    var metodo = 'efectivo';
    final dif = r.diferenciaTotal;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDlg) => DialogoApp(
          titulo: 'Cobrar reserva',
          iconoTitulo: Icons.payments,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${r.clienteNombre} · ${r.cantidad} × '
                  '${r.suplementoNombre}'),
              const SizedBox(height: 8),
              Text('Total a cobrar: ${fmtMonto(r.totalFoto)} CUP',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              Text('Precio al reservar: '
                  '${fmtMonto(r.precioUnitario)} CUP'),
              if (dif != null && dif != 0)
                Text(
                  'Precio hoy: ${fmtMonto(r.precioVigente)} CUP — '
                  '${dif > 0 ? '+' : ''}${fmtMonto(dif)} CUP de '
                  'diferencia. Se cobra el de la reserva.',
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.error),
                ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'efectivo',
                      label: Text('Efectivo'),
                      icon: Icon(Icons.money)),
                  ButtonSegment(
                      value: 'transferencia',
                      label: Text('Transferencia'),
                      icon: Icon(Icons.account_balance)),
                ],
                selected: {metodo},
                onSelectionChanged: (s) =>
                    setStateDlg(() => metodo = s.first),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cobrar'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      await _encolar(
          'cobrar_reserva',
          {'reserva_id': r.id, 'metodo': metodo},
          'Cobro de la reserva #${r.id} encolado — se sincroniza ahora');
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bandeja;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reservas'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Sincronizar',
            onPressed: _refrescar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : b == null ||
                  (b.solicitadas.isEmpty &&
                      b.reservadas.isEmpty &&
                      b.historial.isEmpty)
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Todavía no hay reservas.\nCuando un cliente '
                      'reserve un suplemento desde su app, aparece aquí.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refrescar,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (b.solicitadas.isNotEmpty) ...[
                        _tituloSeccion(
                            'Solicitadas', b.solicitadas.length),
                        for (final r in b.solicitadas)
                          _tarjeta(r, solicitada: true),
                      ],
                      if (b.reservadas.isNotEmpty) ...[
                        _tituloSeccion('Reservadas', b.reservadas.length),
                        for (final r in b.reservadas)
                          _tarjeta(r, reservada: true),
                      ],
                      if (b.historial.isNotEmpty) ...[
                        _tituloSeccion('Historial', b.historial.length),
                        for (final r in b.historial) _tarjeta(r),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _tituloSeccion(String titulo, int n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Text('$titulo ($n)',
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold)),
    );
  }

  Widget _tarjeta(ReservaVista r,
      {bool solicitada = false, bool reservada = false}) {
    final bloqueada = _conOpPendiente.contains(r.id);
    final ahora = ahoraHabana();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(r.clienteNombre,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                Chip(
                  label: Text(etiquetaEstadoReserva(r.estado)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            Text('${r.cantidad} × ${r.suplementoNombre}'),
            Text('Total: ${fmtMonto(r.totalFoto)} CUP '
                '(${fmtMonto(r.precioUnitario)} c/u al reservar)'),
            if (solicitada)
              Text(textoVenceEn(r.expiraEn, ahora),
                  style: const TextStyle(color: Colors.orange)),
            if (reservada)
              Text(textoVenceEn(r.expiraEn, ahora),
                  style: const TextStyle(color: Colors.orange)),
            if (r.notaResolucion != null &&
                r.notaResolucion!.isNotEmpty)
              Text('Nota: ${r.notaResolucion}'),
            if (bloqueada)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Chip(
                  avatar: Icon(Icons.hourglass_top, size: 16),
                  label: Text('Acción encolada — sincronizando'),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            if (solicitada && !bloqueada)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => _rechazar(r),
                    child: const Text('Rechazar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _confirmar(r),
                    child: const Text('Confirmar'),
                  ),
                ],
              ),
            if (reservada && !bloqueada)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => _cancelar(r),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _cobrar(r),
                    child: const Text('Cobrar'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
