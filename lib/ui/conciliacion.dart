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
  final actual = estadoConciliacion(pago);
  const destinos = ['pendiente', 'comprobada', 'problema', 'rechazada'];
  final opciones = destinos.where((d) => d != actual).toList();
  var destino = opciones.contains('comprobada')
      ? 'comprobada'
      : opciones.first;
  // FIN-02 de Argón (1.20): la nota previa se precarga (si la
  // transferencia ya tenía una, el dueño la ve al reabrir).
  final notaCtrl = TextEditingController(
      text: '${pago['conciliacion_nota'] ?? ''}');
  var errorNota = false;
  // (M2-A A10) guarda en vuelo del Guardar + error de
  // servicio visible sin cerrar el diálogo.
  var guardando = false;
  String? errorGuardado;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final notaObligatoria =
            destino == 'problema' || destino == 'rechazada';
        return DialogoApp(
          titulo: 'Conciliar transferencia',
          iconoTitulo: Icons.fact_check_rounded,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (nombreCliente != null &&
                    nombreCliente.isNotEmpty)
                  Text(nombreCliente, style: AppTexto.subtitulo),
                Text(
                  '${fmtMonto(pago['monto'])} CUP · '
                  '${fmtFecha('${pago['fecha'] ?? ''}')}',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: AppEspacio.sm),
                Row(
                  children: [
                    const Text('Estado actual: ',
                        style: AppTexto.secundario),
                    ChipEstado.semantico(
                      texto: etiquetaConciliacion(actual),
                      significado: significadoConciliacion(actual),
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
                    for (final d in opciones)
                      ChoiceChip(
                        label: Text(etiquetaConciliacion(d)),
                        selected: destino == d,
                        onSelected: (_) => setState(() {
                          destino = d;
                          errorNota = false;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppEspacio.lg),
                CampoTexto(
                  controller: notaCtrl,
                  etiqueta: notaObligatoria
                      ? 'Nota (obligatoria)'
                      : 'Nota (opcional)',
                  hint: 'Qué pasó con esta transferencia',
                  maxLineas: 3,
                  onChanged: (_) {
                    if (errorNota) setState(() => errorNota = false);
                  },
                ),
                if (errorNota) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'Para marcar «Con problema» o «Rechazada» '
                    'hay que escribir la nota.',
                    style: AppTexto.metadato
                        .copyWith(color: AppColores.error),
                  ),
                ],
                if (errorGuardado != null) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    errorGuardado!,
                    style: AppTexto.metadato
                        .copyWith(color: AppColores.error),
                  ),
                ],
              ],
            ),
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              // (M2-A A10) deshabilitado durante el guardado:
              // el doble toque encolaba la marca dos veces (la
              // segunda rebotaba en el servidor y caía a
              // revisión). El servicio además la rechaza.
              onPressed: guardando
                  ? null
                  : () async {
                      if (notaObligatoria &&
                          notaCtrl.text.trim().isEmpty) {
                        setState(() => errorNota = true);
                        return;
                      }
                      setState(() => guardando = true);
                      try {
                        await ConciliacionService.instance.marcar(
                          pagoId: (pago['id'] as num).toInt(),
                          estado: destino,
                          estadoEsperado: actual,
                          nota: notaCtrl.text,
                        );
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        if (ctx.mounted) {
                          setState(() {
                            guardando = false;
                            errorGuardado = '$e'
                                .replaceFirst('Bad state: ', '');
                          });
                        }
                      }
                    },
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    ),
  );
  notaCtrl.dispose();
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

  /// (M2-BC B4) marca las seleccionadas como comprobadas
  /// en una sola pasada (servicio: [marcarLoteComprobadas])
  /// y reporta marcadas/omitidas con honestidad.
  Future<void> _marcarLote() async {
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
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
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
                    style: AppTexto.metadato.copyWith(
                        color: (estado == 'problema' ||
                                estado == 'rechazada')
                            ? AppColores.error
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
                          const Tarjeta(
                            child: Text(
                                'No hay transferencias esperando '
                                'comprobación.'),
                          )
                        else
                          for (final p in _porComprobar) _fila(p),
                        if (_resueltas.isNotEmpty) ...[
                          const SizedBox(height: AppEspacio.lg),
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
                        onPressed: _marcarLote,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
