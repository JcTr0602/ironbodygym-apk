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

/// SL-8 (G08-5): el estado de una incidencia de sync,
/// traducido para pantalla. La BD guarda el código crudo
/// ('aprobada', 'descartada') y la tarjeta lo pintaba tal
/// cual; aquí pasa por el mismo criterio que el resto de
/// traductores de la casa y un estado desconocido jamás
/// sale crudo. Top-level para tests.
String etiquetaEstadoIncidenciaSync(String? estado) => switch (estado) {
      'pendiente' => 'Pendiente',
      'aprobada' => 'Aprobada',
      'descartada' => 'Descartada',
      _ => 'Estado registrado',
    };

class IncidenciasSyncScreen extends StatefulWidget {
  const IncidenciasSyncScreen({super.key});

  @override
  State<IncidenciasSyncScreen> createState() =>
      _IncidenciasSyncScreenState();
}

class _IncidenciasSyncScreenState extends State<IncidenciasSyncScreen> {
  bool _cargando = true;
  // (1.36 H-B4 136-907) el progreso es POR incidencia: la
  // lista no se vacía mientras una tarjeta se resuelve.
  final Set<String> _procesandoIds = {};
  // Auditoría Definitiva (B-15): error de carga VISIBLE. Esta
  // pantalla no recibió la familia R2-X1: su catch solo bajaba
  // _cargando y el build decía «Sin incidencias pendientes.»
  // — un fallo de lectura se pintaba como vacío, en silencio.
  String? _errorCarga;
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
          _errorCarga = null;
        });
      }
    } catch (e) {
      // B-15 (familia R2-X1): bitácora + error visible con
      // Reintentar; nunca más «vacío» por un fallo de lectura.
      AppLog.error('incidencias_sync', 'carga_fallo', d: '$e');
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = mensajeErrorAmable(e);
        });
      }
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
    // 1.34 Campo 2 (P-7): regla de Jc — fresco (≤10 min)
    // solo relee lo local; viejo baja el alcance primero.
    if (!await SyncEngine.instance.datosFrescos()) {
      await SyncEngine.instance.sincronizarScope('incidencias_sync');
    }
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
    setState(() => _procesandoIds.add('${inc['id']}'));
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
      if (mounted) setState(() => _procesandoIds.remove('${inc['id']}'));
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
    setState(() => _procesandoIds.add('${inc['id']}'));
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
      if (mounted) setState(() => _procesandoIds.remove('${inc['id']}'));
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
      // G#40 (Hy4): la moneda sale del payload (la op de
      // saldar fiado la trae: un fiado en USD se rotulaba
      // «CUP» y el dueño decidía sobre un monto mal
      // rotulado; el servidor sí aplica la moneda real).
      final monedaRaw = '${p['moneda'] ?? ''}'.trim();
      final moneda = monedaRaw.isEmpty ? 'CUP' : monedaRaw;
      if (p['monto'] != null) {
        partes.add('Monto: ${fmtMonto(p['monto'])} $moneda');
      }
      if (p['total'] != null) {
        partes.add('Total: ${fmtMonto(p['total'])} $moneda');
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
              // 1.36 H-B1 (136-322): guarda de selección
              // vacía antes de s.first.
              onSelectionChanged: (s) {
                if (s.isEmpty) return;
                setState(() => _verResueltas = s.first);
              },
            ),
          ),
          Expanded(
            child: _cargando
                ? const EstadoCargando(texto: 'Cargando incidencias…')
                : _errorCarga != null
                    ? EstadoError(
                        titulo:
                            'No se pudieron cargar las incidencias',
                        detalle: _errorCarga,
                        onReintentar: _cargar,
                      )
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
                    : RefrescoIron(
                        // (1.36 H-B4 136-907) bajar para
                        // actualizar SINCRONIZA el alcance,
                        // no solo relee lo local.
                        onRefresh: _sincronizar,
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

  // 1.30 D5 (UI130-19): la tarjeta adopta la anatomía común
  // [TarjetaDecision] que comparte con la incidencia
  // operativa: cabecera (icono + título + chip de estado),
  // contexto (dispositivo · fecha), el motivo en la
  // superficie de aviso y el pie con Descartar (destructiva)
  // y Aprobar (primaria) SOLO si sigue pendiente. Las
  // acciones y sus diálogos no cambian.
  Widget _tarjeta(Map<String, dynamic> inc) {
    final pendiente = (inc['estado'] as String?) == 'pendiente';
    final resumen = _resumenPayload(inc);
    final resueltaPor = (inc['resuelta_por'] as String?) ?? '';
    final resumenCompleto = [
      if (resumen.isNotEmpty) resumen,
      if (!pendiente && resueltaPor.isNotEmpty)
        // G08-5: la fecha de resolución también va formateada.
        'Resuelta por $resueltaPor · ${fmtFecha('${inc['resuelta_en'] ?? ''}')}',
    ].join('\n');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: TarjetaDecision(
        icono: Icons.sync_problem_rounded,
        colorIcono: AppColores.alerta,
        // F6-05: el tipo de op traducido, no la clave cruda
        // («pago_mensual»).
        titulo: descripcionOp('${inc['tipo'] ?? ''}'),
        chipEstado: ChipEstado.semantico(
          // G08-5: estado traducido, nunca el código crudo.
          texto: etiquetaEstadoIncidenciaSync('${inc['estado'] ?? ''}'),
          significado: pendiente
              ? SignificadoChip.alerta
              : inc['estado'] == 'aprobada'
                  ? SignificadoChip.exito
                  : SignificadoChip.neutral,
        ),
        // G08-5: la fecha del contexto con fmtFecha, como el
        // resumen del payload de esta misma tarjeta.
        contexto:
            '${inc['dispositivo'] ?? '—'} · ${fmtFecha('${inc['creada_en'] ?? ''}')}',
        motivo: (inc['error'] as String?)?.isNotEmpty == true
            ? 'Motivo: ${errorSyncLegible('${inc['error']}')}'
            : null,
        resumen: resumenCompleto.isEmpty ? null : resumenCompleto,
        pie: pendiente
            ? Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // (1.36 H-B4 136-907) progreso en ESTA tarjeta.
                  if (_procesandoIds.contains('${inc['id']}'))
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Descartar'),
                    onPressed: _procesandoIds.contains('${inc['id']}')
                        ? null
                        : () => _descartar(inc),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Aprobar'),
                    onPressed: _procesandoIds.contains('${inc['id']}')
                        ? null
                        : () => _aprobar(inc),
                  ),
                ],
              )
            : null,
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
      // (1.36 H-B4 136-907) desplazable con el teclado abierto.
      content: SingleChildScrollView(
        child: Column(
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
