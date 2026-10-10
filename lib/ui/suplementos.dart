// Catálogo de suplementos ("Inventario en Gimnasio").
//
// - Entrenador: catálogo de solo lectura + botón Vender por producto.
// - Dueño: además gestiona el catálogo (nuevo/editar/activar),
//   el interruptor de la promo "mes gratis" y el historial de ventas.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'detalle_suplemento.dart';
import 'diseno.dart';
import 'historial_ventas.dart';
import 'venta_suplemento.dart';
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
  bool _promoActiva = true;
  // v1.2.1: categorías
  List<Map<String, dynamic>> _categorias = [];
  int? _filtroCategoria; // null = todas
  // v1.2.1: tasa USD del día + ids de los más vendidos.
  double? _tasaUsd;
  List<int> _topIds = [];

  bool get _esDueno => _auth.isOwner;

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
    final ventas =
        await LocalDb.instance.allMirror('ventas_suplementos');
    if (!mounted) return;
    setState(() {
      // v1.2.2: entrenadores solo ven productos con stock > 0
      _items = items
          .where((s) {
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
        ..sort((a, b) =>
            '${a['nombre']}'.compareTo('${b['nombre']}'));
      _promoActiva = (aj['promo_suplementos'] as num?)?.toInt() != 0;
      _tasaUsd = (aj['tasa_usd'] as num?)?.toDouble();
      _topIds = _topVendidos(ventas);
      _cargando = false;
    });
  }

  /// v1.2.1: ids de los 4 productos más vendidos (por cantidad).
  List<int> _topVendidos(
      List<Map<String, dynamic>> ventas) {
    final porProd = <int, int>{};
    for (final v in ventas) {
      // Gemini-2: excluir ventas anuladas del top.
      if ((v['anulada'] as int?) == 1 ||
          (v['activo'] as int?) == 0) continue;
      final id = (v['suplemento_id'] as num?)?.toInt();
      if (id == null) continue;
      porProd[id] =
          (porProd[id] ?? 0) + ((v['cantidad'] as num?)?.toInt() ?? 0);
    }
    final ids = porProd.keys.toList()
      ..sort((a, b) => porProd[b]!.compareTo(porProd[a]!));
    return ids.take(4).toList();
  }

  /// v1.2.1: productos del top visibles (sin búsqueda ni filtro).
  List<Map<String, dynamic>> get _topProductos {
    if (_busqueda.isNotEmpty ||
        _filtroCategoria != null ||
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
    if (_busqueda.isEmpty) return res;
    final q = _busqueda.toLowerCase();
    return res
        .where((s) => '${s['nombre'] ?? ''}'.toLowerCase().contains(q))
        .toList();
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

  void _irVender(Map<String, dynamic> s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VentaSuplementoScreen(suplemento: s),
      ),
    ).then((_) => _cargar());
  }

  /// v1.2.1: ficha del producto al tocar la tarjeta.
  void _irDetalle(Map<String, dynamic> s) {
    Navigator.push<bool>(
      context,
      MaterialPageRoute(
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

  /// v1.2.1: venta rápida (1 unidad, precio oficial, cliente externo).
  /// Gemini-2: exige confirmación previa (riesgo de toques accidentales).
  Future<void> _ventaRapida(Map<String, dynamic> s) async {
    final confirmar = await DialogoApp.confirmar(
      context,
      titulo: 'Venta rápida',
      mensaje: '¿Registrar venta de 1 unidad de ${s['nombre']} '
          'a precio oficial?',
      aceptar: 'Vender',
      icono: Icons.flash_on,
    );
    if (!confirmar || !mounted) return;
    final ok = await ventaRapidaSuplemento(context, s, _tasaUsd);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Venta registrada (se sincronizará)')));
      _cargar();
    }
  }

  void _irEditar(Map<String, dynamic>? s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditarSuplementoScreen(suplemento: s),
      ),
    ).then((_) => _cargar());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Suplementos'),
        actions: [
          if (_esDueno)
            IconButton(
              icon: const Icon(Icons.receipt_long),
              tooltip: 'Historial de ventas',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        const HistorialVentasScreen()),
              ),
            )
          else
            // v1.2.1: el entrenador ve su propio historial.
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Mis ventas',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        const HistorialVentasScreen(
                            soloMias: true)),
              ),
            ),
        ],
      ),
      floatingActionButton: _esDueno
          ? FloatingActionButton.extended(
              onPressed: () => _irEditar(null),
              icon: const Icon(Icons.add),
              label: const Text('Nuevo'),
            )
          : null,
      body: Column(
        children: [
          const SyncBanner(compact: true),
          // v1.2.1: la promo la ven todos (el interruptor solo el dueño).
          _tarjetaPromo(),
          Padding(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: CampoTexto(
              hint: 'Buscar suplemento…',
              icono: Icons.search,
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
                        style: TextStyle(fontSize: 12)),
                    selected: _filtroCategoria == null,
                    onSelected: (_) => setState(
                        () => _filtroCategoria = null),
                  ),
                  const SizedBox(width: 8),
                  for (final c in _categorias) ...[
                    ChoiceChip(
                      label: Text('${c['nombre']}',
                          style:
                              const TextStyle(fontSize: 12)),
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
            horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
        child: Row(
          children: [
            const Icon(Icons.card_giftcard,
                color: AppColores.naranja),
            const SizedBox(width: AppEspacio.sm),
            const Expanded(
              child: Text('Promo: 1 mes gratis por compra',
                  style: AppTexto.cuerpo),
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

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _filtrados;
    if (items.isEmpty) {
      return EstadoVacio(
        icono: Icons.medication_outlined,
        titulo: 'Sin suplementos',
        subtitulo: _esDueno
            ? 'Agrega el primero con el botón Nuevo.'
            : 'Aún no hay productos en el inventario.',
      );
    }
    // v1.2.1: sección destacada con los más vendidos.
    final top = _topProductos;
    return Column(
      children: [
        if (top.isNotEmpty) _seccionTop(top),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _cargar,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.md, AppEspacio.sm, AppEspacio.md, 96),
              itemCount: items.length,
              itemBuilder: (ctx, i) =>
                  _tarjetaProducto(items[i]),
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
                  padding: const EdgeInsets.only(right: 8),
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
    final foto = s['foto_storage'] as String?;
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
            FutureBuilder(
              future: FotoCache.instance.obtener(foto),
              builder: (ctx, snap) {
                final f = snap.data;
                if (f == null) {
                  return Container(
                    height: 64,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: AppColores.fondo(context),
                      borderRadius: BorderRadius.circular(
                          AppRadio.md),
                    ),
                    child: const Icon(
                        Icons.medication_outlined,
                        color: AppColores.naranja),
                  );
                }
                return ClipRRect(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                  child: Image.file(f,
                      height: 64,
                      width: double.infinity,
                      fit: BoxFit.cover),
                );
              },
            ),
            const SizedBox(height: 4),
            Text('${s['nombre'] ?? 'Sin nombre'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTexto.cuerpo),
            Text('${precio.toStringAsFixed(2)} USD',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.naranja,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _tarjetaProducto(Map<String, dynamic> s) {
    final stock = (s['stock'] as num?)?.toInt() ?? 0;
    final precio = (s['precio_oficial'] as num?)?.toDouble() ?? 0;
    final foto = s['foto_storage'] as String?;
    final inactivo = (s['activo'] as int?) != 1;
    // v1.2.1: mostrar categoría del suplemento.
    final catNombre =
        _nombreCategoria(s['categoria_id'] as int?);
    // v1.2.1: equivalente en CUP según la tasa del día.
    final cup =
        _tasaUsd != null && _tasaUsd! > 0 && precio > 0
            ? '≈ ${fmtMonto(precio * _tasaUsd!)} CUP'
            : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.md),
        // v1.2.1: tocar abre la ficha del producto.
        onTap: () => _irDetalle(s),
        child: Row(
          children: [
            _fotoProducto(foto),
            const SizedBox(width: AppEspacio.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${s['nombre'] ?? 'Sin nombre'}',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 2),
                  Text(
                    '${precio.toStringAsFixed(2)} USD · $stock disp.',
                    style: AppTexto.secundario,
                  ),
                  if (cup != null)
                    Text(
                      cup,
                      style: AppTexto.secundario.copyWith(
                          color: AppColores.naranja,
                          fontWeight: FontWeight.bold),
                    ),
                  // v1.2.1: chip de categoría.
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: ChipEstado(
                        texto: catNombre,
                        color: AppColores.naranja),
                  ),
                  if (inactivo)
                    ChipEstado(
                        texto: 'Inactivo',
                        color:
                            AppColores.textoSecundario(context)),
                  // v1.2.2: acciones movidas aquí desde abajo (mejor ubicación).
                  // Rápida y Compartir como botones compactos con icono+etiqueta.
                  Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      TextButton.icon(
                        onPressed: stock > 0
                            ? () => _ventaRapida(s)
                            : null,
                        icon: const Icon(Icons.bolt,
                            size: 16),
                        label: const Text('Rápida',
                            style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          minimumSize: const Size(48, 32),
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => compartirSuplemento(
                            context, s, _tasaUsd),
                        icon: const Icon(
                            Icons.share,
                            size: 16),
                        label: const Text('Compartir',
                            style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          minimumSize: const Size(48, 32),
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // v1.2.1: el dueño ve Editar y Vender (antes solo Editar).
            // Bug 15/16: expandido=false para no romper el Row de la
            // tarjeta (el SizedBox infinito aplastaba el texto a ancho 0
            // y el botón desaparecía/rompía el layout).
            if (_esDueno)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BotonPrimario(
                    texto: 'Vender',
                    expandido: false,
                    onPressed:
                        stock > 0 ? () => _irVender(s) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Editar',
                    onPressed: () => _irEditar(s),
                  ),
                ],
              )
            else
              BotonPrimario(
                texto: 'Vender',
                expandido: false,
                onPressed: stock > 0 ? () => _irVender(s) : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _fotoProducto(String? storagePath) {
    const tam = 56.0;
    Widget placeholder() => Container(
          width: tam,
          height: tam,
          decoration: BoxDecoration(
            color: AppColores.fondo(context),
            borderRadius:
                BorderRadius.circular(AppRadio.md),
          ),
          child: const Icon(Icons.medication_outlined,
              color: AppColores.naranja),
        );
    if (storagePath == null || storagePath.isEmpty) {
      return placeholder();
    }
    return FutureBuilder(
      future: FotoCache.instance.obtener(storagePath),
      builder: (ctx, snap) {
        final f = snap.data;
        if (f == null) return placeholder();
        return ClipRRect(
          borderRadius:
              BorderRadius.circular(AppRadio.md),
          child: Image.file(f,
              width: tam, height: tam, fit: BoxFit.cover),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Crear / editar suplemento (solo dueño)
// ---------------------------------------------------------------------------

class EditarSuplementoScreen extends StatefulWidget {
  final Map<String, dynamic>? suplemento;
  const EditarSuplementoScreen({super.key, this.suplemento});

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
  bool _activo = true;
  bool _guardando = false;
  Uint8List? _fotoNueva;
  // v1.2.1 fix auditoría Gemini: ruta local de la foto para el
  // mecanismo de fotos pendientes (no se pierde offline).
  String? _fotoNuevaPath;
  // v1.2.1: categoría del suplemento.
  List<Map<String, dynamic>> _categorias = [];
  int? _categoriaId;

  bool get _editando => widget.suplemento != null;

  @override
  void initState() {
    super.initState();
    final s = widget.suplemento;
    if (s != null) {
      _nombre.text = '${s['nombre'] ?? ''}';
      _desc.text = '${s['descripcion'] ?? ''}';
      _precio.text = '${s['precio_oficial'] ?? ''}';
      _stock.text = '${s['stock'] ?? 0}';
      _activo = (s['activo'] as int?) == 1;
      _categoriaId = s['categoria_id'] as int?;
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
        ..sort((a, b) =>
            '${a['nombre']}'.compareTo('${b['nombre']}'));
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
    final nombre = _nombre.text.trim();
    final precio = double.tryParse(
        _precio.text.trim().replaceAll(',', '.'));
    final stock =
        int.tryParse(_stock.text.trim()) ?? 0;
    if (nombre.isEmpty || precio == null || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa los datos',
          mensaje:
              'El nombre y un precio oficial mayor que 0 son obligatorios.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    setState(() => _guardando = true);
    try {
      final payload = {
        'nombre': nombre,
        'descripcion': _desc.text.trim(),
        'precio_oficial': precio,
        'stock': stock,
        'activo': _activo ? 1 : 0,
        // v1.2.1: categoría asignada.
        if (_categoriaId != null) 'categoria_id': _categoriaId,
        if (_editando) 'suplemento_id': widget.suplemento!['id'],
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
        final fid = await LocalDb.instance.addFotoPendiente(
          opUuid: fotoOpUuid,
          localPath: _fotoNuevaPath!,
        );
        if (_editando) {
          final sid = widget.suplemento!['id'] as int?;
          if (sid != null) {
            await LocalDb.instance.setFotoSuplemento(fid, sid);
          }
        }
      }
      unawaited(SyncEngine.instance.push());
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              _editando ? 'Editar suplemento' : 'Nuevo suplemento')),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const SyncBanner(compact: true),
          const SizedBox(height: AppEspacio.md),
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
                        : const Column(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            children: [
                              Icon(
                                  Icons.add_a_photo_outlined,
                                  color: AppColores.naranja),
                              // v1.2.1: texto genérico (antes "Foto al editar").
                              Text('Agregar foto',
                                  style:
                                      AppTexto.minuscula),
                            ],
                          ),
              ),
            ),
          ),
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
          const SizedBox(height: AppEspacio.md),
          // v1.2.1: selector de categoría.
          if (_categorias.isNotEmpty)
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
          if (_categorias.isNotEmpty)
            const SizedBox(height: AppEspacio.md),
          Row(
            children: [
              Expanded(
                child: CampoTexto(
                    controller: _precio,
                    etiqueta: 'Precio oficial (USD)',
                    teclado:
                        const TextInputType.numberWithOptions(
                            decimal: true)),
              ),
              const SizedBox(width: AppEspacio.md),
              Expanded(
                child: CampoTexto(
                    controller: _stock,
                    etiqueta: 'Stock',
                    teclado: TextInputType.number),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          SwitchListTile(
            value: _activo,
            activeThumbColor: AppColores.naranja,
            title:
                const Text('Activo en catálogo', style: AppTexto.cuerpo),
            onChanged: (v) => setState(() => _activo = v),
          ),
          const SizedBox(height: AppEspacio.lg),
          BotonPrimario(
            texto: _guardando
                ? 'Guardando…'
                : (_editando ? 'Guardar cambios' : 'Crear suplemento'),
            onPressed: _guardando ? null : _guardar,
          ),
        ],
      ),
    );
  }
}
