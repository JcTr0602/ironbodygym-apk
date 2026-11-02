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
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

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
      if (mounted) {
        setState(() {
          _pendientes = p;
          _resueltas = r;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
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
          'Se aplicará la operación "${inc['tipo']}" rechazada '
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
      _aviso('No se pudo aprobar: $e');
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _descartar(Map<String, dynamic> inc) async {
    final notaCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Descartar incidencia'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                'Se descartará la operación "${inc['tipo']}" sin aplicarla.'),
            const SizedBox(height: 12),
            TextField(
              controller: notaCtrl,
              decoration: const InputDecoration(
                labelText: 'Nota (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    notaCtrl.dispose();
    if (ok != true || !mounted) return;
    setState(() => _procesando = true);
    try {
      await descartarIncidenciaSync('${inc['id']}',
          nota: notaCtrl.text.trim().isEmpty
              ? null
              : notaCtrl.text.trim());
      if (mounted) {
        mostrarSnack(context, 'Incidencia descartada.', significado: SignificadoChip.exito);
        await _cargar();
      }
    } catch (e) {
      _aviso('No se pudo descartar: $e');
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
      final partes = <String>[];
      for (final k in [
        'cliente_id',
        'monto',
        'total',
        'nombre',
        'concepto',
        'fecha'
      ]) {
        if (p[k] != null) partes.add('$k: ${p[k]}');
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
        appBar: AppBar(title: const Text('Incidencias de sync')),
        body: const Center(
            child: Text('Solo el dueño puede revisar estas incidencias.')),
      );
    }
    final lista = _verResueltas ? _resueltas : _pendientes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Incidencias de sync'),
        actions: [
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
                          padding: const EdgeInsets.all(32),
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
                          padding: const EdgeInsets.all(16),
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
                  child: Text('${inc['tipo'] ?? '—'}',
                      style: AppTexto.subtitulo),
                ),
                if (!pendiente)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (inc['estado'] == 'aprobada'
                              ? Colors.green
                              : AppColores.textoSecundario(context))
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
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
                padding: const EdgeInsets.only(top: 4),
                child: Text(resumen,
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
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
                  padding: const EdgeInsets.only(top: 4),
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
