// Catálogo de suplementos ("Inventario en Gimnasio").
//
// - Entrenador: catálogo de solo lectura + botón Vender por producto.
// - Dueño: además gestiona el catálogo (nuevo/editar/activar),
//   el interruptor de la promo "mes gratis" y el historial de ventas.
library;

import 'dart:async';

import '../etiqueta_producto.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../fotos.dart';
import '../permisos_entrenador.dart';
import '../fotos_cola.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'categorias_suplemento.dart';
import 'cuentas_por_cobrar.dart';
import 'detalle_suplemento.dart';
import 'diseno.dart';
import 'historial_ventas.dart';
import 'reservas.dart';
import 'servicios.dart';
import 'servicios_admin.dart';
import 'widgets.dart';

class SuplementosScreen extends StatefulWidget {
  const SuplementosScreen({super.key});

  @override
  State<SuplementosScreen> createState() => _SuplementosScreenState();
}

class _SuplementosScreenState extends State<SuplementosScreen> {
  final _auth = AuthService();
  List<Map<String, dynamic>> _items = [];
  bool _cargando = true;
  String _busqueda = '';
  final _busquedaCtrl = TextEditingController();
  bool _promoActiva = true;
  // v1.2.1: categorías
  List<Map<String, dynamic>> _categorias = [];
  int? _filtroCategoria; // null = todas
  // 14/25: disponibilidad: 'todos' | 'con_stock' | 'bajo' | 'agotado'.
  String _filtroStock = 'todos';
  // v1.2.1: tasa USD del día + ids de los más vendidos.
  double? _tasaUsd;
  List<int> _topIds = [];

  // SU2 (estéticas 1.19): vista del catálogo (cuadrícula/lista).
  bool _vistaLista = false;

  bool get _esDueno => _auth.isOwner;

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  // Reservas v2: solicitudes pendientes de respuesta (contador
  // del acceso a la bandeja).
  int _reservasSolicitadas = 0;

  bool get _puedeReservas =>
      _esDueno || PermisosEntrenador().canVenderSuplementos;

  Future<void> _cargarReservasPendientes() async {
    if (!_puedeReservas) return;
    final reservas = await LocalDb.instance.allMirror('reservas');
    if (!mounted) return;
    setState(() {
      _reservasSolicitadas =
          reservas.where((r) => r['estado'] == 'solicitada').length;
    });
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final items = await LocalDb.instance.allMirror('suplementos');
    final cats =
        await LocalDb.instance.allMirror('categorias_suplemento');
    final aj = await LocalDb.instance.getAjustes();
    // v1.2.1: top vendidos para la sección destacada.
    // D-04 (1.21): agregado en SQL, sin decodificar el espejo
    // entero de ventas solo para el top-4.
    final topIds =
        await LocalDb.instance.topVendidosSuplementos();
    if (!mounted) return;
    setState(() {
      // v1.2.2: entrenadores solo ven productos con stock > 0
      _items = items
          .where((s) {
            // FIN-24 de Argón (1.20): un suplemento ELIMINADO no
            // se muestra a nadie (antes el dueño lo veía como
            // «Inactivo», mezclado con los desactivados, sin
            // forma de reactivarlo desde aquí).
            if (s['eliminado'] == 1 || s['eliminado'] == true) {
              return false;
            }
            if (_esDueno) return true;
            final activo = (s['activo'] as int?) == 1;
            final stock = (s['stock'] as num?)?.toInt() ?? 0;
            return activo && stock > 0;
          })
          .toList();
      _categorias = cats
          .where((c) =>
              (c['activa'] as int?) != 0 || _esDueno)
          .toList()
        ..sort(compararPorNombre);
      _promoActiva = (aj['promo_suplementos'] as num?)?.toInt() != 0;
      _tasaUsd = (aj['tasa_usd'] as num?)?.toDouble();
      _topIds = topIds;
      _cargando = false;
    });
    await _cargarReservasPendientes();
  }

  /// v1.2.1: productos del top visibles (sin búsqueda ni filtro).
  List<Map<String, dynamic>> get _topProductos {
    if (_busqueda.isNotEmpty ||
        _filtroCategoria != null ||
        _filtroStock != 'todos' ||
        _topIds.isEmpty) {
      return [];
    }
    final mapa = <int, Map<String, dynamic>>{};
    for (final s in _items) {
      final id = (s['id'] as num?)?.toInt();
      if (id != null) mapa[id] = s;
    }
    return [
      for (final id in _topIds)
        if (mapa[id] != null) mapa[id]!
    ];
  }

  /// v1.2.1: nombre de la categoría por id.
  String _nombreCategoria(int? id) {
    if (id == null) return 'Sin categoría';
    for (final c in _categorias) {
      if ((c['id'] as int?) == id) {
        return '${c['nombre'] ?? 'Sin categoría'}';
      }
    }
    return 'Sin categoría';
  }

  List<Map<String, dynamic>> get _filtrados {
    var res = _items;
    // v1.2.1: filtro por categoría
    if (_filtroCategoria != null) {
      res = res
          .where((s) =>
              (s['categoria_id'] as int?) == _filtroCategoria)
          .toList();
    }
    if (_busqueda.isNotEmpty) {
      // Ítem 13 (Argón): el buscador filtra sobre la cadena compuesta
      // «Nombre · Categoría», no solo sobre el nombre.
      final cats = mapaCategoriasSuplemento(_categorias);
      res = res
          .where((s) => coincideBusquedaProducto(
              _busqueda,
              '${s['nombre'] ?? ''}',
              categoriaDeSuplemento(s, cats)))
          .toList();
    }
    // 14/25: filtro por disponibilidad.
    if (_filtroStock != 'todos') {
      res = res.where((s) => coincideFiltroStock(s, _filtroStock)).toList();
    }
    // v1.2.3: para el dueño, ordenar sin-stock al final
    if (_esDueno) {
      res = [...res]..sort((a, b) {
        final sa = (a['stock'] as num?)?.toInt() ?? 0;
        final sb = (b['stock'] as num?)?.toInt() ?? 0;
        final aSin = sa <= 0 ? 1 : 0;
        final bSin = sb <= 0 ? 1 : 0;
        if (aSin != bSin) return aSin - bSin;
        // v1.2.3: orden estable (sugerencia GPT-5.4-mini)
        // nombre, luego id como desempate final
        final cmpNombre = compararPorNombre(a, b);
        if (cmpNombre != 0) return cmpNombre;
        return (a['id'] as int? ?? 0).compareTo(b['id'] as int? ?? 0);
      });
    }
    return res;
  }

