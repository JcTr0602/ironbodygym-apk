/// Bloque G de Invitados (v1.5.0): bandeja de Gestión.
///
/// Lista y detalle de los invitados registrados desde la app de
/// clientes. TODO vive en Supabase y se lee por RPC de staff
/// (lib/invitados.dart): la bandeja necesita conexión; a cambio no
/// hay espejo local que se desactualice. La lista NO muestra datos
/// corporales (diseño §8); las medidas autodeclaradas viven en el
/// detalle, visibles ANTES de Convertir junto con la última sync
/// (ajuste 5 de Argón).
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../invitados.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'horario_gym.dart';
import 'inscribir.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Bandeja (lista)
// ---------------------------------------------------------------------------

class InvitadosScreen extends StatefulWidget {
  /// v1.6.0: embebida como pestaña de «Usuarios» (sin Scaffold ni
  /// AppBar propios; las acciones de la AppBar van en una fila).
  final bool embebido;

  /// Filtro con el que abre la bandeja ('todos' por defecto; el
  /// Panel del dueño enlaza directo con 'solicitudes').
  final String filtroInicial;

  const InvitadosScreen(
      {super.key, this.embebido = false, this.filtroInicial = 'todos'});
  @override
  State<InvitadosScreen> createState() => _InvitadosScreenState();
}

/// v1.8.0: ciclo del op_id de los lotes COMPARTIDO por la lista
/// y el detalle (la huella distingue cada intención).
final _loteInvitados = AccionLoteInvitados();

/// Dorado de la pastilla y la línea Plus (rango «Invitado Plus»).
const _doradoPlus = Color(0xFF9A7B0A);

