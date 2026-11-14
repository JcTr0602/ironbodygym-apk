// Historial de ventas de suplementos.
//
// - Dueño: ve todas las ventas (quién vendió qué, cuándo, a cuánto).
// - Entrenador (v1.2.1, `soloMias: true`): ve solo SU propio historial.
// Las ventas con precio diferente al oficial se destacan en ámbar.
// Totales separados por moneda (CUP y USD no se mezclan).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../negocio.dart';
import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../cliente_protegido.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';
import '../app_log.dart';

/// Totales del historial excluyendo ventas de clientes protegidos
/// (Argón #9, ALTO). La tarjeta ya oculta fecha y total de la venta
/// protegida, pero _totales() sumaba todas las filas: con pocas
/// ventas, el total superior revelaba el monto oculto. Para el dueño
/// (esDueno: true) no se excluye nada. El conteo de ventas no se
/// toca (no revela montos). PURO.
({double cup, double usd}) totalesHistorialVentas(
    List<Map<String, dynamic>> ventas,
    Map<int, Map<String, dynamic>> clientesPorId, {
    bool esDueno = false,
  }) {
  var cup = 0.0;
  var usd = 0.0;
  for (final v in ventas) {
    final cidVenta = (v['cliente_id'] as num?)?.toInt() ??
        (v['fiado_cliente_id'] as num?)?.toInt();
    final clienteVenta =
        cidVenta != null ? clientesPorId[cidVenta] : null;
    if (clienteVenta != null &&
        esVistaProtegida(clienteVenta, esDueno: esDueno)) {
      continue;
    }
    final precio = (v['precio'] as num?)?.toDouble() ?? 0;
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final total =
        (v['total'] as num?)?.toDouble() ?? precio * cant;
    // D2-09: moneda normalizada (LocalDb.monedaDe).
    if (LocalDb.monedaDe(v) == 'USD') {
      usd += total;
    } else {
      cup += total;
    }
  }
  return (cup: cup, usd: usd);
}

/// Autoauditoría 1.22 #2 (D2-10): encola la anulación de una
/// venta UNA sola vez. Dentro de una transacción re-verifica
/// que no exista ya una op viva `anular_venta_suplemento` para
/// la misma venta; devuelve false si ya la había (nada escrito).
Future<bool> encolarAnulacionVenta(int ventaId) async {
  final db = LocalDb.instance;
  final conn = await db.db;
  return conn.transaction((txn) async {
    final vivas = await txn.query('ops_queue',
        columns: ['payload'],
        where: "tipo = 'anular_venta_suplemento' "
            "AND estado NOT IN ('aplicada', 'rechazada')");
    for (final o in vivas) {
      try {
        final p =
            jsonDecode(o['payload'] as String) as Map<String, dynamic>;
        if ((p['venta_id'] as num?)?.toInt() == ventaId) return false;
      } catch (_) {}
    }
    await db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'anular_venta_suplemento',
      payload: {'venta_id': ventaId},
      txn: txn,
    );
    return true;
  });
}

/// Filtro del historial de ventas (PURO): texto (producto, comprador o
/// vendedor, sin distinguir mayúsculas), producto, moneda y rango de
/// fechas. La moneda ausente cuenta como CUP, igual que en
/// totalesHistorialVentas. No toca visibilidad de protegidos: eso lo
/// siguen resolviendo la tarjeta y los totales.
List<Map<String, dynamic>> filtrarVentasHistorial({
  required List<Map<String, dynamic>> ventas,
  required Map<int, Map<String, dynamic>> productos,
  String texto = '',
  int? productoId,
  String? moneda,
  String? desde,
  String? hasta,
}) {
  final t = texto.trim().toLowerCase();
  return ventas.where((v) {
    if (productoId != null &&
        (v['suplemento_id'] as num?)?.toInt() != productoId) {
      return false;
    }
    if (moneda == 'USD') {
      if ((v['moneda'] as String?) != 'USD') return false;
    } else if (moneda == 'CUP') {
      if ((v['moneda'] as String?) == 'USD') return false;
    }
    final f = '${v['fecha'] ?? ''}';
    if (f.length >= 10) {
      final dia = f.substring(0, 10);
      if (desde != null && dia.compareTo(desde) < 0) return false;
      if (hasta != null && dia.compareTo(hasta) > 0) return false;
    } else if (desde != null || hasta != null) {
      return false;
    }
    if (t.isNotEmpty) {
      final prodId = (v['suplemento_id'] as num?)?.toInt();
      final nombreProd =
          '${productos[prodId]?['nombre'] ?? 'Producto $prodId'}'
              .toLowerCase();
      final comprador = '${v['comprador_nombre'] ?? ''}'.toLowerCase();
      final vendedor =
          '${v['registrado_por_nombre'] ?? v['registrado_por'] ?? ''}'
              .toLowerCase();
      if (!nombreProd.contains(t) &&
          !comprador.contains(t) &&
          !vendedor.contains(t)) {
        return false;
      }
    }
    return true;
  }).toList();
}

