import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../premios_panel.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

/// Premios (1.27, S3/G3): pestaña «Clientes» del hub —
/// buscador sobre el espejo local y, por cliente, el
/// detalle del servidor (S3): progreso del ciclo con
/// barra, historial completo de vales, sesiones que
/// sumaron, sello de logros (S5) y reinicios (S6).
/// Acciones del dueño: conceder un vale manual (S4,
/// entra en la bandeja y se aprueba con el mismo
/// botón) y reiniciar el ciclo (S6). Todo por RPC
/// directa con timeout: no mueve dinero al momento.
/// Inyectables para los tests, como el resto del hub.
class PremiosClientesTab extends StatefulWidget {
  final Future<List<({int id, String nombre, String telefono})>>
      Function()? buscarClientes;
  final Future<Map<String, dynamic>> Function(int clienteId)?
      cargarDetalle;
  final Future<List<EntradaCatalogoPremio>> Function()?
      cargarCatalogo;
  final Future<Map<String, dynamic>> Function(int clienteId,
      String logroId, int premioDias, String nota)? concederVale;
  final Future<Map<String, dynamic>> Function(
      int clienteId, String nota)? reiniciarCiclo;

  /// S7: anular un vale canjeado (encola la op; el
  /// servidor recalcula y revierte el pago).
  final Future<void> Function(int clienteId, ValeHistorial vale,
      String modo, int diasQuitables, String nota)? anularVale;
  final Future<String?> Function(int clienteId)? pagadoHastaDe;
  final Future<bool> Function(int valeId)? anulacionEnCursoDe;

  const PremiosClientesTab(
      {super.key,
      this.buscarClientes,
      this.cargarDetalle,
      this.cargarCatalogo,
      this.concederVale,
      this.reiniciarCiclo,
      this.anularVale,
      this.pagadoHastaDe,
      this.anulacionEnCursoDe});

  @override
  State<PremiosClientesTab> createState() => _PremiosClientesTabState();
}

class _PremiosClientesTabState extends State<PremiosClientesTab> {
  final _busquedaCtrl = TextEditingController();
  List<({int id, String nombre, String telefono})> _todos = const [];
  bool _cargandoClientes = true;
  int? _seleccionadoId;
  String _seleccionadoNombre = '';
  DetallePremiosCliente? _detalle;
  bool _cargandoDetalle = false;
  bool _falloDetalle = false;
  String? _pagadoHasta;
  Set<int> _anulacionesEnCurso = {};

  // H-01 (Argón 1.27): candado anti doble-toque de las
  // acciones del detalle (patrón _resolviendo de la
  // Bandeja): check-and-set SÍNCRONO antes del primer
  // await; un doble toque apilaba dos diálogos.
  bool _operando = false;

