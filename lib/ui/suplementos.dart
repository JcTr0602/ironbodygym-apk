// Catálogo de suplementos ("Inventario en Gimnasio").
//
// - Entrenador: catálogo de solo lectura + botón Vender por producto.
// - Dueño: además gestiona el catálogo (nuevo/editar/activar),
//   el interruptor de la promo "mes gratis" y el historial de ventas.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../fotos.dart';
import '../fotos_cola.dart';
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
  // v1.2.9+47: vista compacta (decisión Jc).
  bool _vistaCompacta = true;
  // v1.2.9+47: ventas del día para el banner.
  Map<String, dynamic> _ventasHoy = {'n': 0, 'total': 0.0};
  // v1.2.9+47: ids con ops pendientes (badge naranja).
  Set<int> _idsPendientes = {};

  bool get _esDueno => _auth.isOwner;

  @override
  void initState() {
    super.initState();
    _cargarPreferenciaVista();
    _cargar();
  }

  Future<void> _cargarPreferenciaVista() async {
    final v = await LocalDb.instance.getMeta('suplementos_vista');
    if (mounted) {
      setState(() => _vistaCompacta = v != 'tarjetas');
    }
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
    _cargarVentasHoy();
    _cargarIdsPendientes();
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
    if (_busqueda.isNotEmpty) {
      final q = _busqueda.toLowerCase();
      res = res
          .where((s) => '${s['nombre'] ?? ''}'.toLowerCase().contains(q))
          .toList();
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
        final cmpNombre =
            '${a['nombre']}'.compareTo('${b['nombre']}');
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

  void _irVender(Map<String, dynamic> s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VentaSuplementoScreen(suplemento: s),
      ),
    ).then((_) => _cargar());
  }

  /// v1.2.9+47: vende usando el nuevo diálogo con confirmación obligatoria.
  /// Guarda en ventas_suplementos local, descuenta stock, actualiza
  /// ultimo_precio y encola la op con creada_en (corrección Gemini).
  Future<void> _venderConDialogo(Map<String, dynamic> s) async {
    final resultado = await mostrarDialogoVenta(context, s);
    if (resultado == null || !mounted) return;

    final cantidad = resultado['cantidad'] as int;
    final precio = resultado['precio'] as double;
    final db = LocalDb.instance;
    final ahoraIso = DateTime.now().toIso8601String();

    try {
      final stockActual = (s['stock'] as num?)?.toInt() ?? 0;
      final nuevoStock = stockActual - cantidad;
      if (nuevoStock < 0) throw Exception('Stock insuficiente');

      // v1.2.9+47 (Gemini): transacción atómica. Si el móvil se bloquea
      // o la app crashea a mitad, no quedan datos inconsistentes.
      final d = await db.db;
      final opUuid = const Uuid().v4();
      final payload = {
        'suplemento_id': s['id'],
        'cantidad': cantidad,
        'precio': precio,
        'total': cantidad * precio,
        'creada_en': ahoraIso,
      };
      final auth = AuthService();
      await d.transaction((txn) async {
        // 1. Registro local (para banner y reportes)
        await txn.rawInsert(
            'INSERT INTO ventas_suplementos '
            '(suplemento_id, cantidad, precio, total, creada_en) '
            'VALUES (?, ?, ?, ?, ?)',
            [s['id'], cantidad, precio, cantidad * precio, ahoraIso]);

        // 2. Descontar stock + memoria de precio
        await txn.update(
          'suplementos',
          {'stock': nuevoStock, 'ultimo_precio': precio},
          where: 'id = ?',
          whereArgs: [s['id']],
        );

        // 3. Encolar op con timestamp real (campos de queueOp)
        await txn.insert('ops_queue', {
          'op_uuid': opUuid,
          'tipo': 'venta_suplemento',
          'payload': jsonEncode(payload),
          'estado': 'pendiente',
          'creada_ts': ahoraIso,
          'user_id': auth.userId,
          'telegram_id': auth.telegramId,
        });
      });
      unawaited(SyncEngine.instance.push());
      if (mounted) {
        setState(() {
          _idsPendientes.add(s['id'] as int);
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Venta: $cantidad x '
                '\$${precio.toStringAsFixed(2)}')));
        _cargar();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// v1.2.9+47: suma +1 al stock con opción Deshacer.
  Future<void> _sumarStockRapido(Map<String, dynamic> s) async {
    final db = LocalDb.instance;
    final stockActual = (s['stock'] as num?)?.toInt() ?? 0;
    final nuevoStock = stockActual + 1;

    await db.actualizarSuplemento(
        s['id'] as int, {'stock': nuevoStock});
    await db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_suplemento',
      payload: {'id': s['id'], 'stock': nuevoStock},
    );
    unawaited(SyncEngine.instance.push());
    if (mounted) {
      setState(() {
        _idsPendientes.add(s['id'] as int);
      });
    }
    _cargar();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${s['nombre']}: stock $nuevoStock'),
          action: SnackBarAction(
            label: 'Deshacer',
            onPressed: () async {
              await db.actualizarSuplemento(
                  s['id'] as int, {'stock': stockActual});
              await db.queueOp(
                opUuid: const Uuid().v4(),
                tipo: 'editar_suplemento',
                payload: {'id': s['id'], 'stock': stockActual},
              );
              unawaited(SyncEngine.instance.push());
              _cargar();
            },
          ),
        ),
      );
    }
  }

  /// v1.2.9+47: ajuste manual de stock (long-press).
  Future<void> _ajusteManualStock(Map<String, dynamic> s) async {
    final ctrl =
        TextEditingController(text: '${s['stock'] ?? 0}');
    final nuevo = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stock: ${s['nombre']}'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration:
              const InputDecoration(labelText: 'Nuevo stock'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(ctrl.text)),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (nuevo == null || nuevo < 0 || !mounted) return;

    final db = LocalDb.instance;
    await db.actualizarSuplemento(s['id'] as int, {'stock': nuevo});
    await db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_suplemento',
      payload: {'id': s['id'], 'stock': nuevo},
    );
    unawaited(SyncEngine.instance.push());
    _cargar();
  }

  /// v1.2.9+47: ventas del día para el banner.
  Future<void> _cargarVentasHoy() async {
    try {
      final d = await LocalDb.instance.db;
      final hoy =
          DateTime.now().toIso8601String().substring(0, 10);
      final r = await d.rawQuery(
          'SELECT COUNT(*) as n, SUM(total) as total '
          'FROM ventas_suplementos WHERE date(creada_en) = ?',
          [hoy]);
      if (mounted) {
        setState(() {
          _ventasHoy = {
            'n': r.first['n'] ?? 0,
            'total': (r.first['total'] as num?)?.toDouble() ?? 0.0,
          };
        });
      }
    } catch (_) {}
  }

  /// v1.2.9+47: ¿tiene ops pendientes este suplemento?
  bool _tieneOpPendiente(dynamic id) {
    final i = (id as num?)?.toInt();
    return i != null && _idsPendientes.contains(i);
  }

  /// v1.2.9+47: precarga ids con ops pendientes (filtro por tipo).
  Future<void> _cargarIdsPendientes() async {
    try {
      final d = await LocalDb.instance.db;
      final rows = await d.query(
        'ops_queue',
        columns: ['tipo', 'payload'],
        where: "estado IN ('pendiente', 'enviada') "
            "AND tipo IN ('venta_suplemento', 'editar_suplemento')",
      );
      final ids = <int>{};
      for (final r in rows) {
        final p = r['payload'] as String?;
        if (p == null) continue;
        final m = RegExp(r'"(?:suplemento_id|id)":\s*(\d+)')
            .firstMatch(p);
        if (m != null) ids.add(int.parse(m.group(1)!));
      }
      if (mounted) setState(() => _idsPendientes = ids);
    } catch (_) {}
  }

  /// v1.2.9+47: selector de vista (compacta vs tarjeta).
  Widget _itemSuplemento(Map<String, dynamic> s) {
    if (_vistaCompacta) {
      return FilaSuplementoCompacta(
        sup: s,
        tienePendiente: _tieneOpPendiente(s['id']),
        onVender: () => _venderConDialogo(s),
        onEditar: () => _irDetalle(s),
        onSumarStock: () => _sumarStockRapido(s),
        onAjusteManual: () => _ajusteManualStock(s),
      );
    }
    return _tarjetaProducto(s);
  }

  /// v1.2.9+47: tarjeta del carrusel "Más vendidos" con venta directa.
  Widget _tarjetaMasVendido(Map<String, dynamic> s) {
    final nombre = (s['nombre'] ?? '').toString();
    final precio = (s['precio'] as num?)?.toDouble() ?? 0.0;
    final stock = (s['stock'] as num?)?.toInt() ?? 0;
    final activo = (s['activo'] as int? ?? 1) == 1;
    final fotoPath = s['foto_local'] as String?;

    return Container(
      width: 148,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        color: AppColores.fondo(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12)),
            child: fotoPath != null && fotoPath.isNotEmpty
                ? Image.file(
                    File(fotoPath),
                    height: 90,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        PlaceholderFotoSuplemento(
                      nombre: nombre,
                      width: double.infinity,
                      height: 90,
                      borderRadius:
                          const BorderRadius.vertical(
                              top: Radius.circular(12)),
                    ),
                  )
                : PlaceholderFotoSuplemento(
                    nombre: nombre,
                    width: double.infinity,
                    height: 90,
                    borderRadius:
                        const BorderRadius.vertical(
                            top: Radius.circular(12)),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nombre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${precio.toStringAsFixed(2)} USD',
                  style: TextStyle(
                      fontSize: 12, color: Colors.orange[300]),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 30,
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: (stock > 0 && activo)
                        ? () => _venderConDialogo(s)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColores.naranja,
                      padding: EdgeInsets.zero,
                    ),
                    child: const Text('Vender',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v1.2.9+47: banner HUD de ventas del día.
  Widget _bannerVentasHoy() {
    final n = _ventasHoy['n'] as int;
    if (n <= 0) return const SizedBox.shrink();
    final total =
        (_ventasHoy['total'] as num?)?.toDouble() ?? 0.0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(
          horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColores.naranja.withOpacity(0.25),
            AppColores.naranja.withOpacity(0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AppColores.naranja.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.today,
              color: AppColores.naranja, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Hoy: $n ventas · '
              '\$${total.toStringAsFixed(2)} USD',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  /// v1.2.9+47: comparte catálogo como texto para WhatsApp.
  Future<void> _compartirCatalogo() async {
    final d = await LocalDb.instance.db;
    final rows = await d.query('suplementos',
        columns: ['nombre', 'precio'],
        where: 'activo = 1 AND stock > 0',
        orderBy: 'nombre');

    if (rows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'No hay productos activos con stock')),
        );
      }
      return;
    }

    final buf = StringBuffer();
    buf.writeln('🏋️ *IRON BODY GYM*');
    buf.writeln('Catálogo de suplementos');
    buf.writeln('');
    for (final r in rows) {
      final nombre = r['nombre'];
      final precio =
          (r['precio'] as num?)?.toDouble() ?? 0;
      buf.writeln(
          '• $nombre — \$${precio.toStringAsFixed(2)} USD');
    }
    buf.writeln('');
    buf.writeln('_Precios en USD. Stock limitado._');

    await Share.share(buf.toString());
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
            child: _listaConSeccionSinStock(items),
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

  /// v1.2.3: Lista con sección "Sin stock" para el dueño.
  Widget _listaConSeccionSinStock(List<Map<String, dynamic>> items) {
    if (!_esDueno || items.isEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.md, AppEspacio.sm, AppEspacio.md, 96),
        itemCount: items.length,
        itemBuilder: (ctx, i) => _itemSuplemento(items[i]),
      );
    }
    // Encontrar índice donde empieza sin-stock
    int idxSinStock = -1;
    for (int i = 0; i < items.length; i++) {
      final stock = (items[i]['stock'] as num?)?.toInt() ?? 0;
      if (stock <= 0) {
        idxSinStock = i;
        break;
      }
    }
    if (idxSinStock == -1) {
      // No hay sin-stock
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.md, AppEspacio.sm, AppEspacio.md, 96),
        itemCount: items.length,
        itemBuilder: (ctx, i) => _itemSuplemento(items[i]),
      );
    }
    // Construir lista con header
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 96),
      itemCount: items.length + 1, // +1 por el header
      itemBuilder: (ctx, i) {
        if (i == idxSinStock) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppEspacio.md),
            child: EncabezadoSeccion(titulo: 'Sin stock'),
          );
        }
        final itemIdx = i > idxSinStock ? i - 1 : i;
        return _itemSuplemento(items[itemIdx]);
      },
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
    // v1.3.1 (Medio #6): solo si la tasa es real (> 1.0).
    final cup =
        _tasaUsd != null && _tasaUsd! > 1.0 && precio > 0
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
        final nEncoladas = await FotosColaService.instance.encolarFoto(
          opUuid: fotoOpUuid,
          suplementoId: sid,
          rutaOriginal: _fotoNuevaPath!,
        );
        // v1.2.9+40: diagnóstico visible (temporal).
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Fotos encoladas: $nEncoladas (sid=$sid)')),
          );
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

