import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart' show fmtMonto, fechaLargaCorta;
import '../servicios.dart';
import 'app_bar.dart';
import 'diseno.dart';
import 'componentes.dart';
import 'servicios_detalle.dart';
import '../app_log.dart';

/// Historial completo de Servicios (pedido de Jc 2026-10-28):
/// todas las operaciones de venta de raciones, combos y agua, más
/// las salidas sin venta, en orden de nuevas a viejas, con filtros
/// por tipo y (solo dueño) por vendedor. No vende, pero desde
/// la 1.31 (Mejoras) SÍ abre el detalle único de la venta y
/// revierte también aquí (G-1: antes revertir era privilegio
/// del día en curso).
///
/// Roles: el dueño ve todas las operaciones; el entrenador solo
/// las suyas (el mismo predicado que «Ventas de hoy»: vendedor o
/// pomo propio). Las salidas sin venta solo las registra el dueño,
/// así que al entrenador no le llega ninguna. Solo operaciones
/// sincronizadas (espejo): una venta offline pendiente aparece aquí
/// cuando sincroniza.
///
/// 10/25: la pantalla carga sus propios datos al abrirse (ventas
/// y salidas del espejo) en vez de recibir las listas ya cargadas
/// desde Servicios: así la pantalla principal ya no escanea los
/// espejos completos en cada carga.
class ServiciosHistorialScreen extends StatelessWidget {
  final bool esDueno;
  final int? miTid;
  final Set<int> misPomosIds;
  final Map<int, String> personas;

  /// 4/25: venta que resaltar y desplazar a la vista al abrir (llegada
  /// desde el Extracto). Null = comportamiento normal.
  final int? resaltarId;

  const ServiciosHistorialScreen({
    super.key,
    required this.esDueno,
    this.miTid,
    this.misPomosIds = const {},
    required this.personas,
    this.resaltarId,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Historial de Servicios'),
      body: ServiciosHistorialCuerpo(
        esDueno: esDueno,
        miTid: miTid,
        misPomosIds: misPomosIds,
        personas: personas,
        resaltarId: resaltarId,
      ),
    );
  }
}

/// 1.31 (Mejoras · Día): el cuerpo del historial es un widget
/// propio: la pantalla lo monta con su Scaffold y el hub
/// «Servicios» lo embebe en la zona Día, sin duplicar lógica.
class ServiciosHistorialCuerpo extends StatefulWidget {
  final bool esDueno;
  final int? miTid;
  final Set<int> misPomosIds;
  final Map<int, String> personas;
  final int? resaltarId;

  const ServiciosHistorialCuerpo({
    super.key,
    required this.esDueno,
    this.miTid,
    this.misPomosIds = const {},
    required this.personas,
    this.resaltarId,
  });

  @override
  State<ServiciosHistorialCuerpo> createState() =>
      _ServiciosHistorialCuerpoState();
}