class HistorialVentasScreen extends StatefulWidget {
  /// v1.2.1: si es true, filtra solo las ventas del entrenador actual.
  final bool soloMias;

  /// 4/25: venta que resaltar y desplazar a la vista al abrir (llegada
  /// desde el Extracto). Null = comportamiento normal.
  final int? resaltarId;

  const HistorialVentasScreen(
      {super.key, this.soloMias = false, this.resaltarId});

  @override
  State<HistorialVentasScreen> createState() =>
      _HistorialVentasScreenState();
}

class _HistorialVentasScreenState
    extends State<HistorialVentasScreen> {
  List<Map<String, dynamic>> _ventas = [];
  Map<int, Map<String, dynamic>> _productos = {};
  // Rediseño 1.20 (D5): ventas con la anulación aún en cola
  // (la fila sigue en el espejo hasta que el servidor aplica
  // el DELETE); se deriva de ops_queue, sin flags nuevos.
  Set<int> _anuladasPendientes = {};
  // Cliente protegido (2026-10-26, A5): mapa para resolver el
  // candado del comprador en cada fila (el espejo ya lo trae).
  Map<int, Map<String, dynamic>> _clientes = {};
  bool _cargando = true;
  // Resaltado (4/25): id + llave por fila para desplazar a la venta.
  int? _resaltado;
  final _llaves = <int, GlobalKey>{};
  // FIN-18 de Argón (1.20): ListView.builder no construye las
  // filas fuera de pantalla; para saltar a una venta lejana se
  // usa el controller con una posición estimada y luego el
  // ensureVisible fino. _posResaltado = índice en la lista de
  // ítems (con encabezados de día) registrado al construir.
  final _scrollCtrl = ScrollController();
  int _posResaltado = -1;
  // Filtros (3/25): texto, producto, moneda y rango de fechas.
  final _textoCtrl = TextEditingController();
  String _texto = '';
  int? _productoId;
  String? _moneda;
  String? _desde;
  String? _hasta;

  @override
  void dispose() {
    _textoCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // D-10 (1.21): filtrado e ítems agrupados MEMOIZADOS — antes
  // el getter re-filtraba todo en cada acceso (2× por build y
  // por tecla) y _cuerpo re-agrupaba y ESCRIBÍA _posResaltado
  // durante el build. Se recalcula solo al cambiar datos o
  // filtros, vía _refiltrar().
  List<Map<String, dynamic>> _filtradasCache = [];
  List<Object> _itemsCache = [];

  List<Map<String, dynamic>> get _ventasFiltradas => _filtradasCache;

  void _refiltrar() {
    _filtradasCache = filtrarVentasHistorial(
      ventas: _ventas,
      productos: _productos,
      texto: _texto,
      productoId: _productoId,
      moneda: _moneda,
      desde: _desde,
      hasta: _hasta,
    );
    final items = <Object>[];
    String? diaActual;
    _posResaltado = -1;
    for (final v in _filtradasCache) {
      final f = '${v['fecha'] ?? ''}';
      final dia = f.length >= 10 ? f.substring(0, 10) : f;
      if (dia != diaActual) {
        diaActual = dia;
        items.add(dia);
      }
      if ((v['id'] as num?)?.toInt() == widget.resaltarId) {
        _posResaltado = items.length;
      }
      items.add(v);
    }
    _itemsCache = items;
  }

  bool get _hayFiltros =>
      _texto.isNotEmpty ||
      _productoId != null ||
      _moneda != null ||
      _desde != null ||
      _hasta != null;

  void _limpiarFiltros() {
    _textoCtrl.clear();
    setState(() {
      _texto = '';
      _productoId = null;
      _moneda = null;
      _desde = null;
      _hasta = null;
      _refiltrar();
    });
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

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
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final todas =
        await LocalDb.instance.allMirror('ventas_suplementos');
    // v1.2.1: el entrenador solo ve su propio historial.
    // Fix auditoría Gemini: fallar cerrado — si tid es null, lista vacía.
    final tid = AuthService().telegramId;
    final ventas = widget.soloMias
        ? (tid != null
            ? todas
                .where((v) => (v['registrado_por'] as num?)?.toInt() == tid)
                .toList()
            : <Map<String, dynamic>>[])
        : todas;
    final prods =
        await LocalDb.instance.allMirror('suplementos');
    final mapa = <int, Map<String, dynamic>>{};
    for (final p in prods) {
      final id = (p['id'] as num?)?.toInt();
      if (id != null) mapa[id] = p;
    }
    // Cliente protegido (2026-10-26, A5): solo la marca, para el
    // candado de la fila. El entrenador ya ve estos nombres en
    // listas; no se expone nada nuevo.
    final todosClientes =
        await LocalDb.instance.allMirror('clientes');
    final mapaClientes = <int, Map<String, dynamic>>{};
    for (final c in todosClientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) mapaClientes[id] = c;
    }
    ventas.sort((a, b) =>
        '${b['fecha'] ?? ''}'.compareTo('${a['fecha'] ?? ''}'));
    final dbH = await LocalDb.instance.db;
    final opsAnul = await dbH.rawQuery(
        "SELECT payload FROM ops_queue "
        "WHERE tipo = 'anular_venta_suplemento' "
        "AND estado NOT IN ('aplicada', 'rechazada')");
    final anuladas = <int>{};
    for (final r in opsAnul) {
      try {
        final p =
            jsonDecode('${r['payload']}') as Map<String, dynamic>;
        final vid = (p['venta_id'] as num?)?.toInt();
        if (vid != null) anuladas.add(vid);
      } catch (_) {
        // Payload ilegible: no marca nada (la op seguirá su
        // curso en el sync; la marca es solo visual).
      }
    }
    if (!mounted) return;
    setState(() {
      _ventas = ventas;
      _productos = mapa;
      _anuladasPendientes = anuladas;
      _clientes = mapaClientes;
      _cargando = false;
      // D-17 (1.21): las llaves de resaltado se podan al
      // recargar (crecían con cada venta mostrada).
      _llaves.clear();
      _refiltrar();
    });
    if (widget.resaltarId != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _irAResaltado());
    }
  }

  /// Desplaza a la venta resaltada y la tiñe (4/25). Si no está en la
  /// lista (p. ej. otro entrenador con soloMias), no hace nada.
  /// FIN-18 de Argón (1.20): si la fila aún no está construida
  /// (ListView.builder perezoso), salta a su posición estimada
  /// y reintenta el ajuste fino en el siguiente frame.
  void _irAResaltado([int intentos = 0]) {
    final id = widget.resaltarId;
    if (id == null || !mounted) return;
    final ctx = _llaves[id]?.currentContext;
    if (ctx == null) {
      if (intentos < 3 &&
          _posResaltado >= 0 &&
          _scrollCtrl.hasClients) {
        final destino = _posResaltado * 116.0;
        final maximo = _scrollCtrl.position.maxScrollExtent;
        _scrollCtrl.jumpTo(destino > maximo ? maximo : destino);
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => _irAResaltado(intentos + 1));
      }
      return;
    }
    setState(() => _resaltado = id);
    Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 400), alignment: 0.5);
  }

  Future<void> _anular(Map<String, dynamic> v) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Anular venta',
      icono: Icons.undo_rounded,
      peligro: true,
      mensaje: 'Se anulará esta venta y se restaurará el stock. '
          '¿Continuar?',
      aceptar: 'Anular venta',
    );
    if (!ok) return;
    // Autoauditoría 1.22 #2 (D2-10): re-chequeo DENTRO de la
    // función (antes solo el botón se ocultaba): un doble toque
    // o una lista sin refrescar encolaba DOS anulaciones de la
    // misma venta.
    final encolada =
        await encolarAnulacionVenta((v['id'] as num).toInt());
    if (!mounted) return;
    if (!encolada) {
      mostrarSnack(context,
          'Esta venta ya tiene una anulación pendiente de sincronizar',
          significado: SignificadoChip.alerta);
      _cargar();
      return;
    }
    unawaited(SyncEngine.instance.push());
    if (mounted) {
      mostrarSnack(context, 'Venta anulada (se sincronizará)', significado: SignificadoChip.exito);
      _cargar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(
        context,
        widget.soloMias ? 'Mis ventas' : 'Ventas de suplementos',
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          _filtros(),
          _totales(),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _totales() {
    // Argón #9 (ALTO): los totales excluían nada y revelaban el
    // monto de ventas protegidas que la tarjeta oculta con candado.
    final t = totalesHistorialVentas(_ventasFiltradas, _clientes,
        esDueno: AuthService().isOwner);
    final cup = t.cup;
    final usd = t.usd;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.md),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment.spaceAround,
          children: [
            _totalCol('Total CUP', '${cup.toStringAsFixed(0)} CUP'),
            _totalCol('Total USD',
                '${usd.toStringAsFixed(2)} USD'),
            _totalCol('Ventas', '${_ventasFiltradas.length}'),
          ],
        ),
      ),
    );
  }

  Widget _totalCol(String etiqueta, String valor) {
    return Column(
      children: [
        Text(valor, style: AppTexto.subtitulo),
        Text(etiqueta, style: AppTexto.secundario),
      ],
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando ventas…');
    }
    if (_ventas.isEmpty) {
      return const EstadoVacio(
        icono: Icons.receipt_long_rounded,
        titulo: 'Sin ventas registradas',
        subtitulo:
            'Las ventas de suplementos aparecerán aquí.',
      );
    }
    final filtradas = _ventasFiltradas;
    if (filtradas.isEmpty) {
      return EstadoVacio(
        icono: Icons.search_off_rounded,
        titulo: 'Sin ventas con esos filtros',
        subtitulo: 'Prueba con otro texto, producto o fecha.',
        textoAccion: _hayFiltros ? 'Limpiar filtros' : null,
        onAccion: _hayFiltros ? _limpiarFiltros : null,
      );
    }
    // V23: la lista se agrupa por día con encabezados claros;
    // cada tarjeta ya lee en tres niveles (producto → total →
    // fecha · vendedor → comprador). La agrupación y la
    // posición del resaltado vienen de la caché de _refiltrar()
    // (D-10: nada de computar ni escribir estado en build).
    final items = _itemsCache;
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.all(AppEspacio.md),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final it = items[i];
          if (it is String) {
            return Padding(
              padding: EdgeInsets.only(
                  top: i == 0 ? 0 : AppEspacio.sm,
                  bottom: AppEspacio.sm),
              child: Text(fmtFecha(it), style: AppTexto.subtitulo),
            );
          }
          return _fila(it as Map<String, dynamic>);
        },
      ),
    );
  }

  /// Controles de filtro. 3/25: buscador, producto, moneda y
  /// rango en tres filas permanentes. 1.34 (C-48 · G-02):
  /// PLEGADO — el buscador queda y lo demás vive en la hoja
  /// tras el botón «Filtrar · …» que nombra lo activo (molde
  /// de Actividad). Los totales de arriba ya reflejan lo
  /// filtrado.
  Widget _filtros() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
            controller: _textoCtrl,
            onChanged: (v) => setState(() {
                          _texto = v;
                          _refiltrar();
                        }),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'Buscar producto, cliente o vendedor…',
              suffixIcon: _texto.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _textoCtrl.clear();
                        setState(() {
                          _texto = '';
                          _refiltrar();
                        });
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
          Flexible(child: _botonFiltrosVentas()),
        ],
      ),
    );
  }

  String _resumenFiltrosVentas() {
    final partes = <String>['Filtrar'];
    if (_productoId != null) {
      partes.add('${_productos[_productoId]?['nombre'] ?? 'Producto'}');
    } else {
      partes.add('Todos los productos');
    }
    if (_moneda != null) partes.add(_moneda!);
    final rango = _resumenRangoVentas(_desde, _hasta);
    if (rango != null) partes.add(rango);
    return partes.join(' · ');
  }

  Widget _botonFiltrosVentas() {
    return OutlinedButton.icon(
      icon: const Icon(Icons.filter_list_rounded, size: 16),
      label: Text(_resumenFiltrosVentas(),
          style: AppTexto.metadato,
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.lg),
        ),
      ),
      onPressed: _abrirFiltrosVentas,
    );
  }

  Future<void> _abrirFiltrosVentas() async {
    final productos = _productos.values.toList()
      ..sort((a, b) =>
          '${a['nombre'] ?? ''}'.compareTo('${b['nombre'] ?? ''}'));
    final r = await showModalBottomSheet<
        ({
          int? productoId,
          String? moneda,
          String? desde,
          String? hasta
        })>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadio.xl)),
      ),
      builder: (ctx) => _HojaFiltrosVentas(
        productos: productos,
        productoId: _productoId,
        moneda: _moneda,
        desde: _desde,
        hasta: _hasta,
      ),
    );
    if (r == null || !mounted) return;
    setState(() {
      _productoId = r.productoId;
      _moneda = r.moneda;
      _desde = r.desde;
      _hasta = r.hasta;
      _refiltrar();
    });
  }


  Widget _fila(Map<String, dynamic> v) {    final prodId = (v['suplemento_id'] as num?)?.toInt();
    final prod = prodId != null ? _productos[prodId] : null;
    final nombreProd =
        '${prod?['nombre'] ?? 'Producto $prodId'}';
    final precio = (v['precio'] as num?)?.toDouble() ?? 0;
    final oficial =
        (prod?['precio_oficial'] as num?)?.toDouble();
    final difiere = oficial != null &&
        (precio - oficial).abs() > 0.009;
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final moneda = '${v['moneda'] ?? 'CUP'}';
    final tasa = (v['usd_tasa'] as num?)?.toDouble();
    final total =
        (v['total'] as num?)?.toDouble() ?? precio * cant;
    final vendedor =
        '${v['registrado_por_nombre'] ?? v['registrado_por'] ?? '?'}';
    final comprador = '${v['comprador_nombre'] ?? '?'}';
    // Cliente protegido (2026-10-26, A5): candado junto al nombre
    // del comprador. Anular ya es solo dueño (v1.2.1), así que no
    // hay botón que ocultar en la fila.
    final cidVenta = (v['cliente_id'] as num?)?.toInt() ??
        (v['fiado_cliente_id'] as num?)?.toInt();
    final clienteVenta =
        cidVenta != null ? _clientes[cidVenta] : null;
    final ventaProtegida =
        clienteVenta != null && esVistaProtegida(clienteVenta);
    final fecha = '${v['fecha'] ?? ''}'.length >= 10
        ? '${v['fecha']}'.substring(0, 10)
        : '${v['fecha'] ?? ''}';
    final conPromo = (v['promo_mes'] as int?) == 1;
    final viaInscripcion =
        (v['via_inscripcion'] as num?)?.toInt() == 1;
    // v1.2.1: nota opcional de la venta (ej: "apartado").
    final nota = '${v['nota'] ?? ''}'.trim();

    // v1.2.4: misma regla en todas las pantallas (negocio.textoTotalVenta).
    final lineaTotal = '$cant x ${precio.toStringAsFixed(2)} $moneda'
        '${tasa != null && tasa > 0 ? ' · tasa ${tasa.toStringAsFixed(2)}' : ''}'
        ' = ${textoTotalVenta(total, moneda, tasa)}';

    final idVenta = (v['id'] as num?)?.toInt() ?? 0;
    final llave = _llaves.putIfAbsent(idVenta, () => GlobalKey());
    return Padding(
      key: llave,
      padding:
          const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.md),
        color: _resaltado == idVenta
            ? AppColores.naranja.withValues(alpha: 0.15)
            : difiere
                ? AppColores.alerta.withValues(alpha: 0.08)
                : null,
        onTap: viaInscripcion ? () => _detalle(v) : null,
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(nombreProd,
                      style: AppTexto.subtitulo),
                ),
                if (viaInscripcion)
                  const ChipEstado(
                      texto: 'Inscripción + venta',
                      color: AppColores.naranja,
                      icono: Icons.person_add_rounded),
                if (difiere && !ventaProtegida)
                  const ChipEstado(
                      texto: 'Precio diferente',
                      color: AppColores.alerta,
                      icono: Icons.warning_amber_rounded),
                if ((v['es_fiado'] == 1 || v['es_fiado'] == true) &&
                    !ventaProtegida)
                  const ChipEstado.semantico(
                      texto: 'Fiado',
                      significado: SignificadoChip.alerta),
                // v1.2.1: anular es acción del dueño. Con la
                // anulación ya en cola el botón sobra.
                if (AuthService().isOwner &&
                    !_anuladasPendientes.contains(idVenta))
                  IconButton(
                    icon: const Icon(Icons.undo_rounded,
                        color: AppColores.error, size: 20),
                    tooltip: 'Anular venta',
                    onPressed: () => _anular(v),
                  ),
                // 13/25: recibo por WhatsApp (dueño; nunca en
                // ventas protegidas, cuyo total/fecha la lista
                // oculta a propósito).
                if (AuthService().isOwner && !ventaProtegida)
                  IconButton(
                    icon: Icon(Icons.receipt_long_rounded,
                        color: AppColores.textoSecundario(context), size: 20),
                    tooltip: 'Recibo por WhatsApp',
                    onPressed: () => _recibo(v),
                  ),
              ],
            ),
            if (_anuladasPendientes.contains(idVenta)) ...[
              const SizedBox(height: 4),
              const ChipEstado.semantico(
                  texto: 'Anulada · pendiente de sincronizar',
                  significado: SignificadoChip.error),
            ],
            const SizedBox(height: 4),
            // Cliente protegido (2026-10-26, Protegido 2 residual
            // #9): la tarjeta no muestra fecha ni total de la venta
            // (quedan producto + comprador + candado).
            if (!ventaProtegida)
              Text(
                lineaTotal,
                style: AppTexto.cuerpo
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            if (nota.isNotEmpty && !ventaProtegida)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(Icons.sticky_note_2_rounded,
                        size: 13,
                        color: AppColores.textoSecundario(context)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        nota,
                        style: AppTexto.secundario.copyWith(
                            fontStyle: FontStyle.italic),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    ventaProtegida
                        ? '$vendedor → $comprador'
                        : '$fecha · $vendedor → $comprador'
                            '${conPromo ? ' · +1 mes gratis' : ''}',
                    style: AppTexto.secundario,
                  ),
                ),
                if (ventaProtegida)
                  const Icon(Icons.lock_rounded,
                      size: 16, color: AppColores.naranja),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 13/25: recibo completo de la venta por WhatsApp (dueño):
  /// producto, cantidad, precio, total, método (si la fila lo
  /// trae; si no, la línea no sale, jamás se inventa), cliente,
  /// vendedor y fecha. El teléfono sale de la ficha si lo hay;
  /// si no, el dueño lo escribe (patrón de ficha.dart).
  Future<void> _recibo(Map<String, dynamic> v) async {
    final prodId = (v['suplemento_id'] as num?)?.toInt();
    final prod = prodId != null ? _productos[prodId] : null;
    final precio = (v['precio'] as num?)?.toDouble() ?? 0;
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final moneda = '${v['moneda'] ?? 'CUP'}';
    final total =
        (v['total'] as num?)?.toDouble() ?? precio * cant;
    final metodo = '${v['metodo'] ?? ''}'.trim();
    final texto = textoComprobanteCompra(
      nombreProducto: '${prod?['nombre'] ?? 'Producto $prodId'}',
      cantidad: cant,
      precio: precio,
      moneda: moneda,
      total: total,
      nombreComprador: '${v['comprador_nombre'] ?? '?'}',
      fechaIso: '${v['fecha'] ?? ''}',
      conPromo: (v['promo_mes'] as int?) == 1,
      esFiado: v['es_fiado'] == 1 || v['es_fiado'] == true,
      metodo: metodo.isEmpty ? null : metodo,
      vendedor:
          '${v['registrado_por_nombre'] ?? v['registrado_por'] ?? '?'}',
    );
    final cid = (v['cliente_id'] as num?)?.toInt() ??
        (v['fiado_cliente_id'] as num?)?.toInt();
    // 1.32 (D-6, familia teléfono efectivo): el recibo se
    // pre-rellena desde el teléfono EFECTIVO (movil primero),
    // no desde el `telefono` crudo (que en el migrado es el
    // carnet y nacía vacío, o un número viejo).
    final cliHist = cid != null ? _clientes[cid] : null;
    final waNum = cliHist != null ? telefonoEfectivoWa(cliHist) : '';
    // El campo guarda 8 dígitos (como el resto de la app); el 53
    // va solo al armar el wa.me (igual que en ficha.dart).
    if (!mounted) return;
    // 1.29 (Oleada 4, barrido): el diálogo vive en un
    // StatefulWidget dueño de su controlador
    // (_DialogoReciboWa), envío incluido. Antes el
    // controlador se disponía nada más cerrar el diálogo,
    // con la animación de salida aún reconstruyendo el
    // campo (defecto D-B1-08).
    await showDialog<void>(
      context: context,
      builder: (_) => _DialogoReciboWa(
        texto: texto,
        telefonoInicial: waNum.length == 10 ? waNum.substring(2) : '',
      ),
    );
  }

  /// Detalle expandido de una venta con inscripción: dos bloques,
  /// "Cliente" (del espejo local si ya sincronizó) y "Venta".
  Future<void> _detalle(Map<String, dynamic> v) async {
    // D-10 (1.21): el cliente sale del mapa ya cargado en el
    // estado; antes se releía el espejo entero por un id.
    final cid = (v['cliente_id'] as num?)?.toInt();
    final cliente = cid != null ? _clientes[cid] : null;
    final moneda = '${v['moneda'] ?? 'CUP'}';
    final esUsd = moneda == 'USD';
    final tasa = (v['usd_tasa'] as num?)?.toDouble();
    final precio = (v['precio'] as num?)?.toDouble() ?? 0;
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final total =
        (v['total'] as num?)?.toDouble() ?? precio * cant;
    final prodId = (v['suplemento_id'] as num?)?.toInt();
    final prod = prodId != null ? _productos[prodId] : null;
    final conPromo = (v['promo_mes'] as int?) == 1;
    if (!mounted) return;

    Widget fila(String e, String valor) => Padding(
          padding: const EdgeInsets.only(bottom: AppEspacio.xs),
          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 92,
                  child: Text(e,
                      style: AppTexto.secundario)),
              Expanded(
                  child: Text(valor,
                      style: AppTexto.cuerpo)),
            ],
          ),
        );

    await showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Inscripción + venta',
        iconoTitulo: Icons.person_add_rounded,
        contenido: SingleChildScrollView(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const EncabezadoSeccion(titulo: 'Cliente'),
              fila('Nombre',
                  '${v['comprador_nombre'] ?? cliente?['nombre'] ?? '?'}'),
              // Cliente protegido (2026-10-26, A5): el entrenador
              // NO ve teléfono, estado ni vencimiento del comprador
              // protegido; solo el nombre y el candado. El resto de
              // la venta (producto, precio) no es personal.
              if (cliente != null && esVistaProtegida(cliente))
                const Row(
                  children: [
                    Icon(Icons.lock_rounded,
                        size: 16, color: AppColores.naranja),
                    SizedBox(width: 4),
                    Expanded(
                      child: Text(bannerClienteProtegido,
                          style: AppTexto.secundario),
                    ),
                  ],
                )
              else if (cliente != null) ...[
                fila('Teléfono',
                    '${cliente['telefono'] ?? '—'}'),
                fila('Estado',
                    '${cliente['estado'] ?? '—'}'),
                fila('Vence',
                    '${cliente['pagado_hasta'] ?? '—'}'),
              ] else
                const Text(
                  'El perfil completo aparecerá al sincronizar.',
                  style: AppTexto.secundario,
                ),
              const EncabezadoSeccion(titulo: 'Venta'),
              fila('Producto',
                  '${prod?['nombre'] ?? 'Producto $prodId'}'),
              fila('Cantidad', '$cant'),
              fila('Precio',
                  '${precio.toStringAsFixed(2)} $moneda'),
              if (esUsd && tasa != null)
                fila('Tasa',
                    '${tasa.toStringAsFixed(2)} CUP/USD'),
              fila('Total', textoTotalVenta(total, moneda, tasa)),
              fila('Fecha', '${v['fecha'] ?? '—'}'),
              if (conPromo)
                fila('Promo', '1 mes gratis asignado'),
            ],
          ),
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
}

