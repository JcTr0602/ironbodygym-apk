/// Bandeja de congelaciones (Congelación 0.5, M2 — SOLO dueño).
///
/// Lista las solicitudes del espejo `cliente_congelaciones`
/// (refresca con la RPC admin_listar_congelaciones, que trae
/// el pagado_hasta ACTUAL de cada cliente). El motivo ÍNTEGRO
/// se lee en la tarjeta ANTES de decidir: puede traer datos
/// de salud y por eso esta bandeja jamás baja al teléfono de
/// un entrenador (RLS + manifiesto + espejo prohibido).
///
/// Aprobar confirma o ajusta las fechas y muestra los días
/// en vivo; si el rango rompe alguna regla, el servidor lo
/// devuelve SIN aplicar y la UI ofrece el acto expreso
/// «Aprobar como excepción del dueño» (queda auditado).
/// Rechazar admite un motivo opcional que el cliente lee.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../congelaciones_gestion.dart';
import '../errores_sync.dart';
import '../localdb.dart';
import '../app_log.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';

String _fmtF(DateTime? d) {
  if (d == null) return '—';
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}

String _fmtIso(String? iso) {
  if (iso == null || iso.length < 10) return '—';
  final d = DateTime.tryParse(iso.substring(0, 10));
  return _fmtF(d);
}

String _haceCuando(String? creadoEn) {
  if (creadoEn == null) return '';
  final t = DateTime.tryParse(creadoEn);
  if (t == null) return '';
  final dif = ahoraHabana().difference(t.toLocal());
  if (dif.inMinutes < 60) return 'hace ${dif.inMinutes} min';
  if (dif.inHours < 24) return 'hace ${dif.inHours} h';
  return 'hace ${dif.inDays} d';
}

class CongelacionesScreen extends StatefulWidget {
  const CongelacionesScreen({super.key});
  @override
  State<CongelacionesScreen> createState() => _CongelacionesScreenState();
}

