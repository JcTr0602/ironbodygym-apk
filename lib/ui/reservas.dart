import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../permisos_entrenador.dart';
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
  // v1.4.6: moneda snapshot de la reserva (la de la foto de
  // precio al reservar), no la del catálogo actual.
  final String moneda;
  // v1.4.6: moneda ACTUAL del suplemento en el catálogo. Si
  // difiere de [moneda] (el dueño cambió la moneda del producto
  // tras crearse la reserva), el precio vigente NO es comparable
  // con el snapshot: no hay diferencia numérica válida.
  final String monedaVigente;
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
    this.moneda = 'CUP',
    this.monedaVigente = 'CUP',
    required this.estado,
    required this.creadaTs,
    required this.expiraEn,
    required this.notaResolucion,
  });

  double get totalFoto => cantidad * precioUnitario;

  /// Diferencia total contra el precio vigente del catálogo
  /// (null si el suplemento ya no está en el espejo, o si la
  /// moneda del catálogo difiere de la snapshot: restar unidades
  /// incompatibles fabricaría una diferencia falsa).
  double? get diferenciaTotal => precioVigente == null ||
          monedaVigente != moneda
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
      // v1.4.6: moneda snapshot que trae la propia reserva.
      moneda: LocalDb.monedaDe(r),
      // v1.4.6: moneda vigente del catálogo; sin suplemento en
      // el espejo, la del snapshot (nada con qué comparar).
      monedaVigente:
          supl == null ? LocalDb.monedaDe(r) : LocalDb.monedaDe(supl),
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

/// Aviso de «precio hoy» cuando la moneda del catálogo difiere
/// de la snapshot de la reserva: el precio vigente va con SU
/// moneda y SIN diferencia numérica (unidades incompatibles), y
/// queda claro que el cobro usa el precio al reservar. Null si
/// no hay precio vigente o si las monedas coinciden (en ese caso
/// manda la diferencia normal de [ReservaVista.diferenciaTotal]).
String? avisoMonedaReserva(ReservaVista r) {
  if (r.precioVigente == null || r.monedaVigente == r.moneda) {
    return null;
  }
  return 'Precio hoy: ${fmtMonto(r.precioVigente)} '
      '${r.monedaVigente}. Se cobra el precio al reservar: '
      '${fmtMonto(r.precioUnitario)} ${r.moneda}.';
}

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
  /// Acceso a la bandeja. Null = se calcula de la sesión (dueño
  /// o can_vender_suplementos, la misma clave que exige el
  /// servidor para las ops). Inyectable en tests.
  final bool? accesoPermitido;

  const ReservasScreen({super.key, this.accesoPermitido});

  @override
  State<ReservasScreen> createState() => _ReservasScreenState();
}

class _ReservasScreenState extends State<ReservasScreen> {
  BandejaReservas? _bandeja;
  Set<int> _conOpPendiente = {};

  /// Reservas con una op encolándose AHORA (panel Gestión
  /// 2026-10-21): el bloqueo es inmediato y local, antes de
  /// cualquier await — un segundo toque no puede encolar una
  /// op contradictoria mientras la primera se persiste o la
  /// sincronización corre (o falla).
  final Set<int> _enCurso = {};
  bool _cargando = true;

  bool get _puedeAcceder =>
      widget.accesoPermitido ??
      (AuthService().isOwner ||
          PermisosEntrenador().canVenderSuplementos);

  bool _bloqueada(int id) =>
      _enCurso.contains(id) || _conOpPendiente.contains(id);

  @override
  void initState() {
    super.initState();
    if (_puedeAcceder) _cargar();
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
    try {
      await SyncEngine.instance.sincronizarScope('suplementos');
    } catch (_) {
      // Sin red o sync ocupado: la cola y el bloqueo ya están
      // persistidos; se relee lo que haya y el ciclo normal de
      // sincronización resuelve el envío.
    }
    await _cargar();
  }