/// 1.29 (Oleada 4, barrido de diálogos): «Recibo por
/// WhatsApp» como StatefulWidget DUEÑO de su controlador,
/// dispuesto en dispose() — el patrón de la casa. El envío
/// (validar el móvil, armar el wa.me y abrirlo) vive dentro,
/// como antes.
class _DialogoReciboWa extends StatefulWidget {
  const _DialogoReciboWa({
    required this.texto,
    required this.telefonoInicial,
  });

  final String texto;
  final String telefonoInicial;

  @override
  State<_DialogoReciboWa> createState() => _DialogoReciboWaState();
}

class _DialogoReciboWaState extends State<_DialogoReciboWa> {
  late final TextEditingController _telCtrl;

  @override
  void initState() {
    super.initState();
    _telCtrl = TextEditingController(text: widget.telefonoInicial);
  }

  @override
  void dispose() {
    _telCtrl.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    final num = normalizarTelefonoWaMe(_telCtrl.text.trim());
    if (num.isEmpty) {
      mostrarSnack(context, 'Escribe un móvil válido',
          significado: SignificadoChip.alerta);
      return;
    }
    final url = Uri.parse(
        'https://wa.me/$num?text=${Uri.encodeComponent(widget.texto)}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo abrir WhatsApp',
            significado: SignificadoChip.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Recibo por WhatsApp',
      iconoTitulo: Icons.receipt_long_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.texto.replaceAll('*', '')),
            const SizedBox(height: 12),
            TextField(
              controller: _telCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Móvil del cliente',
                prefixText: '+53 ',
                hintText: '8 dígitos',
              ),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.send_rounded),
          label: const Text('Enviar por WhatsApp'),
          onPressed: _enviar,
        ),
      ],
    );
  }
}

