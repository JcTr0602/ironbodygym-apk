/// T4 (1.20): bandeja «Transferencias por comprobar» del
/// dueño + diálogo compartido de conciliación (lo usan la
/// bandeja y la ficha del cliente).
///
/// La conciliación es CONTROL, no contabilidad: marcar una
/// transferencia no toca la vigencia ni el dinero (la
/// semántica aprobada por Jc: la transferencia pendiente
/// extiende la vigencia igual). El servidor valida dueño,
/// estado esperado (CAS) y nota obligatoria en
/// problema/rechazada; si el estado ya cambió en otro
/// teléfono, la op rebota y llega por incidencias.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../comprobantes.dart';
import '../conciliacion.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import '../errores_sync.dart';
import '../app_log.dart';

/// Color semántico del chip de cada estado de conciliación.
SignificadoChip significadoConciliacion(String estado) {
  switch (estado) {
    case 'pendiente':
      return SignificadoChip.alerta;
    case 'comprobada':
      return SignificadoChip.exito;
    case 'problema':
    case 'rechazada':
      return SignificadoChip.error;
    default:
      return SignificadoChip.neutral;
  }
}

/// Diálogo para conciliar UN pago por transferencia.
/// Devuelve true si se encoló la marca (el espejo se
/// actualiza al sincronizar; no hay edición optimista).
Future<bool> mostrarDialogoConciliar(
  BuildContext context, {
  required Map<String, dynamic> pago,
  String? nombreCliente,
}) async {
  // 1.29 (Oleada 4, barrido): el diálogo vive en un
  // StatefulWidget dueño de su controlador (_DialogoConciliar);
  // ver su doc. El aviso de éxito sigue aquí, como siempre.
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _DialogoConciliar(pago: pago, nombreCliente: nombreCliente),
  );
  if (ok == true && context.mounted) {
    mostrarSnack(context, 'Conciliación guardada (se sincronizará)',
        significado: SignificadoChip.exito);
  }
  return ok == true;
}