  Future<void> _encolar(String tipo, Map<String, dynamic> payload,
      String mensajeOk) async {
    final rid = _entero(payload['reserva_id']);
    if (rid <= 0 || _bloqueada(rid)) return;
    // Bloqueo SINCRÓNICO, antes del primer await (panel).
    setState(() => _enCurso.add(rid));
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: tipo,
        payload: payload,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _enCurso.remove(rid));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo guardar la acción. '
                'Inténtalo de nuevo.')));
      }
      return;
    }
    if (!mounted) return;
    // La op ya está persistida: la tarjeta queda bloqueada
    // desde ya, sin esperar a que la sincronización termine.
    setState(() {
      _enCurso.remove(rid);
      _conOpPendiente = {..._conOpPendiente, rid};
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(mensajeOk)));
    await _refrescar();
  }

  Future<void> _confirmar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar reserva',
      mensaje: '${r.clienteNombre} aparta ${r.cantidad} × '
          '${r.suplementoNombre} a ${fmtMonto(r.precioUnitario)} ${r.moneda} '
          '(${fmtMonto(r.totalFoto)} ${r.moneda} en total).\n\n'
          'El apartado dura 72 horas: ese stock no se puede vender '
          'a nadie más hasta que pague o venza.',
      aceptar: 'Confirmar',
      icono: Icons.bookmark_added,
    );
    if (ok && mounted) {
      await _encolar('confirmar_reserva', {'reserva_id': r.id},
          'Confirmación de la reserva #${r.id} encolada');
    }
  }

  Future<void> _rechazar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
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
          'Rechazo de la reserva #${r.id} encolado');
    }
    ctrl.dispose();
  }

  Future<void> _cancelar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
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
          'Cancelación de la reserva #${r.id} encolada');
    }
  }

  Future<void> _cobrar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
    var metodo = 'efectivo';
    final dif = r.diferenciaTotal;
    final avisoMoneda = avisoMonedaReserva(r);
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
              Text('Total a cobrar: ${fmtMonto(r.totalFoto)} ${r.moneda}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              Text('Precio al reservar: '
                  '${fmtMonto(r.precioUnitario)} ${r.moneda}'),
              if (avisoMoneda != null)
                Text(
                  avisoMoneda,
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.error),
                ),
              if (dif != null && dif != 0)
                Text(
                  'Precio hoy: ${fmtMonto(r.precioVigente)} ${r.moneda} — '
                  '${dif > 0 ? '+' : ''}${fmtMonto(dif)} ${r.moneda} de '
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
    // La puerta de acceso vive TAMBIÉN en la pantalla (panel
    // Gestión 2026-10-21): el botón de Suplementos no es la
    // única ruta posible hasta aquí.
    if (!_puedeAcceder) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reservas')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No tienes permiso para ver las reservas.\n'
              'Pídele al dueño que te active «Vender suplementos».',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
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
                          TarjetaReserva(
                            reserva: r,
                            bloqueada: _bloqueada(r.id),
                            onConfirmar: () => _confirmar(r),
                            onRechazar: () => _rechazar(r),
                            onCancelar: () => _cancelar(r),
                            onCobrar: () => _cobrar(r),
                          ),
                      ],
                      if (b.reservadas.isNotEmpty) ...[
                        _tituloSeccion('Reservadas', b.reservadas.length),
                        for (final r in b.reservadas)
                          TarjetaReserva(
                            reserva: r,
                            bloqueada: _bloqueada(r.id),
                            onConfirmar: () => _confirmar(r),
                            onRechazar: () => _rechazar(r),
                            onCancelar: () => _cancelar(r),
                            onCobrar: () => _cobrar(r),
                          ),
                      ],
                      if (b.historial.isNotEmpty) ...[
                        _tituloSeccion('Historial', b.historial.length),
                        for (final r in b.historial)
                          TarjetaReserva(
                            reserva: r,
                            bloqueada: _bloqueada(r.id),
                            onConfirmar: () => _confirmar(r),
                            onRechazar: () => _rechazar(r),
                            onCancelar: () => _cancelar(r),
                            onCobrar: () => _cobrar(r),
                          ),
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

}

/// Tarjeta de una reserva. Widget sin estado y sin dependencias
/// de BD/sync (testeable directo): la pantalla le pasa si está
/// [bloqueada] (op encolada o encolándose) y los callbacks; con
/// bloqueo muestra el chip y NINGÚN botón de acción.
class TarjetaReserva extends StatelessWidget {
  final ReservaVista reserva;
  final bool bloqueada;
  final VoidCallback onConfirmar;
  final VoidCallback onRechazar;
  final VoidCallback onCancelar;
  final VoidCallback onCobrar;

  const TarjetaReserva({
    super.key,
    required this.reserva,
    required this.bloqueada,
    required this.onConfirmar,
    required this.onRechazar,
    required this.onCancelar,
    required this.onCobrar,
  });

  @override
  Widget build(BuildContext context) {
    final r = reserva;
    final solicitada = r.estado == 'solicitada';
    final reservada = r.estado == 'reservada';
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
            Text('Total: ${fmtMonto(r.totalFoto)} ${r.moneda} '
                '(${fmtMonto(r.precioUnitario)} ${r.moneda} c/u al reservar)'),
            if (avisoMonedaReserva(r) != null)
              Text(avisoMonedaReserva(r)!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            if (solicitada || reservada)
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
                    onPressed: onRechazar,
                    child: const Text('Rechazar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onConfirmar,
                    child: const Text('Confirmar'),
                  ),
                ],
              ),
            if (reservada && !bloqueada)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: onCancelar,
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onCobrar,
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