/// Fila compacta de suplemento (76px). Revisado por Gemini 2026-10-13.
/// - Borde izquierdo condicional por stock (rojo ≤3, naranja ≤5)
/// - Swipe endToStart: +1 stock (confirmDismiss retorna false)
/// - LongPress: ajuste manual de stock
/// - Tap: abre edición. Botón Vender: abre diálogo de venta.
class FilaSuplementoCompacta extends StatelessWidget {
  final Map<String, dynamic> sup;
  final bool tienePendiente;
  final VoidCallback onVender;
  final VoidCallback onEditar;
  final VoidCallback onSumarStock;
  final VoidCallback onAjusteManual;

  const FilaSuplementoCompacta({
    super.key,
    required this.sup,
    required this.tienePendiente,
    required this.onVender,
    required this.onEditar,
    required this.onSumarStock,
    required this.onAjusteManual,
  });

  @override
  Widget build(BuildContext context) {
    final stock = (sup['stock'] as num?)?.toInt() ?? 0;
    final nombre = (sup['nombre'] ?? '').toString();
    final precio = (sup['precio'] as num?)?.toDouble() ?? 0.0;
    final activo = (sup['activo'] as int? ?? 1) == 1;

    Color? bordeColor;
    if (stock <= 3) {
      bordeColor = Colors.redAccent;
    } else if (stock <= 5) {
      bordeColor = Colors.orangeAccent;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Dismissible(
        key: ValueKey('sup_${sup['id']}'),
        direction: DismissDirection.endToStart,
        movementDuration: const Duration(milliseconds: 200),
        dismissThresholds: const {DismissDirection.endToStart: 0.35},
        background: Container(
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: const Icon(Icons.add, color: Colors.green),
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.endToStart) {
            onSumarStock();
            HapticFeedback.lightImpact();
          }
          return false;
        },
        child: GestureDetector(
          onLongPress: onAjusteManual,
          onTap: onEditar,
          child: Container(
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColores.fondo(context),
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(
                  color: bordeColor ?? Colors.transparent,
                  width: 3.5,
                ),
              ),
            ),
            child: Row(
              children: [
                _miniaturaSuplemento(sup, nombre),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              nombre,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: activo ? Colors.white : Colors.white38,
                              ),
                            ),
                          ),
                          if (tienePendiente)
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.only(left: 6),
                              decoration: const BoxDecoration(
                                color: Colors.orange,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${precio.toStringAsFixed(2)} USD · $stock disp.',
                        style: TextStyle(
                          color: activo ? Colors.orange[300] : Colors.white24,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: (stock > 0 && activo) ? onVender : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColores.naranja,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white10,
                    disabledForegroundColor: Colors.white24,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Vender'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniaturaSuplemento(
      Map<String, dynamic> sup, String nombre) {
    final fotoPath = sup['foto_local'] as String?;
    if (fotoPath != null && fotoPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(fotoPath),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => PlaceholderFotoSuplemento(
            nombre: nombre,
            width: 56,
            height: 56,
          ),
        ),
      );
    }
    return PlaceholderFotoSuplemento(
      nombre: nombre,
      width: 56,
      height: 56,
    );
  }
}

