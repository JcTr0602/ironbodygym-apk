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

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque2_resto.dart';
import '../errores_sync.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tipos_operacion.dart';
import 'auditoria.dart';
import 'auditoria_persona.dart';
import 'componentes.dart';
import 'diseno.dart';

Widget _soloDueno(String titulo) => Scaffold(
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
// F1
// ---------------------------------------------------------------------------

class AuditoriaPanelScreen extends StatelessWidget {
  const AuditoriaPanelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Auditoría (F1)')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Por defecto, el entrenador no ve la auditoría. Solo el '
              'dueño la ve completa. Si el dueño lo autoriza, un '
              'entrenador vería únicamente su propia actividad, nunca '
              'la de otros.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    void ir(Widget p) => Navigator.push(
        context, MaterialPageRoute(builder: (_) => p));
    return Scaffold(
      appBar: AppBar(title: const Text('Auditoría (F1)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'La misma auditoría de 1.8.0, con sus filtros (persona, '
            'fecha, tipo de acción). No se reescribe: se enlaza.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history, color: AppColores.naranja),
              title: const Text('Auditoría general',
                  style: AppTexto.cuerpo),
              subtitle: const Text('Ops, filtros y alertas',
                  style: AppTexto.secundario),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => ir(const AuditoriaScreen()),
            ),
          ),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_search,
                  color: AppColores.naranja),
              title: const Text('Auditoría por persona',
                  style: AppTexto.cuerpo),
              subtitle: const Text('Día, semana, mes o rango',
                  style: AppTexto.secundario),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => ir(const AuditoriaPersonaScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// F3
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

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final ops = await opsConError();
      final huerfanas = await fotosHuerfanasDeOpsRechazadas();
      if (mounted) {
        setState(() {
          _ops = ops;
          _huerfanas = huerfanas;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final soyDueno = AuthService().isOwner;
    return Scaffold(
      appBar: AppBar(title: const Text('Errores de sync (F3)')),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando sistema…')
          : ListView(
              padding: const EdgeInsets.all(16),
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
                  const Text('Sin errores pendientes.',
                      style: AppTexto.secundario)
                else ...[
                  for (final op in _ops)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.sync_problem,
                            color: AppColores.error),
                        title: Text(describirTipoOp('${op['tipo']}'),
                            style: AppTexto.cuerpo),
                        subtitle: Text(
                            '${resumenErrorDiagnostico('${op['error'] ?? ''}')}'
                            ' · estado: ${op['estado']}',
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
                        leading: const Icon(Icons.broken_image,
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
      return _soloDueno('Mantenimiento (F5)');
    }
    void irSnack(String m) =>
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    return Scaffold(
      appBar: AppBar(title: const Text('Mantenimiento (F5)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Lista cerrada, nada fuera de esto. PROHIBIDO: borrar datos '
            'a mano, VACUUM, podar applied_ops, tocar watermarks o '
            'secuencias. Cada herramienta pide confirmación y queda '
            'registrada en la auditoría local.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          Text('Ops pendientes de subir: ${_pendientes < 0 ? '—' : _pendientes}',
              style: AppTexto.cuerpo),
          Text('Tamaño de la BD local: $_tamanoTexto',
              style: AppTexto.cuerpo),
          const SizedBox(height: 12),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  const Icon(Icons.sync, color: AppColores.naranja),
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
                  leading: const Icon(Icons.download,
                      color: AppColores.naranja),
                  title: const Text('Re-descargar tabla espejo',
                      style: AppTexto.cuerpo),
                  subtitle: Text(
                      _pendientes > 0
                          ? 'BLOQUEADA: hay $_pendientes ops pendientes de subir. Vacía la cola primero: re-descargar ahora pisaría los cobros sin subir.'
                          : 'Sin cola pendiente: se puede re-descargar.',
                      style: AppTexto.secundario),
                ),
                DropdownButton<String>(
                  value: _tabla,
                  isExpanded: true,
                  items: [
                    for (final t in _kTablasEspejoF5)
                      DropdownMenuItem(value: t, child: Text(t))
                  ],
                  onChanged: (v) => setState(() => _tabla = v ?? 'clientes'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: puedeRedescargarEspejo(_pendientes)
                        ? () async {
                            if (!await _confirmar(context,
                                'Re-descargar $_tabla',
                                'El espejo bajado del servidor reemplazará la tabla local. Sin cola pendiente, no hay cobros que perder.')) {
                              return;
                            }
                            await LocalDb.instance.setMeta(
                                'forzar_redescarga_$_tabla', '1');
                            await SyncEngine.instance.pull();
                            await registrarAccionMantenimiento(
                                'f5_redescargar_espejo', {'tabla': _tabla});
                            await _cargar();
                            irSnack('Tabla $_tabla re-descargada');
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
              leading: const Icon(Icons.broken_image,
                  color: AppColores.naranja),
              title: const Text('Descartar fotos huérfanas',
                  style: AppTexto.cuerpo),
              subtitle: const Text(
                  'Solo huérfanas de ops rechazadas (regla G5). Abre la '
                  'pantalla F3 para descartarlas una a una.',
                  style: AppTexto.secundario),
              trailing: TextButton(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ErroresSyncPanelScreen())),
                child: const Text('Abrir F3'),
              ),
            ),
          ),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  const Icon(Icons.storage, color: AppColores.naranja),
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
