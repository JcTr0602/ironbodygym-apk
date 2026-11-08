/// v1.3.6 (ítem 1C): cola de incidencias de sync.
///
/// Solo dueño. Muestra las operaciones rechazadas que el servidor guardó
/// en incidencias_sync, con botones Aprobar (aplica la op original a su
/// tabla destino) y Descartar. Al resolver, el servidor re-secuenciá la
/// fila y el pull la actualiza.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import '../sync.dart';
import 'app_bar.dart';
import 'auditoria.dart' show descripcionOp;
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';
import '../errores_sync.dart';
import '../app_log.dart';

class IncidenciasSyncScreen extends StatefulWidget {
  const IncidenciasSyncScreen({super.key});

  @override
  State<IncidenciasSyncScreen> createState() =>
      _IncidenciasSyncScreenState();
}

class _IncidenciasSyncScreenState extends State<IncidenciasSyncScreen> {
  bool _cargando = true;
  bool _procesando = false;
  List<Map<String, dynamic>> _pendientes = [];
  List<Map<String, dynamic>> _resueltas = [];
  bool _verResueltas = false;
  // 1.25 T123 (F6-05): nombres de cliente resueltos al
  // cargar, para que el resumen no enseñe «cliente_id: 123».
  Map<int, String> _nombresClientes = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final p = await incidenciasSyncPendientes();
      final r = await incidenciasSyncResueltas();
      // F6-05: resolver los nombres de los clientes citados
      // en los payloads (una pasada, sin N+1 en build).
      final nombres = <int, String>{};
      for (final inc in [...p, ...r]) {
        final cid = _clienteIdDe(inc);
        if (cid == null || cid <= 0 || nombres.containsKey(cid)) {
          continue;
        }
        final fila = await clientePorId(cid);
        final n = (fila?['nombre'] as String?)?.trim();
        if (n != null && n.isNotEmpty) nombres[cid] = n;
      }
      if (mounted) {
        setState(() {
          _pendientes = p;
          _resueltas = r;
          _nombresClientes = nombres;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// cliente_id citado en el payload de la incidencia.
  int? _clienteIdDe(Map<String, dynamic> inc) {
    try {
      final raw = inc['payload'];
      if (raw == null) return null;
      final p = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : Map<String, dynamic>.from(raw as Map);
      return (p['cliente_id'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  Future<void> _sincronizar() async {
    await SyncEngine.instance.sincronizarScope('incidencias_sync');
    await _cargar();
  }

  Future<void> _aprobar(Map<String, dynamic> inc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Aprobar incidencia'),
        content: Text(
          'Se aplicará la operación "${descripcionOp('${inc['tipo'] ?? ''}')}" rechazada '
          '(${inc['error'] ?? 'sin detalle'}). ¿Continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Aprobar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _procesando = true);
    try {
      await aprobarIncidenciaSync('${inc['id']}');
      if (mounted) {
        mostrarSnack(context, 'Aprobación enviada. Se aplicará al sincronizar.', significado: SignificadoChip.exito);
        await _cargar();
      }
    } catch (e) {
      AppLog.error('incidencias_sync', 'aprobar_fallo', d: '$e');
      _aviso('No se pudo aprobar: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _descartar(Map<String, dynamic> inc) async {
    // 1.29 (Oleada 4, barrido): el diálogo vive en un
    // StatefulWidget dueño de su controlador
    // (_DialogoDescartarIncidencia). Antes se creaba aquí y
    // se disponía nada más resolver el showDialog, con la
    // animación de salida aún reconstruyendo el campo (el
    // defecto D-B1-08; la captura previa del texto de la
    // 1.25 T41 solo evitaba perder la nota, no el uso tras
    // el dispose).
    final nota = await showDialog<String>(
      context: context,
      builder: (_) => _DialogoDescartarIncidencia(
          descripcion: descripcionOp('${inc['tipo'] ?? ''}')),
    );
    if (nota == null || !mounted) return;
    setState(() => _procesando = true);
    try {
      await descartarIncidenciaSync('${inc['id']}',
          nota: nota.isEmpty ? null : nota);
      if (mounted) {
        mostrarSnack(context, 'Incidencia descartada.', significado: SignificadoChip.exito);
        await _cargar();
      }
    } catch (e) {
      AppLog.error('incidencias_sync', 'descartar_fallo', d: '$e');
      _aviso('No se pudo descartar: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  void _aviso(String msg) {
    if (!mounted) return;
    mostrarSnack(context, msg);
  }

  /// Resumen legible del payload para la tarjeta.
  String _resumenPayload(Map<String, dynamic> inc) {
    final raw = inc['payload'];
    if (raw == null || (raw is String && raw.isEmpty)) return '';
    try {
      final p = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : Map<String, dynamic>.from(raw as Map);
      // F6-05: etiquetas en llano, sin claves del payload
      // («cliente_id: 123 · monto: 2000» no dice nada al
      // decidir). El cliente sale por su NOMBRE si el
      // payload lo trae o se resolvió al cargar.
      final partes = <String>[];
      final nombrePayload = (p['nombre'] as String?)?.trim();
      final cid = (p['cliente_id'] as num?)?.toInt();
      final nombre = (nombrePayload != null && nombrePayload.isNotEmpty)
          ? nombrePayload
          : (cid != null ? _nombresClientes[cid] : null);
      if (nombre != null && nombre.isNotEmpty) {
        partes.add('Cliente: $nombre');
      }
      if (p['monto'] != null) {
        partes.add('Monto: ${fmtMonto(p['monto'])} CUP');
      }
      if (p['total'] != null) {
        partes.add('Total: ${fmtMonto(p['total'])} CUP');
      }
      if (p['concepto'] != null) partes.add('Concepto: ${p['concepto']}');
      if (p['fecha'] != null) {
        partes.add('Fecha: ${fmtFecha('${p['fecha']}')}');
      }
      return partes.take(4).join(' · ');
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Incidencias de sync'),
        body: const Center(
            child: Text('Solo el dueño puede revisar estas incidencias.')),
      );
    }
    final lista = _verResueltas ? _resueltas : _pendientes;
    return Scaffold(
      appBar: appBarIron(
        context,
        'Incidencias de sync',
        acciones: [
          IconButton(
            tooltip: 'Sincronizar',
            icon: const Icon(Icons.sync_rounded),
            onPressed: _sincronizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                    value: false,
                    label:
                        Text('Pendientes (${_pendientes.length})')),
                ButtonSegment(
                    value: true,
                    label: Text('Resueltas (${_resueltas.length})')),
              ],
              selected: {_verResueltas},
              onSelectionChanged: (s) =>
                  setState(() => _verResueltas = s.first),
            ),
          ),
          Expanded(
            child: _cargando || _procesando
                ? const EstadoCargando(texto: 'Cargando incidencias…')
                : lista.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppEspacio.xxl),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                  _verResueltas
                                      ? Icons.history_rounded
                                      : Icons.check_circle_outline_rounded,
                                  size: 56,
                                  color: Colors.green),
                              const SizedBox(height: 12),
                              Text(
                                _verResueltas
                                    ? 'Sin incidencias resueltas todavía.'
                                    : 'Sin incidencias pendientes.',
                                style: AppTexto.subtitulo,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(AppEspacio.lg),
                          itemCount: lista.length,
                          itemBuilder: (_, i) =>
                              _tarjeta(lista[i]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _tarjeta(Map<String, dynamic> inc) {
    final pendiente = (inc['estado'] as String?) == 'pendiente';
    final resumen = _resumenPayload(inc);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_problem_rounded,
                    color: AppColores.alerta, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  // F6-05: el tipo de op traducido, no la
                  // clave cruda («pago_mensual»).
                  child: Text(descripcionOp('${inc['tipo'] ?? ''}'),
                      style: AppTexto.subtitulo),
                ),
                if (!pendiente)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppEspacio.sm, vertical: 2),
                    decoration: BoxDecoration(
                      color: (inc['estado'] == 'aprobada'
                              ? Colors.green
                              : AppColores.textoSecundario(context))
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(AppRadio.md),
                    ),
                    child: Text('${inc['estado']}',
                        style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if ((inc['error'] as String?)?.isNotEmpty == true)
              Text('Motivo: ${errorSyncLegible('${inc['error']}')}',
                  style: AppTexto.secundario),
            if (resumen.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Text(resumen,
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
              ),
            Padding(
              padding: const EdgeInsets.only(top: AppEspacio.xs),
              child: Text(
                '${inc['dispositivo'] ?? '—'} · ${inc['creada_en'] ?? ''}',
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
              ),
            ),
            if (pendiente) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Descartar'),
                    onPressed: () => _descartar(inc),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Aprobar'),
                    onPressed: () => _aprobar(inc),
                  ),
                ],
              ),
            ] else ...[
              if ((inc['resuelta_por'] as String?)?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: AppEspacio.xs),
                  child: Text(
                    'Resuelta por ${inc['resuelta_por']} · '
                    '${inc['resuelta_en'] ?? ''}',
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): «Descartar
/// incidencia» como StatefulWidget DUEÑO de su controlador,
/// dispuesto en dispose() — el patrón de la casa. Devuelve
/// la nota tecleada (recortada) al confirmar; null al
/// cancelar.
class _DialogoDescartarIncidencia extends StatefulWidget {
  const _DialogoDescartarIncidencia({required this.descripcion});

  final String descripcion;

  @override
  State<_DialogoDescartarIncidencia> createState() =>
      _DialogoDescartarIncidenciaState();
}

class _DialogoDescartarIncidenciaState
    extends State<_DialogoDescartarIncidencia> {
  final _notaCtrl = TextEditingController();

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Descartar incidencia'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Se descartará la operación "${widget.descripcion}" '
              'sin aplicarla.'),
          const SizedBox(height: 12),
          TextField(
            controller: _notaCtrl,
            decoration: const InputDecoration(
              labelText: 'Nota (opcional)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_notaCtrl.text.trim()),
          child: const Text('Descartar'),
        ),
      ],
    );
  }
}