class _InvitadosScreenState extends State<InvitadosScreen> {
  final _svc = InvitadosService();
  static const _filtros = <({String id, String etiqueta})>[
    (id: 'todos', etiqueta: 'Todos'),
    (id: 'solicitudes', etiqueta: 'Solicitudes'),
    (id: 'nuevos', etiqueta: 'Nuevos'),
    (id: 'por_expirar', etiqueta: 'Cuenta por expirar'),
    (id: 'plus', etiqueta: 'Plus'),
    (id: 'plus_por_vencer', etiqueta: 'Plus por vencer'),
    (id: 'convertidos', etiqueta: 'Convertidos'),
  ];
  String _filtro = 'todos';
  bool _cargando = true;
  String? _error;
  List<InvitadoResumen> _lista = [];
  Map<String, ConversionInvitado> _locales = {};
  // v1.6.0: ids de clientes de la base LOCAL, para contar la historia
  // completa del convertido (si su cliente ya no existe aquí, fue
  // eliminado después de la conversión).
  Set<String> _idsClientes = {};
  // v1.8.0: conteos de cabecera (del servidor), modo offline de
  // SOLO LECTURA (J3/G1) y multiselección para acciones en lote.
  InvitadosConteos? _conteos;
  bool _offline = false;
  DateTime? _cacheAt;
  final Set<String> _seleccion = {};
  bool get _modoSeleccion => _seleccion.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _filtro = widget.filtroInicial;
    _cargar();
  }

  void _limpiarSeleccion() {
    if (_seleccion.isNotEmpty) setState(() => _seleccion.clear());
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    // Primero cerrar conversiones cuya op ya subió (idempotente).
    try {
      await _svc.verificarConversiones();
    } catch (_) {}
    try {
      final lista = await _svc.listar(filtro: _filtro);
      final conteos = await _svc.resumen();
      final locales = await ConversionInvitadoStore().todas();
      final clientes = await LocalDb.instance.allMirror('clientes');
      if (!mounted) return;
      // G1: la caché guarda SOLO el par {resumen, lista «Todos»}.
      if (_filtro == 'todos') {
        await _svc.guardarCacheInvitados(
            resumen: conteos, listaTodos: lista);
      }
      setState(() {
        _lista = lista;
        _conteos = conteos;
        _offline = false;
        _cacheAt = null;
        _seleccion.clear();
        _locales = {for (final c in locales) c.invitadoId: c};
        _idsClientes = {for (final c in clientes) '${c['id']}'};
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      // J3/G1: sin conexión, la caché manda en SOLO LECTURA y la
      // vista se clava en «Todos» (sin chips, búsqueda ni acciones).
      if (e is InvitadoError && e.codigo == 'RED') {
        final cache = await _svc.leerCacheInvitados();
        if (!mounted) return;
        if (cache != null && cache.lista.isNotEmpty) {
          setState(() {
            _lista = cache.lista;
            _conteos = cache.resumen;
            _offline = true;
            _cacheAt = cache.cachedAt;
            _filtro = 'todos';
            _seleccion.clear();
            _cargando = false;
            _error = null;
          });
          return;
        }
      }
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  String? _badgeLocal(ConversionInvitado? c) {
    if (c == null) return null;
    switch (c.estado) {
      case EstadoConversion.preparada:
        return 'Conversión preparada';
      case EstadoConversion.opEncolada:
        return 'Inscripción por sincronizar';
      case EstadoConversion.confirmada:
        return 'Convertido desde este teléfono';
      case EstadoConversion.opRechazada:
        return 'Inscripción rechazada';
      case EstadoConversion.cancelada:
        return null;
    }
  }

  /// Mini-conteos de cabecera (del servidor): tocar uno aplica
  /// su chip. En offline se pintan pero no navegan (vista clavada
  /// en «Todos», G1).
  Widget _lineaConteos() {
    final c = _conteos!;
    Widget seg(String texto, String filtro) => InkWell(
          onTap: _offline
              ? null
              : () {
                  setState(() {
                    _filtro = filtro;
                    _seleccion.clear();
                  });
                  _cargar();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 6, vertical: 4),
            child: Text(texto,
                style: AppTexto.secundario.copyWith(
                    fontWeight: FontWeight.w600,
                    color: _filtro == filtro
                        ? AppColores.naranja
                        : null)),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          seg('${c.total} invitados', 'todos'),
          const Text('·', style: AppTexto.secundario),
          seg('${c.plus} Plus', 'plus'),
          const Text('·', style: AppTexto.secundario),
          seg('${c.solicitudes} solicitudes', 'solicitudes'),
          const Text('·', style: AppTexto.secundario),
          seg('${c.porExpirar} por expirar', 'por_expirar'),
          if (c.plusPorVencer > 0) ...[
            const Text('·', style: AppTexto.secundario),
            seg('${c.plusPorVencer} Plus por vencer',
                'plus_por_vencer'),
          ],
        ],
      ),
    );
  }

  /// Barra inferior del modo selección: SOLO las tres acciones de
  /// lote del diseño (Plus = dueño; vida = staff). Jamás convertir,
  /// ajustar clave ni eliminar en masa.
  Widget _barraLote() {
    final esDueno = AuthService().isOwner;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, -2)),
        ],
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.sm, vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (esDueno)
            TextButton.icon(
              onPressed: () => _confirmarLote('plus_cortesia'),
              icon: const Icon(Icons.star_rounded, size: 18),
              label: const Text('Dar Plus'),
            ),
          if (esDueno)
            TextButton.icon(
              onPressed: () => _confirmarLote('plus_quitar'),
              icon: const Icon(Icons.star_border_rounded, size: 18),
              label: const Text('Quitar Plus'),
            ),
          TextButton.icon(
            onPressed: () => _confirmarLote('vida_extender'),
            icon: const Icon(Icons.event_available_rounded, size: 18),
            label: const Text('Extender vida'),
          ),
        ],
      ),
    );
  }

  /// Hoja de confirmación del lote con auto-exclusión EXPLICADA
  /// (diseño §4): los no aplicables se listan con nombre y motivo
  /// y NO bloquean al resto.
  Future<void> _confirmarLote(String accion) async {
    final seleccionados = [
      for (final inv in _lista)
        if (_seleccion.contains(inv.id)) inv,
    ];
    if (seleccionados.isEmpty) return;
    final parte = partirLote(seleccionados, accion);
    final aplicables = parte.aplicables;
    final excluidos = parte.excluidos;
    final params = await showDialog<({int dias, String motivo})>(
      context: context,
      builder: (_) => _DialogoLote(
        accion: accion,
        aplicables: aplicables,
        excluidos: excluidos,
      ),
    );
    if (params == null || !mounted || aplicables.isEmpty) return;
    await _ejecutarLote(
      ids: [for (final i in aplicables) i.id],
      accion: accion,
      dias: params.dias,
      motivo: params.motivo,
      nombres: {for (final i in _lista) i.id: i.nombre},
    );
  }

  Future<void> _ejecutarLote({
    required List<String> ids,
    required String accion,
    required int dias,
    required String motivo,
    required Map<String, String> nombres,
  }) async {
    ResultadoLote? res;
    String? error;
    try {
      res = await _loteInvitados.ejecutar(
        _svc,
        ids: ids,
        accion: accion,
        dias: accion == 'plus_quitar' ? null : dias,
        motivo: motivo.isEmpty ? null : motivo,
      );
    } catch (e) {
      error = e is InvitadoError
          ? e.mensaje
          : 'No se pudo aplicar el lote.';
    }
    if (!mounted) return;
    if (error != null || res == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error ?? 'Sin respuesta.')));
      return;
    }
    // Los fallidos quedan seleccionados para reintento (con op_id
    // NUEVO, G4.3: la respuesta ya consumió la intención).
    final fallidos = {
      for (final it in res.items)
        if (!it.ok && it.codigo == 'error') it.id,
    };
    setState(() {
      _seleccion
        ..clear()
        ..addAll(fallidos);
    });
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _DialogoResultadoLote(res: res!, nombres: nombres),
    );
    if (mounted) _cargar();
  }

  /// Acciones de la cabecera (información pública y actualizar):
  /// en la AppBar en modo pantalla y en una fila propia en modo
  /// embebido, para no perder ninguna función al integrar la
  /// bandeja como pestaña de «Usuarios» (v1.6.0).
  List<Widget> _acciones(bool esAdmin) {
    return [
      if (esAdmin)
        IconButton(
          tooltip: 'Información pública de la app',
          icon: const Icon(Icons.public_rounded),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const InfoPublicaScreen()),
          ),
        ),
      IconButton(
        tooltip: 'Actualizar',
        icon: const Icon(Icons.refresh_rounded),
        onPressed: _cargando ? null : _cargar,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final esAdmin = AuthService().isAdmin;
    final cuerpo = Column(
      children: [
        const SyncBanner(compact: true),
        if (_offline)
          Container(
            width: double.infinity,
            color: AppColores.alerta.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
            child: Text(
              '📴 Sin conexión · datos de hace '
              '${_cacheAt != null ? hace(_cacheAt) : 'un rato'} · '
              'solo lectura',
              style: AppTexto.secundario.copyWith(
                  color: AppColores.alertaOscuro,
                  fontWeight: FontWeight.w600),
            ),
          ),
        if (_modoSeleccion && !_offline)
          Container(
            width: double.infinity,
            color: AppColores.naranja.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg, vertical: AppEspacio.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_seleccion.length} seleccionado(s)',
                    style: AppTexto.secundario
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _seleccion.addAll(
                        [for (final i in _lista.take(50)) i.id]);
                  }),
                  child: const Text('Seleccionar los cargados'),
                ),
                IconButton(
                  tooltip: 'Salir de la selección',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _limpiarSeleccion,
                ),
              ],
            ),
          ),
        if (widget.embebido)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Registros desde la app de clientes: atiende '
                    'solicitudes y convierte invitados en clientes.',
                    style: AppTexto.secundario,
                  ),
                ),
                ..._acciones(esAdmin),
              ],
            ),
          ),
        if (!_offline)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: Row(
              children: [
                for (final f in _filtros) ...[
                  ChoiceChip(
                    label: Text(f.etiqueta),
                    selected: _filtro == f.id,
                    onSelected: (_) {
                      setState(() {
                        _filtro = f.id;
                        _seleccion.clear();
                      });
                      _cargar();
                    },
                  ),
                  const SizedBox(width: AppEspacio.sm),
                ],
              ],
            ),
          ),
        if (_conteos != null) _lineaConteos(),
        Expanded(child: _cuerpo()),
        if (_modoSeleccion && !_offline) _barraLote(),
      ],
    );
    if (widget.embebido) return cuerpo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Invitados'),
        actions: _acciones(esAdmin),
      ),
      body: cuerpo,
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La bandeja de invitados vive en el servidor: '
                'necesita conexión.',
                textAlign: TextAlign.center,
                style: AppTexto.secundario,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    if (_lista.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppEspacio.xl),
          child: Text(
            'No hay invitados en esta vista.\nLos registros nuevos '
            'desde la app de clientes aparecen aquí.',
            textAlign: TextAlign.center,
            style: AppTexto.secundario,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppEspacio.lg),
        itemCount: _lista.length,
        itemBuilder: (ctx, i) {
          final inv = _lista[i];
          final badge = _badgeLocal(_locales[inv.id]);
          final seleccionado = _seleccion.contains(inv.id);
          void alternar() => setState(() {
                if (seleccionado) {
                  _seleccion.remove(inv.id);
                } else if (_seleccion.length < 50) {
                  _seleccion.add(inv.id);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Máximo 50 invitados por lote.')));
                }
              });
          return Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: GestureDetector(
              onLongPress: _offline ? null : alternar,
              child: Tarjeta(
              color: seleccionado
                  ? AppColores.naranja.withValues(alpha: 0.07)
                  : null,
              onTap: () async {
                if (_offline) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Sin conexión: el detalle no está '
                              'disponible en modo lectura.')));
                  return;
                }
                if (_modoSeleccion) {
                  alternar();
                  return;
                }
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      InvitadoDetalleScreen(invitadoId: inv.id),
                ));
                if (mounted) _cargar();
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (_modoSeleccion)
                        Checkbox(
                          value: seleccionado,
                          onChanged: (_) => alternar(),
                        )
                      else
                        const Icon(Icons.person_outline_rounded,
                            color: AppColores.naranja),
                      const SizedBox(width: AppEspacio.sm),
                      Expanded(
                        child: Text(inv.nombre,
                            style: AppTexto.subtitulo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (inv.tieneSolicitudPendiente)
                        const Icon(Icons.mark_email_unread_rounded,
                            color: AppColores.alerta),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '📱 ${inv.telefono} · registrado '
                    '${inv.creadoEn != null ? hace(inv.creadoEn) : '—'}',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (inv.tieneSolicitudPendiente)
                        _chip('🙋 Quiere inscribirse',
                            AppColores.alerta),
                      // v1.8.0: pastilla de rango. Jerarquía:
                      // Convertido > En conversión > PLUS > regular
                      // (sin pastilla: la ausencia ES la señal).
                      if (inv.convertido)
                        _chip('✓ Convertido', AppColores.exitoOscuro)
                      else if (inv.enConversion)
                        _chip('En conversión', AppColores.infoOscuro)
                      else if (inv.plusActivo)
                        _chip('⭐ PLUS', _doradoPlus)
                      else if (inv.caducado)
                        _chip('Caducado', AppColores.error)
                      else if (inv.caducaPronto)
                        _chip(
                            'Caduca en ${inv.diasRestantes} día(s)',
                            AppColores.alertaOscuro),
                      if (badge != null)
                        _chip(badge, AppColores.infoOscuro),
                      // v1.6.0: el cliente vinculado ya no existe en
                      // la base local: fue eliminado tras convertir.
                      // La inferencia por ausencia SOLO vale si el
                      // espejo de clientes tiene filas: con el espejo
                      // vacío (reinstalación, primer sync pendiente)
                      // la ausencia no prueba ninguna eliminación.
                      if (inv.convertido &&
                          inv.clienteId != null &&
                          _idsClientes.isNotEmpty &&
                          !_idsClientes.contains('${inv.clienteId}'))
                        _chip('Cliente eliminado', AppColores.error),
                    ],
                  ),
                  // v1.6.0: la tarjeta del convertido cuenta su
                  // historia: cuándo se convirtió y a qué cliente.
                  if (inv.convertido) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Convertido'
                      '${inv.convertidoEn != null ? ' el ${fechaAbsoluta(inv.convertidoEn)}' : ''}'
                      '${inv.clienteId != null ? ' · Cliente #${inv.clienteId}' : ''}',
                      style: AppTexto.secundario,
                    ),
                  ],
                  // v1.8.0: línea Plus (el residual de un convertido
                  // NO se pinta: es inerte, diseño §2).
                  if (inv.plusActivo && !inv.convertido) ...[
                    const SizedBox(height: 4),
                    Text(
                      '⭐ Plus hasta el '
                      '${inv.plusHasta != null ? fmtFecha(inv.plusHasta!.toIso8601String()) : '—'}'
                      '${inv.plusDiasRestantes != null ? ' · quedan ${inv.plusDiasRestantes} día(s)' : ''}'
                      '${inv.plusOrigen != null ? ' · ${inv.plusOrigen == 'cortesia' ? 'cortesía' : 'pago'}' : ''}',
                      style: AppTexto.secundario.copyWith(
                        color: inv.plusPorVencer
                            ? AppColores.alertaOscuro
                            : _doradoPlus,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Widget _chip(String texto, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(texto,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color)),
  );
}

String _n(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

/// Auto-exclusión del lote (diseño §4): parte la selección en
/// aplicables y excluidos CON MOTIVO, para que la hoja de
/// confirmación lo explique con nombres. Los excluidos no
/// bloquean al resto. (La guardia real es el servidor; esto es
/// solo la explicación previa.)
({List<InvitadoResumen> aplicables, List<(InvitadoResumen, String)> excluidos})
    partirLote(List<InvitadoResumen> seleccion, String accion) {
  final aplicables = <InvitadoResumen>[];
  final excluidos = <(InvitadoResumen, String)>[];
  for (final inv in seleccion) {
    if (inv.convertido) {
      excluidos.add((inv, 'ya es cliente'));
    } else if (inv.enConversion && accion != 'vida_extender') {
      excluidos.add((inv, 'conversión en curso'));
    } else if (accion == 'plus_quitar' && !inv.plusActivo) {
      excluidos.add((inv, 'no tiene Plus activo'));
    } else {
      aplicables.add(inv);
    }
  }
  return (aplicables: aplicables, excluidos: excluidos);
}

String tituloLote(String accion) => switch (accion) {
      'plus_cortesia' => 'Dar Plus de cortesía',
      'plus_quitar' => 'Quitar Plus',
      _ => 'Extender vida',
    };

/// Hoja de confirmación de una acción (individual o en lote):
/// presets de días cerrados (J2) y motivo OBLIGATORIO en las
/// acciones Plus (chips + texto corto).
class _DialogoLote extends StatefulWidget {
  final String accion;
  final List<InvitadoResumen> aplicables;
  final List<(InvitadoResumen, String)> excluidos;
  const _DialogoLote({
    required this.accion,
    required this.aplicables,
    required this.excluidos,
  });
  @override
  State<_DialogoLote> createState() => _DialogoLoteState();
}

class _DialogoLoteState extends State<_DialogoLote> {
  int _dias = 30;
  String? _motivoChip;
  final _motivoCtrl = TextEditingController();

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  List<int> get _presets =>
      widget.accion == 'vida_extender' ? const [30, 90] : const [15, 30];
  bool get _motivoObligatorio => widget.accion != 'vida_extender';

  String get _motivo {
    final partes = [
      if (_motivoChip != null) _motivoChip!,
      _motivoCtrl.text.trim(),
    ].where((s) => s.isNotEmpty);
    return partes.join(': ');
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.aplicables.length;
    return AlertDialog(
      title: Text(tituloLote(widget.accion)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(n == 1
                ? 'Para ${widget.aplicables.first.nombre}.'
                : 'Para $n invitado(s).'),
            if (widget.accion == 'plus_cortesia') ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'Es una cortesía: sin pago registrado y NO da '
                'derecho a entrenar en el gym.',
                style: AppTexto.secundario,
              ),
            ],
            if (widget.accion == 'plus_quitar') ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'El Plus se revoca desde ahora. El historial de '
                'pagos y reportes NO se toca.',
                style: AppTexto.secundario,
              ),
            ],
            if (widget.excluidos.isNotEmpty) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(
                '${widget.excluidos.length} no aplica(n):',
                style: AppTexto.secundario
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              for (final (inv, motivo) in widget.excluidos)
                Text('· ${inv.nombre} — $motivo',
                    style: AppTexto.secundario),
            ],
            if (widget.accion != 'plus_quitar') ...[
              const SizedBox(height: AppEspacio.md),
              const Text('Días', style: AppTexto.secundario),
              const SizedBox(height: AppEspacio.xs),
              Wrap(
                spacing: AppEspacio.sm,
                children: [
                  for (final d in _presets)
                    ChoiceChip(
                      label: Text('$d días'),
                      selected: _dias == d,
                      onSelected: (_) => setState(() => _dias = d),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppEspacio.md),
            Text(
                _motivoObligatorio
                    ? 'Motivo (obligatorio)'
                    : 'Motivo (opcional)',
                style: AppTexto.secundario),
            const SizedBox(height: AppEspacio.xs),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                for (final m in const [
                  'Cortesía',
                  'Promo',
                  'Compensación',
                  'Error mío',
                ])
                  ChoiceChip(
                    label: Text(m),
                    selected: _motivoChip == m,
                    onSelected: (sel) =>
                        setState(() => _motivoChip = sel ? m : null),
                  ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            TextField(
              controller: _motivoCtrl,
              decoration: const InputDecoration(
                hintText: 'Nota corta (opcional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLength: 80,
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
          onPressed: n == 0 ||
                  (_motivoObligatorio && _motivo.isEmpty)
              ? null
              : () => Navigator.of(context)
                  .pop((dias: _dias, motivo: _motivo)),
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}

/// Resultado del lote construido desde la RESPUESTA de la RPC:
/// aunque la recarga de la lista falle después, el dueño ve qué
/// pasó con cada invitado.
class _DialogoResultadoLote extends StatelessWidget {
  final ResultadoLote res;
  final Map<String, String> nombres;
  const _DialogoResultadoLote({required this.res, required this.nombres});

  @override
  Widget build(BuildContext context) {
    String nombreDe(ItemLote it) => nombres[it.id] ?? 'Invitado';
    return AlertDialog(
      title: Text('${tituloLote(res.accion)} — resultado'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '✅ ${res.aplicados} aplicado(s) · '
              '⏭ ${res.omitidos} omitido(s) · '
              '❌ ${res.fallidos} fallido(s)',
              style: AppTexto.secundario
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            if (res.repetida)
              const Text(
                'Esta operación ya se había aplicado: se muestra '
                'el resultado original, sin duplicar.',
                style: AppTexto.secundario,
              ),
            const SizedBox(height: AppEspacio.sm),
            for (final it in res.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  it.ok
                      ? '✅ ${nombreDe(it)}'
                          '${it.plusHasta != null ? ' — Plus hasta el ${fmtFecha(it.plusHasta!.toIso8601String())}' : ''}'
                          '${it.caducaEn != null ? ' — caduca el ${fmtFecha(it.caducaEn!.toIso8601String())}' : ''}'
                      : '${it.codigo == 'error' ? '❌' : '⏭'} '
                          '${nombreDe(it)} — ${it.motivo ?? it.codigo}',
                  style: AppTexto.secundario,
                ),
              ),
            if (res.fallidos > 0)
              const Text(
                'Los fallidos quedan seleccionados para reintentar.',
                style: AppTexto.secundario,
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Entendido'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Detalle
// ---------------------------------------------------------------------------

class InvitadoDetalleScreen extends StatefulWidget {
  final String invitadoId;
  const InvitadoDetalleScreen({super.key, required this.invitadoId});
  @override
  State<InvitadoDetalleScreen> createState() =>
      _InvitadoDetalleScreenState();
}

class _InvitadoDetalleScreenState extends State<InvitadoDetalleScreen> {
  final _svc = InvitadosService();
  bool _cargando = true;
  bool _actuando = false;
  String? _error;
  InvitadoDetalle? _d;
  ConversionInvitado? _local;
  // v1.6.0: el cliente vinculado ya no está en la base local.
  bool _clienteEliminado = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      await _svc.verificarConversiones();
    } catch (_) {}
    try {
      final d = await _svc.detalle(widget.invitadoId);
      var local =
          await ConversionInvitadoStore().leer(widget.invitadoId);
      // G1(b): si este teléfono preparó la conversión y el
      // registro local se perdió (cierre entre la RPC y el
      // guardado), se adopta la preparación que ve el servidor.
      local ??= await _svc.adoptarConversionDelServidor(d);
      // G3: una preparación local cuyo lock venció (o que ya no
      // existe en el servidor) se cierra como cancelada: el
      // detalle no ofrecerá «Reanudar» con un uuid muerto y se
      // podrá preparar una conversión nueva.
      if (local != null) {
        local = await _svc.reconciliarPreparadaObsoleta(d, local);
      }
      // v1.6.0: ¿el cliente vinculado sigue existiendo en la base
      // local? Si no está, fue eliminado después de la conversión.
      // Panel 1.6.0: la inferencia por ausencia solo aplica con el
      // espejo NO vacío; vacío (reinstalación/sin primer sync) no
      // prueba eliminación: ni se marca ni se oculta «Ver ficha».
      var clienteEliminado = false;
      if (d.clienteId != null) {
        final clientes = await LocalDb.instance.allMirror('clientes');
        clienteEliminado = clientes.isNotEmpty &&
            !clientes.any((c) => '${c['id']}' == '${d.clienteId}');
      }
      if (!mounted) return;
      setState(() {
        _d = d;
        _local = local;
        _clienteEliminado = clienteEliminado;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  void _snack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _whatsapp() async {
    final d = _d!;
    final num = normalizarTelefonoWaMe(d.telefono);
    if (num.isEmpty) {
      _snack('El teléfono del invitado no es válido para WhatsApp.');
      return;
    }
    final ok = await launchUrl(Uri.parse('https://wa.me/$num'),
        mode: LaunchMode.externalApplication);
    if (!ok) _snack('No se pudo abrir WhatsApp.');
  }

  Future<void> _atender() async {
    setState(() => _actuando = true);
    try {
      final n = await _svc.atenderSolicitud(widget.invitadoId);
      _snack(n > 0
          ? 'Solicitud marcada como atendida'
          : 'La solicitud ya estaba atendida');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _convertir() async {
    final d = _d!;
    setState(() => _actuando = true);
    try {
      final datos = await _svc.prepararConversion(d);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InscribirScreen(conversion: datos),
      ));
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  /// «Reanudar inscripción»: reabre Inscribir con el MISMO
  /// conversion_uuid durable (el formulario se cerró a mitad).
  Future<void> _reanudar() async {
    final d = _d!;
    final local = _local!;
    final datos = DatosConversionInvitado(
      invitadoId: d.id,
      conversionUuid: local.conversionUuid,
      nombre: d.nombre,
      telefono: d.telefono,
      fechaNac: d.fechaNac,
      medidas: d.mediciones,
    );
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InscribirScreen(conversion: datos),
    ));
    await _cargar();
  }

  Future<void> _cancelarConversion() async {
    final local = _local;
    if (local == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cancelar conversión',
        iconoTitulo: Icons.cancel_outlined,
        contenido: const Text(
            'Se cancela la preparación en el servidor y el '
            'invitado vuelve a estar activo normal. Podrás '
            'convertirlo de nuevo cuando quieras.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Volver')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cancelar conversión')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _actuando = true);
    try {
      await _svc.cancelarConversion(local.conversionUuid,
          invitadoId: widget.invitadoId);
      _snack('Conversión cancelada');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _sincronizarAhora() async {
    setState(() => _actuando = true);
    try {
      await SyncEngine.instance.push();
      await _svc.verificarConversiones();
      await _cargar();
      _snack('Sincronización revisada');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detalle del invitado')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null || _d == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error ?? 'Sin datos', textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    final d = _d!;
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          _tarjetaDatos(d),
          if (d.solicitud != null) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaSolicitud(d),
          ],
          if (d.plus != null) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaPlus(d),
          ],
          const SizedBox(height: AppEspacio.md),
          _tarjetaSync(d),
          const SizedBox(height: AppEspacio.md),
          _tarjetaConversion(d),
          if (d.staffAcciones.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaStaff(d),
          ],
          const SizedBox(height: AppEspacio.md),
          _tarjetaAcciones(d),
        ],
      ),
    );
  }

  Widget _tarjetaDatos(InvitadoDetalle d) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_rounded,
                  color: AppColores.naranja),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                  child: Text(d.nombre, style: AppTexto.titulo)),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          _chip('⚠ Teléfono no verificado', AppColores.alertaOscuro),
          const SizedBox(height: AppEspacio.sm),
          _linea('📱 Teléfono', d.telefono),
          if (d.fechaNac != null)
            _linea('🎂 Nacimiento', fmtFecha(d.fechaNac)),
          _linea('🗓 Registrado', fechaAbsoluta(d.creadoEn)),
          _linea(
              '⏳ Caduca',
              d.convertido
                  ? 'ya convertido'
                  : '${fechaAbsoluta(d.caducaEn)}${d.caducado ? ' (caducado)' : ''}'),
          _linea('Estado', d.estado),
          if (d.telefonoYaCliente)
            const Padding(
              padding: EdgeInsets.only(top: AppEspacio.sm),
              child: Text(
                'ℹ️ Este teléfono también es de un cliente. El '
                'Plus y las acciones aplican SOLO a la cuenta de '
                'invitado.',
                style: AppTexto.secundario,
              ),
            ),
        ],
      ),
    );
  }

  Widget _linea(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 130,
              child: Text(etiqueta, style: AppTexto.secundario)),
          Expanded(child: Text(valor, style: AppTexto.cuerpo)),
        ],
      ),
    );
  }

  Widget _tarjetaSolicitud(InvitadoDetalle d) {
    final s = d.solicitud!;
    return Tarjeta(
      color: s.pendiente
          ? AppColores.alerta.withValues(alpha: 0.10)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.mark_email_unread_rounded,
                  color: AppColores.alertaOscuro),
              SizedBox(width: AppEspacio.sm),
              Text('Solicitud «Quiero inscribirme»',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            s.pendiente
                ? 'Pendiente desde ${fechaAbsoluta(s.creadaEn)}'
                : 'Atendida ${s.atendidaEn != null ? fechaAbsoluta(s.atendidaEn) : ''}'
                    '${s.atendidoPor != null ? ' por ${s.atendidoPor}' : ''}'
                    '${s.resultado != null ? ' · ${s.resultado}' : ''}',
            style: AppTexto.cuerpo,
          ),
          if (s.pendiente) ...[
            const SizedBox(height: AppEspacio.md),
            BotonPrimario(
              texto: 'Marcar atendida',
              icono: Icons.done_all_rounded,
              onPressed: _actuando ? null : _atender,
            ),
          ],
        ],
      ),
    );
  }

  /// Ajuste 5 de Argón: lo sincronizado se ve ANTES de convertir;
  /// lo que siga en el teléfono del invitado se pierde al revocar.
  Widget _tarjetaSync(InvitadoDetalle d) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.sync_rounded, color: AppColores.naranja),
              SizedBox(width: AppEspacio.sm),
              Text('Datos sincronizados', style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          _linea('Última sync',
              d.ultimaSync != null ? hace(d.ultimaSync) : '—'),
          _linea('Medidas sincronizadas',
              '${d.medicionesSincronizadas}'),
          if (d.mediciones.isEmpty)
            const Text(
              'El invitado aún no ha sincronizado medidas.',
              style: AppTexto.secundario,
            )
          else
            for (final m in d.mediciones) ...[
              const Divider(height: 16),
              _linea('📅 ${fmtFecha(m.fecha)}',
                  m.resumen.isEmpty ? 'medida registrada' : m.resumen),
              if (_detalleMedida(m).isNotEmpty)
                Text(_detalleMedida(m), style: AppTexto.secundario),
              if (m.notas != null && m.notas!.isNotEmpty)
                Text('«${m.notas}»', style: AppTexto.secundario),
            ],
          const SizedBox(height: AppEspacio.sm),
          const Text(
            'Medidas autodeclaradas por el invitado en su app. '
            'Al convertirlo, su acceso de invitado se revoca: las '
            'medidas que aún estén en su teléfono SIN sincronizar '
            'se pierden.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }

  String _detalleMedida(MedidaInvitado m) {
    final p = <String>[];
    if (m.pechoCm != null) p.add('pecho ${_n(m.pechoCm!)}');
    if (m.brazoCm != null) p.add('brazo ${_n(m.brazoCm!)}');
    if (m.cinturaCm != null) p.add('cintura ${_n(m.cinturaCm!)}');
    if (m.caderaCm != null) p.add('cadera ${_n(m.caderaCm!)}');
    if (m.musloCm != null) p.add('muslo ${_n(m.musloCm!)}');
    return p.isEmpty ? '' : '${p.join(' · ')} cm';
  }

  Widget _tarjetaConversion(InvitadoDetalle d) {
    if (d.convertido) {
      return Tarjeta(
        color: AppColores.exito.withValues(alpha: 0.10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.verified_rounded,
                    color: AppColores.exitoOscuro),
                SizedBox(width: AppEspacio.sm),
                Text('Ya es cliente', style: AppTexto.subtitulo),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Text(
              'Convertido ${d.convertidoEn != null ? fechaAbsoluta(d.convertidoEn) : ''}'
              '${d.clienteId != null ? ' · Cliente #${d.clienteId}' : ''}.',
              style: AppTexto.cuerpo,
            ),
            if (_clienteEliminado) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(
                'El cliente vinculado fue eliminado.',
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.error, fontWeight: FontWeight.w600),
              ),
            ],
            if (_local?.resultadoMedidas != null) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(_local!.resultadoMedidas!.texto,
                  style: AppTexto.secundario),
            ],
            if (d.clienteId != null && !_clienteEliminado) ...[
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Ver ficha del cliente',
                icono: Icons.badge_rounded,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) =>
                          FichaScreen(clienteId: d.clienteId!)),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final reanudar = reanudarPara(
        local: _local, enServidor: d.conversionPreparada);
    switch (reanudar) {
      case ReanudarConversion.abrirInscribir:
        return Tarjeta(
          color: AppColores.info.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      color: AppColores.infoOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Conversión preparada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La inscripción quedó a mitad en este teléfono. '
                'Reanúdala con el mismo registro preparado: no se '
                'duplica.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Reanudar inscripción',
                icono: Icons.play_arrow_rounded,
                onPressed: _actuando ? null : _reanudar,
              ),
              const SizedBox(height: AppEspacio.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancelar conversión'),
                onPressed: _actuando ? null : _cancelarConversion,
              ),
            ],
          ),
        );
      case ReanudarConversion.esperandoSync:
        return Tarjeta(
          color: AppColores.alerta.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.cloud_upload_rounded,
                      color: AppColores.alertaOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Inscripción guardada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La inscripción ya se guardó en este teléfono y '
                'está esperando sincronizarse. Al subirse, la '
                'conversión se confirma sola y aquí verás el '
                'resultado de las medidas.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Sincronizar / verificar ahora',
                icono: Icons.sync_rounded,
                onPressed: _actuando ? null : _sincronizarAhora,
              ),
            ],
          ),
        );
      case ReanudarConversion.verResultado:
        return Tarjeta(
          color: AppColores.exito.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.verified_rounded,
                      color: AppColores.exitoOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Conversión confirmada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              if (_local?.resultadoMedidas != null)
                Text(_local!.resultadoMedidas!.texto,
                    style: AppTexto.cuerpo)
              else
                const Text('El invitado ya es cliente.',
                    style: AppTexto.cuerpo),
            ],
          ),
        );
      case ReanudarConversion.revisarFallo:
        return Tarjeta(
          color: AppColores.error.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      color: AppColores.errorOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('La inscripción fue rechazada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'El servidor rechazó la operación de inscripción '
                '(revisa la cola de operaciones para el motivo). '
                'Cancela esta conversión para poder intentarlo de '
                'nuevo.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancelar conversión'),
                onPressed: _actuando ? null : _cancelarConversion,
              ),
            ],
          ),
        );
      case ReanudarConversion.ninguna:
        final enSrv = d.conversionPreparada;
        return Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      color: AppColores.naranja),
                  SizedBox(width: AppEspacio.sm),
                  Text('Convertir en cliente',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              if (enSrv != null)
                Text(
                  enSrv.lockVigente
                      ? 'Hay una conversión preparada'
                          '${enSrv.preparadaPor != null ? ' por ${enSrv.preparadaPor}' : ''} '
                          'con bloqueo hasta '
                          '${enSrv.expiraLockEn != null ? fechaAbsoluta(enSrv.expiraLockEn) : '—'}. '
                          'Si la preparaste tú en OTRO teléfono, termínala allá; '
                          'si intentas convertir ahora, el servidor lo rechazará '
                          'hasta que venza el bloqueo.'
                      : 'Hubo una conversión preparada cuyo bloqueo '
                          'ya venció: al convertir se emitirá una nueva.',
                  style: AppTexto.cuerpo,
                )
              else
                const Text(
                  'Abre la inscripción pre-llenada con sus datos. '
                  'Al sincronizarse, el invitado pasa a cliente y '
                  'sus medidas sincronizadas se envían al servidor '
                  'para verificarlas: se importan solo las que el '
                  'servidor confirme como suyas, y el resultado se '
                  'verá al confirmarse la conversión.',
                  style: AppTexto.cuerpo,
                ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Convertir en cliente',
                icono: Icons.person_add_alt_rounded,
                onPressed: _actuando ? null : _convertir,
              ),
            ],
          ),
        );
    }
  }

  /// v1.8.0 — Bloque Plus del detalle (diseño §5.4): estado con
  /// su nombre (revocado ≠ vencido, G5), origen e historial.
  /// Las acciones son del dueño (dinero) y van por la MISMA RPC
  /// de lote con un array de 1.
  Widget _tarjetaPlus(InvitadoDetalle d) {
    final p = d.plus!;
    final esDueno = AuthService().isOwner;
    String textoEstado() {
      switch (p.estado) {
        case 'activo':
          return '⭐ Activo hasta el '
              '${p.hasta != null ? fmtFecha(p.hasta!.toIso8601String()) : '—'}'
              '${p.diasRestantes != null ? ' · quedan ${p.diasRestantes} día(s)' : ''}'
              '${p.origen != null ? ' · origen: ${p.origen == 'cortesia' ? 'cortesía' : 'pago'}' : ''}';
        case 'vencido':
          return 'Vencido el '
              '${p.hasta != null ? fmtFecha(p.hasta!.toIso8601String()) : '—'}';
        case 'revocado':
          return 'Revocado (lo quitó el dueño; no venció solo)';
        default:
          return 'Sin Plus';
      }
    }

    String textoHistorial(PlusHistorialItem h) {
      final fecha =
          h.fecha != null ? fmtFecha(h.fecha!.toIso8601String()) : '—';
      switch (h.tipo) {
        case 'plus_cortesia':
          return '🎁 Cortesía de ${h.dias ?? ''} días · $fecha'
              '${h.actor != null ? ' · ${h.actor}' : ''}'
              '${h.motivo != null ? ' · «${h.motivo}»' : ''}';
        case 'plus_quitar':
          return '🚫 Revocado · $fecha'
              '${h.actor != null ? ' · ${h.actor}' : ''}'
              '${h.motivo != null ? ' · «${h.motivo}»' : ''}';
        case 'reporte_confirmado':
          return '💳 Pago confirmado · $fecha'
              '${h.montoCup != null ? ' · ${fmtMonto(h.montoCup!)} CUP' : ''}'
              '${h.hasta != null ? ' → Plus hasta el ${fmtFecha(h.hasta!.toIso8601String())}' : ''}';
        case 'reporte_pendiente':
          return '⏳ Reporte de pago pendiente · $fecha';
        case 'reporte_rechazado':
          return '↩️ Reporte rechazado · $fecha'
              '${h.motivo != null ? ' · «${h.motivo}»' : ''}';
        default:
          return '${h.tipo} · $fecha';
      }
    }

    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Invitado Plus', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          Text(textoEstado(), style: AppTexto.cuerpo),
          if (d.convertido)
            const Padding(
              padding: EdgeInsets.only(top: AppEspacio.xs),
              child: Text(
                'Ya es cliente: el Plus residual queda inerte y '
                'revive solo si su mensualidad cae.',
                style: AppTexto.secundario,
              ),
            ),
          if (p.historial.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.sm),
            const Text('Historial', style: AppTexto.secundario),
            for (final h in p.historial)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(textoHistorial(h),
                    style: AppTexto.secundario),
              ),
          ],
          if (esDueno && !d.convertido) ...[
            const SizedBox(height: AppEspacio.md),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                if (!p.activo)
                  FilledButton.icon(
                    icon: const Icon(Icons.star_rounded, size: 18),
                    label: const Text('Dar Plus de cortesía'),
                    onPressed: _actuando
                        ? null
                        : () => _accionUnica('plus_cortesia'),
                  ),
                if (p.activo)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.star_border_rounded,
                        size: 18),
                    label: const Text('Quitar Plus'),
                    onPressed: _actuando
                        ? null
                        : () => _accionUnica('plus_quitar'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// v1.8.0 — Historial de acciones de staff (diseño §5.7):
  /// responde «¿quién le regaló el Plus / le extendió la vida?».
  Widget _tarjetaStaff(InvitadoDetalle d) {
    String textoAccion(AccionStaffInvitado a) {
      final motivo = a.detalle['motivo'] as String?;
      final dias = (a.detalle['dias'] as num?)?.toInt();
      final base = switch (a.accion) {
        'plus_cortesia' => '🎁 Dio Plus de cortesía'
            '${dias != null ? ' ($dias días)' : ''}',
        'plus_quitar' => '🚫 Quitó el Plus',
        'vida_extender' => '⏳ Extendió la vida'
            '${dias != null ? ' (+$dias días)' : ''}',
        'eliminar_invitado' => '🗑 Eliminó la cuenta',
        _ => a.accion,
      };
      return '$base'
          '${a.actor != null ? ' · ${a.actor}' : ''}'
          '${a.fecha != null ? ' · ${fmtFecha(a.fecha!.toIso8601String())}' : ''}'
          '${motivo != null ? ' · «$motivo»' : ''}';
    }

    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acciones del equipo',
              style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          for (final a in d.staffAcciones)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(textoAccion(a),
                  style: AppTexto.secundario),
            ),
        ],
      ),
    );
  }

  /// Acción individual por la RPC de lote (array de 1): mismo
  /// diálogo, mismo resultado y mismo ciclo de op_id que la
  /// multiselección de la lista.
  Future<void> _accionUnica(String accion) async {
    final d = _d;
    if (d == null) return;
    final resumen = InvitadoResumen(
      id: d.id,
      nombre: d.nombre,
      telefono: d.telefono,
      estado: d.estado,
      plusActivo: d.plus?.activo ?? false,
    );
    final params = await showDialog<({int dias, String motivo})>(
      context: context,
      builder: (_) => _DialogoLote(
        accion: accion,
        aplicables: [resumen],
        excluidos: const [],
      ),
    );
    if (params == null || !mounted) return;
    setState(() => _actuando = true);
    try {
      final res = await _loteInvitados.ejecutar(
        _svc,
        ids: [d.id],
        accion: accion,
        dias: accion == 'plus_quitar' ? null : params.dias,
        motivo: params.motivo.isEmpty ? null : params.motivo,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _DialogoResultadoLote(
            res: res, nombres: {d.id: d.nombre}),
      );
      if (mounted) _cargar();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is InvitadoError
              ? e.mensaje
              : 'No se pudo aplicar la acción.')));
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Widget _tarjetaAcciones(InvitadoDetalle d) {
    final esAdmin = AuthService().isAdmin;
    // G4: con una conversión sin resolver, Eliminar queda
    // deshabilitado (la op podría crear el cliente después y la
    // conversión quedaría imposible de confirmar).
    final eliminarBloqueado = eliminarInvitadoBloqueado(
        local: _local, enServidor: d.conversionPreparada);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acciones', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.md),
          OutlinedButton.icon(
            icon: const Icon(Icons.chat_rounded),
            label: const Text('Escribir por WhatsApp'),
            onPressed: _whatsapp,
          ),
          if (!d.convertido) ...[
            const SizedBox(height: AppEspacio.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_available_rounded),
              label: const Text('Extender vida (+30/+90 días)'),
              onPressed: _actuando
                  ? null
                  : () => _accionUnica('vida_extender'),
            ),
          ],
          if (esAdmin && !d.convertido) ...[
            const SizedBox(height: AppEspacio.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.key_rounded),
              label: const Text('Ajustar acceso (clave)'),
              onPressed: _actuando ? null : _ajustarClave,
            ),
          ],
          // J1 (v1.8.0): eliminar invitado es SOLO del dueño; el
          // servidor lo refuerza con el error limpio 42501 (G2).
          if (AuthService().isOwner && !d.convertido) ...[
            const SizedBox(height: AppEspacio.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppColores.error),
              label: const Text('Eliminar invitado',
                  style: TextStyle(color: AppColores.error)),
              onPressed:
                  (_actuando || eliminarBloqueado) ? null : _eliminar,
            ),
            if (eliminarBloqueado) ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'No se puede eliminar mientras haya una '
                'conversión en curso: termínala o cancélala '
                'primero.',
                style: AppTexto.secundario,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// Regla anti-fuga (§12.3): el ajuste de clave SOLO procede si
  /// la persona confirma el nombre registrado y la fecha de
  /// creación. Si el nombre no coincide con quien reclama, NO se
  /// resetea: se elimina (libera el número) o se inscribe directo.
  Future<void> _ajustarClave() async {
    final d = _d!;
    final ctrl = TextEditingController();
    var confirmado = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Ajustar acceso del invitado',
          iconoTitulo: Icons.key_rounded,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'El teléfono del invitado NO está verificado. '
                  'Solo ajusta la clave si la persona confirma '
                  'estos datos:',
                  style: AppTexto.cuerpo,
                ),
                const SizedBox(height: AppEspacio.md),
                _linea('Nombre registrado', d.nombre),
                _linea('Registrado el', fechaAbsoluta(d.creadoEn)),
                const SizedBox(height: AppEspacio.sm),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: confirmado,
                  onChanged: (v) =>
                      setS(() => confirmado = v ?? false),
                  title: const Text(
                      'La persona confirmó su nombre y su fecha '
                      'de registro',
                      style: AppTexto.cuerpo),
                ),
                const SizedBox(height: AppEspacio.sm),
                CampoTexto(
                  controller: ctrl,
                  etiqueta: 'Clave nueva (6–32, sin espacios)',
                  icono: Icons.lock_outline_rounded,
                  obscure: true,
                  onChanged: (_) => setS(() {}),
                ),
                const SizedBox(height: AppEspacio.sm),
                const Text(
                  'Si quien reclama dice que el teléfono es suyo '
                  'pero el nombre NO coincide, no ajustes la '
                  'clave: elimina el invitado (libera el número '
                  'al instante) o inscribe a la persona '
                  'directamente como cliente.',
                  style: AppTexto.secundario,
                ),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: confirmado &&
                      RegExp(r'^\S{6,32}$')
                          .hasMatch(ctrl.text.trim())
                  ? () => Navigator.pop(ctx, true)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Ajustar clave'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      await _svc.ajustarClave(widget.invitadoId, ctrl.text.trim());
      _snack('Clave ajustada. Las sesiones del invitado se '
          'revocaron: debe entrar con la clave nueva y cambiarla.');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _eliminar() async {
    final d = _d!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Eliminar invitado',
        iconoTitulo: Icons.delete_outline_rounded,
        contenido: Text(
            'Se elimina a «${d.nombre}» con sus medidas y '
            'sesiones de invitado, y el número ${d.telefono} '
            'queda libre al instante (también se resetea su '
            'límite de registro). Esta acción no se puede '
            'deshacer.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      await _svc.eliminar(widget.invitadoId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
      if (mounted) setState(() => _actuando = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Información pública (panel del dueño): lo que la app de
// clientes muestra al invitado. Cambiar un enlace o un número
// aquí NO exige actualizar la app (diseño §10.2). Vacío = la
// clave se borra y el dato/botón no se muestra.
// ---------------------------------------------------------------------------

class InfoPublicaScreen extends StatefulWidget {
  const InfoPublicaScreen({super.key});
  @override
  State<InfoPublicaScreen> createState() => _InfoPublicaScreenState();
}

class _InfoPublicaScreenState extends State<InfoPublicaScreen> {
  final _svc = InvitadosService();
  final Map<String, TextEditingController> _ctrls = {};
  Map<String, String> _originales = {};
  bool _cargando = true;
  bool _guardando = false;
  String? _error;
  // v1.6.0 (Jc): el horario ya NO se edita en esta pantalla: la
  // fuente única es el horario del sistema («Horario del Gym»).
  // Aquí se muestra en solo lectura y al guardar se republica como
  // «horario_texto» para que el invitado vea el horario real.
  List<DiaHorario> _horarioSistema = [];

  @override
  void initState() {
    super.initState();
    for (final c in clavesInfoPublica) {
      _ctrls[c.clave] = TextEditingController();
    }
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final info = await _svc.infoPublica();
      // v1.6.0: el horario canónico del sistema (caché local o la
      // misma RPC que usa «Horario del Gym»); [] si no se pudo.
      final horario = await cargarHorarioCanonico();
      if (!mounted) return;
      setState(() {
        _originales = info;
        for (final c in clavesInfoPublica) {
          _ctrls[c.clave]!.text = info[c.clave] ?? '';
        }
        _horarioSistema = horario;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  Future<void> _guardar() async {
    final cambios = <String, String>{};
    for (final c in clavesInfoPublica) {
      // v1.6.0: «horario_texto» no sale de un campo editable (ver
      // el bloque siguiente); el resto, como siempre.
      if (c.clave == 'horario_texto') continue;
      // G6: las claves de teléfono se comparan y guardan
      // NORMALIZADAS (8 dígitos); el resto, como texto libre.
      final v =
          valorAGuardarInfoPublica(c.clave, _ctrls[c.clave]!.text);
      if (v != (_originales[c.clave] ?? '')) cambios[c.clave] = v;
    }
    // v1.6.0 (Jc, fuente única): el horario que ve el invitado se
    // REPUBLICA desde el horario del sistema al guardar esta
    // pantalla, para que nunca quede un horario viejo tecleado a
    // mano. Si el canónico no cargó, no se toca el valor guardado.
    final textoHorario = textoHorarioCanonico(_horarioSistema);
    if (textoHorario.isNotEmpty &&
        textoHorario != (_originales['horario_texto'] ?? '')) {
      cambios['horario_texto'] = textoHorario;
    }
    if (cambios.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sin cambios que guardar')));
      return;
    }
    // G6: un teléfono que no cumple (8 dígitos) frena TODO el
    // guardado con aviso claro: nada llega a info_publica_guardar
    // a medias.
    for (final c in clavesInfoPublica) {
      if (!cambios.containsKey(c.clave)) continue;
      // El horario republicado no es texto tecleado: no se valida.
      if (c.clave == 'horario_texto') continue;
      final error = validarValorInfoPublica(
          c.clave, _ctrls[c.clave]!.text);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('«${c.etiqueta}» $error')));
        return;
      }
    }
    setState(() => _guardando = true);
    try {
      for (final e in cambios.entries) {
        await _svc.guardarInfoPublica(e.key, e.value);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Información pública actualizada: la app de '
              'clientes la verá en su próxima sincronización')));
      await _cargar();
    } on InvitadoError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.mensaje)));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Información pública')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        const Text(
          'Esto es lo que ve el invitado en su portada: redes, '
          'contactos, precios estándar, horario y ubicación. '
          'Deja un campo vacío para que no se muestre.',
          style: AppTexto.secundario,
        ),
        const SizedBox(height: AppEspacio.md),
        for (final c in clavesInfoPublica) ...[
          // v1.6.0 (Jc): el horario ya no es un campo editable
          // aquí; se muestra el del sistema en solo lectura.
          if (c.clave == 'horario_texto')
            _tarjetaHorarioSistema()
          else
            CampoTexto(
              controller: _ctrls[c.clave],
              etiqueta: c.etiqueta,
              hint: c.ayuda,
            ),
          const SizedBox(height: AppEspacio.md),
        ],
        const SizedBox(height: AppEspacio.sm),
        _guardando
            ? const Center(
                child:
                    CircularProgressIndicator(color: AppColores.naranja))
            : BotonPrimario(
                texto: 'Guardar información pública',
                icono: Icons.save_rounded,
                onPressed: _guardar,
              ),
        const SizedBox(height: AppEspacio.lg),
      ],
    );
  }

  /// v1.6.0 (Jc): el horario del gym en SOLO LECTURA dentro de la
  /// Información pública. La fuente única es el horario del
  /// sistema; aquí no se teclea nada.
  Widget _tarjetaHorarioSistema() {
    final texto = textoHorarioCanonico(_horarioSistema);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.schedule_rounded,
                  size: 18, color: AppColores.naranja),
              SizedBox(width: AppEspacio.sm),
              Text('Horario del gym', style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            texto.isEmpty
                ? 'No se pudo cargar el horario del sistema.'
                : texto,
            style: AppTexto.cuerpo,
          ),
          const SizedBox(height: AppEspacio.xs),
          const Text(
            'Este es el horario del sistema; se edita en su '
            'sección («Horario del Gym»). Al guardar esta pantalla '
            'se republica tal cual para los invitados.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }
}
