import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart' show fmtMonto, fmtFecha;
import '../servicios.dart';
import 'app_bar.dart';
import 'diseno.dart';
import 'componentes.dart';

/// Historial completo de Servicios (pedido de Jc 2026-10-28):
/// todas las operaciones de venta de raciones, combos y agua, más
/// las salidas sin venta, en orden de nuevas a viejas, con filtros
/// por tipo y (solo dueño) por vendedor. Solo lectura: no vende,
/// no revierte, no cambia nada.
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
class ServiciosHistorialScreen extends StatefulWidget {
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
  State<ServiciosHistorialScreen> createState() =>
      _ServiciosHistorialScreenState();
}

class _ServiciosHistorialScreenState
    extends State<ServiciosHistorialScreen> {
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

  /// Respaldo de nombre por tid (menor Argón adenda): nombre que
  /// traía la venta (registrado_por_nombre) cuando el tid no está
  /// en widget.personas (p. ej. ventas viejas o del dueño).
  Map<int, String> _respaldoPorTid = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// 10/25: carga propia. El predicado de rol es el mismo que
  /// «Ventas de hoy» en Servicios (vendedor o pomo propio).
  Future<void> _cargar() async {
    final ventas = await LocalDb.instance.allMirror('servicio_ventas');
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
      _cargando = false;
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

  Widget _chip(String clave, String texto) {
    return Padding(
      padding: const EdgeInsets.only(right: AppEspacio.sm),
      child: ChoiceChip(
        label: Text(texto),
        selected: _filtroTipo == clave,
        onSelected: (_) => setState(() => _filtroTipo = clave),
      ),
    );
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
        duration: const Duration(milliseconds: 400), alignment: 0.5);
  }

  /// V23: aplana las entradas visibles intercalando el día
  /// ('aaaa-mm-dd') como encabezado de grupo.
  List<Object> _itemsPorDia(List<Map<String, dynamic>> visibles) {
    final items = <Object>[];
    String? diaActual;
    for (final e in visibles) {
      final f = '${e['fecha']}';
      final dia = f.length >= 10 ? f.substring(0, 10) : f;
      if (dia != diaActual) {
        diaActual = dia;
        items.add(dia);
      }
      items.add(e);
    }
    return items;
  }

  Widget _filaEntrada(Map<String, dynamic> e) {
    final esVenta = e['kind'] == 'venta';
    final esReverso = e['esReverso'] == true;
    final yaReversada = e['yaReversada'] == true;
    final esCasa = e['casa'] == true;
    final fecha = '${e['fecha']}';
    final fecha10 = fecha.length >= 10 ? fecha.substring(0, 10) : fecha;
    final hora = '${e['hora']}';
    if (!esVenta) {
      return Card(
        margin: const EdgeInsets.only(bottom: AppEspacio.sm),
        child: ListTile(
          leading: Icon(Icons.outbox_rounded,
              color: AppColores.textoSecundario(context)),
          title: const Text('Salida sin venta', style: AppTexto.cuerpo),
          subtitle: Text(
            '${e['tipo'] == 'agua' ? 'Agua' : 'Dosis'} ×${e['cantidad']}'
            ' · ${e['motivo']}'
            ' · $fecha10',
            style: AppTexto.secundario,
          ),
        ),
      );
    }
    final tipoTxt = switch ('${e['tipo']}') {
      'dosis_sin_agua' => 'Ración',
      'dosis_con_agua' => 'Combo',
      'agua_suelta' => 'Agua suelta ×${e['cantidad']}',
      _ => '${e['tipo']}',
    };
    final icono = esReverso
        ? Icons.undo_rounded
        : esCasa
            ? Icons.star_rounded
            : e['tipo'] == 'dosis_sin_agua'
                ? Icons.science_rounded
                : e['tipo'] == 'dosis_con_agua'
                    ? Icons.local_drink_rounded
                    : Icons.water_drop_rounded;
    final colorIcono = esReverso
        ? AppColores.error
        : esCasa
            ? AppColores.alerta
            : e['tipo'] == 'agua_suelta'
                ? AppColores.info
                : AppColores.naranja;
    final titulo = '$tipoTxt'
        '${esReverso ? ' · Reverso' : yaReversada ? ' · Reversada' : ''}'
        '${esCasa ? ' · Casa' : ''}';
    final vendedor = widget.esDueno
        ? ' · Vend: ${_nombreVendedor(_vendedorDe(e), '${e['registradoPor'] ?? ''}')}'
        : '';
    final idVenta = (e['id'] as num?)?.toInt() ?? 0;
    final llave = _llaves.putIfAbsent(idVenta, () => GlobalKey());
    return Card(
      key: llave,
      color: _resaltado == idVenta
          ? AppColores.naranja.withValues(alpha: 0.15)
          : null,
      margin: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: ListTile(
        leading: Icon(icono, color: colorIcono),
        title: Text(titulo, style: AppTexto.cuerpo),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${e['cliente']}', style: AppTexto.secundario),
            Text(
              '$fecha10${hora.isNotEmpty ? ' $hora' : ''}'
              '$vendedor'
              '${esCasa ? '' : (e['metodo'] as String).isNotEmpty ? ' · ${e['metodo']}' : ''}',
              style: AppTexto.metadato,
            ),
          ],
        ),
        trailing: Text('${fmtMonto((e['monto'] as num).toDouble())} CUP',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: esReverso ? AppColores.error : null)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return Scaffold(
        appBar: appBarIron(context, 'Historial de Servicios'),
        body: const EstadoCargando(texto: 'Cargando historial…'),
      );
    }
    final visibles = _visibles;
    final itemsHist = _itemsPorDia(visibles);
    final vendedores = _vendedores;
    return Scaffold(
      appBar: appBarIron(context, 'Historial de Servicios'),
      body: Column(
        children: [
          // 11/25: buscador por cliente, vendedor o tipo.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip('todas', 'Todas'),
                  _chip('racion', 'Raciones'),
                  _chip('combo', 'Combos'),
                  _chip('agua', 'Agua'),
                  if (widget.esDueno) _chip('salida', 'Salidas'),
                ],
              ),
            ),
          ),
          if (widget.esDueno && vendedores.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
              child: Row(
                children: [
                  const Text('Vendedor: ',
                      style: AppTexto.secundario),
                  Expanded(
                    child: DropdownButton<int?>(
                      isExpanded: true,
                      value: _filtroVendedor,
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Todos'),
                        ),
                        for (final tid in vendedores)
                          DropdownMenuItem<int?>(
                            value: tid,
                            child: Text(_nombreVendedor(
                                tid, _respaldoPorTid[tid])),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _filtroVendedor = v),
                    ),
                  ),
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
                  : ListView.builder(
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
                      if (it is String) {
                        return Padding(
                          padding: EdgeInsets.only(
                              top: index == 0 ? 0 : AppEspacio.sm,
                              bottom: AppEspacio.sm),
                          child: Text(fmtFecha(it),
                              style: AppTexto.subtitulo),
                        );
                      }
                      return _filaEntrada(it as Map<String, dynamic>);
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