/// Ver la foto del comprobante de una transferencia (misma
/// cadena de resolución que la ficha: archivo local → ruta
/// guardada → ruta determinista vía FotoCache).
Future<void> verComprobanteTransferencia(
    BuildContext context, String uuid) async {
  File? local;
  try {
    final fila = await ComprobantesService.instance.filaDe(uuid);
    final ruta = fila?['ruta_local'] as String?;
    if (ruta != null) {
      final f = File(ruta);
      if (await f.exists() && await f.length() > 0) local = f;
    }
    if (local == null) {
      final exacta = fila?['storage_path'] as String?;
      if (exacta != null && exacta.isNotEmpty) {
        local = await FotoCache.instance.obtener(exacta);
      }
    }
    if (local == null) {
      for (final ext in ['webp', 'jpg']) {
        local = await FotoCache.instance
            .obtener(rutaStorageComprobante(uuid, ext));
        if (local != null) break;
      }
    }
  } catch (_) {}
  if (!context.mounted) return;
  if (local == null) {
    mostrarSnack(context,
        'El comprobante aún no está disponible en este teléfono',
        significado: SignificadoChip.alerta);
    return;
  }
  final archivo = local;
  await showDialog<void>(
    context: context,
    builder: (ctx) => DialogoApp(
      titulo: 'Comprobante de la transferencia',
      iconoTitulo: Icons.image_rounded,
      // FIN-02 de Argón (1.20): zoom con pellizco — los números
      // de confirmación bancaria tienen tipografía pequeña.
      contenido: InteractiveViewer(
        minScale: 1.0,
        maxScale: 4.0,
        child: Image.file(archivo,
            errorBuilder: (context, error, stackTrace) => const Text(
                'No se pudo mostrar la imagen del comprobante.')),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );
}

/// Bandeja del dueño: transferencias pendientes de
/// comprobación (y con problema) + resueltas recientes.
/// Los pagos históricos (anteriores a T4) no entran.
class ConciliacionScreen extends StatefulWidget {
  const ConciliacionScreen({super.key});

  @override
  State<ConciliacionScreen> createState() =>
      _ConciliacionScreenState();
}

class _ConciliacionScreenState extends State<ConciliacionScreen> {
  bool _cargando = true;
  // Yunque de App 1.31 (C1-2): el fallo de carga se PINTA
  // como error, no como «no hay transferencias esperando».
  String? _falloCarga;
  List<Map<String, dynamic>> _porComprobar = [];
  List<Map<String, dynamic>> _resueltas = [];
  Map<int, String> _nombres = {};
  // (M2-BC B4) conciliación en lote: modo selección sobre
  // las «por comprobar» y el conjunto de ids elegidos.
  bool _seleccionando = false;
  final Set<int> _seleccion = {};

  void _alternarSeleccion(int id, bool? v) {
    setState(() {
      if (v == true) {
        _seleccion.add(id);
      } else {
        _seleccion.remove(id);
      }
    });
  }

  /// Corrección A3-D1 (auditorías 1.28): guarda de vuelo
  /// del lote — el marcado tarda segundos (una op por
  /// fila) y el botón quedaba vivo con la selección
  /// intacta: un segundo toque abría otro diálogo y
  /// lanzaba un SEGUNDO lote concurrente.
  bool _marcandoLote = false;

  /// (M2-BC B4) marca las seleccionadas como comprobadas
  /// en una sola pasada (servicio: [marcarLoteComprobadas])
  /// y reporta marcadas/omitidas con honestidad.
  Future<void> _marcarLote() async {
    if (_marcandoLote) return;
    setState(() => _marcandoLote = true);
    try {
      await _marcarLoteReal();
    } finally {
      if (mounted) setState(() => _marcandoLote = false);
    }
  }

  Future<void> _marcarLoteReal() async {
    final filas = [
      for (final p in _porComprobar)
        if (_seleccion.contains((p['id'] as num?)?.toInt())) p,
    ];
    if (filas.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Conciliar en lote'),
        content: Text(
            '¿Marcar ${filas.length} transferencia(s) como '
            'comprobadas? Solo entran las que siguen «por '
            'comprobar»; las que ya tengan marca en cola se '
            'omiten.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          BotonPrimario(
            texto: 'Marcar comprobadas',
            onPressed: () => Navigator.pop(ctx, true),
            expandido: false,
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r =
        await ConciliacionService.instance.marcarLoteComprobadas(filas);
    if (!mounted) return;
    setState(() {
      _seleccion.clear();
      _seleccionando = false;
    });
    mostrarSnack(
      context,
      r.omitidas == 0
          ? '${r.marcadas} transferencias marcadas como comprobadas'
          : '${r.marcadas} marcadas · ${r.omitidas} omitidas '
              '(ya tenían marca en cola)',
      significado: r.omitidas == 0
          ? SignificadoChip.exito
          : SignificadoChip.alerta,
    );
    _cargar();
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final filas =
          await ConciliacionService.instance.transferencias();
      final clientes = await LocalDb.instance.allMirror('clientes');
      if (mounted) {
        setState(() {
          _nombres = {
            for (final c in clientes)
              if (c['id'] is num)
                (c['id'] as num).toInt(): '${c['nombre'] ?? ''}',
          };
          _porComprobar = filas
              .where((r) => conciliacionAccionable(
                  r['_conciliacion'] as String))
              .toList();
          _resueltas = filas
              .where((r) =>
                  r['_conciliacion'] == 'comprobada' ||
                  r['_conciliacion'] == 'rechazada')
              .take(20)
              .toList();
          _falloCarga = null;
          _cargando = false;
        });
      }
    } catch (e) {
      // Yunque de App 1.31 (C1-2): bitácora + error visible.
      // Antes el fallo se leía como «todas comprobadas» y el
      // dueño podía cerrar el día creyendo que no quedaba
      // nada por comprobar.
      AppLog.error('conciliacion', 'carga_fallo', d: '$e');
      if (mounted) {
        setState(() {
          _falloCarga = '$e';
          _cargando = false;
        });
      }
    }
  }

  String _nombreDe(Map<String, dynamic> p) {
    final id = p['cliente_id'];
    if (id is num) return _nombres[id.toInt()] ?? 'Cliente';
    return 'Cliente';
  }

  Widget _fila(Map<String, dynamic> p) {
    final estado = p['_conciliacion'] as String;
    final uuid = '${p['comprobante_uuid'] ?? ''}';
    final nota = '${p['conciliacion_nota'] ?? ''}'.trim();
    final cobradoPor =
        '${p['registrado_por_nombre'] ?? p['registrado_por'] ?? ''}';
    final idFila = (p['id'] as num?)?.toInt();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // (M2-BC B4) casilla del lote: solo en modo
                // selección y solo en las accionables (las
                // resueltas no entran al lote).
                if (_seleccionando &&
                    conciliacionAccionable(estado) &&
                    idFila != null)
                  Checkbox(
                    value: _seleccion.contains(idFila),
                    onChanged: (v) => _alternarSeleccion(idFila, v),
                  ),
                Expanded(
                  child: Text(_nombreDe(p),
                      style: AppTexto.subtitulo),
                ),
                ChipEstado.semantico(
                  texto: etiquetaConciliacion(estado),
                  significado: significadoConciliacion(estado),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(
              '${fmtMonto(p['monto'])} CUP · '
              '${fmtFecha('${p['fecha'] ?? ''}')}',
              style: AppTexto.secundario,
            ),
            if (cobradoPor.isNotEmpty)
              Text('Cobrado por $cobradoPor',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
            // FIN-02 de Argón (1.20): la nota se muestra siempre
            // que exista (también en comprobadas: puede ser una
            // aclaración útil); en error solo para problema y
            // rechazada.
            if (nota.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Text('Nota: $nota',
                    // 1.29 (Oleada 2): rol de TEXTO de error
                    // de la Oleada 1 en la nota de problema.
                    style: AppTexto.metadato.copyWith(
                        color: (estado == 'problema' ||
                                estado == 'rechazada')
                            ? AppColores.errorTexto(context)
                            : AppColores.textoSecundario(context))),
              ),
            const SizedBox(height: AppEspacio.sm),
            Row(
              children: [
                if (uuid.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.image_rounded, size: 18),
                    label: const Text('Comprobante'),
                    onPressed: () =>
                        verComprobanteTransferencia(context, uuid),
                  ),
                const Spacer(),
                ElevatedButton.icon(
                  icon:
                      const Icon(Icons.fact_check_rounded, size: 18),
                  label: const Text('Conciliar'),
                  onPressed: () async {
                    final ok = await mostrarDialogoConciliar(
                      context,
                      pago: p,
                      nombreCliente: _nombreDe(p),
                    );
                    if (ok) _cargar();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Transferencias'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño concilia transferencias',
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Transferencias por comprobar',
        acciones: [
          // (M2-BC B4) entrar/salir del modo de conciliación
          // en lote (solo si hay algo por comprobar).
          if (_porComprobar.isNotEmpty)
            IconButton(
              icon: Icon(_seleccionando
                  ? Icons.close_rounded
                  : Icons.checklist_rounded),
              tooltip: _seleccionando
                  ? 'Salir del lote'
                  : 'Conciliar en lote',
              onPressed: () => setState(() {
                _seleccionando = !_seleccionando;
                if (!_seleccionando) _seleccion.clear();
              }),
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando transferencias…')
          : _falloCarga != null
              ? EstadoError(
                  detalle: _falloCarga,
                  onReintentar: _cargar,
                )
              : Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      children: [
                        EncabezadoSeccion(
                            titulo:
                                'Por comprobar (${_porComprobar.length})'),
                        if (_seleccionando)
                          Padding(
                            padding: const EdgeInsets.only(
                                bottom: AppEspacio.sm),
                            child: Text(
                              'Toca las casillas de las que ya '
                              'comprobaste en tu cuenta y márcalas '
                              'todas de una vez.',
                              style: AppTexto.metadato.copyWith(
                                  color: AppColores.textoSecundario(
                                      context)),
                            ),
                          ),
                        if (_porComprobar.isEmpty)
                          // 1.30 (Oleada D6, UI130-22): la
                          // cola por revisar vacía pasa del
                          // texto plano en tarjeta al
                          // EstadoVacio sin marco, con el
                          // calendario de la lámina. (La
                          // FranjaPorRevisar no pinta nada
                          // sin ítems, por diseño D-23.)
                          const EstadoVacio(
                            sinMarco: true,
                            ilustracion:
                                'assets/vacio_calendario.jpg',
                            icono: Icons.event_available_rounded,
                            titulo: 'No hay transferencias '
                                'esperando comprobación.',
                          )
                        else
                          for (final p in _porComprobar) _fila(p),
                        if (_resueltas.isNotEmpty) ...[
                          const EncabezadoSeccion(
                              titulo: 'Resueltas recientes'),
                          for (final p in _resueltas) _fila(p),
                        ],
                      ],
                    ),
                  ),
                ),
                // (M2-BC B4) barra del lote con la selección.
                if (_seleccionando && _seleccion.isNotEmpty)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(AppEspacio.md),
                      child: BotonPrimario(
                        texto: 'Marcar comprobadas '
                            '(${_seleccion.length})',
                        icono: Icons.fact_check_rounded,
                        // Corrección A3-D1: mientras el lote
                        // corre, el botón se deshabilita y
                        // enseña el indicador.
                        onPressed: _marcandoLote ? null : _marcarLote,
                        cargando: _marcandoLote,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): «Conciliar
/// transferencia» como StatefulWidget DUEÑO de su
/// controlador, dispuesto en dispose() — el patrón de la
/// casa. Antes el controlador se creaba en la función y se
/// disponía nada más resolver el showDialog, con la
/// animación de salida aún reconstruyendo el campo
/// (defecto D-B1-08). El cuerpo del diálogo (chips de
/// estado, nota obligatoria según destino, guardado en
/// vuelo con su error visible) se movió verbatim; devuelve
/// true solo si la marca se guardó.
class _DialogoConciliar extends StatefulWidget {
  const _DialogoConciliar({required this.pago, this.nombreCliente});

  final Map<String, dynamic> pago;
  final String? nombreCliente;

  @override
  State<_DialogoConciliar> createState() => _DialogoConciliarState();
}

class _DialogoConciliarState extends State<_DialogoConciliar> {
  late final String _actual;
  late final List<String> _opciones;
  late final TextEditingController _notaCtrl;
  late String _destino;
  bool _errorNota = false;
  // (M2-A A10) guarda en vuelo del Guardar + error de
  // servicio visible sin cerrar el diálogo.
  bool _guardando = false;
  String? _errorGuardado;

  @override
  void initState() {
    super.initState();
    _actual = estadoConciliacion(widget.pago);
    const destinos = ['pendiente', 'comprobada', 'problema', 'rechazada'];
    _opciones = destinos.where((d) => d != _actual).toList();
    _destino =
        _opciones.contains('comprobada') ? 'comprobada' : _opciones.first;
    // FIN-02 de Argón (1.20): la nota previa se precarga (si la
    // transferencia ya tenía una, el dueño la ve al reabrir).
    _notaCtrl = TextEditingController(
        text: '${widget.pago['conciliacion_nota'] ?? ''}');
  }

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notaObligatoria =
        _destino == 'problema' || _destino == 'rechazada';
    return DialogoApp(
          titulo: 'Conciliar transferencia',
          iconoTitulo: Icons.fact_check_rounded,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.nombreCliente != null &&
                    widget.nombreCliente!.isNotEmpty)
                  Text(widget.nombreCliente!, style: AppTexto.subtitulo),
                Text(
                  '${fmtMonto(widget.pago['monto'])} CUP · '
                  '${fmtFecha('${widget.pago['fecha'] ?? ''}')}',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: AppEspacio.sm),
                Row(
                  children: [
                    const Text('Estado _actual: ',
                        style: AppTexto.secundario),
                    ChipEstado.semantico(
                      texto: etiquetaConciliacion(_actual),
                      significado: significadoConciliacion(_actual),
                    ),
                  ],
                ),
                const SizedBox(height: AppEspacio.lg),
                const Text('Nuevo estado',
                    style: AppTexto.etiqueta),
                const SizedBox(height: AppEspacio.sm),
                Wrap(
                  spacing: AppEspacio.sm,
                  runSpacing: AppEspacio.sm,
                  children: [
                    for (final d in _opciones)
                      ChoiceChip(
                        label: Text(etiquetaConciliacion(d)),
                        selected: _destino == d,
                        onSelected: (_) => setState(() {
                          _destino = d;
                          _errorNota = false;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppEspacio.lg),
                CampoTexto(
                  controller: _notaCtrl,
                  etiqueta: notaObligatoria
                      ? 'Nota (obligatoria)'
                      : 'Nota (opcional)',
                  hint: 'Qué pasó con esta transferencia',
                  maxLineas: 3,
                  onChanged: (_) {
                    if (_errorNota) setState(() => _errorNota = false);
                  },
                ),
                if (_errorNota) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'Para marcar «Con problema» o «Rechazada» '
                    'hay que escribir la nota.',
                    // 1.29 (Oleada 2): rol de TEXTO de error
                    // de la Oleada 1 (contraste sobre el
                    // fondo del tema en claro y en oscuro).
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.errorTexto(context)),
                  ),
                ],
                if (_errorGuardado != null) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    _errorGuardado!,
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.errorTexto(context)),
                  ),
                ],
              ],
            ),
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              // (M2-A A10) deshabilitado durante el guardado:
              // el doble toque encolaba la marca dos veces (la
              // segunda rebotaba en el servidor y caía a
              // revisión). El servicio además la rechaza.
              onPressed: _guardando
                  ? null
                  : () async {
                      if (notaObligatoria &&
                          _notaCtrl.text.trim().isEmpty) {
                        setState(() => _errorNota = true);
                        return;
                      }
                      setState(() => _guardando = true);
                      try {
                        await ConciliacionService.instance.marcar(
                          pagoId: (widget.pago['id'] as num).toInt(),
                          estado: _destino,
                          estadoEsperado: _actual,
                          nota: _notaCtrl.text,
                        );
                        if (mounted) Navigator.pop(context, true);
                      } catch (e) {
                        if (mounted) {
                          setState(() {
                            _guardando = false;
                            AppLog.error('conciliacion', 'guardar_fallo', d: '$e');
                            _errorGuardado = mensajeErrorAmable(e);
                          });
                        }
                      }
                    },
              child: const Text('Guardar'),
            ),
          ],
        );
  }
}