class _CongelacionesScreenState extends State<CongelacionesScreen> {
  bool _cargando = true;
  bool _actuando = false;
  String? _errorRemoto;
  List<CongelacionGestion> _lista = [];
  final Map<int, String> _phPorCliente = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Pinta primero con el espejo local (offline-first) y
    // refresca después con la RPC enriquecida.
    final espejo = await CongelacionesService.instance.leerEspejo();
    if (espejo.ok && mounted) {
      setState(() {
        _lista = espejo.datos;
        _cargando = false;
      });
    }
    await _enriquecerClientes();
    final remoto = await CongelacionesService.instance.listarRemoto();
    if (!mounted) return;
    if (remoto.ok) {
      setState(() {
        _lista = remoto.datos;
        _errorRemoto = null;
        _cargando = false;
      });
    } else {
      setState(() {
        _errorRemoto = remoto.error;
        _cargando = false;
      });
    }
  }

  Future<void> _enriquecerClientes() async {
    try {
      final filas = await LocalDb.instance.allMirror('clientes');
      if (!mounted) return;
      setState(() {
        for (final f in filas) {
          final id = (f['id'] as num?)?.toInt();
          final ph = f['pagado_hasta'] as String?;
          if (id != null && ph != null) _phPorCliente[id] = ph;
        }
      });
    } catch (_) {}
  }

  void _snack(String texto) {
    if (!mounted) return;
    mostrarSnack(context, texto);
  }

  String? _phDe(CongelacionGestion c) =>
      c.clientePagadoHasta ?? _phPorCliente[c.clienteId];

  Future<void> _aprobar(CongelacionGestion c) async {
    if (!AuthService().isOwner) {
      _snack('Solo el dueño puede aprobar congelaciones.');
      return;
    }
    final rango = await showDialog<({DateTime desde, DateTime hasta})>(
      context: context,
      builder: (ctx) => _DialogoAprobarCongelacion(congelacion: c),
    );
    if (rango == null || !mounted) return;
    await _resolver(c,
        aprobar: true, desde: rango.desde, hasta: rango.hasta);
  }

  Future<void> _rechazar(CongelacionGestion c) async {
    if (!AuthService().isOwner) {
      _snack('Solo el dueño puede rechazar congelaciones.');
      return;
    }
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => const _DialogoRechazarCongelacion(),
    );
    if (motivo == null || !mounted) return;
    await _resolver(c,
        aprobar: false,
        motivoResolucion: motivo.isEmpty ? null : motivo);
  }

  Future<void> _resolver(
    CongelacionGestion c, {
    required bool aprobar,
    DateTime? desde,
    DateTime? hasta,
    String? motivoResolucion,
    bool forzarExcepcion = false,
  }) async {
    setState(() => _actuando = true);
    try {
      final res = await CongelacionesService.instance.resolver(
        id: c.id,
        aprobar: aprobar,
        desde: desde,
        hasta: hasta,
        motivoResolucion: motivoResolucion,
        forzarExcepcion: forzarExcepcion,
      );
      if (!mounted) return;
      if (res['ok'] == true) {
        if (res['ya_resuelta'] == true) {
          final estadoReal = '${res['estado'] ?? ''}';
          _snack('Esta solicitud ya estaba resuelta '
              '(${estadoReal == 'aprobada' ? 'aprobada' : 'rechazada'}) '
              'en otro dispositivo.');
        } else if (aprobar) {
          final dias = res['dias_a_extender'];
          final nota = res['excepcion_dueno'] == true
              ? ' (excepción del dueño)'
              : '';
          final fin = _fmtIso('${res['hasta'] ?? ''}');
          _snack(dias != null
              ? 'Congelación aprobada$nota: se devolverán $dias días '
                  'al terminar (hasta el $fin). Los días se aplican '
                  'solos al sincronizar.'
              : 'Congelación aprobada$nota.');
        } else {
          _snack('Solicitud rechazada.');
        }
        await _cargar();
      } else {
        final rotas = (res['reglas_rotas'] as List?)
                ?.map((e) => '$e')
                .toList() ??
            const <String>[];
        if (aprobar && rotas.isNotEmpty && !forzarExcepcion) {
          final confirma = await showDialog<bool>(
            context: context,
            builder: (ctx) => _DialogoExcepcion(reglasRotas: rotas),
          );
          if (confirma == true && mounted) {
            await _resolver(c,
                aprobar: true,
                desde: desde,
                hasta: hasta,
                forzarExcepcion: true);
          }
        } else {
          _snack('${res['error'] ?? 'No se pudo resolver'}');
        }
      }
    } catch (e) {
      AppLog.error('congelaciones', 'resolver_fallo', d: '$e');
      _snack('No se pudo resolver: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _cerrar(CongelacionGestion c) async {
    final nombre = AuthService().displayName;
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cerrar la congelación ahora',
        iconoTitulo: Icons.ac_unit_rounded,
        contenido: Text(
          'La pausa de ${c.clienteNombre ?? 'el cliente'} termina '
          'ayer: los días congelados hasta ayer se le devuelven '
          'al sincronizar y desde hoy su mensualidad corre '
          'normal. Si aún no había empezado, se cancela con 0 '
          'días. Queda registrado que la cerraste tú.',
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar ahora'),
          ),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      final res = await CongelacionesService.instance
          .cerrar(id: c.id, cerradoPorNombre: nombre);
      if (!mounted) return;
      if (res['ok'] == true) {
        _snack(res['ya_cerrada'] == true
            ? 'La congelación ya estaba cerrada.'
            : 'Congelación cerrada.');
        await _cargar();
      } else {
        _snack('${res['error'] ?? 'No se pudo cerrar'}');
      }
    } catch (e) {
      AppLog.error('congelaciones', 'cerrar_fallo', d: '$e');
      _snack('No se pudo cerrar: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Defensa en profundidad (P2#9): aunque un entrenador
    // llegara por el buscador, la bandeja es solo del dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Congelaciones'),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Las solicitudes de congelación solo las ve el '
              'dueño: el motivo puede traer datos de salud del '
              'cliente.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final hoy = ahoraHabana();
    final pendientes = [
      for (final c in _lista) if (c.esPendiente) c,
    ];
    final aprobadas = [
      for (final c in _lista) if (c.esAprobada) c,
    ];
    final historial = [
      for (final c in _lista)
        if (!c.esPendiente && !c.esAprobada) c,
    ];
    return Scaffold(
      appBar: appBarIron(context, 'Congelaciones'),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (_errorRemoto != null)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.cloud_off_rounded),
                        title: const Text(
                            'Sin conexión con el servidor: se muestra '
                            'lo último sincronizado.'),
                        subtitle: Text(_errorRemoto!),
                      ),
                    ),
                  if (_lista.isEmpty)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.ac_unit_rounded),
                        title: Text('Sin solicitudes'),
                        subtitle: Text(
                            'Cuando un cliente pida congelar su '
                            'mensualidad desde su app, aparecerá aquí.'),
                      ),
                    ),
                  if (pendientes.isNotEmpty) ...[
                    _tituloSeccion(
                        'Pendientes (${pendientes.length})'),
                    for (final c in pendientes)
                      _TarjetaCongelacion(
                        congelacion: c,
                        hoy: hoy,
                        phActual: _phDe(c),
                        actuando: _actuando,
                        onAprobar: () => _aprobar(c),
                        onRechazar: () => _rechazar(c),
                        onCerrar: null,
                      ),
                  ],
                  if (aprobadas.isNotEmpty) ...[
                    _tituloSeccion('Aprobadas (${aprobadas.length})'),
                    for (final c in aprobadas)
                      _TarjetaCongelacion(
                        congelacion: c,
                        hoy: hoy,
                        phActual: _phDe(c),
                        actuando: _actuando,
                        onAprobar: null,
                        onRechazar: null,
                        onCerrar: () => _cerrar(c),
                      ),
                  ],
                  if (historial.isNotEmpty) ...[
                    _tituloSeccion('Historial'),
                    for (final c in historial)
                      _TarjetaCongelacion(
                        congelacion: c,
                        hoy: hoy,
                        phActual: _phDe(c),
                        actuando: _actuando,
                        onAprobar: null,
                        onRechazar: null,
                        onCerrar: null,
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _tituloSeccion(String texto) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
        child: Text(texto,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold)),
      );
}