  Future<void> _togglePromo(bool v) async {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'ajuste',
      payload: {'clave': 'promo_suplementos', 'valor': v ? 1 : 0},
    );
    // Optimista: reflejar de inmediato en ajustes locales.
    final aj = await LocalDb.instance.getAjustes();
    aj['promo_suplementos'] = v ? 1 : 0;
    await LocalDb.instance.setAjustes(aj);
    unawaited(SyncEngine.instance.push());
    if (mounted) setState(() => _promoActiva = v);
  }

  /// v1.3.4: abre la venta con el flujo unificado (VentaSuplementoScreen +
  /// registrarVentaSuplemento). Esta pantalla NUNCA escribe SQL de venta.
  /// Rediseño 1.20 (D1): el botón «Vender» de la tarjeta
  /// abre la VENTA RÁPIDA (diálogo de 1 unidad); la venta
  /// completa vive en el detalle del producto.
  void _irVender(Map<String, dynamic> s) {
    ventaRapidaSuplemento(context, s, _tasaUsd).then((vendido) {
      // Sin recibo enganchado aquí (13/25): el historial ofrece
      // el recibo de cada venta; engancharlo duplicaría el
      // ofrecimiento tras cada venta.
      if (vendido) _cargar();
    });
  }

  /// v1.3.4 (B2): comparte el catálogo como texto para WhatsApp.
  /// Lee del JSON `data` (las columnas nombre/precio no existen en la
  /// tabla espejo). Filtro de negocio: solo stock > 0 y activos
  /// (no eliminados). Precio <= 0 → "Consultar precio", jamás $0.00.
  /// Orden determinista: categoría, luego nombre.
  Future<void> _compartirCatalogo() async {
    final items = await LocalDb.instance.allMirror('suplementos');
    final visibles = items.where((s) {
      final stock = (s['stock'] as num?)?.toInt() ?? 0;
      if (stock <= 0) return false;
      final activo = s['activo'];
      if (activo == false || activo == 0) return false;
      final eliminado = s['eliminado'];
      if (eliminado == 1 || eliminado == true) return false;
      return true;
    }).toList();
    visibles.sort((a, b) {
      final cmpCat = _nombreCategoria(a['categoria_id'] as int?)
          .compareTo(_nombreCategoria(b['categoria_id'] as int?));
      if (cmpCat != 0) return cmpCat;
      return '${a['nombre'] ?? ''}'.compareTo('${b['nombre'] ?? ''}');
    });
    if (visibles.isEmpty) {
      if (mounted) {
        mostrarSnack(context, 'No hay productos activos con stock',
            significado: SignificadoChip.alerta);
      }
      return;
    }
    // v1.3.7 (pedido de Jc 2026-10-17): catálogo profesional para
    // WhatsApp — sin stock (el cliente no necesita verlo), con
    // descripción del producto; compacto y con formato.
    final buf = StringBuffer('🏋️ *Iron Body Gym — Suplementos*');
    for (final s in visibles) {
      final nombre = '${s['nombre'] ?? 'Suplemento'}';
      final precio = (s['precio_oficial'] as num?)?.toDouble() ??
          (s['precio'] as num?)?.toDouble() ??
          0;
      final desc = '${s['descripcion'] ?? ''}'.trim();
      buf.writeln('\n');
      buf.writeln('*$nombre*');
      if (desc.isNotEmpty) buf.writeln(desc);
      // B2 (Argón): jamás exportar "$0.00" a clientes.
      // v1.4.6: la moneda es la del propio suplemento (puede
      // ser CUP desde el formulario), no «USD» fijo.
      // Ronda 3-9 #8: en USD, equivalente CUP redondeado a
      // decenas (precioOficialEn) cuando hay tasa.
      final moneda = LocalDb.monedaDe(s);
      final cup = moneda == 'USD'
          ? precioOficialEn('CUP', precio, _tasaUsd)
          : null;
      buf.writeln(precio > 0
          ? '💰 ${precio.toStringAsFixed(2)} $moneda'
              '${cup != null ? ' (≈ ${cup.toStringAsFixed(0)} CUP)' : ''}'
          : '💰 Consultar precio');
    }
    await Share.share(buf.toString().trimRight());
  }
  /// v1.2.1: ficha del producto al tocar la tarjeta.
  void _irDetalle(Map<String, dynamic> s) {
    Navigator.push<bool>(
      context,
      RutaIron(
        builder: (_) => DetalleSuplementoScreen(
          suplemento: s,
          categoriaNombre:
              _nombreCategoria(s['categoria_id'] as int?),
          tasaUsd: _tasaUsd,
        ),
      ),
    ).then((v) {
      if (v == true) _cargar();
    });
  }

  void _irEditar(Map<String, dynamic>? s) {
    Navigator.push(
      context,
      RutaIron(
        builder: (_) => EditarSuplementoScreen(suplemento: s),
      ),
    ).then((_) => _cargar());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(
        context,
        'Suplementos',
        acciones: [
          // v1.3.4 (C5): "+ Nuevo" compacto en la cabecera (solo dueño).
          // Ni FAB (tapaba el botón Vender) ni tarjeta en el grid.
          if (_esDueno)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
              child: FilledButton.tonalIcon(
                onPressed: () => _irEditar(null),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Nuevo'),
              ),
            ),
          // v1.3.4 (B2): compartir el catálogo como texto (WhatsApp).
          IconButton(
            icon: const Icon(Icons.share_rounded),
            tooltip: 'Compartir catálogo',
            onPressed: _compartirCatalogo,
          ),
          // Reservas v2: bandeja de reservas de los clientes,
          // con contador de solicitudes sin responder.
          if (_puedeReservas)
            IconButton(
              icon: Badge(
                isLabelVisible: _reservasSolicitadas > 0,
                label: Text('$_reservasSolicitadas'),
                child: const Icon(Icons.bookmark_border_rounded),
              ),
              tooltip: 'Reservas',
              onPressed: () async {
                await Navigator.push(
                  context,
                  RutaIron(
                      builder: (_) => const ReservasScreen()),
                );
                if (mounted) _cargar();
              },
            ),
          // v1.3.7 (Fase B §6.2): fiados por cobrar (fiados).
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_rounded),
            tooltip: 'Fiados por cobrar',
            onPressed: () => Navigator.push(
              context,
              RutaIron(
                  builder: (_) =>
                      const CuentasPorCobrarScreen()),
            ),
          ),
          // Rediseño 1.20: Historial, Categorías y Servicios
          // se agrupan en el menú ⋮ (antes iconos sueltos y una
          // tarjeta grande en el cuerpo).
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'Más opciones',
            onSelected: (v) async {
              if (v == 'historial') {
                await Navigator.push(
                  context,
                  RutaIron(
                      builder: (_) => HistorialVentasScreen(
                          soloMias: !_esDueno)),
                );
              } else if (v == 'categorias') {
                await Navigator.push(
                  context,
                  RutaIron(
                      builder: (_) =>
                          const CategoriasSuplementoScreen()),
                );
                if (mounted) _cargar();
              } else if (v == 'admin_servicios') {
                // 1.23 (backlog de campo): la administración de
                // dosis y botes (precios, comisión, pomos, agua)
                // también se alcanza desde la sección, sin tener
                // que entrar primero a vender un servicio.
                await Navigator.push(
                  context,
                  RutaIron(
                      builder: (_) =>
                          const ServiciosAdminScreen()),
                );
                if (mounted) _cargar();
              } else if (v == 'servicios') {
                await Navigator.push(
                  context,
                  RutaIron(
                      builder: (_) => const ServiciosScreen()),
                );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'historial',
                child: Row(
                  children: [
                    Icon(
                        _esDueno
                            ? Icons.receipt_long_rounded
                            : Icons.history_rounded,
                        size: 20),
                    const SizedBox(width: AppEspacio.sm),
                    Text(_esDueno
                        ? 'Historial de ventas'
                        : 'Mis ventas'),
                  ],
                ),
              ),
              if (_esDueno)
                const PopupMenuItem(
                  value: 'categorias',
                  child: Row(
                    children: [
                      Icon(Icons.category_rounded, size: 20),
                      SizedBox(width: AppEspacio.sm),
                      Text('Categorías'),
                    ],
                  ),
                ),
              // 1.23 (backlog de campo): administración completa
              // de las dosis a mano desde la sección (solo dueño;
              // la pantalla además se protege sola).
              if (_esDueno)
                const PopupMenuItem(
                  value: 'admin_servicios',
                  child: Row(
                    children: [
                      Icon(Icons.settings_rounded, size: 20),
                      SizedBox(width: AppEspacio.sm),
                      Text('Administrar dosis y botes'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'servicios',
                child: Row(
                  children: [
                    Icon(Icons.bolt_rounded, size: 20),
                    SizedBox(width: AppEspacio.sm),
                    Text('Servicios ⚡ por dosis'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true, alcance: 'suplementos'),
          // v1.2.1: la promo la ven todos (el interruptor solo
          // el dueño). Rediseño 1.20: banda compacta; Servicios
          // vive ahora en el menú ⋮ del app bar.
          _tarjetaPromo(),
          Padding(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: CampoTexto(
              controller: _busquedaCtrl,
              hint: 'Buscar suplemento…',
              icono: Icons.search_rounded,
              onChanged: (v) =>
                  setState(() => _busqueda = v.trim()),
            ),
          ),
          // v1.2.1: filtro por categoría (visible si hay categorías).
          if (_categorias.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.md),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Todas',
                        style: AppTexto.etiqueta),
                    selected: _filtroCategoria == null,
                    onSelected: (_) => setState(
                        () => _filtroCategoria = null),
                  ),
                  const SizedBox(width: 8),
                  for (final c in _categorias) ...[
                    ChoiceChip(
                      label: Text('${c['nombre']}',
                          style: AppTexto.etiqueta),
                      selected: _filtroCategoria ==
                          (c['id'] as int?),
                      onSelected: (_) => setState(() =>
                          _filtroCategoria =
                              c['id'] as int?),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          // 14/25: filtro por disponibilidad.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.md, 0, AppEspacio.md, 0),
            child: Row(
              children: [
                for (final f in const [
                  ('todos', 'Todos'),
                  ('con_stock', 'Con stock'),
                  ('bajo', 'Stock bajo'),
                  ('agotado', 'Agotados'),
                ]) ...[
                  ChoiceChip(
                    label: Text(f.$2,
                        style: AppTexto.etiqueta),
                    selected: _filtroStock == f.$1,
                    onSelected: (_) =>
                        setState(() => _filtroStock = f.$1),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _tarjetaPromo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
      child: Tarjeta(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.xs),
        child: Row(
          children: [
            Icon(Icons.card_giftcard_rounded,
                size: 20,
                color: AppColores.textoSecundario(context)),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: Text(
                  _promoActiva
                      ? 'Promo activa · 1 mes gratis por compra'
                      : 'Promo inactiva',
                  style: AppTexto.secundario),
            ),
            Switch(
              value: _promoActiva,
              activeThumbColor: AppColores.naranja,
              // v1.2.1: solo el dueño la activa/desactiva.
              onChanged: _esDueno ? _togglePromo : null,
            ),
          ],
        ),
      ),
    );
  }

  /// v1.3.4 (C5): vista ÚNICA de catálogo — Grid 2 columnas.
  /// NOTA: el spec pedía childAspectRatio 0.72, pero con foto
  /// AspectRatio(1.1) la mitad inferior queda en ~76-88px en pantallas de
  /// 360-412dp y el contenido del spec (nombre 2 líneas + precio grande +
  /// botón ancho completo, ~107-116px) desborda. 0.60 preserva todos los
  /// elementos del spec sin overflow.
  Widget _cuerpo() {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando suplementos…');
    }
    final items = _filtrados;
    if (items.isEmpty) {
      // 14/25: con filtros activos, el vacío ofrece limpiarlos
      // (búsqueda, categoría y stock) en vez del alta.
      final hayFiltros = _busqueda.isNotEmpty ||
          _filtroCategoria != null ||
          _filtroStock != 'todos';
      return EstadoVacio(
        icono: Icons.medication_rounded,
        titulo: 'Sin suplementos',
        subtitulo: hayFiltros
            ? 'Ningún producto coincide con esos filtros.'
            : _esDueno
                ? 'Agrega el primero para empezar el catálogo.'
                : 'Aún no hay productos en el inventario.',
        textoAccion: hayFiltros
            ? 'Limpiar filtros'
            : _esDueno
                ? '+ Crear primer suplemento'
                : null,
        onAccion: hayFiltros
            ? () {
                _busquedaCtrl.clear();
                setState(() {
                  _busqueda = '';
                  _filtroCategoria = null;
                  _filtroStock = 'todos';
                });
              }
            : _esDueno
                ? () => _irEditar(null)
                : null,
      );
    }
    // v1.2.1: sección destacada con los más vendidos (solo si hay ventas).
    final top = _topProductos;
    final hayFiltros = _busqueda.isNotEmpty ||
        _filtroCategoria != null ||
        _filtroStock != 'todos';
    return Column(
      children: [
        if (top.isNotEmpty) _seccionTop(top),
        // SU2 (estéticas 1.19): interruptor cuadrícula/lista.
        // Rediseño 1.20: contador de resultados a la izquierda.
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.md, 0, AppEspacio.md, AppEspacio.sm),
          child: Row(
            children: [
              Text(
                hayFiltros
                    ? '${items.length} de ${_items.length} suplementos'
                    : '${items.length} suplemento'
                        '${items.length == 1 ? '' : 's'}',
                style: AppTexto.metadato,
              ),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.grid_view_rounded, size: 18),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.view_list_rounded, size: 18),
                  ),
                ],
                selected: {_vistaLista},
                onSelectionChanged: (s) =>
                    setState(() => _vistaLista = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _cargar,
            child: _vistaLista
                ? ListView.builder(
                    padding: const EdgeInsets.all(AppEspacio.md),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) => Padding(
                      padding:
                          const EdgeInsets.only(bottom: AppEspacio.sm),
                      child: _FilaSuplemento(
                        key: ValueKey(items[i]['id']),
                        sup: items[i],
                        onVender: () => _irVender(items[i]),
                        onTap: () => _irDetalle(items[i]),
                        tasaUsd: _tasaUsd,
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(AppEspacio.md),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      // SU1: el BotonPrimario (52 px de alto) es
                      // más alto que el ElevatedButton anterior;
                      // 0.52 da aire a nombre + precio + botón.
                      childAspectRatio: 0.52,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) => _TarjetaSuplemento(
                      key: ValueKey(items[i]['id']),
                      sup: items[i],
                      onVender: () => _irVender(items[i]),
                      onTap: () => _irDetalle(items[i]),
                      tasaUsd: _tasaUsd,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// v1.2.1: carrusel horizontal con los productos más vendidos.
  Widget _seccionTop(List<Map<String, dynamic>> top) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(
              AppEspacio.md, AppEspacio.sm, AppEspacio.md, 4),
          child:
              EncabezadoSeccion(titulo: 'Más vendidos'),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.md),
          child: Row(
            children: [
              for (final s in top)
                Padding(
                  padding: const EdgeInsets.only(right: AppEspacio.sm),
                  child: _miniTop(s),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _miniTop(Map<String, dynamic> s) {
    final precio =
        (s['precio_oficial'] as num?)?.toDouble() ?? 0;
    return SizedBox(
      width: 148,
      child: Tarjeta(
        onTap: () => _irDetalle(s),
        padding: const EdgeInsets.all(AppEspacio.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // D-11 (1.21): la foto del mini-top vive en un
            // StatefulWidget con el futuro en su State (patrón
            // de _FotoSuplemento): nada de existsSync ni de
            // futuros creados en build.
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadio.md),
              child: _FotoMiniTop(sup: s),
            ),
            const SizedBox(height: 4),
            Text('${s['nombre'] ?? 'Sin nombre'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTexto.cuerpo),
            // Ronda 3-9 #8: en USD, equivalente CUP redondeado.
            Builder(builder: (_) {
              final moneda = LocalDb.monedaDe(s);
              final cup = moneda == 'USD'
                  ? precioOficialEn('CUP', precio, _tasaUsd)
                  : null;
              return Text(
                  '${precio.toStringAsFixed(2)} $moneda'
                  '${cup != null ? ' (≈ ${cup.toStringAsFixed(0)} CUP)' : ''}',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.naranja,
                      fontWeight: FontWeight.bold));
            }),
          ],
        ),
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// v1.3.4 (C5): tarjeta de catálogo — vista única de suplementos.
// ---------------------------------------------------------------------------

/// Tarjeta de catálogo (spec Argón):
/// - Mitad superior: foto AspectRatio(1.1), bordes superiores 12px,
///   BoxFit.cover, con triestado de carga (ver _FotoSuplemento).
/// - Badge de stock flotante (sup. derecha): chip negro + punto semántico.
/// SU2 (estéticas 1.19): fila compacta de la vista lista —
/// foto pequeña + nombre + precio + Vender en una fila.
class _FilaSuplemento extends StatelessWidget {
  final Map<String, dynamic> sup;
  final VoidCallback onVender;
  final VoidCallback onTap;
  final double? tasaUsd;

  const _FilaSuplemento({
    super.key,
    required this.sup,
    required this.onVender,
    required this.onTap,
    this.tasaUsd,
  });

  @override
  Widget build(BuildContext context) {
    final nombre = '${sup['nombre'] ?? 'Sin nombre'}';
    final stock = (sup['stock'] as num?)?.toInt() ?? 0;
    final precio = (sup['precio_oficial'] as num?)?.toDouble() ??
        (sup['precio'] as num?)?.toDouble() ??
        0;
    final act = sup['activo'];
    final inactivo = act == 0 ||
        act == false ||
        sup['eliminado'] == 1 ||
        sup['eliminado'] == true;
    final hayStock = stock > 0 && !inactivo;
    final moneda = LocalDb.monedaDe(sup);
    final cup = moneda == 'USD'
        ? precioOficialEn('CUP', precio, tasaUsd)
        : null;
    final presentacion = textoPresentacion(sup);
    final estado = estadoStockSuplemento(sup);
    return Opacity(
      opacity: hayStock ? 1.0 : 0.55,
      child: Tarjeta(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.sm),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadio.sm),
                child: _FotoSuplemento(sup: sup),
              ),
            ),
            const SizedBox(width: AppEspacio.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nombre,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTexto.secundario
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${precio.toStringAsFixed(2)} $moneda'
                    '${cup != null ? ' (≈ ${cup.toStringAsFixed(0)} CUP)' : ''}',
                    style: AppTexto.subtitulo.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppColores.naranja,
                    ),
                  ),
                  if (presentacion.isNotEmpty)
                    Text(
                      presentacion,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTexto.minuscula.copyWith(
                        color: AppColores.textoSecundario(context),
                      ),
                    ),
                  if (estado != EstadoStockSuplemento.disponible)
                    Text(
                      textoEstadoStock(sup),
                      style: AppTexto.minuscula.copyWith(
                        fontWeight: FontWeight.w600,
                        color: switch (estado) {
                          EstadoStockSuplemento.inactivo =>
                            AppColores.textoSecundario(context),
                          EstadoStockSuplemento.agotado =>
                            AppColores.error,
                          EstadoStockSuplemento.bajo =>
                            AppColores.alerta,
                          EstadoStockSuplemento.disponible =>
                            AppColores.exito,
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppEspacio.sm),
            BotonPrimario(
              texto: hayStock
                  ? 'Vender'
                  : inactivo
                      ? 'Inactivo'
                      : 'Sin stock',
              onPressed: hayStock ? onVender : null,
              expandido: false,
            ),
          ],
        ),
      ),
    );
  }
}

/// - Mitad inferior: nombre (2 líneas), precio oficial grande, botón Vender.
/// - Elevación 2, borde 1px (white10 oscuro / black12 claro).
class _TarjetaSuplemento extends StatelessWidget {
  final Map<String, dynamic> sup;
  final VoidCallback onVender;
  final VoidCallback onTap;
  // Ronda 3-9 #8: tasa para el equivalente CUP en USD.
  final double? tasaUsd;

  const _TarjetaSuplemento({
    super.key,
    required this.sup,
    required this.onVender,
    required this.onTap,
    this.tasaUsd,
  });

  @override
  Widget build(BuildContext context) {
    final nombre = '${sup['nombre'] ?? 'Sin nombre'}';
    final stock = (sup['stock'] as num?)?.toInt() ?? 0;
    // B3 (Argón): el precio mostrado es SIEMPRE precio_oficial
    // (fallback legacy a `precio`); ultimo_precio no se usa.
    final precio = (sup['precio_oficial'] as num?)?.toDouble() ??
        (sup['precio'] as num?)?.toDouble() ??
        0;
    // Lógica tolerante (igual que _compartirCatalogo): 'activo' puede
    // venir como int, bool o faltar (null) sin romper ni marcar
    // falso "Agotado".
    final act = sup['activo'];
    final inactivo = act == 0 ||
        act == false ||
        sup['eliminado'] == 1 ||
        sup['eliminado'] == true;
    final hayStock = stock > 0 && !inactivo;
    final oscuro = Theme.of(context).brightness == Brightness.dark;

    return Opacity(
      // SU3 (estéticas 1.19): sin stock la tarjeta se atenúa para
      // distinguirse al pasar la vista (antes solo el botón
      // cambiaba a «Agotado» y la tarjeta se veía igual).
      opacity: hayStock ? 1.0 : 0.55,
      child: Card(
        elevation: 2,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.md),
          side: BorderSide(
            color: oscuro ? Colors.white10 : Colors.black12,
            width: 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 1.1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _FotoSuplemento(sup: sup),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _BadgeStock(sup: sup),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppEspacio.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nombre,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTexto.secundario.copyWith(
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    // Ronda 3-9 #8: en USD, equivalente CUP
                    // redondeado a decenas (precioOficialEn).
                    Builder(builder: (_) {
                      final moneda = LocalDb.monedaDe(sup);
                      final cup = moneda == 'USD'
                          ? precioOficialEn('CUP', precio, tasaUsd)
                          : null;
                      return Text(
                        '${precio.toStringAsFixed(2)} $moneda'
                        '${cup != null ? ' (≈ ${cup.toStringAsFixed(0)} CUP)' : ''}',
                        style: AppTexto.subtitulo.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColores.naranja,
                        ),
                      );
                    }),
                    Builder(builder: (ctx) {
                      final pres = textoPresentacion(sup);
                      if (pres.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Text(
                        pres,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTexto.minuscula.copyWith(
                          color: AppColores.textoSecundario(ctx),
                        ),
                      );
                    }),
                    Builder(builder: (ctx) {
                      final estado = estadoStockSuplemento(sup);
                      if (estado ==
                          EstadoStockSuplemento.disponible) {
                        return const SizedBox.shrink();
                      }
                      return Text(
                        textoEstadoStock(sup),
                        style: AppTexto.minuscula.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          color: switch (estado) {
                            EstadoStockSuplemento.inactivo =>
                              AppColores.textoSecundario(ctx),
                            EstadoStockSuplemento.agotado =>
                              AppColores.error,
                            EstadoStockSuplemento.bajo =>
                              AppColores.alerta,
                            EstadoStockSuplemento.disponible =>
                              AppColores.exito,
                          },
                        ),
                      );
                    }),
                    const Spacer(),
                    // SU1 (estéticas 1.19): botón de venta con el
                    // estilo primario del sistema; en «Agotado»
                    // queda deshabilitado con su gris del tema.
                    BotonPrimario(
                      texto: hayStock
                          ? 'Vender'
                          : inactivo
                              ? 'Inactivo'
                              : 'Sin stock',
                      onPressed: hayStock ? onVender : null,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// Foto con triestado estricto (condición C4/B4 de Argón):
/// 1. `foto_local` existe → directa, sin red.
/// 2. `foto_storage` en caché (`enCache`) → directa, sin red.
/// 3. Si no: shimmer sutil mientras `obtener()` descarga;
///    null (fallo de red/offline) → placeholder elegante SIN cachear
///    el fallo (se reintenta en el próximo render).
/// 4. Sin `foto_local` ni `foto_storage` → placeholder directo, sin red.
/// D-11 (1.21): foto del mini-top de Suplementos con el futuro
/// en el State (mismo patrón que _FotoSuplemento): la local
/// recién tomada manda; si no, caché/descarga de la remota.
/// Antes _miniTop hacía existsSync() y creaba el futuro de
/// FotoCache DENTRO del build (parpadeo y E/S en el hilo de UI).
class _FotoMiniTop extends StatefulWidget {
  final Map<String, dynamic> sup;
  const _FotoMiniTop({required this.sup});

  @override
  State<_FotoMiniTop> createState() => _FotoMiniTopState();
}

class _FotoMiniTopState extends State<_FotoMiniTop> {
  late Future<File?> _futura;

  @override
  void initState() {
    super.initState();
    _futura = _resolver();
  }

  @override
  void didUpdateWidget(covariant _FotoMiniTop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sup['id'] != widget.sup['id'] ||
        oldWidget.sup['foto_local'] != widget.sup['foto_local'] ||
        oldWidget.sup['foto_storage'] != widget.sup['foto_storage']) {
      _futura = _resolver();
    }
  }

  // Fuente única compartida con el detalle (fotos.dart):
  // mismo archivo en ambos extremos del Hero.
  Future<File?> _resolver() => resolverFotoSuplemento(widget.sup);

  Widget _sinFoto(BuildContext context) => Container(
        height: 64,
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColores.fondo(context),
          borderRadius: BorderRadius.circular(AppRadio.md),
        ),
        child: Icon(Icons.medication_rounded,
            color: AppColores.textoSecundario(context)),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        final f = snap.data;
        if (f == null) return _sinFoto(ctx);
        // T2 (Bloque 2): la foto vuela al detalle. La
        // decodificación va acotada por ancho a 1080 con
        // providerFotoAcotada en AMBOS extremos: el
        // ImageProvider es el mismo (no parpadea) y no
        // deforma (hotfix de campo).
        return Hero(
          tag: tagHeroSuplemento(widget.sup['id']),
          flightShuttleBuilder: shuttleHeroFoto,
          child: Image(
              image: providerFotoAcotada(FileImage(f),
                  ancho: 1080),
              height: 64,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _sinFoto(ctx)),
        );
      },
    );
  }
}

class _FotoSuplemento extends StatefulWidget {
  final Map<String, dynamic> sup;
  const _FotoSuplemento({required this.sup});

  @override
  State<_FotoSuplemento> createState() => _FotoSuplementoState();
}

class _FotoSuplementoState extends State<_FotoSuplemento> {
  late Future<File?> _futura;

  @override
  void initState() {
    super.initState();
    _futura = _resolver();
  }

  /// Si el widget se recicla para otro suplemento (filtro, búsqueda,
  /// sync), re-resolver la foto en vez de conservar la anterior.
  @override
  void didUpdateWidget(covariant _FotoSuplemento oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sup['id'] != widget.sup['id'] ||
        oldWidget.sup['foto_local'] != widget.sup['foto_local'] ||
        oldWidget.sup['foto_storage'] != widget.sup['foto_storage']) {
      _futura = _resolver();
    }
  }

  // Fuente única compartida con el detalle (fotos.dart).
  // (Antes consultaba enCache antes que obtener: obtener
  // ya devuelve el archivo de caché si está, sin red.)
  Future<File?> _resolver() => resolverFotoSuplemento(widget.sup);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _ShimmerFoto();
        }
        final f = snap.data;
        if (f != null) {
          return Image.file(
            f,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _PlaceholderFoto(),
          );
        }
        return const _PlaceholderFoto();
      },
    );
  }
}

/// Placeholder elegante: gradiente carbón/gris acero + ícono vectorial
/// a baja opacidad. Cero letras gigantes (decisión Jc).
class _PlaceholderFoto extends StatelessWidget {
  const _PlaceholderFoto();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B3138), Color(0xFF14171B)],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.fitness_center_rounded,
          size: 46,
          color: Color(0x40FFFFFF),
        ),
      ),
    );
  }
}

