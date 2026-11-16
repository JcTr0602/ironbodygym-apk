/// Pantallas F del Panel (1.11.0): F1, F3, F4, F5.
///
/// - F1: auditoría por persona con filtros (la de 1.8.0, sin
///   reescribirla). El dueño la ve completa; el entrenador, por
///   defecto, NO la ve (esta pantalla se lo dice; si Jc lo autoriza,
///   solo vería la suya).
/// - F3: errores de sync con los textos de Diagnóstico (sin segunda
///   redacción). SIN acción «Descartar» para ops de datos: solo
///   reintentar, o avisar al dueño. El descarte directo sin
///   reconciliar solo existe para fotos huérfanas (regla G5).
/// - F4: estado de sync del dueño: contadores y fechas, NUNCA
///   contenidos de ops. El dato «teléfonos con sync vieja» sale del
///   espejo real `sync_ultimo_sync` (CONTRATO_F4_20261024, 1.13.0):
///   una fila por usuario con su última sync efectiva (solo ops
///   APLICADAS); sin fila, «Sin registro de sync».
/// - F5: lista CERRADA de herramientas (reintentar cola, re-descargar
///   espejo, descartar huérfanas, tamaño de BD). PROHIBIDO: borrar
///   datos a mano, VACUUM, podar applied_ops, tocar watermarks o
///   secuencias. Cada herramienta pide confirmación y queda en la
///   auditoría local.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart' show clientePorId, fmtFecha, tiempoRelativo;
import '../tiempo.dart' show aHabana;
import '../bloque2_resto.dart';
import '../errores_sync.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tipos_operacion.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

Widget _soloDueno(String titulo) => Scaffold(
      // Sin appBarIron: función top-level, no hay BuildContext.
      appBar: AppBar(title: Text(titulo)),
      body: const Center(child: Text('Solo el dueño ve esta pantalla.')),
    );

/// Guardia F5 (1.14, M6.26): re-descargar un espejo solo con la
/// cola limpia. Con ops pendientes, el espejo bajado pisaría
/// cobros sin subir. -1 (aún cargando) también bloquea, como
/// antes: el botón solo se habilitaba con exactamente 0.
bool puedeRedescargarEspejo(int pendientes) => pendientes == 0;

Future<bool> _confirmar(BuildContext context, String titulo, String texto) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => DialogoApp(
      titulo: titulo,
      contenido: Text(texto),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirmar')),
      ],
    ),
  );
  return ok == true;
}

// ---------------------------------------------------------------------------
// F1: la auditoría enlaza DIRECTO desde el módulo Control del
// Panel desde la 1.25 (T121/F5-23): la intermedia
// AuditoriaPanelScreen (dos enlaces) se eliminó.
// ---------------------------------------------------------------------------

class ErroresSyncPanelScreen extends StatefulWidget {
  const ErroresSyncPanelScreen({super.key});
  @override
  State<ErroresSyncPanelScreen> createState() =>
      _ErroresSyncPanelScreenState();
}