/// 1.34 (C-48 · G-02): resumen compacto del rango de fechas
/// para la etiqueta del botón «Filtrar · …»: «1-30 nov» si
/// ambas fechas caen en el mismo mes; si no, las fechas
/// sueltas con fmtFecha. null si no hay rango.
String? _resumenRangoVentas(String? desde, String? hasta) {
  if (desde == null && hasta == null) return null;
  const meses = [
    'ene', 'feb', 'mar', 'abr', 'may', 'jun',
    'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
  ];
  if (desde != null && hasta != null) {
    final d = DateTime.tryParse(desde);
    final h = DateTime.tryParse(hasta);
    if (d != null && h != null && d.year == h.year && d.month == h.month) {
      return '${d.day}-${h.day} ${meses[d.month - 1]}';
    }
    return '${fmtFecha(desde)} – ${fmtFecha(hasta)}';
  }
  if (desde != null) return 'Desde ${fmtFecha(desde)}';
  return 'Hasta ${fmtFecha(hasta!)}';
}

/// 1.34 (C-48 · G-02): hoja de filtros del Historial de
/// ventas. Copia temporal: «Aplicar» devuelve el resultado
/// por el Navigator; «Limpiar» restaura la copia a «todo».
class _HojaFiltrosVentas extends StatefulWidget {
  final List<Map<String, dynamic>> productos;
  final int? productoId;
  final String? moneda;
  final String? desde;
  final String? hasta;