  @override
  void initState() {
    super.initState();
    _cargarClientes();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<List<({int id, String nombre, String telefono})>>
      _buscarReal() async {
    final filas = await LocalDb.instance.allMirror('clientes');
    final out = <({int id, String nombre, String telefono})>[];
    for (final m in filas) {
      // H-04 (Argón 1.27): las cáscaras de clientes
      // eliminados no son personas: fuera del buscador,
      // como en el resto de listas de la casa.
      if (esClienteEliminado(m)) continue;
      final id = (m['id'] as num?)?.toInt() ??
          int.tryParse('${m['id'] ?? ''}');
      if (id == null) continue;
      out.add((
        id: id,
        nombre: '${m['nombre'] ?? 'Cliente'}',
        telefono: '${m['telefono'] ?? ''}',
      ));
    }
    out.sort((a, b) => a.nombre.compareTo(b.nombre));
    return out;
  }

  Future<Map<String, dynamic>> _detalleReal(int clienteId) async {
    final res = await Supabase.instance.client.rpc(
      'admin_premios_cliente',
      params: {'p_cliente_id': clienteId},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<List<EntradaCatalogoPremio>> _catalogoReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_premios_catalogo')
        .timeout(const Duration(seconds: 12));
    return parseCatalogoPremios(res);
  }

  Future<Map<String, dynamic>> _concederReal(int clienteId,
      String logroId, int premioDias, String nota) async {
    final res = await Supabase.instance.client.rpc(
      'admin_crear_vale_manual',
      params: {
        'p_cliente_id': clienteId,
        'p_logro_id': logroId,
        'p_premio_dias': premioDias,
        'p_nota': nota,
      },
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<Map<String, dynamic>> _reiniciarReal(
      int clienteId, String nota) async {
    final res = await Supabase.instance.client.rpc(
      'admin_reiniciar_ciclo_premio',
      params: {'p_cliente_id': clienteId, 'p_nota': nota},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<void> _cargarClientes() async {
    try {
      final todos =
          await (widget.buscarClientes ?? _buscarReal)();
      if (!mounted) return;
      setState(() {
        _todos = todos;
        _cargandoClientes = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargandoClientes = false);
    }
  }

  Future<String?> _pagadoHastaReal(int clienteId) async {
    final filas =
        await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
    if (filas.isEmpty) return null;
    return filas.first['pagado_hasta'] as String?;
  }

  Future<bool> _enCursoReal(int valeId) async {
    return await LocalDb.instance
            .getMeta('premio_vale_anulado_$valeId') !=
        null;
  }

  /// S7 real: encola la op de anulación (el servidor
  /// recalcula los días y revierte el pago), marca el
  /// vale como «en curso» en este teléfono y ajusta el
  /// espejo como avance (el pull lo confirma).
  Future<void> _anularReal(int clienteId, ValeHistorial vale,
      String modo, int diasQuitables, String nota) async {
    // H-01 (Argón 1.27): si este teléfono ya encoló la
    // anulación de este vale, no se encola otra: la
    // marca meta sobrevive a matar la app entre el
    // queueOp y el setMeta, y a que el detalle se
    // recargue con la foto vieja del servidor.
    if (await _enCursoReal(vale.id)) return;
    final opUuid = const Uuid().v4();
    // Nota (Argón, delta 1.27): en modo «completo»
    // el espejo resta premioDias lineal, aunque parte
    // del vale ya se hubiera consumido; el servidor
    // recalcula el vencimiento desde el último pago
    // real, así que la foto local puede diferir unos
    // días hasta que el pull inmediato la confirme.
    // Lo que manda es la op: k viaja en el payload y
    // el servidor lo verifica contra su propio cálculo.
    final k = modo == 'completo' ? vale.premioDias : diasQuitables;
    await LocalDb.instance.queueOp(
      opUuid: opUuid,
      tipo: 'anular_vale_premio',
      payload: {
        'cliente_id': clienteId,
        'vale_id': vale.id,
        'modo': modo,
        'dias_quitados': k,
        'nota': nota,
      },
    );
    await LocalDb.instance
        .setMeta('premio_vale_anulado_${vale.id}', opUuid);
    if (k > 0 && _pagadoHasta != null) {
      // H-01 (Argón 1.27): aritmética UTC pura
      // (sumarDiasIso). Restar un Duration a un
      // DateTime en hora local cruza el cambio de
      // horario de Cuba y puede correr el espejo un
      // día de más que el servidor.
      if (DateTime.tryParse(_pagadoHasta!) != null) {
        await LocalDb.instance.updateMirrorPagadoHasta(
          clienteId,
          sumarDiasIso(_pagadoHasta!, -k),
        );
      }
    }
    unawaited(SyncEngine.instance.push());
  }

  Future<void> _abrirDetalle(
      ({int id, String nombre, String telefono}) c) async {
    setState(() {
      _seleccionadoId = c.id;
      _seleccionadoNombre = c.nombre;
      _cargandoDetalle = true;
      _falloDetalle = false;
      _detalle = null;
      _pagadoHasta = null;
      _anulacionesEnCurso = {};
    });
    try {
      final json =
          await (widget.cargarDetalle ?? _detalleReal)(c.id);
      if (!mounted) return;
      final detalle = parseDetallePremiosCliente(json);
      // Datos locales de apoyo (vencimiento y marcas de
      // anulación en curso): si el espejo local falla,
      // el detalle del servidor se muestra igual, solo
      // sin el botón de anular afinado.
      String? hasta;
      try {
        hasta = await (widget.pagadoHastaDe ?? _pagadoHastaReal)(c.id);
      } catch (_) {}
      final enCurso = <int>{};
      for (final v in detalle.vales) {
        if (!v.canjeado) continue;
        try {
          if (await (widget.anulacionEnCursoDe ?? _enCursoReal)(v.id)) {
            enCurso.add(v.id);
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _detalle = detalle;
        _pagadoHasta = hasta;
        _anulacionesEnCurso = enCurso;
        _cargandoDetalle = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargandoDetalle = false;
          _falloDetalle = true;
        });
      }
    }
  }

  Future<void> _recargarDetalle() async {
    final id = _seleccionadoId;
    if (id == null) return;
    try {
      final json =
          await (widget.cargarDetalle ?? _detalleReal)(id);
      if (!mounted) return;
      setState(() => _detalle = parseDetallePremiosCliente(json));
    } catch (_) {}
  }

  Future<void> _conceder() async {
    // H-01 (Argón 1.27): check-and-set síncrono ANTES
    // del primer await (patrón _resolviendo de la
    // Bandeja); sin él, un doble toque apilaba dos
    // diálogos de concesión.
    if (_operando) return;
    final id = _seleccionadoId;
    if (id == null) return;
    setState(() => _operando = true);
    try {
      List<EntradaCatalogoPremio> catalogo;
      try {
        catalogo = await (widget.cargarCatalogo ?? _catalogoReal)();
      } catch (_) {
        if (mounted) {
          mostrarSnack(context, 'Sin conexión con el servidor.',
              significado: SignificadoChip.error);
        }
        return;
      }
      if (!mounted) return;
      final hecho = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoConcederVale(
          nombreCliente: _seleccionadoNombre,
          catalogo: catalogo,
          conceder: (logroId, dias, nota) =>
              (widget.concederVale ?? _concederReal)(
                  id, logroId, dias, nota),
        ),
      );
      if (hecho == true && mounted) {
        mostrarSnack(
            context,
            'Vale creado: está en la Bandeja, apruébalo ahí '
            'para aplicar los días.',
            significado: SignificadoChip.exito);
        await _recargarDetalle();
      }
    } finally {
      if (mounted) setState(() => _operando = false);
    }
  }

  Future<void> _anular(ValeHistorial v) async {
    // H-01 (Argón 1.27): misma guarda síncrona que
    // _conceder — dos diálogos de anulación confirmados
    // encolarían DOS ops anular_vale_premio con uuid
    // distinto para el mismo vale.
    if (_operando) return;
    final id = _seleccionadoId;
    if (id == null) return;
    setState(() => _operando = true);
    try {
      final hecho = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoAnularVale(
          nombreCliente: _seleccionadoNombre,
          vale: v,
          pagadoHasta: _pagadoHasta,
          hoy: ahoraHabana(),
          anular: (modo, k, nota) =>
              (widget.anularVale ?? _anularReal)(id, v, modo, k, nota),
        ),
      );
      if (hecho == true && mounted) {
        setState(
            () => _anulacionesEnCurso = {..._anulacionesEnCurso, v.id});
        mostrarSnack(
            context,
            'Anulación encolada: se aplica al sincronizar.',
            significado: SignificadoChip.exito);
      }
    } finally {
      if (mounted) setState(() => _operando = false);
    }
  }

  Future<void> _reiniciar() async {
    // H-01 (Argón 1.27): misma guarda síncrona.
    if (_operando) return;
    final id = _seleccionadoId;
    if (id == null) return;
    setState(() => _operando = true);
    try {
      final hecho = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoReiniciarCiclo(
          nombreCliente: _seleccionadoNombre,
          reiniciar: (nota) =>
              (widget.reiniciarCiclo ?? _reiniciarReal)(id, nota),
        ),
      );
      if (hecho == true && mounted) {
        mostrarSnack(context, 'Ciclo reiniciado: el conteo parte de hoy.',
            significado: SignificadoChip.exito);
        await _recargarDetalle();
      }
    } finally {
      if (mounted) setState(() => _operando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_seleccionadoId != null) return _vistaDetalle();
    if (_cargandoClientes) {
      return const EstadoCargando(texto: 'Cargando clientes…');
    }
    final q = _busquedaCtrl.text.trim().toLowerCase();
    final visibles = q.isEmpty
        ? _todos
        : _todos
            .where((c) =>
                c.nombre.toLowerCase().contains(q) ||
                c.telefono.contains(q))
            .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppEspacio.lg),
          child: CampoTexto(
            controller: _busquedaCtrl,
            etiqueta: 'Buscar cliente por nombre o teléfono',
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: visibles.isEmpty
              ? const EstadoVacio(
                  icono: Icons.person_search_rounded,
                  titulo: 'Sin clientes con ese criterio.',
                )
              : ListView.builder(
                  itemCount: visibles.length,
                  itemBuilder: (_, i) {
                    final c = visibles[i];
                    return ListTile(
                      leading: const Icon(Icons.person_rounded),
                      title: Text(c.nombre),
                      subtitle:
                          c.telefono.isEmpty ? null : Text(c.telefono),
                      trailing:
                          const Icon(Icons.chevron_right_rounded),
                      onTap: () => _abrirDetalle(c),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _vistaDetalle() {
    return Column(
      children: [
        ListTile(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => setState(() {
              _seleccionadoId = null;
              _detalle = null;
            }),
          ),
          title: Text(_seleccionadoNombre,
              style: AppTexto.subtitulo),
          subtitle: const Text('Premios y logros'),
        ),
        // H-04 (Argón 1.27): al terminar el sync, el
        // detalle se recarga solo (patrón de la Bandeja):
        // el «⏳ Anulación en curso (sincronizando)» se
        // resuelve con la foto fresca sin salir y volver.
        SyncBanner(alTerminarSync: _recargarDetalle),
        Expanded(
          child: _cargandoDetalle
              ? const EstadoCargando(texto: 'Cargando detalle…')
              : _falloDetalle
                  ? EstadoVacio(
                      icono: Icons.cloud_off_rounded,
                      titulo: 'No se pudo cargar el detalle.',
                      subtitulo: 'El detalle vive en el '
                          'servidor: hace falta conexión.',
                      textoAccion: 'Reintentar',
                      onAccion: () => _abrirDetalle((
                        id: _seleccionadoId!,
                        nombre: _seleccionadoNombre,
                        telefono: '',
                      )),
                    )
                  : _cuerpoDetalle(_detalle!),
        ),
      ],
    );
  }

  Widget _cuerpoDetalle(DetallePremiosCliente d) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _operando ? null : _conceder,
                icon: const Icon(Icons.card_giftcard_rounded,
                    size: 18),
                label: const Text('Conceder vale'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _operando ? null : _reiniciar,
                icon: const Icon(Icons.restart_alt_rounded,
                    size: 18),
                label: const Text('Reiniciar ciclo'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const EncabezadoSeccion(titulo: 'Progreso del ciclo'),
        if (d.logroBarraId == null)
          const Text(
            'No hay ningún premio activo en el catálogo: '
            'actívalo en la pestaña Catálogo.',
            style: AppTexto.secundario,
          )
        else ...[
          Text(
            '${tituloLogroPremio(d.logroBarraId!)}: '
            '${d.dias} de ${d.metaDias} días verificados',
            style: AppTexto.cuerpo,
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: d.fraccionBarra,
            minHeight: 10,
            borderRadius: BorderRadius.circular(5),
          ),
          const SizedBox(height: 6),
          Text(
            d.faltan > 0
                ? 'Le faltan ${d.faltan} días para el premio '
                    'de ${d.premioDias} días gratis.'
                : 'Ya cumple la meta: puede reclamar su '
                    'premio de ${d.premioDias} días gratis.',
            style: AppTexto.secundario,
          ),
          if (d.cicloDesde != null)
            Text(
              'Ciclo desde: ${fmtFecha(d.cicloDesde!.length >= 10 ? d.cicloDesde!.substring(0, 10) : d.cicloDesde)}',
              style: AppTexto.secundario,
            ),
        ],
        if (d.sesionesQueSumaron.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Últimas fechas que sumaron: '
            '${d.sesionesQueSumaron.map(fmtFecha).join(' · ')}',
            style: AppTexto.secundario,
          ),
        ],
        const SizedBox(height: 16),
        const EncabezadoSeccion(titulo: 'Historial de vales'),
        if (d.vales.isEmpty)
          const Text('Sin vales todavía.',
              style: AppTexto.secundario)
        else
          for (final v in d.vales) ...[
            _tarjetaValeHistorial(v),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 8),
        const EncabezadoSeccion(titulo: 'Medallas (sello)'),
        if (d.sello.isEmpty)
          const Text(
            'La app del cliente aún no ha subido su sello '
            'de medallas.',
            style: AppTexto.secundario,
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in d.sello.entries)
                Chip(
                  avatar: const Icon(
                      Icons.emoji_events_rounded, size: 16),
                  label: Text(
                      '${tituloLogroPremio(e.key)} · ${fmtFecha(e.value.length >= 10 ? e.value.substring(0, 10) : e.value)}'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Evaluado en el teléfono del cliente.',
            style: AppTexto.secundario,
          ),
        ],
        if (d.marcas.isNotEmpty) ...[
          const SizedBox(height: 16),
          const EncabezadoSeccion(titulo: 'Reinicios de ciclo'),
          for (final m in d.marcas)
            ListTile(
              dense: true,
              leading:
                  const Icon(Icons.restart_alt_rounded, size: 20),
              title: Text(fmtFecha(
                  m.desde.length >= 10 ? m.desde.substring(0, 10) : m.desde)),
              subtitle: Text(m.nota),
            ),
        ],
      ],
    );
  }

  Widget _tarjetaValeHistorial(ValeHistorial v) {
    final (icono, color) = switch (v.estado) {
      'canjeado' => (Icons.done_all_rounded, AppColores.exito),
      'rechazado' => (Icons.block_rounded, AppColores.error),
      'anulado' => (Icons.undo_rounded, AppColores.alerta),
      _ => (Icons.hourglass_top_rounded, AppColores.naranja),
    };
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${tituloLogroPremio(v.logroId)} · '
                  '${v.premioDias} días gratis · ${v.estado}',
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          Text(
            'Reclamado con ${v.diasAlReclamar} días verificados'
            '${v.creadoEn.length >= 10 ? ' · ${fmtFecha(v.creadoEn.substring(0, 10))}' : ''}'
            '${v.resueltoEn != null && v.resueltoEn!.length >= 10 ? ' · Resuelto el ${fmtFecha(v.resueltoEn!.substring(0, 10))}' : ''}',
            style: AppTexto.secundario,
          ),
          if (v.creadoNota.isNotEmpty)
            Text('📝 ${v.creadoNota}', style: AppTexto.secundario),
          if (v.resueltoNota.isNotEmpty)
            Text('Resolución: ${v.resueltoNota}',
                style: AppTexto.secundario),
          if (v.estado == 'anulado' && v.anuladoEn != null)
            Text(
              'Anulado el ${fmtFecha(v.anuladoEn!.length >= 10 ? v.anuladoEn!.substring(0, 10) : v.anuladoEn!)}',
              style: AppTexto.secundario,
            ),
          // S7: anular un vale canjeado con pago. El
          // botón solo vive con la foto FRESCA del
          // detalle (este historial viene de la RPC) y
          // se apaga en este teléfono al encolar la op.
          if (v.canjeado &&
              (v.pagoUuid ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            if (_anulacionesEnCurso.contains(v.id))
              const Text('⏳ Anulación en curso (sincronizando)',
                  style: AppTexto.secundario)
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _operando ? null : () => _anular(v),
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('Anular vale'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Diálogo «Conceder vale» (S4): el dueño elige el
/// logro (o «Vale manual» libre), los días de premio
/// y la nota OBLIGATORIA. El vale nace en la bandeja:
/// se aprueba allí con el mismo botón de siempre.
class _DialogoConcederVale extends StatefulWidget {
  final String nombreCliente;
  final List<EntradaCatalogoPremio> catalogo;
  final Future<Map<String, dynamic>> Function(
      String logroId, int premioDias, String nota) conceder;

  const _DialogoConcederVale(
      {required this.nombreCliente,
      required this.catalogo,
      required this.conceder});

  @override
  State<_DialogoConcederVale> createState() =>
      _DialogoConcederValeState();
}

class _DialogoConcederValeState extends State<_DialogoConcederVale> {
  late String _logroId;
  final _diasCtrl = TextEditingController();
  final _notaCtrl = TextEditingController();
  String? _error;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _logroId = widget.catalogo.any((e) => e.logroId == 'manual')
        ? 'manual'
        : (widget.catalogo.isNotEmpty
            ? widget.catalogo.first.logroId
            : 'manual');
    final entrada = widget.catalogo
        .where((e) => e.logroId == _logroId)
        .firstOrNull;
    if (entrada != null && entrada.premioDias > 0) {
      _diasCtrl.text = '${entrada.premioDias}';
    }
  }

  @override
  void dispose() {
    _diasCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    final dias = int.tryParse(_diasCtrl.text.trim());
    final nota = _notaCtrl.text.trim();
    String? error;
    if (dias == null || dias < 1 || dias > 365) {
      error = 'El premio debe estar entre 1 y 365 días.';
    } else if (nota.isEmpty) {
      error = 'La nota es obligatoria: explica el motivo del vale.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final res = await widget.conceder(_logroId, dias!, nota);
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _guardando = false;
        _error =
            '${res['mensaje'] ?? res['motivo'] ?? 'No se pudo crear el vale.'}';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'Sin conexión con el servidor.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Conceder vale',
      iconoTitulo: Icons.card_giftcard_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Para ${widget.nombreCliente}. El vale queda '
            'en la Bandeja: lo apruebas allí y los días se '
            'aplican por la vía de siempre.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _logroId,
            isExpanded: true,
            decoration:
                const InputDecoration(labelText: 'Logro'),
            items: [
              for (final e in widget.catalogo)
                DropdownMenuItem(
                  value: e.logroId,
                  child: Text(e.nombre, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _guardando
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() {
                      _logroId = v;
                      final entrada = widget.catalogo
                          .where((e) => e.logroId == v)
                          .firstOrNull;
                      if (entrada != null && entrada.premioDias > 0) {
                        _diasCtrl.text = '${entrada.premioDias}';
                      }
                    });
                  },
          ),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _diasCtrl,
              etiqueta: 'Días de mensualidad gratis',
              teclado: TextInputType.number),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _notaCtrl,
              etiqueta: 'Nota (obligatoria)',
              maxLineas: 2),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _enviar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Creando…' : 'Crear vale'),
        ),
      ],
    );
  }
}

/// Diálogo «Reiniciar ciclo» (S6): pone el contador
/// de días a cero desde hoy SIN tocar el candado
/// anual de canje. Nota obligatoria (D4).
class _DialogoReiniciarCiclo extends StatefulWidget {
  final String nombreCliente;
  final Future<Map<String, dynamic>> Function(String nota)
      reiniciar;

  const _DialogoReiniciarCiclo(
      {required this.nombreCliente, required this.reiniciar});

  @override
  State<_DialogoReiniciarCiclo> createState() =>
      _DialogoReiniciarCicloState();
}

class _DialogoReiniciarCicloState
    extends State<_DialogoReiniciarCiclo> {
  final _notaCtrl = TextEditingController();
  String? _error;
  bool _guardando = false;

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    final nota = _notaCtrl.text.trim();
    if (nota.isEmpty) {
      setState(() => _error =
          'La nota es obligatoria: explica el motivo del reinicio.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final res = await widget.reiniciar(nota);
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _guardando = false;
        _error =
            '${res['mensaje'] ?? res['motivo'] ?? 'No se pudo reiniciar.'}';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'Sin conexión con el servidor.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Reiniciar ciclo',
      iconoTitulo: Icons.restart_alt_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'El contador de días de ${widget.nombreCliente} '
            'vuelve a cero desde hoy. No cambia su '
            'vencimiento ni destraba el canje de un '
            'premio ya cobrado este año.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          CampoTexto(
              controller: _notaCtrl,
              etiqueta: 'Nota (obligatoria)',
              maxLineas: 2),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _enviar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Reiniciando…' : 'Reiniciar'),
        ),
      ],
    );
  }
}

/// Diálogo «Anular vale» (S7, D2 de Jc): el dueño
/// elige EN EL MOMENTO entre quitar el pago completo
/// o solo los días no consumidos, viendo el efecto de
/// cada vía antes de confirmar. Nota obligatoria.
/// El servidor recalcula los días: lo que aquí se
/// muestra es la misma fórmula, y si el servidor no
/// coincide, la op se rechaza sin tocar nada.
class _DialogoAnularVale extends StatefulWidget {
  final String nombreCliente;
  final ValeHistorial vale;
  final String? pagadoHasta;
  final DateTime hoy;
  final Future<void> Function(String modo, int diasQuitables,
      String nota) anular;

  const _DialogoAnularVale(
      {required this.nombreCliente,
      required this.vale,
      required this.pagadoHasta,
      required this.hoy,
      required this.anular});

  @override
  State<_DialogoAnularVale> createState() =>
      _DialogoAnularValeState();
}

class _DialogoAnularValeState extends State<_DialogoAnularVale> {
  String _modo = 'no_consumidos';
  final _notaCtrl = TextEditingController();
  String? _error;
  bool _guardando = false;

  late final int _k = diasQuitablesVale(
    pagadoHasta: widget.pagadoHasta,
    resueltoEn: widget.vale.resueltoEn,
    premioDias: widget.vale.premioDias,
    hoy: widget.hoy,
  );

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  String _hastaTras(int diasMenos) {
    final hasta = widget.pagadoHasta;
    if (hasta == null) return '—';
    if (DateTime.tryParse(hasta) == null) return '—';
    // H-01 (Argón 1.27): aritmética UTC pura
    // (sumarDiasIso). La resta sobre un DateTime local
    // cruzaba el cambio de horario (marzo en Cuba) y
    // la vista previa se corría un día frente al
    // servidor.
    return fmtFecha(sumarDiasIso(hasta, -diasMenos));
  }

  Future<void> _enviar() async {
    final nota = _notaCtrl.text.trim();
    if (nota.isEmpty) {
      setState(() => _error =
          'La nota es obligatoria: explica el motivo de la anulación.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await widget.anular(_modo, _k, nota);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'No se pudo encolar la anulación.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vale;
    return DialogoApp(
      titulo: 'Anular vale',
      iconoTitulo: Icons.undo_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'El vale de ${v.premioDias} días de '
            '${widget.nombreCliente} ya se aplicó. Elige '
            'cómo revertirlo:',
            style: AppTexto.secundario,
          ),
          RadioGroup<String>(
            groupValue: _modo,
            onChanged: _guardando
                ? (_) {}
                : (m) => setState(() => _modo = m ?? 'no_consumidos'),
            child: Column(
              children: [
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'no_consumidos',
                  title: const Text('Solo los días no consumidos'),
                  subtitle: Text(_k > 0
                      ? 'Se quitan $_k días: el vencimiento pasa '
                          'de ${fmtFecha(widget.pagadoHasta)} a '
                          '${_hastaTras(_k)}. Los ${v.premioDias - _k} '
                          'ya disfrutados se quedan.'
                      : 'Este vale ya se consumió entero: esta '
                          'vía resta 0 días, solo cierra el vale '
                          'como anulado.'),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'completo',
                  title: const Text('Quitar el pago completo'),
                  // H-03 (Argón 1.27): la fecha que sale
                  // de restar los días es solo la
                  // ESTIMACIÓN local: en modo completo el
                  // servidor borra el pago y recalcula el
                  // vencimiento sin él, y esa es la fecha
                  // que manda (con un hueco de por medio,
                  // la resta lineal puede no coincidir).
                  subtitle: Text(widget.pagadoHasta != null
                      ? 'Se quitan los ${v.premioDias} días '
                          'completos (también los ya '
                          'disfrutados): pasaría de '
                          '${fmtFecha(widget.pagadoHasta)} a '
                          '${_hastaTras(v.premioDias)}. Es una '
                          'estimación: la fecha exacta la '
                          'confirma el servidor al sincronizar.'
                      : 'Se quitan los ${v.premioDias} días '
                          'completos (también los ya '
                          'disfrutados). La fecha exacta la '
                          'confirma el servidor al sincronizar.'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _notaCtrl,
              etiqueta: 'Nota (obligatoria)',
              maxLineas: 2),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _enviar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.error,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Anulando…' : 'Anular vale'),
        ),
      ],
    );
  }
}