/// Shimmer sutil para el estado "cargando / descargando" del triestado.
class _ShimmerFoto extends StatefulWidget {
  const _ShimmerFoto();

  @override
  State<_ShimmerFoto> createState() => _ShimmerFotoState();
}

class _ShimmerFotoState extends State<_ShimmerFoto>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 0.95).animate(_c),
      child: const _PlaceholderFoto(),
    );
  }
}

/// Badge de stock flotante: chip negro translúcido + punto semántico
/// (verde > 5, ámbar 1–5, rojo agotado) + "Stock: X".
class _BadgeStock extends StatelessWidget {
  final Map<String, dynamic> sup;
  const _BadgeStock({required this.sup});

  @override
  Widget build(BuildContext context) {
    // Rediseño 1.20: el badge consume la regla ÚNICA de stock
    // (umbral_stock del producto; antes un umbral fijo de 5) y
    // lleva siempre el texto del estado.
    final Color punto = switch (estadoStockSuplemento(sup)) {
      EstadoStockSuplemento.agotado => AppColores.error,
      EstadoStockSuplemento.bajo => AppColores.alerta,
      EstadoStockSuplemento.disponible => AppColores.exito,
      EstadoStockSuplemento.inactivo => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: punto,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            textoEstadoStock(sup),
            style: AppTexto.minuscula.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// Crear / editar suplemento (solo dueño)
// ---------------------------------------------------------------------------

class EditarSuplementoScreen extends StatefulWidget {
  final Map<String, dynamic>? suplemento;

  /// F12 (1.20): plantilla para DUPLICAR — el editor abre en
  /// modo CREAR con los campos llenos desde otro suplemento,
  /// pero sin su id (el payload es crear_suplemento) y sin
  /// heredar su foto.
  final Map<String, dynamic>? plantilla;
  const EditarSuplementoScreen(
      {super.key, this.suplemento, this.plantilla});

  @override
  State<EditarSuplementoScreen> createState() =>
      _EditarSuplementoScreenState();
}

class _EditarSuplementoScreenState
    extends State<EditarSuplementoScreen> {
  final _nombre = TextEditingController();
  final _desc = TextEditingController();
  final _precio = TextEditingController();
  final _stock = TextEditingController();
  // v1.3.7 (Fase B §6.2): costo (solo dueño) y umbral de stock bajo.
  final _costo = TextEditingController();
  final _umbral = TextEditingController();
  // v1.4.3: presentación del envase (contenido + unidad + servicios)
  // — lo que el cliente ve en su catálogo («300 g · 60 servicios»).
  final _pesoValor = TextEditingController();
  final _servicios = TextEditingController();
  String? _pesoUnidad;

  // Presentación tal como venía al abrir la ficha (para mandar las
  // claves al servidor SOLO si cambió; ver _guardar).
  double? _presPesoIni;
  String? _presUnidadIni;
  int? _presServiciosIni;
  static const _unidadesEnvase = [
    'g', 'kg', 'ml', 'L', 'cápsulas', 'tabletas', 'unidades',
  ];
  bool _activo = true;
  bool _guardando = false;
  // v1.4.6: moneda del precio oficial ('CUP'|'USD'). _monedaIni
  // conserva la que traía el suplemento al abrir, para avisar si
  // el dueño la cambia al editar.
  String _moneda = 'CUP';
  String _monedaIni = 'CUP';
  Uint8List? _fotoNueva;
  // v1.2.1 fix auditoría Gemini: ruta local de la foto para el
  // mecanismo de fotos pendientes (no se pierde offline).
  String? _fotoNuevaPath;
  // v1.2.1: categoría del suplemento.
  List<Map<String, dynamic>> _categorias = [];
  int? _categoriaId;

  bool get _editando => widget.suplemento != null;
  bool get _duplicando =>
      widget.suplemento == null && widget.plantilla != null;

  /// Número del espejo sin decimales inútiles (300.0 → «300»).
  static String _fmtNum(dynamic v) {
    final n = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
  }

  @override
  void initState() {
    super.initState();
    // F12: en duplicar, los campos se llenan desde la
    // plantilla pero el modo sigue siendo CREAR (sin id, sin
    // foto y sin trackers de "valor inicial": la presentación
    // viaja siempre al crear).
    final s = widget.suplemento ?? widget.plantilla;
    if (s != null) {
      _nombre.text = '${s['nombre'] ?? ''}';
      _desc.text = '${s['descripcion'] ?? ''}';
      _precio.text = '${s['precio_oficial'] ?? ''}';
      _stock.text = '${s['stock'] ?? 0}';
      _costo.text = '${s['costo'] ?? ''}';
      _umbral.text = '${s['umbral_stock'] ?? 3}';
      if (s['peso_valor'] != null) _pesoValor.text = _fmtNum(s['peso_valor']);
      if (s['servicios_estandar'] != null) {
        _servicios.text = _fmtNum(s['servicios_estandar']);
      }
      final unidad = s['peso_unidad']?.toString().trim();
      _pesoUnidad = (unidad != null && unidad.isNotEmpty) ? unidad : null;
      if (widget.suplemento != null) {
        _presPesoIni = (s['peso_valor'] as num?)?.toDouble();
        _presUnidadIni = _pesoUnidad;
        final servIni = (s['servicios_estandar'] as num?)?.toDouble();
        _presServiciosIni =
            (servIni != null && servIni == servIni.roundToDouble())
                ? servIni.toInt()
                : null;
      }
      _activo = (s['activo'] as int?) == 1;
      _categoriaId = s['categoria_id'] as int?;
      // v1.4.6: moneda actual del suplemento (fallback 'CUP').
      _moneda = LocalDb.monedaDe(s);
      _monedaIni = _moneda;
    } else {
      _umbral.text = '3';
    }
    _cargarCategorias();
  }

  Future<void> _cargarCategorias() async {
    final cats =
        await LocalDb.instance.allMirror('categorias_suplemento');
    if (!mounted) return;
    setState(() {
      _categorias = cats
          .where((c) => (c['activa'] as int?) != 0)
          .toList()
        ..sort(compararPorNombre);
      // Fix auditoría Gemini: si el suplemento en edición tiene asignada
      // una categoría inactiva, incluirla en el dropdown (marcada) para
      // que DropdownButtonFormField no crashee por valor sin item.
      if (_categoriaId != null &&
          !_categorias.any((c) => (c['id'] as int?) == _categoriaId)) {
        final inactivas = cats
            .where((c) => (c['id'] as int?) == _categoriaId)
            .toList();
        if (inactivas.isNotEmpty) _categorias.add(inactivas.first);
      }
    });
  }

  @override
  void dispose() {
    _nombre.dispose();
    _desc.dispose();
    _precio.dispose();
    _stock.dispose();
    _pesoValor.dispose();
    _servicios.dispose();
    // Argón #9 (BAJO): _costo y _umbral también se liberan.
    _costo.dispose();
    _umbral.dispose();
    super.dispose();
  }

  Future<void> _elegirFoto() async {
    final img = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 75); // Gemini: compresión obligatoria para Cuba
    if (img == null || !mounted) return;
    final bytes = await img.readAsBytes();
    if (mounted) {
      setState(() {
        _fotoNueva = bytes;
        _fotoNuevaPath = img.path;
      });
    }
  }

  Future<void> _guardar() async {
    // Ronda 3-9 #10: editar el catálogo es solo del dueño (la UI
    // ya oculta el botón; esto frena un cambio de sesión a mitad).
    if (!AuthService().isOwner) return;
    final nombre = _nombre.text.trim();
    final precio = double.tryParse(
        _precio.text.trim().replaceAll(',', '.'));
    final stock =
        int.tryParse(_stock.text.trim()) ?? 0;
    if (nombre.isEmpty || precio == null || !precio.isFinite || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa los datos',
          mensaje:
              'El nombre y un precio oficial mayor que 0 son obligatorios.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    // Autoauditoría 1.22 #2 (D2-07): el stock tecleado viajaba
    // sin validar signo: «-5» se guardaba como stock -5 (y un
    // texto no numérico se convertía en 0 en silencio, borrando
    // el stock real al editar). Misma doctrina estricta de la
    // presentación (v1.4.3): campo no vacío no interpretable =
    // error, nunca traducción silenciosa.
    final stockTxt = _stock.text.trim();
    final stockParse = int.tryParse(stockTxt);
    if ((stockTxt.isNotEmpty && stockParse == null) ||
        (stockParse != null && stockParse < 0)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el stock',
          mensaje:
              'El stock debe ser un número entero de 0 en adelante.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    // v1.4.3: presentación del envase, con validación ESTRICTA
    // (panel de código 2026-10-21): un campo NO vacío que no se
    // puede interpretar es un ERROR y no se guarda — jamás se
    // traduce a «limpiar el dato» (antes, escribir «abc» mandaba
    // '' y el servidor borraba el dato bueno). Servicios solo
    // acepta enteros: nada de redondear «60.5» a 61 en silencio.
    final pesoTxt = _pesoValor.text.trim().replaceAll(',', '.');
    double? pesoValor;
    if (pesoTxt.isNotEmpty) {
      pesoValor = double.tryParse(pesoTxt);
      if (pesoValor == null ||
          !pesoValor.isFinite ||
          pesoValor <= 0 ||
          pesoValor > 100000) {
        await DialogoApp.confirmar(context,
            titulo: 'Revisa la presentación',
            mensaje:
                'El contenido del envase debe ser un número mayor que 0 (ej. 300), o el campo vacío.',
            aceptar: 'Entendido',
            cancelar: '');
        return;
      }
    }
    final serviciosTxt = _servicios.text.trim();
    int? servicios;
    if (serviciosTxt.isNotEmpty) {
      servicios = int.tryParse(serviciosTxt);
      if (servicios == null || servicios <= 0 || servicios > 100000) {
        await DialogoApp.confirmar(context,
            titulo: 'Revisa la presentación',
            mensaje:
                'Los servicios por envase deben ser un número entero mayor que 0 (ej. 60), o el campo vacío.',
            aceptar: 'Entendido',
            cancelar: '');
        return;
      }
    }
    // La presentación va en pareja (cantidad + unidad); si falta
    // una, el servidor rechazaría la op entera.
    if ((pesoValor != null) != (_pesoUnidad != null)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa la presentación',
          mensaje:
              'El contenido del envase necesita cantidad y unidad juntas (ej. 300 + g), o ambos vacíos.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    setState(() => _guardando = true);
    try {
      // v1.3.7 (Fase B §6.2): costo (solo dueño) y umbral de stock.
      // Autoauditoría 1.22 #2 (D2-07): el costo sigue la MISMA
      // doctrina estricta de la presentación (v1.4.3): un texto
      // NO vacío que no se puede interpretar (o no es finito, o
      // es negativo) es un ERROR y no se guarda — jamás se
      // traduce en silencio a «sin costo», porque al editar eso
      // significaba perder el costo bueno sin darse cuenta.
      final costoTxt = _costo.text.trim().replaceAll(',', '.');
      double? costo;
      if (costoTxt.isNotEmpty) {
        costo = double.tryParse(costoTxt);
        if (costo == null || !costo.isFinite || costo < 0) {
          await DialogoApp.confirmar(context,
              titulo: 'Revisa el costo',
              mensaje:
                  'El costo debe ser un número de 0 en adelante, o el campo vacío.',
              aceptar: 'Entendido',
              cancelar: '');
          return;
        }
      }
      final umbral =
          int.tryParse(_umbral.text.trim()) ?? 3;
      final payload = {
        'nombre': nombre,
        'descripcion': _desc.text.trim(),
        'precio_oficial': precio,
        // v1.4.6: moneda del precio oficial; viaja siempre en la
        // op (crear y editar) para que el servidor la persista.
        'moneda': _moneda,
        'stock': stock,
        'activo': _activo ? 1 : 0,
        // v1.2.1: categoría asignada.
        if (_categoriaId != null) 'categoria_id': _categoriaId,
        if (_editando) 'suplemento_id': widget.suplemento!['id'],
        // v1.3.7: costo solo lo envía el dueño (el campo UI ya lo
        // restringe); umbral siempre.
        if (AuthService().isOwner && costo != null && costo >= 0)
          'costo': costo,
        'umbral_stock': umbral < 0 ? 3 : umbral,
        // v1.4.3: presentación del envase. Al CREAR se manda
        // siempre; al EDITAR solo si cambió respecto a lo que
        // traía la ficha (vacío = limpiar el dato). Si no cambió,
        // la op no lleva las claves y el servidor conserva el
        // dato: así un espejo local atrasado no pisa una
        // presentación más nueva al editar otro campo (panel
        // 2026-10-21). El servidor también conserva el dato si
        // la op no trae las claves (apps viejas).
        if (!_editando ||
            pesoValor != _presPesoIni ||
            _pesoUnidad != _presUnidadIni ||
            servicios != _presServiciosIni) ...{
          'peso_valor': pesoValor ?? '',
          'peso_unidad': _pesoUnidad ?? '',
          'servicios_estandar': servicios ?? '',
        },
      };
      // v1.2.1 fix auditoría Gemini: el uuid de creación se genera aquí
      // para ligar la foto pendiente a la op (así no se pierde offline).
      final crearOpUuid = const Uuid().v4();
      if (_editando) {
        await LocalDb.instance.queueOp(
          opUuid: const Uuid().v4(),
          tipo: 'editar_suplemento',
          payload: payload,
        );
      } else {
        await LocalDb.instance.queueOp(
          opUuid: crearOpUuid,
          tipo: 'crear_suplemento',
          payload: payload,
        );
      }
      // Fix auditoría Gemini: la foto NUNCA se pierde. Se guarda como
      // pendiente ligada al op_uuid; SyncEngine la sube en el próximo
      // ciclo de sync, cuando el puente ya aplicó la op y devolvió el
      // suplemento_id en el resultado. Al editar, el id ya se conoce.
      if (_fotoNuevaPath != null) {
        final fotoOpUuid = _editando ? const Uuid().v4() : crearOpUuid;
        // v1.2.9: usar la cola persistente (no fotos_pendientes).
        // v1.2.9+40 (Gemini): extracción tolerante del ID + bloqueo si null.
        // No se permite encolar con suplementoId null al editar (crearía
        // fila huérfana invisible para reencolarFotos).
        final rawId =
            widget.suplemento?['id'] ?? widget.suplemento?['suplemento_id'];
        final sid = _editando
            ? (rawId is int
                ? rawId
                : int.tryParse(rawId?.toString() ?? ''))
            : null;
        if (_editando && sid == null) {
          throw StateError(
              'No se puede encolar foto: _editando=true pero suplemento no tiene ID válido: ${widget.suplemento}');
        }
        await FotosColaService.instance.encolarFoto(
          opUuid: fotoOpUuid,
          suplementoId: sid,
          rutaOriginal: _fotoNuevaPath!,
        );
        // Foto encolada: aviso limpio al usuario.
        if (mounted) {
          mostrarSnack(
              context, 'Foto guardada. Se subirá al sincronizar.',
              significado: SignificadoChip.exito);
        }
      }
      unawaited(SyncEngine.instance.push());
      // v1.4.6: si el dueño cambió la moneda de un suplemento
      // existente, aviso breve (sin bloquear): el cambio solo
      // afecta a ventas y reservas futuras; lo ya vendido o
      // reservado conserva su moneda snapshot.
      if (mounted && _editando && _moneda != _monedaIni) {
        mostrarSnack(
            context,
            'Moneda cambiada a $_moneda: solo '
            'afecta a las ventas y reservas futuras.',
            significado: SignificadoChip.info);
      }
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rediseño 1.20 (paso 4): el formulario se agrupa en
    // secciones con EncabezadoSeccion; la foto ACTUAL se ve
    // al abrir en edición; el guardado vive en una barra
    // inferior fija. Los campos, controladores y el
    // _guardar completo NO cambian.
    final fotoLocalActual = _editando
        ? (widget.suplemento?['foto_local'] as String?)
        : null;
    return Scaffold(
      appBar: appBarIron(
        context,
        _editando ? 'Editar suplemento' : _duplicando ? 'Duplicar suplemento' : 'Nuevo suplemento',
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
            vertical: AppEspacio.lg),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppEspacio.lg),
            child: SyncBanner(compact: true, alcance: 'suplementos'),
          ),
          const EncabezadoSeccion(titulo: 'Identificación'),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: GestureDetector(
                    // v1.2.1: permitir foto también al crear (antes solo al editar).
                    onTap: _elegirFoto,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: AppColores.fondo(context),
                        borderRadius:
                            BorderRadius.circular(AppRadio.lg),
                        border: Border.all(
                            color: AppColores.borde(context)),
                      ),
                      child: _fotoNueva != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(
                                  AppRadio.lg),
                              child: Image.memory(_fotoNueva!,
                                  fit: BoxFit.cover),
                            )
                          : (_editando && widget.suplemento != null)
                              ? ClipRRect(
                                  borderRadius:
                                      BorderRadius.circular(
                                          AppRadio.lg),
                                  child: _FotoSuplemento(
                                      sup: widget.suplemento!),
                                )
                              : Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                        Icons.add_a_photo_rounded,
                                        color: AppColores
                                            .textoSecundario(
                                                context)),
                                    // v1.2.1: texto genérico (antes "Foto al editar").
                                    const Text('Agregar foto',
                                        style:
                                            AppTexto.minuscula),
                                  ],
                                ),
                    ),
                  ),
                ),
                if (_editando && widget.suplemento != null) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'Toca la foto para cambiarla',
                    textAlign: TextAlign.center,
                    style: AppTexto.minuscula.copyWith(
                        color:
                            AppColores.textoSecundario(context)),
                  ),
                ],
                if (fotoLocalActual != null &&
                    fotoLocalActual.isNotEmpty &&
                    _fotoNueva == null) ...[
                  const SizedBox(height: AppEspacio.sm),
                  const Center(
                    child: ChipEstado.semantico(
                        texto: 'Foto pendiente de sincronizar',
                        significado: SignificadoChip.alerta),
                  ),
                ],
                const SizedBox(height: AppEspacio.md),
                CampoTexto(
                    controller: _nombre,
                    etiqueta: 'Nombre',
                    hint: 'Ej. Creatina Monohidrato 500g'),
                const SizedBox(height: AppEspacio.md),
                CampoTexto(
                    controller: _desc,
                    etiqueta: 'Descripción (opcional)',
                    maxLineas: 2),
                // v1.2.1: selector de categoría.
                if (_categorias.isNotEmpty) ...[
                  const SizedBox(height: AppEspacio.md),
                  DropdownButtonFormField<int?>(
                    initialValue: _categoriaId,
                    decoration: const InputDecoration(
                      labelText: 'Categoría',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('Sin categoría'),
                      ),
                      for (final c in _categorias)
                        DropdownMenuItem<int?>(
                          value: c['id'] as int?,
                          child: Text(
                              '${c['nombre']}${(c['activa'] as int?) == 0 ? ' (inactiva)' : ''}'),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => _categoriaId = v),
                  ),
                ],
              ],
            ),
          ),
          const EncabezadoSeccion(
              titulo: 'Presentación del envase'),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // v1.4.3: presentación del envase — el cliente la ve en
                // su catálogo bajo el nombre del producto.
                Row(
                  children: [
                    Expanded(
                      child: CampoTexto(
                          controller: _pesoValor,
                          etiqueta: 'Contenido del envase',
                          hint: 'Ej. 300',
                          teclado:
                              const TextInputType.numberWithOptions(
                                  decimal: true)),
                    ),
                    const SizedBox(width: AppEspacio.md),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: _pesoUnidad,
                        decoration: const InputDecoration(
                          labelText: 'Unidad',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('—'),
                          ),
                          for (final u in _unidadesEnvase)
                            DropdownMenuItem<String?>(
                              value: u,
                              child: Text(u),
                            ),
                          // Si el dato guardado trae una unidad fuera de
                          // la lista, se incluye para no romper el
                          // dropdown (mismo arreglo que en Categoría).
                          if (_pesoUnidad != null &&
                              !_unidadesEnvase.contains(_pesoUnidad))
                            DropdownMenuItem<String?>(
                              value: _pesoUnidad,
                              child: Text(_pesoUnidad!),
                            ),
                        ],
                        onChanged: (v) =>
                            setState(() => _pesoUnidad = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppEspacio.sm),
                CampoTexto(
                    controller: _servicios,
                    etiqueta: 'Servicios por envase (opcional)',
                    hint: 'Ej. 60',
                    teclado: TextInputType.number),
              ],
            ),
          ),
          const EncabezadoSeccion(titulo: 'Precio'),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: CampoTexto(
                          controller: _precio,
                          etiqueta: 'Precio oficial ($_moneda)',
                          teclado:
                              const TextInputType.numberWithOptions(
                                  decimal: true)),
                    ),
                    const SizedBox(width: AppEspacio.md),
                    // v1.4.6: selector de moneda del precio oficial.
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _moneda,
                        decoration: const InputDecoration(
                          labelText: 'Moneda',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem<String>(
                            value: 'CUP',
                            child: Text('CUP'),
                          ),
                          DropdownMenuItem<String>(
                            value: 'USD',
                            child: Text('USD'),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _moneda = v ?? 'CUP'),
                      ),
                    ),
                  ],
                ),
                // v1.3.7 (Fase B §6.2): costo (solo dueño, sensible).
                if (AuthService().isOwner) ...[
                  const SizedBox(height: AppEspacio.sm),
                  CampoTexto(
                      controller: _costo,
                      etiqueta: 'Costo por unidad (USD)',
                      teclado:
                          const TextInputType.numberWithOptions(
                              decimal: true)),
                ],
              ],
            ),
          ),
          const EncabezadoSeccion(titulo: 'Inventario'),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CampoTexto(
                    controller: _stock,
                    etiqueta: 'Stock',
                    teclado: TextInputType.number),
                const SizedBox(height: AppEspacio.sm),
                CampoTexto(
                    controller: _umbral,
                    etiqueta: 'Alerta de stock bajo (unidades)',
                    teclado: TextInputType.number),
                const SizedBox(height: AppEspacio.sm),
                SwitchListTile(
                  value: _activo,
                  activeThumbColor: AppColores.naranja,
                  title: const Text('Activo en catálogo',
                      style: AppTexto.cuerpo),
                  onChanged: (v) => setState(() => _activo = v),
                ),
              ],
            ),
          ),
        ],
      ),
      // Guardado en barra inferior fija (rediseño 1.20).
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
              AppEspacio.sm, AppEspacio.lg, AppEspacio.md),
          child: BotonPrimario(
            texto:
                _editando ? 'Guardar cambios' : 'Crear suplemento',
            cargando: _guardando,
            onPressed: _guardando ? null : _guardar,
          ),
        ),
      ),
    );
  }
}
