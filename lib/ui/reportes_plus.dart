/// G2 (v1.7.0): bandeja «Reportes A++» — reportes de pago del
/// App Plus de los invitados, pendientes de decisión.
///
/// Visible para entrenadores (ven los reportes), pero Confirmar y
/// Rechazar son SOLO del dueño (decisión cerrada de Jc; gate
/// fail-closed con [puedeDecidirReportesPlus]). La decisión se
/// encola como op (confirmar y rechazar son ops distintas:
/// `plus_confirmar_reporte` / `plus_rechazar_reporte`) y la
/// aplica el servidor al sincronizar: esta pantalla nunca finge
/// que el Plus ya quedó activo, solo que la decisión va en
/// camino. Si el reporte ya se resolvió en otro dispositivo, el
/// servidor responde REPORTE_YA_RESUELTO y la op se ve como
/// aviso en «Incidencias de sync», sin cuelgues.
///
/// La lista viene de la RPC `plus_reportes_listar` (contrato en
/// lib/plus_reportes.dart): sin conexión muestra error con
/// reintento, nunca una bandeja «vacía» falsa.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../plus_reportes.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class ReportesPlusScreen extends StatefulWidget {
  /// Inyectables en tests: servicio de listado y si el usuario es
  /// el dueño. Null = se resuelven de la sesión real.
  final PlusReportesService? servicio;
  final bool? esDueno;

  const ReportesPlusScreen({super.key, this.servicio, this.esDueno});

  @override
  State<ReportesPlusScreen> createState() => _ReportesPlusScreenState();
}

class _ReportesPlusScreenState extends State<ReportesPlusScreen> {
  late final PlusReportesService _svc =
      widget.servicio ?? PlusReportesService();
  List<ReportePlus> _reportes = [];
  Set<String> _conOpPendiente = {};

  /// Decisiones encolándose AHORA (bloqueo sincrónico local, como
  /// en ReservasScreen): un segundo toque no puede encolar una
  /// decisión contradictoria sobre el mismo reporte.
  final Set<String> _enCurso = {};
  bool _cargando = true;
  String? _error;

  bool get _puedeDecidir => puedeDecidirReportesPlus(
      esDueno: widget.esDueno ?? AuthService().isOwner);