class _ServiciosHistorialCuerpoState
    extends State<ServiciosHistorialCuerpo> {
  // Filtros: tipo 'todas' | 'racion' | 'combo' | 'agua' | 'salida';
  // vendedor null = todos (solo dueño; el entrenador solo ve lo suyo).
  String _filtroTipo = 'todas';
  int? _filtroVendedor;

  // Resaltado (4/25): id + llave por fila para desplazar a la venta.
  int? _resaltado;
  final _llaves = <int, GlobalKey>{};

  // 11/25: buscador por cliente, vendedor o tipo.
  final _busquedaCtrl = TextEditingController();
  var _busqueda = '';

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _entradas = [];
  bool _cargando = true;
  // SL-7 (G06-1): el fallo de carga se VE (EstadoError con
  // Reintentar, el patrón de la pantalla principal); antes el
  // historial caía en la lista vacía en silencio.
  bool _errorCarga = false;

  /// 1.31 (Mejoras): pomos con el producto resuelto, para el
  /// detalle único y para nombrar el pomo en las salidas.
  List<Map<String, dynamic>> _pomosResueltos = [];

  void _aviso(String m, {bool error = false}) {
    if (!mounted) return;
    mostrarSnack(context, m,
        significado:
            error ? SignificadoChip.error : SignificadoChip.neutral);
  }

  /// Respaldo de nombre por tid (menor Argón adenda): nombre que
  /// traía la venta (registrado_por_nombre) cuando el tid no está
  /// en widget.personas (p. ej. ventas viejas o del dueño).
  Map<int, String> _respaldoPorTid = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// 1.34 Campo 2 (P-7): el Historial gana el gesto de
  /// bajar-para-actualizar (era la primera pantalla sin
  /// él): alcance de servicios con la regla de Jc
  /// (fresco = solo local) y relectura. Sin avisos, como
  /// el resto de la pantalla.
  Future<void> _actualizarHistorial() async {
    try {
      await refrescoScopeIron('servicios');
    } catch (_) {
      // Sin red: se relee lo local igualmente.
    }
    await _cargar();
  }

  /// 10/25: carga propia. El predicado de rol es el mismo que
  /// «Ventas de hoy» en Servicios (vendedor o pomo propio).
  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _errorCarga = true);
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final ventas = await LocalDb.instance.allMirror('servicio_ventas');
    final pomosCrudos =
        await LocalDb.instance.allMirror('servicio_pomos');
    final sups = await LocalDb.instance.allMirror('suplementos');
    final supPorId = <int, Map<String, dynamic>>{
      for (final x in sups)
        if ((x['id'] as num?)?.toInt() != null)
          (x['id'] as num).toInt(): x,
    };
    final pomosResueltos = resolverPomosHistorial(
        pomosCrudos, supPorId, widget.personas);
    final salidas = widget.esDueno
        ? await LocalDb.instance.allMirror('servicio_salidas')
        : <Map<String, dynamic>>[];
    bool visibleParaMi(Map<String, dynamic> v) {
      if (widget.esDueno) return true;
      final vend = LocalDb.normalizarTelegramId(v['vendedor_id']) ??
          LocalDb.normalizarTelegramId(v['registrado_por']);
      return vend == widget.miTid ||
          widget.misPomosIds
              .contains((v['pomo_id'] as num?)?.toInt());
    }

    final historial = ventas.where(visibleParaMi).toList();
    final reversadas = <int>{
      for (final v in ventas)
        if ((v['reverso_de'] as num?) != null)
          (v['reverso_de'] as num).toInt(),
      // Argón Servicios #6: también las reversiones aún en la
      // cola (sin espejar), como en la pantalla principal.
      ...await reversosPendientesVentaIds(),
    };
    final entradas = entradasHistorialServicios(
      ventas: historial,
      salidas: salidas,
      reversadas: reversadas,
    );
    final respaldo = <int, String>{};
    for (final e in entradas) {
      if (e['kind'] != 'venta') continue;
      final tid = _vendedorDe(e);
      if (tid == null || respaldo.containsKey(tid)) continue;
      final r = '${e['registradoPor'] ?? ''}';
      if (r.isNotEmpty) respaldo[tid] = r;
    }
    if (!mounted) return;
    setState(() {
      _entradas = entradas;
      _respaldoPorTid = respaldo;
      _pomosResueltos = pomosResueltos;
      _cargando = false;
      _errorCarga = false;
    });
    if (widget.resaltarId != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _irAResaltado());
    }
  }

  int? _vendedorDe(Map<String, dynamic> e) =>
      LocalDb.normalizarTelegramId(e['vendedorId']) ??
      LocalDb.normalizarTelegramId(e['registradoPorId']);

  String _nombreVendedor(int? tid, [String? respaldo]) {
    if (tid != null && widget.personas[tid] != null) {
      return widget.personas[tid]!;
    }
    if (respaldo != null && respaldo.isNotEmpty) return respaldo;
    return 'Entrenador';
  }

  List<Map<String, dynamic>> get _visibles {
    return _entradas.where((e) {
      final esVenta = e['kind'] == 'venta';
      switch (_filtroTipo) {
        case 'racion':
          if (!esVenta || e['tipo'] != 'dosis_sin_agua') return false;
        case 'combo':
          if (!esVenta || e['tipo'] != 'dosis_con_agua') return false;
        case 'agua':
          if (!esVenta || e['tipo'] != 'agua_suelta') return false;
        case 'salida':
          if (esVenta) return false;
      }
      if (_filtroVendedor != null) {
        if (!esVenta) return false;
        if (_vendedorDe(e) != _filtroVendedor) return false;
      }
      // 11/25: buscador por cliente, vendedor, tipo o motivo.
      if (_busqueda.isNotEmpty &&
          !coincideBusquedaHistorialServicio(
              e,
              _busqueda,
              _nombreVendedor(
                  _vendedorDe(e), '${e['registradoPor'] ?? ''}'))) {
        return false;
      }
      return true;
    }).toList();
  }

  List<int> get _vendedores {
    final tids = <int>{};
    for (final e in _entradas) {
      if (e['kind'] != 'venta') continue;
      final tid = _vendedorDe(e);
      if (tid != null) tids.add(tid);
    }
    final lista = tids.toList()..sort();
    return lista;
  }

  /// Desplaza a la venta resaltada y la tiñe (4/25). Si no está en la
  /// lista visible, no hace nada.
  void _irAResaltado() {
    final id = widget.resaltarId;
    if (id == null || !mounted) return;
    final ctx = _llaves[id]?.currentContext;
    if (ctx == null) return;
    setState(() => _resaltado = id);
    Scrollable.ensureVisible(ctx,
        // 1.35 (UI-13): duración por el token.
        duration: AppMovimiento.larga, alignment: 0.5);
  }

  // 1.34 (C-48 · G-03): resumen del botón de filtros —
  // nombra el tipo activo y, si lo hay, el vendedor.
  String _resumenFiltrosServicios() => resumenFiltrosServiciosTxt(
        tipo: etiquetaTipoHistorialServicio(_filtroTipo),
        vendedor: _filtroVendedor == null
            ? null
            : _nombreVendedor(
                _filtroVendedor!, _respaldoPorTid[_filtroVendedor!]),
      );

  Widget _botonFiltrosServicios(List<int> vendedores) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.filter_list_rounded, size: 16),
      // Yunque 1.34 (C2-5): resumen a 2 líneas (ver Auditoría).
      label: Text(_resumenFiltrosServicios(),
          style: AppTexto.metadato,
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.lg),
        ),
      ),
      onPressed: () => _abrirFiltrosServicios(vendedores),
    );
  }

  Future<void> _abrirFiltrosServicios(List<int> vendedores) async {
    final r = await showModalBottomSheet<({String tipo, int? vendedor})>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadio.xl)),
      ),
      builder: (ctx) => _HojaFiltrosServiciosHistorial(
        tipo: _filtroTipo,
        vendedor: _filtroVendedor,
        esDueno: widget.esDueno,
        vendedores: [
          for (final tid in vendedores)
            (
              tid: tid,
              nombre: _nombreVendedor(tid, _respaldoPorTid[tid]),
            ),
        ],
      ),
    );
    if (r == null || !mounted) return;
    setState(() {
      _filtroTipo = r.tipo;
      _filtroVendedor = r.vendedor;
    });
  }

  /// V23: aplana las entradas visibles intercalando el día
  /// como encabezado de grupo. 1.31 (Mejoras): el encabezado
  /// ya no es la fecha cruda sola: lleva los TOTALES del día
  /// visible (operaciones e importe neto, con
  /// totalesDiaHistorialServicios).
  List<Object> _itemsPorDia(List<Map<String, dynamic>> visibles) {
    final items = <Object>[];
    String? diaActual;
    var delDia = <Map<String, dynamic>>[];
    void cerrarDia() {
      if (diaActual == null) return;
      final t = totalesDiaHistorialServicios(delDia);
      items.add({
        'encabezado': true,
        'dia': diaActual,
        'ops': t.operaciones,
        'importe': t.importe,
      });
      items.addAll(delDia);
      delDia = <Map<String, dynamic>>[];
    }

    for (final e in visibles) {
      final f = '${e['fecha']}';
      final dia = f.length >= 10 ? f.substring(0, 10) : f;
      if (dia != diaActual) {
        cerrarDia();
        diaActual = dia;
      }
      delDia.add(e);
    }
    cerrarDia();
    return items;
  }

  /// Abre el detalle ÚNICO de la venta (el mismo de «Ventas
  /// de hoy») y, desde él, la reversión — también para días
  /// pasados (G-1). Tras revertir, el historial se recarga.
  Future<void> _abrirDetalle(Map<String, dynamic> e) async {
    final cruda = e['cruda'];
    if (cruda is! Map<String, dynamic>) return;
    await mostrarDetalleVentaServicio(
      context,
      venta: cruda,
      pomos: _pomosResueltos,
      yaReversada: e['yaReversada'] == true,
      onRevertir: (venta) async {
        final ok = await revertirVentaServicioUI(context, venta,
            esDueno: widget.esDueno, aviso: _aviso);
        if (ok && mounted) await _cargar();
      },
    );
  }

  /// Nombre del pomo de una salida («del pomo de quién salió»).
  String _nombrePomoSalida(Map<String, dynamic> e) {
    final pid = (e['pomoId'] as num?)?.toInt();
    if (pid == null) return 'sin pomo';
    for (final p in _pomosResueltos) {
      if ((p['id'] as num?)?.toInt() == pid) {
        return '${p['producto_nombre']} · ${p['responsable_nombre']}';
      }
    }
    return 'Pomo sin nombre';
  }

  Widget _filaEntrada(Map<String, dynamic> e) {
    final esVenta = e['kind'] == 'venta';
    final esReverso = e['esReverso'] == true;
    final yaReversada = e['yaReversada'] == true;
    final esCasa = e['casa'] == true;
    final hora = '${e['hora'] ?? ''}';
    if (!esVenta) {
      // Salida sin venta: qué salió, de qué pomo y por qué —
      // antes la fila no decía ni el pomo ni llevaba la hora.
      return Padding(
        padding: const EdgeInsets.only(bottom: AppEspacio.sm),
        child: Tarjeta(
          child: Row(
            children: [
              Icon(Icons.outbox_rounded,
                  color: AppColores.textoSecundario(context)),
              const SizedBox(width: AppEspacio.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Salida sin venta',
                        style: AppTexto.cuerpo),
                    Text(
                      '${e['tipo'] == 'agua' ? 'Agua' : 'Dosis'} '
                      '×${e['cantidad']} · ${_nombrePomoSalida(e)}',
                      style: AppTexto.secundario,
                    ),
                    Text(
                      '${e['motivo']}'
                      '${hora.isNotEmpty ? ' · $hora' : ''}',
                      style: AppTexto.metadato,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    final tipoTxt = '${e['tipo']}' == 'agua_suelta'
        ? 'Agua ×${e['cantidad']}'
        : etiquetaTipoServicio('${e['tipo']}');
    final icono = esReverso
        ? Icons.undo_rounded
        : esCasa
            ? Icons.star_rounded
            : e['tipo'] == 'dosis_sin_agua'
                ? Icons.science_rounded
                : e['tipo'] == 'dosis_con_agua'
                    ? Icons.local_drink_rounded
                    : Icons.water_drop_rounded;
    final significadoTipo = esReverso
        ? SignificadoChip.error
        : e['tipo'] == 'dosis_sin_agua'
            ? SignificadoChip.exito
            : SignificadoChip.info;
    final vendedor = widget.esDueno
        ? ' · ${_nombreVendedor(_vendedorDe(e), '${e['registradoPor'] ?? ''}')}'
        : '';
    final metodo = etiquetaMetodoServicio('${e['metodo'] ?? ''}');
    final idVenta = (e['id'] as num?)?.toInt() ?? 0;
    final llave = _llaves.putIfAbsent(idVenta, () => GlobalKey());
    // 1.31 (Mejoras · Historial elevado): la fila es una
    // Tarjeta del sistema (antes Card+ListTile crudos): el
    // CLIENTE es el título (G-2), el tipo va en chip con su
    // icono y color, y tocarla abre el detalle único — con
    // reversión también desde aquí (G-1).
    return Padding(
      key: llave,
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        color: _resaltado == idVenta
            ? AppColores.naranja.withValues(alpha: 0.15)
            : null,
        onTap: () => _abrirDetalle(e),
        child: Opacity(
          opacity: (esReverso || yaReversada) ? 0.55 : 1,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icono,
                    color: esReverso
                        ? AppColores.error
                        : esCasa
                            ? AppColores.alerta
                            : null),
              ),
              const SizedBox(width: AppEspacio.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${e['cliente']}',
                        style: AppTexto.subtitulo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: AppEspacio.xs),
                    Wrap(
                      spacing: AppEspacio.sm,
                      runSpacing: AppEspacio.xs,
                      children: [
                        ChipEstado.semantico(
                          texto: tipoTxt,
                          significado: significadoTipo,
                          icono: icono,
                        ),
                        if (esReverso)
                          const ChipEstado.semantico(
                            texto: 'Reverso',
                            significado: SignificadoChip.error,
                            icono: Icons.undo_rounded,
                          ),
                        if (yaReversada && !esReverso)
                          const ChipEstado.semantico(
                            texto: 'Revertida',
                            significado: SignificadoChip.error,
                            icono: Icons.undo_rounded,
                          ),
                        if (esCasa)
                          const ChipEstado.semantico(
                            texto: 'Casa',
                            significado: SignificadoChip.alerta,
                            icono: Icons.star_rounded,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppEspacio.xs),
                    Text(
                      '${hora.isNotEmpty ? hora : '—'}'
                      '${metodo.isNotEmpty ? ' · $metodo' : ''}'
                      '$vendedor',
                      style: AppTexto.metadato,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              Text('${fmtMonto((e['monto'] as num).toDouble())} CUP',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: esReverso ? AppColores.error : null)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando historial…');
    }
    if (_errorCarga) {
      return EstadoError(
        titulo: 'No se pudo cargar el historial',
        detalle: 'Revisa la conexión o vuelve a intentarlo.',
        onReintentar: _cargar,
      );
    }
    final visibles = _visibles;
    final itemsHist = _itemsPorDia(visibles);
    final vendedores = _vendedores;
    return Column(
        children: [
          // 11/25: buscador por cliente, vendedor o tipo.
          // 1.34 (C-48 · G-03): el tipo y el vendedor se
          // PLIEGAN en el botón «Filtrar · …» de esta misma
          // fila (molde de Actividad).
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
              controller: _busquedaCtrl,
              onChanged: (v) => setState(() => _busqueda = v),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Buscar cliente, vendedor o tipo…',
                suffixIcon: _busqueda.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _busquedaCtrl.clear();
                          setState(() => _busqueda = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadio.md),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.md),
              ),
                  ),
                ),
                const SizedBox(width: AppEspacio.sm),
                Flexible(child: _botonFiltrosServicios(vendedores)),
              ],
            ),
          ),
          Expanded(
            // 1.23 B7+T7: cruce por tipo de estado en la zona de
            // resultados y vacío compartido (la carga sigue con
            // su Scaffold propio y la cabecera de filtros fija).
            child: CruceEstados(
              estado: visibles.isEmpty ? 'vacio' : 'contenido',
              child: visibles.isEmpty
                  ? EstadoVacio(
                      icono: Icons.history_rounded,
                      titulo: _entradas.isEmpty
                          ? 'Sin operaciones registradas.'
                          : _busqueda.isNotEmpty
                              ? 'Sin operaciones con esa búsqueda.'
                              : 'Sin operaciones con ese filtro.',
                      textoAccion:
                          _busqueda.isNotEmpty ? 'Limpiar búsqueda' : null,
                      onAccion: _busqueda.isNotEmpty
                          ? () {
                              _busquedaCtrl.clear();
                              setState(() => _busqueda = '');
                            }
                          : null,
                    )
                  : RefrescoIron(
                    onRefresh: _actualizarHistorial,
                    child: ListView.builder(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    itemCount: itemsHist.length + 1,
                    itemBuilder: (context, index) {
                      if (index == itemsHist.length) {
                        return Padding(
                          padding:
                              const EdgeInsets.only(top: AppEspacio.sm),
                          child: Text(
                            'Solo operaciones sincronizadas: una venta '
                            'offline aparece aquí cuando sincroniza.',
                            style: AppTexto.minuscula,
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      final it = itemsHist[index];
                      if (it is Map<String, dynamic> &&
                          it['encabezado'] == true) {
                        // 1.31 (Mejoras): día en palabras +
                        // totales del día visible.
                        return Padding(
                          padding: EdgeInsets.only(
                              top: index == 0 ? 0 : AppEspacio.md,
                              bottom: AppEspacio.sm),
                          child: Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Expanded(
                                child: Text(
                                    fechaLargaCorta('${it['dia']}'),
                                    style: AppTexto.subtitulo),
                              ),
                              Text(
                                '${it['ops']} operaciones · '
                                '${fmtMonto((it['importe'] as num).toDouble())} CUP',
                                style: AppTexto.metadato,
                              ),
                            ],
                          ),
                        );
                      }
                      return _filaEntrada(it as Map<String, dynamic>);
                    },
                  ),
                  ),
            ),
          ),
        ],
      );
  }
}

/// 1.34 (C-48 · G-03): etiqueta legible de cada tipo del
/// historial de servicios (las mismas palabras que llevaban
/// los chips: Todas / Dosis / Dosis con agua / Agua /
/// Salidas).
String etiquetaTipoHistorialServicio(String clave) => switch (clave) {
      'racion' => 'Dosis',
      'combo' => 'Dosis con agua',
      'agua' => 'Agua',
      'salida' => 'Salidas',
      _ => 'Todas',
    };

/// 1.34 (C-48 · G-03): hoja de filtros del Historial de
/// servicios: Tipo (radio de 5; 4 para el entrenador) y
/// Vendedor (solo dueño). Copia temporal con Aplicar/Limpiar.
class _HojaFiltrosServiciosHistorial extends StatefulWidget {
  final String tipo;
  final int? vendedor;
  final bool esDueno;
  final List<({int tid, String nombre})> vendedores;

  const _HojaFiltrosServiciosHistorial({
    required this.tipo,
    required this.vendedor,
    required this.esDueno,
    required this.vendedores,
  });

  @override
  State<_HojaFiltrosServiciosHistorial> createState() =>
      _HojaFiltrosServiciosHistorialState();
}

class _HojaFiltrosServiciosHistorialState
    extends State<_HojaFiltrosServiciosHistorial> {
  late String _tipo = widget.tipo;
  late int? _vendedor = widget.vendedor;

  @override
  Widget build(BuildContext context) {
    final tipos = <String>[
      'todas',
      'racion',
      'combo',
      'agua',
      if (widget.esDueno) 'salida',
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Filtros', style: AppTexto.subtitulo),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Cerrar',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            const Text('Tipo', style: AppTexto.etiqueta),
            RadioGroup<String>(
              groupValue: _tipo,
              onChanged: (v) => setState(() => _tipo = v ?? _tipo),
              child: Column(
                children: [
                  for (final t in tipos)
                    RadioListTile<String>(
                      value: t,
                      title: Text(etiquetaTipoHistorialServicio(t)),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            if (widget.esDueno && widget.vendedores.isNotEmpty) ...[
              const SizedBox(height: AppEspacio.md),
              const Text('Vendedor', style: AppTexto.etiqueta),
              const SizedBox(height: AppEspacio.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Todos'),
                    selected: _vendedor == null,
                    onSelected: (_) =>
                        setState(() => _vendedor = null),
                  ),
                  for (final v in widget.vendedores)
                    ChoiceChip(
                      label: Text(v.nombre),
                      selected: _vendedor == v.tid,
                      onSelected: (_) =>
                          setState(() => _vendedor = v.tid),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppEspacio.lg),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _tipo = 'todas';
                    _vendedor = null;
                  }),
                  child: const Text('Limpiar'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context)
                      .pop((tipo: _tipo, vendedor: _vendedor)),
                  child: const Text('Aplicar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Yunque 2.34 (F-7): resumen del botón de filtros del
/// Historial de servicios con gramática corta — el vendedor
/// entra por su primera palabra. PURO.
String resumenFiltrosServiciosTxt({
  required String tipo,
  required String? vendedor,
}) {
  final partes = <String>['Filtrar', tipo];
  if (vendedor != null) partes.add(primeraPalabraResumen(vendedor));
  return partes.join(' · ');
}