class _ErroresSyncPanelScreenState extends State<ErroresSyncPanelScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _ops = [];
  List<Map<String, dynamic>> _huerfanas = [];
  // 1.25 T121 (F5-22): nombres de los clientes afectados por
  // las ops con error, precargados en lote.
  Map<int, String> _nombresClientes = {};

  @override
  void initState() {
    super.initState();
    // 1.26 (auditoría de botones, BAJA): guarda de dueño
    // propia — la ruta vive tras el Panel, pero la
    // pantalla lista ops con error CON nombres de
    // clientes; defensa en profundidad como en Ajustes
    // del gym: un no-dueño ni carga ni ve la lista.
    if (AuthService().isOwner) {
      _cargar();
    } else {
      _cargando = false;
    }
  }

  Future<void> _cargar() async {
    try {
      final ops = await opsConError();
      final huerfanas = await fotosHuerfanasDeOpsRechazadas();
      // F5-22: resolver los nombres de los clientes afectados
      // (cliente_id del payload) para identificar cada op.
      final nombres = <int, String>{};
      final ids = <int>{};
      for (final op in ops) {
        final cid = _clienteIdDeOp(op);
        if (cid != null) ids.add(cid);
      }
      for (final id in ids) {
        final c = await clientePorId(id);
        final n = '${c?['nombre'] ?? ''}'.trim();
        if (n.isNotEmpty) nombres[id] = n;
      }
      if (mounted) {
        setState(() {
          _ops = ops;
          _huerfanas = huerfanas;
          _nombresClientes = nombres;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// F5-22: cliente_id del payload de una op (si lo trae).
  int? _clienteIdDeOp(Map<String, dynamic> op) {
    try {
      final p = jsonDecode('${op['payload'] ?? ''}');
      if (p is Map) {
        final v = p['cliente_id'];
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
      }
    } catch (_) {}
    return null;
  }

  /// F5-22: línea de contexto de una op con error — fecha y
  /// antigüedad, cliente afectado y estado en lenguaje llano
  /// (antes la fila era solo tipo + error + «estado: error»
  /// crudo: con dos errores del mismo tipo no había forma de
  /// saber cuál era cuál ni cuánto llevaba atascado).
  String _contextoOp(Map<String, dynamic> op) {
    final partes = <String>[];
    final creada = '${op['creada_ts'] ?? ''}';
    final f = DateTime.tryParse(creada);
    if (f != null) {
      final h = aHabana(f);
      final hh = '${h.hour}'.padLeft(2, '0');
      final mm = '${h.minute}'.padLeft(2, '0');
      partes.add('${fmtFecha(h.toIso8601String())} $hh:$mm');
      final rel = tiempoRelativo(creada);
      if (rel.isNotEmpty) partes.add(rel);
    }
    final cid = _clienteIdDeOp(op);
    if (cid != null) {
      partes.add('Cliente: ${_nombresClientes[cid] ?? '#$cid'}');
    } else {
      // Inscripciones: el payload trae el nombre del cliente
      // nuevo (aún sin id en este teléfono).
      try {
        final p = jsonDecode('${op['payload'] ?? ''}');
        final n = p is Map ? "${p['nombre'] ?? ''}".trim() : '';
        if (n.isNotEmpty) partes.add('Cliente: $n');
      } catch (_) {}
    }
    partes.add(op['estado'] == 'rechazada'
        ? 'Rechazada por el servidor'
        : 'Error al subir');
    return partes.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final soyDueno = AuthService().isOwner;
    // 1.26 (BAJA): guarda propia de dueño (ver initState).
    if (!soyDueno) {
      return Scaffold(
          appBar: appBarIron(context, 'Errores de sincronización'),
          body: const Center(
              child: Text('Solo el dueño revisa los errores.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Errores de sincronización'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando sistema…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                const Text(
                  'En palabras claras, con los textos de Diagnóstico. '
                  'Las operaciones de datos NO tienen botón «Descartar»: '
                  'descartar una op dejaría el cambio vivo en este '
                  'teléfono pero nunca llegaría al servidor. Solo se '
                  'descartan fotos huérfanas de ops rechazadas.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                if (_ops.isEmpty && _huerfanas.isEmpty)
                  // F5-22: vacío con el componente compartido
                  // y acción de revisar de nuevo.
                  EstadoVacio(
                    icono: Icons.sync_rounded,
                    titulo: 'Sin errores pendientes',
                    subtitulo:
                        'La sincronización no tiene operaciones '
                        'atascadas en este teléfono.',
                    textoAccion: 'Revisar de nuevo',
                    onAccion: _cargar,
                  )
                else ...[
                  for (final op in _ops)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.sync_problem_rounded,
                            color: AppColores.error),
                        title: Text(describirTipoOp('${op['tipo']}'),
                            style: AppTexto.cuerpo),
                        subtitle: Text(
                            '${resumenErrorDiagnostico('${op['error'] ?? ''}')}'
                            '\n${_contextoOp(op)}',
                            style: AppTexto.secundario),
                        trailing: op['estado'] == 'error'
                            ? TextButton(
                                onPressed: () async {
                                  await SyncEngine.instance.push();
                                  await _cargar();
                                },
                                child: const Text('Reintentar'))
                            : const Text('Rechazada: avisar al dueño',
                                style: AppTexto.secundario),
                      ),
                    ),
                  for (final f in _huerfanas)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.broken_image_rounded,
                            color: AppColores.alerta),
                        title: const Text(
                            'Foto huérfana de op rechazada',
                            style: AppTexto.cuerpo),
                        subtitle: const Text(
                            'Se puede descartar sin reconciliar (regla '
                            'G5): solo borra la fila de la cola.',
                            style: AppTexto.secundario),
                        trailing: soyDueno
                            ? TextButton(
                                onPressed: () async {
                                  if (!await _confirmar(
                                      context,
                                      'Descartar foto huérfana',
                                      'Solo se borra la fila de la cola. '
                                      'No toca al cliente ni a su foto.')) {
                                    return;
                                  }
                                  await descartarFotoHuerfana(
                                      (f['id'] as num).toInt());
                                  await registrarAccionMantenimiento(
                                      'descartar_foto_huerfana',
                                      {'foto_cola_id': f['id']});
                                  await _cargar();
                                },
                                child: const Text('Descartar'))
                            : null,
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// F4
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// F5
// ---------------------------------------------------------------------------

const _kTablasEspejoF5 = [
  'clientes',
  'pagos',
  'pagos_diarios',
  'ventas_suplementos',
  'servicio_ventas',
  'suplementos',
];

/// F5-14: etiquetas humanas de las tablas del espejo — el
/// selector de re-descarga mostraba nombres de base de datos
/// (pagos_diarios, servicio_ventas…), lenguaje del equipo de
/// desarrollo, no del negocio. El VALOR sigue siendo el nombre
/// técnico (lo usa la meta forzar_redescarga_<tabla>).
const _etiquetasTablaF5 = {
  'clientes': 'Clientes',
  'pagos': 'Pagos',
  'pagos_diarios': 'Pagos diarios',
  'ventas_suplementos': 'Ventas de suplementos',
  'servicio_ventas': 'Dosis y servicios',
  'suplementos': 'Suplementos (catálogo)',
  // SL-9 (G09-9): las demás tablas que pinta la verificación
  // del espejo, para que ninguna salga con su nombre crudo.
  'reservas': 'Reservas',
  'gympedia_solicitudes': 'Solicitudes de GymPedia',
  'permisos_bandeja': 'Bandeja de permisos',
  'espejo_gympedia_borradores': 'Borradores de GymPedia',
  'avisos_entrenadores': 'Avisos a entrenadores',
};

String _etiquetaTablaF5(String t) => _etiquetasTablaF5[t] ?? t;

/// SL-9 (G09-9): el traductor de tablas de la casa, público
/// para las demás pantallas del Panel (la verificación del
/// espejo lo usa en vez de pintar el nombre crudo de la tabla).
String etiquetaTablaEspejo(String t) => _etiquetaTablaF5(t);

class MantenimientoScreen extends StatefulWidget {
  const MantenimientoScreen({super.key});
  @override
  State<MantenimientoScreen> createState() => _MantenimientoScreenState();
}

class _MantenimientoScreenState extends State<MantenimientoScreen> {
  int _pendientes = -1;
  int _tamano = -1;
  String _tabla = 'clientes';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final p = await LocalDb.instance.countPendingOps();
      final t = await tamanoBdLocal();
      if (mounted) {
        setState(() {
          _pendientes = p;
          _tamano = t;
        });
      }
    } catch (_) {}
  }

  String get _tamanoTexto {
    if (_tamano < 0) return '—';
    if (_tamano < 1024 * 1024) return '${(_tamano / 1024).toStringAsFixed(0)} KB';
    return '${(_tamano / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return _soloDueno('Mantenimiento');
    }
    void irSnack(String m) =>
        mostrarSnack(context, m, significado: SignificadoChip.exito);
    return Scaffold(
      appBar: appBarIron(context, 'Mantenimiento'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          // 1.25 T121 (F5-14): la política de prohibiciones
          // vive en el CÓDIGO (lista cerrada de herramientas),
          // no como párrafo para el dueño.
          const Text(
            'Herramientas seguras: cada una pide confirmación '
            'y queda registrada en la auditoría local.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text('Ops pendientes de subir',
                              style: AppTexto.secundario),
                          Text(
                            _pendientes < 0 ? '—' : '$_pendientes',
                            style: AppTexto.metrica.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ]),
                          ),
                        ],
                      ),
                    ),
                    ChipEstado.semantico(
                      texto: _pendientes < 0
                          ? 'Sin datos'
                          : _pendientes == 0
                              ? 'Al día'
                              : 'Pendientes',
                      significado: _pendientes < 0
                          ? SignificadoChip.neutral
                          : _pendientes == 0
                              ? SignificadoChip.exito
                              : SignificadoChip.alerta,
                    ),
                  ],
                ),
                const Divider(),
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Tamaño de la BD local',
                        style: AppTexto.secundario),
                    Text(_tamanoTexto,
                        style: AppTexto.cuerpo.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  Icon(Icons.sync_rounded, color: AppColores.textoSecundario(context)),
              title: const Text('Reintentar cola de sync',
                  style: AppTexto.cuerpo),
              trailing: TextButton(
                onPressed: () async {
                  if (!await _confirmar(context, 'Reintentar cola',
                      'Se intentará subir la cola pendiente ahora.')) {
                    return;
                  }
                  await SyncEngine.instance.push();
                  await registrarAccionMantenimiento(
                      'f5_reintentar_cola', {});
                  await _cargar();
                  irSnack('Cola reintentada');
                },
                child: const Text('Ejecutar'),
              ),
            ),
          ),
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.download_rounded,
                      color: AppColores.textoSecundario(context)),
                  title: const Text('Re-descargar tabla espejo',
                      style: AppTexto.cuerpo),
                  subtitle: Text(
                      _pendientes > 0
                          ? 'BLOQUEADA: hay $_pendientes ops pendientes de subir. Vacía la cola primero: re-descargar ahora pisaría los cobros sin subir.'
                          : 'Sin cola pendiente: se puede re-descargar.',
                      style: AppTexto.secundario),
                ),
                SelectorIron<String>(
                  valor: _tabla,
                  tituloPanel: 'Tabla espejo',
                  opciones: [
                    for (final t in _kTablasEspejoF5)
                      OpcionSelector(t, _etiquetaTablaF5(t))
                  ],
                  alCambiar: (v) => setState(() => _tabla = v ?? 'clientes'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: puedeRedescargarEspejo(_pendientes)
                        ? () async {
                            if (!await _confirmar(context,
                                'Re-descargar ${_etiquetaTablaF5(_tabla)}',
                                'El espejo bajado del servidor reemplazará la tabla local. Sin cola pendiente, no hay cobros que perder.')) {
                              return;
                            }
                            await LocalDb.instance.setMeta(
                                'forzar_redescarga_$_tabla', '1');
                            await SyncEngine.instance.pull();
                            await registrarAccionMantenimiento(
                                'f5_redescargar_espejo', {'tabla': _tabla});
                            await _cargar();
                            irSnack(
                                '${_etiquetaTablaF5(_tabla)}: tabla re-descargada');
                          }
                        : null,
                    child: const Text('Ejecutar'),
                  ),
                ),
              ],
            ),
          ),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.broken_image_rounded,
                  color: AppColores.naranja),
              title: const Text('Descartar fotos huérfanas',
                  style: AppTexto.cuerpo),
              subtitle: const Text(
                  'Solo huérfanas de operaciones rechazadas. Ábrelos '
                  'en Errores de sincronización para descartarlas '
                  'una a una.',
                  style: AppTexto.secundario),
              trailing: TextButton(
                onPressed: () => Navigator.push(
                    context,
                    RutaIron(
                        builder: (_) => const ErroresSyncPanelScreen())),
                child: const Text('Abrir errores'),
              ),
            ),
          ),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  Icon(Icons.storage_rounded, color: AppColores.textoSecundario(context)),
              title: const Text('Ver tamaño de la BD local',
                  style: AppTexto.cuerpo),
              subtitle: Text(_tamanoTexto, style: AppTexto.secundario),
              trailing: TextButton(
                onPressed: _cargar,
                child: const Text('Actualizar'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