  bool _bloqueado(ReportePlus r) =>
      _enCurso.contains(r.id) || _conOpPendiente.contains(r.id);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    List<ReportePlus>? lista;
    String? error;
    try {
      lista = await _svc.pendientes();
    } catch (_) {
      error = 'Sin conexión o error del servidor. '
          'Los reportes se consultan en vivo; inténtalo de nuevo.';
    }
    final ops = await LocalDb.instance.pendingOps();
    if (!mounted) return;
    setState(() {
      if (lista != null) _reportes = lista;
      _error = error;
      _conOpPendiente = reportesPlusConOpPendiente(ops);
      _cargando = false;
    });
  }

  Future<void> _decidir(ReportePlus r, bool confirmar,
      {String? motivo, num? montoCup}) async {
    if (_bloqueado(r) || !_puedeDecidir) return;
    // Bloqueo SINCRÓNICO, antes del primer await.
    setState(() => _enCurso.add(r.id));
    try {
      await encolarDecisionPlus(
        LocalDb.instance,
        reporte: r,
        confirmar: confirmar,
        motivo: motivo,
        montoCup: montoCup,
        opUuid: const Uuid().v4(),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _enCurso.remove(r.id));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo guardar la decisión. '
                'Inténtalo de nuevo.')));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _enCurso.remove(r.id);
      _conOpPendiente = {..._conOpPendiente, r.id};
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(confirmar
            ? 'Confirmación encolada: el Plus se activa al sincronizar'
            : 'Rechazo encolado: se aplica al sincronizar')));
    unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  }

  Future<void> _confirmar(ReportePlus r) async {
    if (_bloqueado(r)) return;
    // El contrato pide `monto_cup` en la confirmación: el dueño
    // puede ajustarlo si la transferencia difiere de lo cotizado
    // (por defecto, el monto del reporte).
    final ctrl = TextEditingController(
        text: r.monto % 1 == 0
            ? '${r.monto.toInt()}'
            : '${r.monto}');
    var errorMonto = false;
    final monto = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDlg) => DialogoApp(
          titulo: 'Confirmar pago App Plus',
          iconoTitulo: Icons.star_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${r.nombre} reportó ${fmtMonto(r.monto)} CUP '
                  'por transferencia (referencia ${r.referencia}).'
                  '\n\nAl confirmar, el invitado recibe 30 días de '
                  'App Plus desde que el servidor procese la '
                  'confirmación.'),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                keyboardType:
                    const TextInputType.numberWithOptions(
                        decimal: true),
                decoration: InputDecoration(
                  labelText: 'Monto confirmado (CUP)',
                  border: const OutlineInputBorder(),
                  errorText: errorMonto
                      ? 'Escribe un monto válido mayor que 0'
                      : null,
                ),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(
                    ctrl.text.trim().replaceAll(',', '.'));
                // Finito y > 0: tryParse acepta «NaN»/«Infinity»
                // y con NaN ninguna comparación los frenaría.
                if (!montoConfirmacionPlusValido(v)) {
                  setStateDlg(() => errorMonto = true);
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (monto != null && mounted) {
      await _decidir(r, true, montoCup: monto);
    }
  }

  Future<void> _rechazar(ReportePlus r) async {
    if (_bloqueado(r)) return;
    final ctrl = TextEditingController();
    var errorMotivo = false;
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDlg) => DialogoApp(
          titulo: 'Rechazar reporte App Plus',
          iconoTitulo: Icons.star_border_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${r.nombre} · ${fmtMonto(r.monto)} CUP · '
                  'ref. ${r.referencia}'),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  labelText: 'Motivo (obligatorio, lo ve el invitado)',
                  border: const OutlineInputBorder(),
                  errorText: errorMotivo
                      ? 'Escribe el motivo del rechazo'
                      : null,
                ),
                maxLength: 200,
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (ctrl.text.trim().isEmpty) {
                  setStateDlg(() => errorMotivo = true);
                  return;
                }
                Navigator.pop(ctx, ctrl.text.trim());
              },
              child: const Text('Rechazar'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (motivo != null && mounted) {
      await _decidir(r, false, motivo: motivo);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reportes App Plus')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando reportes…');
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.naranja),
              const SizedBox(height: AppEspacio.md),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: AppTexto.secundario),
              const SizedBox(height: AppEspacio.md),
              FilledButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reintentar'),
                onPressed: () {
                  setState(() => _cargando = true);
                  _cargar();
                },
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          if (!_puedeDecidir)
            const Padding(
              padding: EdgeInsets.only(bottom: AppEspacio.md),
              child: Tarjeta(
                child: Row(
                  children: [
                    Icon(Icons.lock_outline_rounded,
                        color: AppColores.naranja),
                    SizedBox(width: AppEspacio.sm),
                    Expanded(
                      child: Text(
                        'Puedes ver los reportes; confirmar o '
                        'rechazar el pago es solo del dueño.',
                        style: AppTexto.secundario,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_reportes.isEmpty)
            const EstadoVacio(
              icono: Icons.star_outline_rounded,
              titulo: 'Sin reportes pendientes',
              subtitulo:
                  'Cuando un invitado reporte el pago de su App '
                  'Plus, aparecerá aquí para que el dueño lo '
                  'confirme.',
            )
          else
            for (final r in _reportes) _tarjeta(r),
        ],
      ),
    );
  }

  Widget _tarjeta(ReportePlus r) {
    final bloqueado = _bloqueado(r);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(r.nombre, style: AppTexto.titulo),
                ),
                Text('${fmtMonto(r.monto)} CUP',
                    style: AppTexto.titulo.copyWith(
                        color: AppColores.naranja)),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            _fila(Icons.phone_rounded, r.telefono.isEmpty
                ? 'Sin teléfono'
                : r.telefono),
            _fila(Icons.receipt_long_rounded,
                'Referencia: ${r.referencia}'),
            if (r.banco.isNotEmpty)
              _fila(Icons.account_balance_rounded, r.banco),
            if (r.movilOrigen.isNotEmpty)
              _fila(Icons.smartphone_rounded,
                  'Desde el móvil ${r.movilOrigen}'),
            if (r.creadoEn != null)
              _fila(Icons.schedule_rounded,
                  'Reportado ${hace(r.creadoEn)}'),
            // Alerta del servidor (ajuste 1 de Argón): la
            // referencia ya apareció en un reporte rechazado. Se
            // avisa; NO se bloquea la confirmación.
            if (r.alertaReferenciaRechazada)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: AppColores.alerta),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Ojo: esta referencia ya apareció en un '
                        'reporte rechazado. Revísala bien antes de '
                        'confirmar.',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColores.alerta),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppEspacio.sm),
            if (bloqueado)
              const Row(
                children: [
                  Icon(Icons.sync_rounded,
                      size: 16, color: AppColores.info),
                  SizedBox(width: 6),
                  Text('Decisión encolada: se aplica al sincronizar',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColores.info)),
                ],
              )
            else if (_puedeDecidir)
              Row(
                children: [
                  Expanded(
                    child: BotonPrimario(
                      texto: 'Confirmar',
                      icono: Icons.check_rounded,
                      onPressed: () => _confirmar(r),
                    ),
                  ),
                  const SizedBox(width: AppEspacio.sm),
                  Expanded(
                    child: BotonSecundario(
                      texto: 'Rechazar',
                      icono: Icons.close_rounded,
                      onPressed: () => _rechazar(r),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _fila(IconData icono, String texto) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icono,
              size: 15, color: AppColores.textoSecundario(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(texto, style: AppTexto.secundario),
          ),
        ],
      ),
    );
  }
}