/// Diálogo de venta con confirmación obligatoria. Revisado por Gemini.
/// - StatefulWidget (no StatefulBuilder) para TextEditingController limpio
/// - Valida precio > 0, deshabilita Confirmar si inválido
/// - Evita crash de clamp con stock 0
Future<Map<String, dynamic>?> mostrarDialogoVenta(
  BuildContext context,
  Map<String, dynamic> sup,
) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => DialogoVenta(sup: sup),
  );
}

class DialogoVenta extends StatefulWidget {
  final Map<String, dynamic> sup;
  const DialogoVenta({super.key, required this.sup});

  @override
  State<DialogoVenta> createState() => _DialogoVentaState();
}

class _DialogoVentaState extends State<DialogoVenta> {
  late int _stock;
  late double _precio;
  late TextEditingController _precioCtrl;
  int _cantidad = 1;
  bool _precioValido = true;

  @override
  void initState() {
    super.initState();
    _stock = (widget.sup['stock'] as num?)?.toInt() ?? 0;
    final precioBase =
        (widget.sup['precio'] as num?)?.toDouble() ?? 0.0;
    _precio =
        (widget.sup['ultimo_precio'] as num?)?.toDouble() ?? precioBase;
    _precioCtrl =
        TextEditingController(text: _precio.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _precioCtrl.dispose();
    super.dispose();
  }

  void _ajustarCantidad(int nueva) {
    if (_stock <= 0) return;
    setState(() {
      _cantidad = nueva.clamp(1, _stock);
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = _precioValido ? (_cantidad * _precio) : 0.0;

    return AlertDialog(
      title: Text('Vender ${widget.sup['nombre']}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: _cantidad > 1
                      ? () => _ajustarCantidad(_cantidad - 1)
                      : null,
                ),
                Text('$_cantidad',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _cantidad < _stock
                      ? () => _ajustarCantidad(_cantidad + 1)
                      : null,
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [1, 5, 10].map((n) {
                return ActionChip(
                  label: Text('+$n'),
                  onPressed: _cantidad + n <= _stock
                      ? () => _ajustarCantidad(_cantidad + n)
                      : null,
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _precioCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Precio unitario (USD)',
                prefixText: '\$ ',
                errorText: _precioValido ? null : 'Precio inválido',
              ),
              onChanged: (v) {
                final p = double.tryParse(v);
                setState(() {
                  if (p != null && p > 0) {
                    _precio = p;
                    _precioValido = true;
                  } else {
                    _precioValido = false;
                  }
                });
              },
            ),
            const SizedBox(height: 14),
            Text(
              'Total: \$${total.toStringAsFixed(2)}',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              'Stock disponible: $_stock',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: (_precioValido && _stock > 0)
              ? () => Navigator.pop(
                  context, {'cantidad': _cantidad, 'precio': _precio})
              : null,
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja),
          child: const Text('Confirmar venta'),
        ),
      ],
    );
  }
}

/// Placeholder unificado con inicial para lista compacta y carrusel.
/// Revisado por Gemini 2026-10-13: evita duplicar lógica.
class PlaceholderFotoSuplemento extends StatelessWidget {
  final String nombre;
  final double width;
  final double height;
  final double fontSize;
  final BorderRadius? borderRadius;

  const PlaceholderFotoSuplemento({
    super.key,
    required this.nombre,
    required this.width,
    required this.height,
    this.fontSize = 22,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final inicial = nombre.trim().isNotEmpty
        ? nombre.trim()[0].toUpperCase()
        : '?';
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColores.naranja.withOpacity(0.15),
        borderRadius: borderRadius ?? BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          inicial,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            color: AppColores.naranja,
          ),
        ),
      ),
    );
  }
}
