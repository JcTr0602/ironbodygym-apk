// Catálogo de suplementos ("Inventario en Gimnasio").
//
// - Entrenador: catálogo de solo lectura + botón Vender por producto.
// - Dueño: además gestiona el catálogo (nuevo/editar/activar),
//   el interruptor de la promo "mes gratis" y el historial de ventas.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
import 'cuentas_por_cobrar.dart';
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
        ..sort(compararPorNombre);
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
          (v['activo'] as int?) == 0) {
        continue;
      }
      final id = (v['suplemento_id'] as num?)?.toInt();
      if (id == null) {
        continue;
      }
      porProd[id] =
          (porProd[id] ?? 0) + ((v['cantidad'] as num?)?.toInt() ?? 0);
    }
    // v1.3.4 (C5): solo productos con ventas reales > 0 en el carrusel.
    final ids = porProd.keys.where((id) => porProd[id]! > 0).toList()
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
  void _irVender(Map<String, dynamic> s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VentaSuplementoScreen(suplemento: s),
      ),
    ).then((exito) {
      _cargar();
      // TODO (Ítem A v1.3.5 / condición C1 — hook recibo WhatsApp, dueño):
      // VentaSuplementoScreen hoy devuelve `true` al cerrar una venta
      // exitosa. Cuando devuelva los datos de la venta (cantidad, total
      // en USD, teléfono del cliente si aplica), ofrecer aquí el recibo
      // por WhatsApp reutilizando normalizarTelefonoWaMe (negocio.dart)
      // y el patrón de _mostrarDialogoWhatsApp (ficha.dart: campo de
      // teléfono editable + wa.me), con moneda explícita "<monto> USD".
      // NO duplicar la lógica del diálogo: extraer un helper compartido
      // antes de implementarlo.
      if (exito == true && _esDueno) {
        // Punto de enganche del recibo (pendiente de los datos de venta).
      }
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No hay productos activos con stock')),
        );
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
      // B2 (Argón): jamás exportar "$0.00 USD" a clientes.
      buf.writeln(precio > 0
          ? '💰 ${precio.toStringAsFixed(2)} USD'
          : '💰 Consultar precio');
    }
    await Share.share(buf.toString().trimRight());
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
          // v1.3.4 (C5): "+ Nuevo" compacto en la cabecera (solo dueño).
          // Ni FAB (tapaba el botón Vender) ni tarjeta en el grid.
          if (_esDueno)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => _irEditar(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Nuevo'),
              ),
            ),
          // v1.3.4 (B2): compartir el catálogo como texto (WhatsApp).
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Compartir catálogo',
            onPressed: _compartirCatalogo,
          ),
          // v1.3.7 (Fase B §6.2): cuentas por cobrar (fiados).
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: 'Cuentas por cobrar',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      const CuentasPorCobrarScreen()),
            ),
          ),
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
      body: Column(
        children: [
          const SyncBanner(compact: true, alcance: 'suplementos'),
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

  /// v1.3.4 (C5): vista ÚNICA de catálogo — Grid 2 columnas.
  /// NOTA: el spec pedía childAspectRatio 0.72, pero con foto
  /// AspectRatio(1.1) la mitad inferior queda en ~76-88px en pantallas de
  /// 360-412dp y el contenido del spec (nombre 2 líneas + precio grande +
  /// botón ancho completo, ~107-116px) desborda. 0.60 preserva todos los
  /// elementos del spec sin overflow.
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
            ? 'Agrega el primero para empezar el catálogo.'
            : 'Aún no hay productos en el inventario.',
        textoAccion: _esDueno ? '+ Crear primer suplemento' : null,
        onAccion: _esDueno ? () => _irEditar(null) : null,
      );
    }
    // v1.2.1: sección destacada con los más vendidos (solo si hay ventas).
    final top = _topProductos;
    return Column(
      children: [
        if (top.isNotEmpty) _seccionTop(top),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _cargar,
            child: GridView.builder(
              padding: const EdgeInsets.all(AppEspacio.md),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.60,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: items.length,
              itemBuilder: (ctx, i) => _TarjetaSuplemento(
                key: ValueKey(items[i]['id']),
                sup: items[i],
                onVender: () => _irVender(items[i]),
                onTap: () => _irDetalle(items[i]),
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
    // v1.3.3: foto local recién tomada (offline) tiene prioridad sobre
    // la remota (aún no subida o sin descargar).
    final fotoLocal = s['foto_local'] as String?;
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
            if (fotoLocal != null && fotoLocal.isNotEmpty && File(fotoLocal).existsSync())
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(AppRadio.md),
                child: Image.file(File(fotoLocal),
                    height: 64,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
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
                    )),
              )
            else
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

}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// v1.3.4 (C5): tarjeta de catálogo — vista única de suplementos.
// ---------------------------------------------------------------------------

/// Tarjeta de catálogo (spec Argón):
/// - Mitad superior: foto AspectRatio(1.1), bordes superiores 12px,
///   BoxFit.cover, con triestado de carga (ver _FotoSuplemento).
/// - Badge de stock flotante (sup. derecha): chip negro + punto semántico.
/// - Mitad inferior: nombre (2 líneas), precio oficial grande, botón Vender.
/// - Elevación 2, borde 1px (white10 oscuro / black12 claro).
class _TarjetaSuplemento extends StatelessWidget {
  final Map<String, dynamic> sup;
  final VoidCallback onVender;
  final VoidCallback onTap;

  const _TarjetaSuplemento({
    super.key,
    required this.sup,
    required this.onVender,
    required this.onTap,
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

    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
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
                    child: _BadgeStock(stock: stock),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nombre,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${precio.toStringAsFixed(2)} USD',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppColores.naranja,
                      ),
                    ),
                    if (inactivo)
                      const Text(
                        'Inactivo',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                          height: 1.2,
                        ),
                      ),
                    // v1.3.7 (Fase B §6.2): chip de stock bajo.
                    Builder(builder: (ctx) {
                      final umbral = (sup['umbral_stock'] as num?)
                              ?.toInt() ??
                          3;
                      if (inactivo || stock <= 0 || stock > umbral) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding:
                            const EdgeInsets.only(top: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColores.alerta
                                .withValues(alpha: 0.15),
                            borderRadius:
                                BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColores.alerta
                                    .withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            'Stock bajo: $stock',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColores.alerta,
                            ),
                          ),
                        ),
                      );
                    }),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: hayStock ? onVender : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColores.naranja,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              oscuro ? Colors.white12 : Colors.black12,
                          disabledForegroundColor:
                              oscuro ? Colors.white38 : Colors.black38,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(hayStock ? 'Vender' : 'Agotado'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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

  Future<File?> _resolver() async {
    final s = widget.sup;
    final local = s['foto_local'] as String?;
    if (local != null && local.isNotEmpty && File(local).existsSync()) {
      return File(local);
    }
    final storage = s['foto_storage'] as String?;
    if (storage == null || storage.isEmpty) return null;
    final enCache = await FotoCache.instance.enCache(storage);
    if (enCache != null) return enCache;
    return FotoCache.instance.obtener(storage);
  }

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
          Icons.fitness_center,
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
  final int stock;
  const _BadgeStock({required this.stock});

  @override
  Widget build(BuildContext context) {
    final Color punto;
    if (stock <= 0) {
      punto = AppColores.error;
    } else if (stock <= 5) {
      punto = AppColores.alerta;
    } else {
      punto = AppColores.exito;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
          const SizedBox(width: 6),
          Text(
            'Stock: $stock',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
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
  // v1.3.7 (Fase B §6.2): costo (solo dueño) y umbral de stock bajo.
  final _costo = TextEditingController();
  final _umbral = TextEditingController();
  // v1.4.3: presentación del envase (contenido + unidad + servicios)
  // — lo que el cliente ve en su catálogo («300 g · 60 servicios»).
  final _pesoValor = TextEditingController();
  final _servicios = TextEditingController();
  String? _pesoUnidad;
  static const _unidadesEnvase = [
    'g', 'kg', 'ml', 'L', 'cápsulas', 'tabletas', 'unidades',
  ];
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

  /// Número del espejo sin decimales inútiles (300.0 → «300»).
  static String _fmtNum(dynamic v) {
    final n = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
  }

  @override
  void initState() {
    super.initState();
    final s = widget.suplemento;
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
      _activo = (s['activo'] as int?) == 1;
      _categoriaId = s['categoria_id'] as int?;
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
    // v1.4.3: la presentación va en pareja (cantidad + unidad);
    // si falta una, el servidor rechazaría la op entera.
    final pesoValor =
        double.tryParse(_pesoValor.text.trim().replaceAll(',', '.'));
    final serviciosTxt = _servicios.text.trim().replaceAll(',', '.');
    final servicios =
        int.tryParse(serviciosTxt) ?? double.tryParse(serviciosTxt)?.round();
    if ((pesoValor != null) != (_pesoUnidad != null) ||
        (pesoValor != null && pesoValor <= 0)) {
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
      final costo =
          double.tryParse(_costo.text.trim().replaceAll(',', '.'));
      final umbral =
          int.tryParse(_umbral.text.trim()) ?? 3;
      final payload = {
        'nombre': nombre,
        'descripcion': _desc.text.trim(),
        'precio_oficial': precio,
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
        // v1.4.3: presentación del envase; se manda siempre
        // (vacío = limpiar el dato). El servidor conserva el
        // dato si la op no trae las claves (apps viejas).
        'peso_valor': pesoValor ?? '',
        'peso_unidad': _pesoUnidad ?? '',
        'servicios_estandar': servicios ?? '',
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
          const SyncBanner(compact: true, alcance: 'suplementos'),
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
          // v1.3.7 (Fase B §6.2): costo (solo dueño, sensible) y
          // umbral de stock bajo.
          if (AuthService().isOwner)
            CampoTexto(
                controller: _costo,
                etiqueta: 'Costo por unidad (USD)',
                teclado: const TextInputType.numberWithOptions(
                    decimal: true)),
          if (AuthService().isOwner)
            const SizedBox(height: AppEspacio.sm),
          CampoTexto(
              controller: _umbral,
              etiqueta: 'Alerta de stock bajo (unidades)',
              teclado: TextInputType.number),
          const SizedBox(height: AppEspacio.sm),
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