class _TarjetaCongelacion extends StatelessWidget {
  final CongelacionGestion congelacion;
  final DateTime hoy;
  final String? phActual;
  final bool actuando;
  final VoidCallback? onAprobar;
  final VoidCallback? onRechazar;
  final VoidCallback? onCerrar;

  const _TarjetaCongelacion({
    required this.congelacion,
    required this.hoy,
    required this.phActual,
    required this.actuando,
    required this.onAprobar,
    required this.onRechazar,
    required this.onCerrar,
  });

  @override
  Widget build(BuildContext context) {
    final c = congelacion;
    final dias = (c.desde != null && c.hasta != null)
        ? diasRangoCongelacion(c.desde!, c.hasta!)
        : null;
    final hace = _haceCuando(c.creadoEn);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.ac_unit_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.clienteNombre ?? 'Cliente ${c.clienteId}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                if (dias != null)
                  Chip(
                    label: Text('$dias días'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_fmtF(c.desde)} → ${_fmtF(c.hasta)}'
              '${phActual != null ? ' · Vence actualmente: ${_fmtIso(phActual)}' : ''}'
              '${hace.isNotEmpty ? ' · Pedida $hace' : ''}',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 2),
            Text(
              'Estado: ${c.etiquetaEstado(hoy)}'
              '${c.excepcionDueno ? ' · ⚠️ Excepción del dueño' : ''}'
              '${c.materializada ? ' · +${c.diasMaterializados} días aplicados' : ''}',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    etiquetaCategoriaCongelacion(c.motivoCategoria),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  // El motivo ÍNTEGRO, antes de decidir (M2).
                  Text(c.motivo),
                ],
              ),
            ),
            if (c.estado == 'rechazada' &&
                (c.motivoResolucion ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Motivo del rechazo: ${c.motivoResolucion}'),
            ],
            if (c.cerradoPorNombre != null) ...[
              const SizedBox(height: 6),
              Text('Cerrada por ${c.cerradoPorNombre} '
                  'el ${_fmtIso(c.cerradoEn)}'),
            ],
            if (onAprobar != null || onCerrar != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onRechazar != null)
                    TextButton(
                      onPressed: actuando ? null : onRechazar,
                      child: const Text('Rechazar'),
                    ),
                  if (onAprobar != null)
                    FilledButton(
                      onPressed: actuando ? null : onAprobar,
                      child: const Text('Aprobar'),
                    ),
                  if (onCerrar != null)
                    FilledButton.tonal(
                      onPressed: actuando ? null : onCerrar,
                      child: const Text('Cerrar ahora'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DialogoAprobarCongelacion extends StatefulWidget {
  final CongelacionGestion congelacion;
  const _DialogoAprobarCongelacion({required this.congelacion});
  @override
  State<_DialogoAprobarCongelacion> createState() =>
      _DialogoAprobarCongelacionState();
}

class _DialogoAprobarCongelacionState
    extends State<_DialogoAprobarCongelacion> {
  late DateTime _desde;
  late DateTime _hasta;

  @override
  void initState() {
    super.initState();
    final hoy = ahoraHabana();
    _desde = widget.congelacion.desde ?? hoy;
    _hasta = widget.congelacion.hasta ??
        hoy.add(const Duration(days: 6));
  }

  Future<void> _elegir(bool esDesde) async {
    final actual = esDesde ? _desde : _hasta;
    final f = await showDatePicker(
      context: context,
      initialDate: actual,
      firstDate: DateTime(actual.year - 1),
      lastDate: DateTime(actual.year + 1, 12, 31),
    );
    if (f == null) return;
    setState(() {
      if (esDesde) {
        _desde = f;
      } else {
        _hasta = f;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final valida = !_hasta.isBefore(_desde);
    final dias = valida ? diasRangoCongelacion(_desde, _hasta) : 0;
    final fuera = dias < 7 || dias > 30;
    return DialogoApp(
      titulo: 'Aprobar congelación',
      iconoTitulo: Icons.ac_unit_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Confirma o ajusta las fechas de la pausa de '
            '${widget.congelacion.clienteNombre ?? 'el cliente'}. '
            'Al terminar, su mensualidad se extiende sola por '
            'los días congelados.',
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Desde'),
            trailing: TextButton(
              onPressed: () => _elegir(true),
              child: Text(_fmtF(_desde)),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hasta'),
            trailing: TextButton(
              onPressed: () => _elegir(false),
              child: Text(_fmtF(_hasta)),
            ),
          ),
          Text(
            valida ? '$dias días de pausa' : 'Rango inválido',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: fuera ? Colors.red : null,
            ),
          ),
          if (fuera && valida)
            const Text(
              'Fuera de las reglas (7–30 días): al aprobar, el '
              'servidor lo señalará y podrás confirmarlo como '
              'excepción del dueño.',
              style: TextStyle(color: Colors.red),
            ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: valida
              ? () => Navigator.pop(
                  context, (desde: _desde, hasta: _hasta))
              : null,
          child: const Text('Aprobar'),
        ),
      ],
    );
  }
}

class _DialogoRechazarCongelacion extends StatefulWidget {
  const _DialogoRechazarCongelacion();
  @override
  State<_DialogoRechazarCongelacion> createState() =>
      _DialogoRechazarCongelacionState();
}

class _DialogoRechazarCongelacionState
    extends State<_DialogoRechazarCongelacion> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Rechazar la solicitud',
      iconoTitulo: Icons.ac_unit_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'El cliente verá «Rechazada» y este motivo si lo '
            'escribes (opcional). Podrá pedir de nuevo dentro '
            'de 7 días.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo (opcional)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Rechazar'),
        ),
      ],
    );
  }
}

class _DialogoExcepcion extends StatelessWidget {
  final List<String> reglasRotas;
  const _DialogoExcepcion({required this.reglasRotas});

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Fuera de reglas',
      iconoTitulo: Icons.warning_amber_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Este rango rompe las reglas de la casa:'),
          const SizedBox(height: 8),
          for (final r in reglasRotas) Text('• $r'),
          const SizedBox(height: 8),
          const Text(
            'Como dueño puedes aprobarlo como EXCEPCIÓN: queda '
            'registrado en la solicitud y los días cuentan en '
            'el cupo del cliente igual que una normal.',
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Aprobar como excepción'),
        ),
      ],
    );
  }
}