  const _HojaFiltrosVentas({
    required this.productos,
    required this.productoId,
    required this.moneda,
    required this.desde,
    required this.hasta,
  });

  @override
  State<_HojaFiltrosVentas> createState() => _HojaFiltrosVentasState();
}

class _HojaFiltrosVentasState extends State<_HojaFiltrosVentas> {
  late int? _productoId = widget.productoId;
  late String? _moneda = widget.moneda;
  late String? _desde = widget.desde;
  late String? _hasta = widget.hasta;

  Future<void> _elegirFecha({required bool esDesde}) async {
    final ahora = ahoraHabana();
    final inicial = esDesde ? _desde : _hasta;
    final elegida = await showDatePicker(
      context: context,
      initialDate: inicial != null
          ? DateTime.tryParse(inicial) ?? ahora
          : ahora,
      firstDate: DateTime(2020),
      lastDate: ahora,
    );
    if (elegida == null) return;
    final iso = '${elegida.year.toString().padLeft(4, '0')}-'
        '${elegida.month.toString().padLeft(2, '0')}-'
        '${elegida.day.toString().padLeft(2, '0')}';
    setState(() {
      if (esDesde) {
        _desde = iso;
      } else {
        _hasta = iso;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
            const Text('Producto', style: AppTexto.etiqueta),
            DropdownButton<int?>(
              value: _productoId,
              isExpanded: true,
              hint: const Text('Todos los productos'),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('Todos los productos'),
                ),
                for (final p in widget.productos)
                  DropdownMenuItem<int?>(
                    value: (p['id'] as num?)?.toInt(),
                    child: Text('${p['nombre'] ?? 'Producto'}'),
                  ),
              ],
              onChanged: (v) => setState(() => _productoId = v),
            ),
            const SizedBox(height: AppEspacio.md),
            const Text('Moneda', style: AppTexto.etiqueta),
            const SizedBox(height: AppEspacio.sm),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Ambas'),
                  selected: _moneda == null,
                  onSelected: (_) => setState(() => _moneda = null),
                ),
                ChoiceChip(
                  label: const Text('CUP'),
                  selected: _moneda == 'CUP',
                  onSelected: (_) => setState(() => _moneda = 'CUP'),
                ),
                ChoiceChip(
                  label: const Text('USD'),
                  selected: _moneda == 'USD',
                  onSelected: (_) => setState(() => _moneda = 'USD'),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.md),
            const Text('Fechas', style: AppTexto.etiqueta),
            const SizedBox(height: AppEspacio.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon:
                        const Icon(Icons.calendar_today_rounded, size: 16),
                    label: Text(
                        _desde == null ? 'Desde…' : 'Desde $_desde'),
                    onPressed: () => _elegirFecha(esDesde: true),
                  ),
                ),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    icon:
                        const Icon(Icons.calendar_today_rounded, size: 16),
                    label: Text(
                        _hasta == null ? 'Hasta…' : 'Hasta $_hasta'),
                    onPressed: () => _elegirFecha(esDesde: false),
                  ),
                ),
              ],
            ),
            if (_desde != null || _hasta != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() {
                    _desde = null;
                    _hasta = null;
                  }),
                  child: const Text('Limpiar fechas'),
                ),
              ),
            const SizedBox(height: AppEspacio.md),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _productoId = null;
                    _moneda = null;
                    _desde = null;
                    _hasta = null;
                  }),
                  child: const Text('Limpiar'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop((
                    productoId: _productoId,
                    moneda: _moneda,
                    desde: _desde,
                    hasta: _hasta,
                  )),
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
