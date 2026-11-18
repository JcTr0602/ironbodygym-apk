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
import 'package:flutter/rendering.dart' show ScrollDirection;
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
import '../tipos_pago.dart';
import 'app_bar.dart';
import 'componentes.dart';
import '../errores_sync.dart';
import 'foto_elegir.dart';
import 'categorias_suplemento.dart';
import 'cuentas_por_cobrar.dart';
import 'por_cobrar.dart';
import 'detalle_suplemento.dart';
import 'diseno.dart';
import 'historial_ventas.dart';
import 'hoja_accion.dart';
import 'reservas.dart';
import 'servicios.dart';
import 'servicios_admin.dart';
import 'widgets.dart';
import '../app_log.dart';

class SuplementosScreen extends StatefulWidget {
  // 1.25 T12: cliente preseleccionado (desde Buscar): la
  // venta rápida nace con ese comprador elegido.
  final int? clienteInicialId;
  final String? clienteInicialNombre;
  /// 1.32 «Mostrador Táctico»: embebida = vista del Pilar 3
  /// (Tienda), sin su AppBar.
  final bool embebida;
  const SuplementosScreen(
      {super.key,
      this.clienteInicialId,
      this.clienteInicialNombre,
      this.embebida = false});

  @override
  State<SuplementosScreen> createState() => _SuplementosScreenState();
}

class _SuplementosScreenState extends State<SuplementosScreen> {
  final _auth = AuthService();
  List<Map<String, dynamic>> _items = [];
  bool _cargando = true;
  // 1.36 H-B3 (136-766): el fallo de la carga inicial es un
  // estado propio con reintento — antes el catch solo
  // escribía en bitácora y la pantalla decía «Sin
  // suplementos», un error disfrazado de catálogo vacío.
  bool _errorCarga = false;
  String _busqueda = '';
  final _busquedaCtrl = TextEditingController();
  bool _promoActiva = true;
  // 1.36 H-B3 (136-769): hasta que los ajustes cargan, la
  // tarjeta de promo NO afirma «activa» (el valor inicial
  // true se leía como estado real, también el entrenador).
  bool _promoCargada = false;
  // v1.2.1: categorías
  List<Map<String, dynamic>> _categorias = [];
  int? _filtroCategoria; // null = todas
  // 14/25: disponibilidad: 'todos' | 'con_stock' | 'bajo' | 'agotado'.
  String _filtroStock = 'todos';
  // v1.2.1: tasa USD del día + ids de los más vendidos.
  double? _tasaUsd;
  List<int> _topIds = [];
  // 1.25 T120 (F4-12): unidades vendidas por suplemento.
  Map<int, int> _topTotales = {};

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
    final clientes = await LocalDb.instance.allMirror('clientes');
    if (!mounted) return;
    setState(() {
      // Yunque B (YB-SER-06): el contador aplica el filtro de
      // protegidos de la bandeja (contarSolicitadasVisibles):
      // sin él, la insignia del entrenador contaba también
      // las solicitudes de clientes protegidos que su
      // bandeja oculta — el número revelaba su existencia.
      _reservasSolicitadas = contarSolicitadasVisibles(
          reservas, clientes,
          esDueno: _esDueno);
    });
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  bool _actualizando = false;

  /// 1.26 (auditoría de botones, MEDIA 6): el gesto de
  /// actualizar SINCRONIZA y después recarga — antes solo
  /// releía el espejo local y el catálogo «actualizado»
  /// podía seguir viejo (Servicios ya sincronizaba así).
  /// Mismo patrón y mismos mensajes honestos que
  /// Servicios._actualizar (1.22).
  Future<void> _actualizar() async {
    if (_actualizando) return;
    setState(() => _actualizando = true);
    var mensaje = 'Suplementos actualizados';
    var esError = false;
    try {
      // 1.34 Campo 2 (P-7): regla de Jc (fresco = solo
      // local) y desenlace veraz, parcial incluida (T-3).
      final r = await refrescoScopeIron('suplementos');
      if (r == null) {
        mensaje = 'Suplementos al día, sin cambios';
      } else if (!r.corrio) {
        mensaje = r.motivo == SyncMotivoNoCorrio.sinSesion
            ? 'Sin sesión: vuelve a iniciar sesión para sincronizar'
            : 'Ya hay una sincronización en curso';
      } else if (r.error) {
        mensaje = 'Sin conexión, mostrando datos locales';
        esError = true;
      } else if (r.parcial) {
        mensaje = 'Bajada parcial: ${r.fallidas} filas no '
            'bajaron; mostrando lo que hay';
        esError = true;
      } else if (r.bajados == 0) {
        mensaje = 'Suplementos al día, sin cambios';
      }
    } catch (_) {
      mensaje = 'Sin conexión, mostrando datos locales';
      esError = true;
    }
    try {
      await _cargar();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _actualizando = false);
    mostrarSnack(context, mensaje,
        significado:
            esError ? SignificadoChip.error : SignificadoChip.exito);
  }

  /// Recarga silenciosa para el aviso del banner: un
  /// fallo de lectura del espejo aquí no debe quedar
  /// como error asíncrono no manejado (la pantalla
  /// conserva lo que tenga; el gesto de actualizar sí
  /// reporta). Autoauditoría 1.26.
  Future<void> _recargarTrasBanner() async {
    try {
      await _cargar();
    } catch (_) {}
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
      if (mounted && _errorCarga) {
        setState(() => _errorCarga = false);
      }
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos) y, desde 136-766,
      // también en pantalla como EstadoError si no hay
      // catálogo que mostrar.
      AppLog.error('ui', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _errorCarga = true);
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final items = await LocalDb.instance.allMirror('suplementos');
    final cats =
        await LocalDb.instance.allMirror('categorias_suplemento');
    final aj = await LocalDb.instance.getAjustes();
    // v1.2.1: top vendidos para la sección destacada.
    // D-04 (1.21): agregado en SQL, sin decodificar el espejo
    // entero de ventas solo para el top-4.
    final topIds =
        await LocalDb.instance.topVendidosSuplementos();
    final topTotales =
        await LocalDb.instance.totalesVendidosSuplementos();
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
      // Yunque 3 (K6-3): lectores tolerantes A2-D2 (promo y
      // tasa llegaban con cast duro: un bool/texto del
      // servidor tumbaba la carga del catálogo).
      _promoActiva = flagAjusteTolerante(aj['promo_suplementos']);
      _promoCargada = true;
      _tasaUsd = montoAjusteTolerante(aj['tasa_usd']);
      _topIds = topIds;
      _topTotales = topTotales;
      _cargando = false;
    });
    await _cargarReservasPendientes();
  }

  // 1.34 Campo 2 (P-5, disciplina D-08): derivados
  // memoizados. Antes _filtrados y _topProductos eran
  // getters que filtraban/ordenaban/construían el mapa
  // del catálogo EN CADA BUILD (varias veces por build:
  // cuerpo, conteos y «Más vendidos»). Ahora se calculan
  // solo cuando cambia una entrada (la lista cargada, la
  // búsqueda o los filtros, por identidad/valor).
  List<Map<String, dynamic>>? _filtradosMemo;
  int? _filtradosClave;
  List<Map<String, dynamic>>? _topMemo;
  int? _topClave;

  int get _claveDerivados => Object.hash(
      identityHashCode(_items),
      identityHashCode(_categorias),
      identityHashCode(_topIds),
      _busqueda,
      _filtroCategoria,
      _filtroStock,
      _esDueno);

  /// v1.2.1: productos del top visibles (sin búsqueda ni filtro).
  List<Map<String, dynamic>> get _topProductos {
    final clave = _claveDerivados;
    final memo = _topMemo;
    if (memo != null && _topClave == clave) return memo;
    final res = _topProductosCalculado();
    _topMemo = res;
    _topClave = clave;
    return res;
  }

  List<Map<String, dynamic>> _topProductosCalculado() {
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
    final clave = _claveDerivados;
    final memo = _filtradosMemo;
    if (memo != null && _filtradosClave == clave) return memo;
    final res = _filtradosCalculado();
    _filtradosMemo = res;
    _filtradosClave = clave;
    return res;
  }

  List<Map<String, dynamic>> _filtradosCalculado() {
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
    } else {
      // 1.36 H-B3 (136-771): el orden determinista también
      // es del entrenador (antes su catálogo quedaba en el
      // orden crudo del espejo y cambiaba entre cargas):
      // nombre, luego id como desempate final.
      res = [...res]..sort((a, b) {
          final cmpNombre = compararPorNombre(a, b);
          if (cmpNombre != 0) return cmpNombre;
          return (SyncEngine.enteroTolerante(a['id']) ?? 0)
              .compareTo(SyncEngine.enteroTolerante(b['id']) ?? 0);
        });
    }
    return res;
  }

  Future<void> _togglePromo(bool v) async {
    // 1.36 H-B3 (136-768): encolar y guardar el ajuste van
    // con red — si algo falla, el interruptor NO se mueve
    // y el dueño ve el aviso (antes la excepción quedaba
    // sin manejar y la promo parecía cambiada sin estarlo).
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': 'promo_suplementos', 'valor': v ? 1 : 0},
      );
      // Optimista: reflejar de inmediato en ajustes locales.
      final aj = await LocalDb.instance.getAjustes();
      aj['promo_suplementos'] = v ? 1 : 0;
      await LocalDb.instance.setAjustes(aj);
    } catch (e) {
      AppLog.error('ui', 'promo_toggle_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(
            context, 'No se pudo cambiar la promo: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
      return;
    }
    unawaited(SyncEngine.instance.push());
    if (mounted) setState(() => _promoActiva = v);
  }

  /// v1.3.4: abre la venta con el flujo unificado (VentaSuplementoScreen +
  /// registrarVentaSuplemento). Esta pantalla NUNCA escribe SQL de venta.
  /// Rediseño 1.20 (D1): el botón «Vender» de la tarjeta
  /// abre la VENTA RÁPIDA (diálogo de 1 unidad); la venta
  /// completa vive en el detalle del producto.
  void _irVender(Map<String, dynamic> s) {
    ventaRapidaSuplemento(context, s, _tasaUsd, widget.clienteInicialId,
            widget.clienteInicialNombre)
        .then((vendido) {
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
      appBar: widget.embebida
          ? null
          : appBarIron(
        context,
        'Suplementos',
        acciones: [
          // v1.3.4 (C5): "+ Nuevo" compacto en la cabecera (solo dueño).
          // Ni FAB (tapaba el botón Vender) ni tarjeta en el grid.
          // 1.36 H-B3 (136-769): a 360 dp, «Nuevo» + Reservas
          // + menú desbordaban la barra — en pantallas
          // estrechas «Nuevo» queda como icono con tooltip.
          if (_esDueno)
            if (MediaQuery.sizeOf(context).width < 380)
              IconButton(
                icon: const Icon(Icons.add_rounded),
                tooltip: 'Nuevo suplemento',
                onPressed: () => _irEditar(null),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
                child: FilledButton.tonalIcon(
                  onPressed: () => _irEditar(null),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Nuevo'),
                ),
              ),
          // 1.25 T120 (F4-14): en la barra quedan solo «Nuevo»
          // y Reservas (con contador) — compartir y fiados
          // pasaron al menú ⋮, agrupados por bloques.
          // Reservas v2: bandeja de reservas de los clientes,
          // con contador de solicitudes sin responder.
          if (_puedeReservas)
            IconButton(
              icon: Badge(
                isLabelVisible: _reservasSolicitadas > 0,
                // 1.36 H-B3 (136-769): el contador se topa
                // («99+») y se anuncia entero al lector de
                // pantalla — antes un número largo rompía
                // la insignia y no se anunciaba.
                label: Text(_reservasSolicitadas > 99
                    ? '99+'
                    : '$_reservasSolicitadas'),
                child: Semantics(
                  label: _reservasSolicitadas > 0
                      ? '$_reservasSolicitadas solicitudes de reserva pendientes'
                      : 'Sin solicitudes de reserva pendientes',
                  child: const Icon(Icons.bookmark_border_rounded),
                ),
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
          // Rediseño 1.20 + F4-14 (1.25): el menú ⋮ agrupa
          // todo lo demás por bloques (Vender / Consultar /
          // Administrar).
          PopupMenuButton<String>(
            popUpAnimationStyle: estiloAparicionMenu,
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'Más opciones',
            onSelected: (v) async {
              if (v == 'compartir') {
                _compartirCatalogo();
              } else if (v == 'fiados') {
                await Navigator.push(
                  context,
                  RutaIron(
                      builder: (_) => const PorCobrarScreen(
                          pestanaInicial: 1)),
                );
              } else if (v == 'historial') {
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
            // F4-14: bloques Vender / Consultar / Administrar.
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'servicios',
                child: Row(
                  children: [
                    Icon(Icons.bolt_rounded, size: 20),
                    SizedBox(width: AppEspacio.sm),
                    // 1.36 H-B3 (136-769): el rayo ya es el
                    // icono — fuera el ⚡ duplicado del texto.
                    Text('Servicios por dosis'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
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
              const PopupMenuItem(
                value: 'fiados',
                child: Row(
                  children: [
                    Icon(Icons.account_balance_wallet_rounded,
                        size: 20),
                    SizedBox(width: AppEspacio.sm),
                    Text('Fiados por cobrar'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'compartir',
                child: Row(
                  children: [
                    Icon(Icons.share_rounded, size: 20),
                    SizedBox(width: AppEspacio.sm),
                    Text('Compartir catálogo'),
                  ],
                ),
              ),
              if (_esDueno) ...[
                const PopupMenuDivider(),
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
                // 1.23 (backlog de campo): administración
                // completa de las dosis a mano desde la sección
                // (solo dueño; la pantalla además se protege).
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
              ],
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 1.26 (BAJA): al terminar el sync del banner,
          // el catálogo se recarga (antes quedaba viejo).
          SyncBanner(
              compact: true,
              alcance: 'suplementos',
              alTerminarSync: _recargarTrasBanner),
          // 1.36 H-B3 (136-771): embebida (dentro de otra
          // pantalla) no hay AppBar: Nuevo, Reservas y el
          // menú no desaparecen sin sustituto — fila
          // compacta con las tres entradas.
          if (widget.embebida)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
              child: Row(
                children: [
                  if (_esDueno)
                    FilledButton.tonalIcon(
                      onPressed: () => _irEditar(null),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Nuevo'),
                    ),
                  const Spacer(),
                  if (_puedeReservas)
                    IconButton(
                      icon: Badge(
                        isLabelVisible: _reservasSolicitadas > 0,
                        label: Text(_reservasSolicitadas > 99
                            ? '99+'
                            : '$_reservasSolicitadas'),
                        child: const Icon(
                            Icons.bookmark_border_rounded),
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
                  IconButton(
                    icon: const Icon(Icons.more_vert_rounded),
                    tooltip: 'Más opciones',
                    onPressed: _abrirMasOpcionesEmbebida,
                  ),
                ],
              ),
            ),
          // 1.34 Campo 2 (B-3): la cabecera del catálogo
          // (promo + buscador + categorías) se PLIEGA al
          // bajar por la lista y reaparece al subir o al
          // llegar arriba — al scrollear manda el catálogo
          // (orden de campo de Jc 2026-11-14: la lista era
          // lo menos visible de su propia pantalla). El
          // pliegue lo decide el gesto sobre la lista
          // (el listener vive dentro del RefrescoIron).
          AnimatedSize(
            duration: AppMovimiento.media,
            curve: AppMovimiento.curvaSuave,
            alignment: Alignment.topCenter,
            child: _cabeceraVisible
                ? _cabeceraCatalogo()
                : const SizedBox.shrink(),
          ),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  /// La cabecera plegable del catálogo: promo, buscador y
  /// la fila de categorías/stock (su contenido no cambia;
  /// lo nuevo es que cede su alto al desplazar).
  Widget _cabeceraCatalogo() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        // v1.2.1 + 14/25, unificadas en 1.25 T33: UNA sola
        // fila de filtros con scroll horizontal (categoría y
        // disponibilidad): antes eran dos filas fijas que
        // empujaban el catálogo media pantalla hacia abajo.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.md, 0, AppEspacio.md, 0),
          child: Row(
            children: [
              if (_categorias.isNotEmpty) ...[
                ChoiceChip(
                  // 1.36 H-B3 (136-769): la etiqueta sigue
                  // al estado del chip (texto pleno si está
                  // elegido, secundario si no) — el estilo
                  // fijo dejaba el elegido en gris apagado.
                  label: Text('Todas',
                      style: AppTexto.etiqueta.copyWith(
                          color: _filtroCategoria == null
                              ? AppColores.texto(context)
                              : AppColores.textoSecundario(context))),
                  selected: _filtroCategoria == null,
                  onSelected: (_) => setState(
                      () => _filtroCategoria = null),
                ),
                const SizedBox(width: 8),
                for (final c in _categorias) ...[
                  ChoiceChip(
                    label: Text('${c['nombre']}',
                        style: AppTexto.etiqueta.copyWith(
                            color: _filtroCategoria ==
                                    (c['id'] as int?)
                                ? AppColores.texto(context)
                                : AppColores.textoSecundario(context))),
                    selected: _filtroCategoria ==
                        (c['id'] as int?),
                    onSelected: (_) => setState(() =>
                        _filtroCategoria =
                            c['id'] as int?),
                  ),
                  const SizedBox(width: 8),
                ],
                const SizedBox(width: 8),
              ],
              // 1.34 (C-48 · G-07, PARCIAL): el filtro de
              // stock sale de la fila a su botón «Stock · …»
              // al final de la misma fila; la categoría se
              // queda (es navegación del catálogo, no un
              // recorte ocasional).
              // 1.36 H-B3 (136-771): el botón es solo del
              // dueño — el catálogo del entrenador YA viene
              // filtrado a activo con stock, así que sus
              // opciones «Agotados»/«Con stock» mentían
              // (una siempre vacía, la otra idéntica a
              // «Todos»).
              if (_esDueno) _botonStock(),
            ],
          ),
        ),
      ],
    );
  }

  bool _cabeceraVisible = true;

  // SL-6 (G05-10): la promo nace PLEGADA tras su botón
  // resumen «Promo · activa/inactiva» (regla anti-regueros
  // de Jc); el interruptor solo ocupa espacio al desplegar.
  bool _promoDesplegada = false;

  /// El pliegue de la cabecera según el scroll del
  /// catálogo: bajar la pliega; subir la despliega (y
  /// volver arriba ES subir: llega desplegada). Solo
  /// reacciona
  /// al scroll VERTICAL (los carruseles horizontales de
  /// chips y de «Más vendidos» no pliegan nada). Buscar y
  /// filtrar quedan a los mismos toques: subir un gesto
  /// devuelve la cabecera entera. El listener vive DENTRO
  /// del RefrescoIron (ver _cuerpo): el RefreshIndicator
  /// se queda las notificaciones de scroll que procesa y
  /// un listener fuera nunca las vería.
  bool _alDesplazarCatalogo(UserScrollNotification n) {
    final eje = n.metrics.axisDirection;
    if (eje != AxisDirection.down && eje != AxisDirection.up) {
      return false;
    }
    // La notificación de dirección llega AL CAMBIAR el
    // sentido del gesto, con los píxeles de ESE instante
    // (al empezar a bajar, aún ~0): el sentido manda, no
    // el recorrido acumulado ni la posición. Bajar →
    // pliega; subir → despliega (y subir es también como
    // se vuelve al tope: la cabecera ya va desplegada).
    final bool debe;
    if (n.direction == ScrollDirection.reverse) {
      debe = false;
    } else if (n.direction == ScrollDirection.forward) {
      debe = true;
    } else {
      return false;
    }
    if (debe != _cabeceraVisible && mounted) {
      setState(() => _cabeceraVisible = debe);
    }
    return false;
  }

  /// 1.34 (C-48 · G-07): botón «Stock · …» con el resumen
  /// del filtro de stock vigente (molde del botón «Mes · …»
  /// de Liquidaciones).
  Widget _botonStock() {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.lg),
        ),
      ),
      onPressed: _abrirHojaStock,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Stock · ${etiquetaFiltroStock(_filtroStock)}',
            style: AppTexto.metadato,
            // Yunque 1.34 (C2-5): a 2 líneas, como los demás
            // botones de filtros plegados (ver Auditoría).
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 16),
        ],
      ),
    );
  }

  /// Hoja del filtro de stock: una sola dimensión → tocar
  /// una opción la aplica y cierra (como la hoja de meses).
  Future<void> _abrirHojaStock() async {
    final elegido = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadio.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
              AppEspacio.md, AppEspacio.lg, AppEspacio.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Stock', style: AppTexto.subtitulo),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Cerrar',
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              RadioGroup<String>(
                groupValue: _filtroStock,
                onChanged: (v) => Navigator.of(ctx).pop(v),
                child: Column(
                  children: [
                    for (final f in opcionesFiltroStock)
                      RadioListTile<String>(
                        value: f.$1,
                        title: Text(f.$2),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (elegido == null || !mounted) return;
    setState(() => _filtroStock = elegido);
  }

  /// 1.36 H-B3 (136-771): las opciones del menú ⋮ cuando
  /// la pantalla va embebida (sin AppBar): la hoja de la
  /// casa con los mismos destinos y las mismas rutas.
  Future<void> _abrirMasOpcionesEmbebida() async {
    Widget opcion(String valor, IconData icono, String texto) =>
        Builder(
          builder: (ctx) => ListTile(
            leading: Icon(icono, size: 20),
            title: Text(texto),
            onTap: () => Navigator.of(ctx).pop(valor),
          ),
        );
    final v = await showHojaIron<String>(
      context,
      titulo: 'Más opciones',
      icono: Icons.more_vert_rounded,
      cuerpo: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          opcion('servicios', Icons.bolt_rounded,
              'Servicios por dosis'),
          opcion(
              'historial',
              _esDueno
                  ? Icons.receipt_long_rounded
                  : Icons.history_rounded,
              _esDueno ? 'Historial de ventas' : 'Mis ventas'),
          opcion('fiados', Icons.account_balance_wallet_rounded,
              'Fiados por cobrar'),
          opcion('compartir', Icons.share_rounded,
              'Compartir catálogo'),
          if (_esDueno) ...[
            opcion('categorias', Icons.category_rounded,
                'Categorías'),
            opcion('admin_servicios', Icons.settings_rounded,
                'Administrar dosis y botes'),
          ],
        ],
      ),
    );
    if (v == null || !mounted) return;
    if (v == 'compartir') {
      _compartirCatalogo();
    } else if (v == 'fiados') {
      await Navigator.push(
        context,
        RutaIron(
            builder: (_) =>
                const PorCobrarScreen(pestanaInicial: 1)),
      );
    } else if (v == 'historial') {
      await Navigator.push(
        context,
        RutaIron(
            builder: (_) =>
                HistorialVentasScreen(soloMias: !_esDueno)),
      );
    } else if (v == 'categorias') {
      await Navigator.push(
        context,
        RutaIron(
            builder: (_) => const CategoriasSuplementoScreen()),
      );
      if (mounted) _cargar();
    } else if (v == 'admin_servicios') {
      await Navigator.push(
        context,
        RutaIron(builder: (_) => const ServiciosAdminScreen()),
      );
      if (mounted) _cargar();
    } else if (v == 'servicios') {
      await Navigator.push(
        context,
        RutaIron(builder: (_) => const ServiciosScreen()),
      );
    }
  }

  Widget _tarjetaPromo() {
    // 1.25 T33: para el entrenador, con la promo apagada la
    // banda solo ocupaba una capa más sobre el catálogo sin
    // decir nada accionable: no se pinta. El dueño la ve
    // siempre (lleva el interruptor).
    if (!_esDueno && !_promoActiva) {
      return const SizedBox.shrink();
    }
    // SL-6 (G05-10): plegada, la promo es UNA fila resumen
    // («Promo · activa/inactiva») que no compite con el
    // catálogo; desplegada, la tarjeta de siempre con su
    // interruptor y su chevron para replegar.
    if (!_promoDesplegada) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
        child: Tarjeta(
          // 1.36 H-B3 (136-771): desplegar la promo es
          // solo del dueño (lleva a su interruptor); el
          // entrenador ve el resumen sin affordance.
          // 1.36 H-B3 (136-769): sin cargar, el resumen no
          // afirma estado («Promo · cargando…»).
          onTap: _esDueno
              ? () => setState(() => _promoDesplegada = true)
              : null,
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
                    !_promoCargada
                        ? 'Promo · cargando…'
                        : _promoActiva
                            ? 'Promo · activa'
                            : 'Promo · inactiva',
                    style: AppTexto.secundario),
              ),
              if (_esDueno)
                Icon(Icons.expand_more_rounded,
                    size: 20,
                    color: AppColores.textoSecundario(context)),
            ],
          ),
        ),
      );
    }
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
              // 1.36 H-B3 (136-770): el texto de la tarjeta
              // desplegada cruza con fundido al cambiar el
              // estado (antes saltaba en seco dentro del
              // AnimatedSize de la cabecera).
              child: AnimatedSwitcher(
                duration: AppMovimiento.corta,
                child: Text(
                    _promoActiva
                        ? 'Promo activa · 1 mes gratis por compra'
                        : 'Promo inactiva',
                    key: ValueKey(_promoActiva),
                    style: AppTexto.secundario),
              ),
            ),
            Switch(
              value: _promoActiva,
              activeThumbColor: AppColores.naranja,
              // v1.2.1: solo el dueño la activa/desactiva.
              onChanged: _esDueno ? _togglePromo : null,
            ),
            IconButton(
              icon: const Icon(Icons.expand_less_rounded, size: 20),
              tooltip: 'Plegar promo',
              onPressed: () =>
                  setState(() => _promoDesplegada = false),
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
    // 1.36 H-B3 (136-766): sin catálogo que mostrar y con
    // fallo de carga, la pantalla lo DICE y ofrece
    // reintentar — no disfraza el error de vacío.
    if (_errorCarga && _items.isEmpty) {
      return EstadoError(
        titulo: 'No se pudieron cargar los suplementos',
        detalle: 'Revisa el teléfono e inténtalo de nuevo.',
        onReintentar: () {
          setState(() => _errorCarga = false);
          _cargar();
        },
      );
    }
    final items = _filtrados;
    if (items.isEmpty) {
      // 14/25: con filtros activos, el vacío ofrece limpiarlos
      // (búsqueda, categoría y stock) en vez del alta.
      final hayFiltros = _busqueda.isNotEmpty ||
          _filtroCategoria != null ||
          _filtroStock != 'todos';
      return EstadoVacio(
        ilustracion: 'assets/vacio_pomo.webp',
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
                // 1.32 (integración, RD-1): sin densidad
                // compacta — el conmutador hereda el mínimo
                // táctil de 48 del tema, como el resto de
                // SegmentedButton de la app.
              ),
            ],
          ),
        ),
        Expanded(
          child: RefrescoIron(
            onRefresh: _actualizar,
            child: NotificationListener<UserScrollNotification>(
              onNotification: _alDesplazarCatalogo,
              child: _vistaLista
                ? CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding:
                            const EdgeInsets.all(AppEspacio.md),
                        sliver: SliverList.builder(
                          itemCount: items.length,
                          itemBuilder: (ctx, i) => Padding(
                            padding: const EdgeInsets.only(
                                bottom: AppEspacio.sm),
                            child: _TarjetaSuplemento.fila(
                              key: ValueKey(items[i]['id']),
                              sup: items[i],
                              onVender: () => _irVender(items[i]),
                              onTap: () => _irDetalle(items[i]),
                              tasaUsd: _tasaUsd,
                              categoriaNombre: _nombreCategoria(
                                  items[i]['categoria_id'] as int?),
                            ),
                          ),
                        ),
                      ),
                      // 1.34 Campo 2 (B-3): «Más vendidos»
                      // cierra el catálogo DENTRO del scroll
                      // (ver la nota en la vista de rejilla).
                      if (top.isNotEmpty)
                        SliverToBoxAdapter(
                            child: _seccionTop(top)),
                    ],
                  )
                : LayoutBuilder(
                    // 1.30 (Oleada D6, UI130-32): la rejilla
                    // del catálogo adopta la cascada de la
                    // fundación, como el Home.
                    builder: (ctx, cons) => EntradaCascada(
                        child: CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding:
                              const EdgeInsets.all(AppEspacio.md),
                          sliver: SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              // 1.30 D5 (UI130-18): el alto de
                              // la celda sale del contenido a
                              // la escala de texto vigente
                              // (altoCeldaCatalogo), no de un
                              // ratio fijo que recortaba a
                              // escala grande.
                              mainAxisExtent: altoCeldaCatalogo(
                                  cons.maxWidth,
                                  MediaQuery.textScalerOf(ctx)),
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            itemCount: items.length,
                            // 1.36 H-B3 (136-770): la cascada
                            // va clavada al ID del suplemento
                            // (la llave vive en el ItemCascada,
                            // no solo en la tarjeta): al
                            // buscar o filtrar, el ítem que
                            // queda conserva su estado y NO
                            // se reanima; antes la posición
                            // mandaba y la rejilla entera
                            // volvía a desfilar.
                            itemBuilder: (ctx, i) => ItemCascada(
                                key: ValueKey(items[i]['id']),
                                indice: i,
                                child: _TarjetaSuplemento(
                                  key: ValueKey(items[i]['id']),
                                  sup: items[i],
                                  onVender: () =>
                                      _irVender(items[i]),
                                  onTap: () =>
                                      _irDetalle(items[i]),
                                  tasaUsd: _tasaUsd,
                                  categoriaNombre:
                                      _nombreCategoria(items[i]
                                              ['categoria_id']
                                          as int?),
                                )),
                          ),
                        ),
                        // 1.34 Campo 2 (B-3): «Más vendidos»
                        // deja de ser una banda FIJA al pie
                        // que le robaba ~130 dp permanentes
                        // a la lista (1.25 T33 la bajó ahí
                        // buscando el pulgar; en campo de
                        // 2026-11-14 Jc dictó lo contrario:
                        // al scrollear manda el catálogo).
                        // Ahora cierra el catálogo dentro
                        // del propio scroll, tras el último
                        // producto.
                        if (top.isNotEmpty)
                          SliverToBoxAdapter(
                              child: _seccionTop(top)),
                      ],
                    ),
                    )),
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
          padding:
              EdgeInsets.symmetric(horizontal: AppEspacio.md),
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
    // 1.36 H-B3 (136-767): el mini-top usa el MISMO precio
    // visible que la tarjeta (oficial → legacy → sin
    // precio); antes solo miraba el oficial y un producto
    // con solo precio legacy salía a 0.00 aquí.
    final visible = precioVisibleSuplemento(s);
    final precio = visible.precio ?? 0;
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
            // 1.36 H-B3 (136-767): sin precio visible, la
            // frase de la casa («Consultar precio»), no 0.00.
            if (visible.precio == null)
              Text('Consultar precio',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context)))
            else
            Builder(builder: (_) {
              final moneda = visible.moneda;
              final cup = moneda == 'USD'
                  ? precioOficialEn('CUP', precio, _tasaUsd)
                  : null;
              return Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: precio.toStringAsFixed(2),
                      style: AppTexto.secundario.copyWith(
                          color: AppColores.textoNaranja(context),
                          fontWeight: FontWeight.bold)),
                  // 1.30 D1 (UI130-03): la moneda va como
                  // metadato junto a la cifra protagonista
                  // (antes todo el precio era texto de
                  // marca a pelo: 2,52 en claro).
                  TextSpan(
                      text: ' $moneda'
                          '${cup != null ? ' (≈ ${cup.toStringAsFixed(0)} CUP)' : ''}',
                      style: AppTexto.metadato.copyWith(
                          color:
                              AppColores.textoSecundario(context))),
                ]),
              );
            }),
            // F4-12: la cifra que sostiene el «más vendido»
            // (histórico de ventas no anuladas).
            if ((_topTotales[(s['id'] as num?)?.toInt()] ?? 0) > 0)
              Text(
                '${_topTotales[(s['id'] as num?)?.toInt()]} uds. vendidas',
                style: AppTexto.minuscula,
              ),
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

/// 1.36 H-B3 (136-767): el precio VISIBLE del catálogo,
/// UNA sola regla para la tarjeta y «Más vendidos»:
/// precio_oficial → legacy `precio` → sin precio (null).
/// Antes la tarjeta caía a «0.00 CUP» y el mini-top solo
/// miraba el oficial: el mismo producto decía dos cosas.
/// PURO (la moneda sale de LocalDb.monedaDe, la de siempre).
({double? precio, String moneda}) precioVisibleSuplemento(
    Map<String, dynamic> s) {
  final oficial = (s['precio_oficial'] as num?)?.toDouble();
  final legacy = (s['precio'] as num?)?.toDouble();
  final p = (oficial != null && oficial > 0)
      ? oficial
      : (legacy != null && legacy > 0 ? legacy : null);
  return (precio: p, moneda: LocalDb.monedaDe(s));
}

/// El precio visible como texto plano: «Consultar precio»
/// cuando no hay precio que enseñar (la misma frase que ya
/// usa compartir el catálogo). PURO.
String textoPrecioVisibleSuplemento(Map<String, dynamic> s) {
  final v = precioVisibleSuplemento(s);
  if (v.precio == null) return 'Consultar precio';
  return '${v.precio!.toStringAsFixed(2)} ${v.moneda}';
}

/// 1.36 H-B3 (136-768): chip «Foto pendiente de
/// sincronizar» decidido por la COLA REAL de fotos
/// (fotos_cola), no por `foto_local`: una foto ya
/// confirmada puede conservar foto_local hasta el próximo
/// pull y el aviso mentía. Si la consulta falla, el aviso
/// se conserva (nunca ocultar un pendiente real).
class ChipFotoPendienteSuplemento extends StatefulWidget {
  final int suplementoId;
  const ChipFotoPendienteSuplemento(
      {super.key, required this.suplementoId});

  @override
  State<ChipFotoPendienteSuplemento> createState() =>
      _ChipFotoPendienteSuplementoState();
}

class _ChipFotoPendienteSuplementoState
    extends State<ChipFotoPendienteSuplemento> {
  late Future<bool> _futura;

  @override
  void initState() {
    super.initState();
    _futura = FotosColaService.instance
        .hayFotoPendienteDeSuplemento(widget.suplementoId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _futura,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        // Error de consulta → conservar el aviso.
        final pendiente = snap.data ?? true;
        if (!pendiente) return const SizedBox.shrink();
        return const ChipEstado.semantico(
            texto: 'Foto pendiente de sincronizar',
            significado: SignificadoChip.alerta);
      },
    );
  }
}

/// (1.30 D5 · UI130-18, ALTA-02) ¿El suplemento no tiene foto
/// propia? Sin foto local ni remota, el catálogo enseña la
/// genérica de su clase — marcada como genérica en la
/// tarjeta, nunca como si fuera su foto.
bool supSinFotoPropia(Map<String, dynamic> sup) {
  final local = '${sup['foto_local'] ?? ''}'.trim();
  final remota = '${sup['foto_storage'] ?? ''}'.trim();
  return local.isEmpty && remota.isEmpty;
}

String _sinAcentosFoto(String t) {
  const mapa = {
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  var r = t.toLowerCase();
  mapa.forEach((k, v) => r = r.replaceAll(k, v));
  return r;
}

/// (1.30 D5 · UI130-18, ALTA-02) La foto genérica que le toca
/// a un suplemento sin foto propia, por su nombre y su
/// categoría: creatina, pre-entreno, shaker, barritas y
/// botella tienen la suya; todo lo demás (proteínas y lo no
/// reconocido) cae a la de proteína. PURO.
String assetFotoGenericaSuplemento(String nombre, {String? categoria}) {
  final t = _sinAcentosFoto('$nombre ${categoria ?? ''}');
  if (t.contains('creatin')) return 'assets/sup_generica_creatina.jpg';
  if (t.contains('pre-entreno') ||
      t.contains('preentreno') ||
      t.contains('pre-workout') ||
      t.contains('pre workout')) {
    return 'assets/sup_generica_preentreno.jpg';
  }
  if (t.contains('shaker') || t.contains('vaso') || t.contains('termo')) {
    return 'assets/sup_generica_shaker.jpg';
  }
  if (t.contains('barra') || t.contains('barrita')) {
    return 'assets/sup_generica_barritas.jpg';
  }
  if (t.contains('bebida') || t.contains('botella')) {
    return 'assets/sup_generica_botella.jpg';
  }
  return 'assets/sup_generica_proteina.jpg';
}

/// (1.30 D5 · UI130-18) Alto de la celda de la cuadrícula del
/// catálogo, calculado por contenido: la foto (ancho / 1,1)
/// más el cuerpo dimensionado para el PEOR caso — nombre,
/// precio, presentación, chip de stock y botón, cada línea a
/// la escala de texto vigente. Sustituye al childAspectRatio
/// fijo 0,52, que con la escala de texto grande recortaba el
/// contenido de la celda (el nombre «a una línea» de F4-07
/// era el parche de aquel alto fijo).
double altoCeldaCatalogo(double anchoVista, TextScaler escala) {
  double linea(double tamano, double altura) => escala.scale(tamano) * altura;
  final anchoCelda = (anchoVista - AppEspacio.md * 2 - 12) / 2;
  final foto = anchoCelda / 1.1;
  // ChipEstado: etiqueta (12 × 1,2) + relleno vertical xs ×2
  // + borde.
  final chip = linea(12, 1.2) + AppEspacio.xs * 2 + 2;
  // BotonPrimario: su texto (~14 × 1,5) + relleno vertical
  // md ×2, con su mínimo de 52.
  final botonCrudo = linea(14, 1.5) + AppEspacio.md * 2;
  final boton = botonCrudo > 52 ? botonCrudo : 52.0;
  final cuerpo = AppEspacio.sm +
      linea(13, 1.4) + // nombre (secundario)
      4 +
      2 * linea(15, 1.3) + // precio: 2 líneas (136-308)
      linea(11, 1.4) + // presentación (minuscula)
      4 +
      chip +
      AppEspacio.sm +
      boton +
      AppEspacio.sm +
      4; // holgura
  return foto + cuerpo;
}

/// Tarjeta de catálogo (spec Argón):
/// - Mitad superior: foto AspectRatio(1.1), bordes superiores 12px,
///   BoxFit.cover, con triestado de carga (ver _FotoSuplemento).
/// - Badge de stock flotante (sup. derecha): chip negro + punto semántico.
/// SU2 (estéticas 1.19): fila compacta de la vista lista —
/// foto pequeña + nombre + precio + Vender en una fila.
/// 1.30 D5 (UI130-18): UN componente con dos densidades y el
/// mismo esqueleto — foto, nombre, precio con el rol de
/// UI130-03, presentación, el estado como ChipEstado con
/// palabra (ya no solo la opacidad 0,55) y «Vender» como
/// acción única destacada. La fila separa zonas: el cuerpo
/// lleva al detalle y el botón vive en su propia zona (fuera
/// el toque anidado sobre la tarjeta entera). Sin foto
/// propia, la genérica de su clase (ALTA-02), marcada
/// «Foto genérica».
class _TarjetaSuplemento extends StatelessWidget {
  final Map<String, dynamic> sup;
  final VoidCallback onVender;
  final VoidCallback onTap;
  // Ronda 3-9 #8: tasa para el equivalente CUP en USD.
  final double? tasaUsd;
  final String? categoriaNombre;
  final bool esFila;

  const _TarjetaSuplemento({
    super.key,
    required this.sup,
    required this.onVender,
    required this.onTap,
    this.tasaUsd,
    this.categoriaNombre,
  }) : esFila = false;

  const _TarjetaSuplemento.fila({
    super.key,
    required this.sup,
    required this.onVender,
    required this.onTap,
    this.tasaUsd,
    this.categoriaNombre,
  }) : esFila = true;

  String get _nombre => '${sup['nombre'] ?? 'Sin nombre'}';

  int get _stock => (sup['stock'] as num?)?.toInt() ?? 0;

  // B3 (Argón): el precio mostrado es SIEMPRE precio_oficial
  // (fallback legacy a `precio`); ultimo_precio no se usa.
  // 1.36 H-B3 (136-767): pasa por el helper único
  // precioVisibleSuplemento (0 cuando no hay precio).
  double get _precio => precioVisibleSuplemento(sup).precio ?? 0;

  // Lógica tolerante (igual que _compartirCatalogo): 'activo'
  // puede venir como int, bool o faltar (null) sin romper ni
  // marcar falso "Agotado".
  bool get _inactivo {
    final act = sup['activo'];
    return act == 0 ||
        act == false ||
        sup['eliminado'] == 1 ||
        sup['eliminado'] == true;
  }

  bool get _hayStock => _stock > 0 && !_inactivo;

  bool get _sinFoto => supSinFotoPropia(sup);

  String? get _assetGenerica => _sinFoto
      ? assetFotoGenericaSuplemento(_nombre, categoria: categoriaNombre)
      : null;

  /// El precio con el rol de UI130-03 (D1): la cifra
  /// protagonista en el texto de marca accesible y la moneda
  /// como metadato (la rejilla lo llevaba aún a pelo, en
  /// AppColores.naranja: 2,52 en claro).
  Widget _precioTexto(BuildContext context, {int? maxLines}) {
    // 1.36 H-B3 (136-767): sin precio visible, «Consultar
    // precio» (la frase de compartir) — nunca «0.00 CUP».
    if (precioVisibleSuplemento(sup).precio == null) {
      return Text(
        'Consultar precio',
        style: AppTexto.secundario
            .copyWith(color: AppColores.textoSecundario(context)),
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
      );
    }
    final moneda = LocalDb.monedaDe(sup);
    // Ronda 3-9 #8: en USD, equivalente CUP redondeado.
    final cup = moneda == 'USD' ? precioOficialEn('CUP', _precio, tasaUsd) : null;
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: _precio.toStringAsFixed(2),
          style: AppTexto.subtitulo.copyWith(
            fontWeight: FontWeight.bold,
            color: AppColores.textoNaranja(context),
          ),
        ),
        TextSpan(
          text: ' $moneda'
              '${cup != null ? ' (≈ ${cup.toStringAsFixed(0)} CUP)' : ''}',
          style: AppTexto.metadato
              .copyWith(color: AppColores.textoSecundario(context)),
        ),
      ]),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }

  /// El estado del stock como chip con palabra (la regla
  /// única de negocio), cuando no está simplemente
  /// disponible.
  Widget? _chipStock() {
    final estado = estadoStockSuplemento(sup);
    if (estado == EstadoStockSuplemento.disponible) return null;
    return ChipEstado.semantico(
      texto: textoEstadoStock(sup),
      significado: switch (estado) {
        EstadoStockSuplemento.inactivo => SignificadoChip.agotado,
        EstadoStockSuplemento.agotado => SignificadoChip.error,
        EstadoStockSuplemento.bajo => SignificadoChip.alerta,
        EstadoStockSuplemento.disponible => SignificadoChip.exito,
      },
    );
  }

  Widget _botonVender({required bool expandido}) => BotonPrimario(
        texto: _hayStock
            ? 'Vender'
            : _inactivo
                ? 'Inactivo'
                : 'Sin stock',
        onPressed: _hayStock ? onVender : null,
        expandido: expandido,
      );

  /// La marca de la foto genérica en la rejilla: pastilla
  /// flotante, como el badge de stock.
  /// 1.36 H-B3 (136-769): el par inverso del tema
  /// (inverseSurface/onInverseSurface), pensado para
  /// flotar sobre contenido en ambos temas — fuera el
  /// black87/white fijos.
  Widget _marcaGenerica() => Builder(builder: (context) {
        final esquema = Theme.of(context).colorScheme;
        return Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
          decoration: BoxDecoration(
            color: esquema.inverseSurface,
            borderRadius: BorderRadius.circular(AppRadio.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_library_outlined,
                  size: 11, color: esquema.onInverseSurface),
              const SizedBox(width: 4),
              Text('Foto genérica',
                  style: AppTexto.minuscula.copyWith(
                      color: esquema.onInverseSurface,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        );
      });

  Widget _buildFila(BuildContext context) {
    final presentacion = textoPresentacion(sup);
    final chip = _chipStock();
    // 1.36 H-B3 (136-769): fuera el Opacity 0.55 de SU3 — a
    // media opacidad bajaba el contraste de nombre, precio,
    // chip y botón; el estado ya lo dicen el chip con
    // palabra y el botón deshabilitado («Sin stock»).
    return Tarjeta(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadio.lg),
          child: Material(
            type: MaterialType.transparency,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Zona del cuerpo: foto + datos → detalle.
                Expanded(
                  child: InkWell(
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppEspacio.md,
                          vertical: AppEspacio.sm),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 56,
                            height: 56,
                            child: ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(AppRadio.sm),
                              child: _FotoSuplemento(
                                  sup: sup, assetGenerica: _assetGenerica),
                            ),
                          ),
                          const SizedBox(width: AppEspacio.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _nombre,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTexto.secundario.copyWith(
                                      fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                _precioTexto(context),
                                if (presentacion.isNotEmpty)
                                  Text(
                                    presentacion,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTexto.minuscula.copyWith(
                                      color: AppColores.textoSecundario(
                                          context),
                                    ),
                                  ),
                                if (chip != null) ...[
                                  const SizedBox(height: 4),
                                  chip,
                                ],
                                if (_sinFoto) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    'Foto genérica',
                                    style: AppTexto.minuscula.copyWith(
                                      color: AppColores.textoSecundario(
                                          context),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 1.36 H-B3 (136-769): el separador se
                // estira con la fila (antes 64 fijos: con
                // nombre de 2 líneas + chip quedaba corto).
                Container(width: 1, color: AppColores.borde(context)),
                // Zona de la acción: «Vender», única y destacada.
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.md),
                  child: Center(child: _botonVender(expandido: false)),
                ),
              ],
            ),
          ),
        ),
    );
  }

  Widget _buildRejilla(BuildContext context) {
    final presentacion = textoPresentacion(sup);
    final chip = _chipStock();
    // 1.36 H-B3 (136-769): fuera el Opacity 0.55 (contraste)
    // y el borde white10/black12 a pelo: el token de borde
    // de la casa, como el resto de tarjetas.
    return Card(
        elevation: 2,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.md),
          side: BorderSide(
            color: AppColores.borde(context),
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
                    _FotoSuplemento(sup: sup, assetGenerica: _assetGenerica),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _BadgeStock(sup: sup),
                    ),
                    if (_sinFoto)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: _marcaGenerica(),
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
                      // 1.25 T120 (F4-07): el nombre va a UNA
                      // línea en la cuadrícula — la celda la
                      // dimensiona altoCeldaCatalogo (D5) para
                      // el peor caso a la escala vigente; el
                      // nombre completo se ve en la vista de
                      // lista y en el detalle.
                      Text(
                        _nombre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTexto.secundario
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      // 1.36 (136-308/317): 2 líneas — con 1, la elipsis
                      // se comía el equivalente en CUP (el dato
                      // de decisión).
                      _precioTexto(context, maxLines: 2),
                      if (presentacion.isNotEmpty)
                        Text(
                          presentacion,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTexto.minuscula.copyWith(
                            color: AppColores.textoSecundario(context),
                          ),
                        ),
                      if (chip != null) ...[
                        const SizedBox(height: 4),
                        chip,
                      ],
                      const Spacer(),
                      // SU1 (estéticas 1.19): botón de venta con
                      // el estilo primario del sistema.
                      _botonVender(expandido: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      esFila ? _buildFila(context) : _buildRejilla(context);
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

  // 1.35 (UI-14): el placeholder compartido de la casa.
  Widget _sinFoto(BuildContext context) =>
      const PlaceholderSuplemento();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        // 1.36 H-B3 (136-769): «Más vendidos» enseña lo
        // mismo que el catálogo — mientras resuelve, el
        // shimmer de la casa (antes salía el placeholder
        // final y parpadeaba); sin foto propia, la genérica
        // de su clase (antes nunca llegaba aquí).
        if (snap.connectionState == ConnectionState.waiting) {
          return const _ShimmerFoto();
        }
        final f = snap.data;
        if (f == null) {
          if (supSinFotoPropia(widget.sup)) {
            return Image(
                image: providerFotoAcotada(
                    AssetImage(assetFotoGenericaSuplemento(
                        '${widget.sup['nombre'] ?? ''}')),
                    ancho: 1080),
                height: 64,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _sinFoto(ctx));
          }
          return _sinFoto(ctx);
        }
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

  /// 1.30 D5 (UI130-18, ALTA-02): foto genérica de la clase
  /// del producto, para cuando no hay foto propia que
  /// resolver (la tarjeta la marca «Foto genérica»).
  final String? assetGenerica;
  const _FotoSuplemento({required this.sup, this.assetGenerica});

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
    // 1.34 Campo 2 (P-1): la decodificación va ACOTADA al
    // ancho físico real del hueco (56 dp en fila; la tarjeta
    // de rejilla a su ancho de layout). Antes la foto del
    // producto se decodificaba a resolución completa en cada
    // tarjeta: culpable directo de los tirones del catálogo.
    return LayoutBuilder(
      builder: (ctx, cons) {
        final ancho = (cons.maxWidth *
                MediaQuery.devicePixelRatioOf(ctx))
            .ceil()
            .clamp(56, 1440);
        return FutureBuilder<File?>(
          future: _futura,
          builder: (ctx2, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const _ShimmerFoto();
            }
            final f = snap.data;
            if (f != null) {
              return Image(
                image: providerFotoAcotada(FileImage(f), ancho: ancho),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                      // SL-6 (G05-13): la marca única de la casa.
                      const PlaceholderSuplemento(alto: null, radio: 0),
              );
            }
            // 1.30 D5 (UI130-18, ALTA-02): sin foto propia, la
            // genérica de su clase (la tarjeta la marca como
            // genérica); si ni eso, el placeholder de siempre.
            final generica = widget.assetGenerica;
            if (generica != null) {
              return Image(
                image:
                    providerFotoAcotada(AssetImage(generica), ancho: ancho),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                      // SL-6 (G05-13): la marca única de la casa.
                      const PlaceholderSuplemento(alto: null, radio: 0),
              );
            }
            return const PlaceholderSuplemento(alto: null, radio: 0);
          },
        );
      },
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
      // 1.35 (UI-13): período del pulso en bucle, no una
      // transición: fuera de los tokens a propósito.
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
      child: const PlaceholderSuplemento(alto: null, radio: 0),
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
    // 1.36 H-B3 (136-769): pastilla con el par inverso del
    // tema (flota sobre la foto en claro y en oscuro) y el
    // punto de inactivo con el color de su superficie —
    // fuera black87/white/grey fijos.
    final esquema = Theme.of(context).colorScheme;
    final Color punto = switch (estadoStockSuplemento(sup)) {
      EstadoStockSuplemento.agotado => AppColores.error,
      EstadoStockSuplemento.bajo => AppColores.alerta,
      EstadoStockSuplemento.disponible => AppColores.exito,
      EstadoStockSuplemento.inactivo => esquema.onInverseSurface,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
      decoration: BoxDecoration(
        color: esquema.inverseSurface,
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
              color: esquema.onInverseSurface,
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
  // 1.36 H-B3 (136-769): mientras las categorías cargan, el
  // hueco del selector se reserva (antes aparecía de golpe
  // tras el async y la pantalla saltaba).
  bool _cargandoCategorias = true;
  // 1.36 H-B3 (136-771): focos de los campos validables —
  // el diálogo de validación ahora ADEMÁS lleva al campo
  // culpable al cerrarse.
  final _focoNombre = FocusNode();
  final _focoPrecio = FocusNode();
  final _focoStock = FocusNode();
  final _focoCosto = FocusNode();
  final _focoUmbral = FocusNode();
  final _focoPeso = FocusNode();
  final _focoServicios = FocusNode();
  // 1.36 H-B3 (136-771): foto de los valores al abrir, para
  // pedir confirmación si se sale con cambios sin guardar
  // (antes el back los descartaba en silencio).
  String _iniNombre = '';
  String _iniDesc = '';
  String _iniPrecio = '';
  String _iniStock = '';
  String _iniCosto = '';
  String _iniUmbral = '';
  String _iniPesoValor = '';
  String _iniServicios = '';
  String? _iniPesoUnidad;
  int? _iniCategoriaId;
  bool _iniActivo = true;
  bool _permitirSalida = false;

  bool _hayCambiosSinGuardar() {
    return _nombre.text != _iniNombre ||
        _desc.text != _iniDesc ||
        _precio.text != _iniPrecio ||
        _stock.text != _iniStock ||
        _costo.text != _iniCosto ||
        _umbral.text != _iniUmbral ||
        _pesoValor.text != _iniPesoValor ||
        _servicios.text != _iniServicios ||
        _pesoUnidad != _iniPesoUnidad ||
        _moneda != _monedaIni ||
        _categoriaId != _iniCategoriaId ||
        _activo != _iniActivo ||
        _fotoNueva != null;
  }

  /// Salida del editor marcando la PopScope como libre y
  /// saliendo en el siguiente frame (con el resultado que
  /// toque: true si se guardó).
  void _salirEditor([Object? resultado]) {
    setState(() => _permitirSalida = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(resultado);
    });
  }

  Future<void> _alIntentarSalir() async {
    if (!_hayCambiosSinGuardar()) {
      _salirEditor();
      return;
    }
    final salir = await DialogoApp.confirmar(context,
        titulo: 'Descartar cambios',
        mensaje:
            'Tienes cambios sin guardar en este suplemento. '
            'Si sales ahora, se pierden.',
        aceptar: 'Descartar',
        cancelar: 'Seguir editando',
        peligro: true);
    if (salir && mounted) _salirEditor();
  }

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
    // 1.36 H-B3 (136-771): la foto de valores iniciales se
    // toma con el formulario YA llenado (crear, editar o
    // duplicar): salir sin tocar nada no pide confirmación.
    _iniNombre = _nombre.text;
    _iniDesc = _desc.text;
    _iniPrecio = _precio.text;
    _iniStock = _stock.text;
    _iniCosto = _costo.text;
    _iniUmbral = _umbral.text;
    _iniPesoValor = _pesoValor.text;
    _iniServicios = _servicios.text;
    _iniPesoUnidad = _pesoUnidad;
    _iniCategoriaId = _categoriaId;
    _iniActivo = _activo;
    _cargarCategorias();
  }

  Future<void> _cargarCategorias() async {
    List<Map<String, dynamic>> cats;
    try {
      cats = await LocalDb.instance.allMirror('categorias_suplemento');
    } catch (e) {
      AppLog.error('ui', 'editor_categorias_fallo', d: '$e');
      if (mounted) setState(() => _cargandoCategorias = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _cargandoCategorias = false;
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
    // 1.36 H-B3 (136-771): los nodos de foco también.
    _focoNombre.dispose();
    _focoPrecio.dispose();
    _focoStock.dispose();
    _focoCosto.dispose();
    _focoUmbral.dispose();
    _focoPeso.dispose();
    _focoServicios.dispose();
    super.dispose();
  }

  Future<void> _elegirFoto() async {
    // Cierre §17 (×10): por la vía segura de la casa
    // (foto_elegir.dart) — try/catch con aviso visible,
    // recuperación con retrieveLostData y guarda
    // anti-doble-toque. Antes era un pickImage pelado: el
    // patrón exacto del fallo de campo 2026-11-07 (un
    // selector colgado mataba en silencio todo toque
    // posterior de foto en esta pantalla).
    final img = await elegirFotoSegura(
      context,
      origen: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 75, // Gemini: compresión obligatoria para Cuba
    );
    if (img == null || !mounted) return;
    try {
      final bytes = await img.readAsBytes();
      if (mounted) {
        setState(() {
          _fotoNueva = bytes;
          _fotoNuevaPath = img.path;
        });
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo leer la foto: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _guardar() async {
    // Ronda 3-9 #10: editar el catálogo es solo del dueño (la UI
    // ya oculta el botón; esto frena un cambio de sesión a mitad).
    if (!AuthService().isOwner) return;
    final nombre = _nombre.text.trim();
    final precio = double.tryParse(
        _precio.text.trim().replaceAll(',', '.'));
    // El stock se lee de su parseo ESTRICTO de abajo
    // (stockParse): el blando con «?? 0» traducía en
    // silencio un texto no numérico a stock 0.
    if (nombre.isEmpty || precio == null || !precio.isFinite || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa los datos',
          mensaje:
              'El nombre y un precio oficial mayor que 0 son obligatorios.',
          aceptar: 'Entendido',
          cancelar: '');
      // 1.36 H-B3 (136-771): el aviso lleva al campo.
      if (mounted) {
        (nombre.isEmpty ? _focoNombre : _focoPrecio).requestFocus();
      }
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
      if (mounted) _focoStock.requestFocus();
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
        if (mounted) _focoPeso.requestFocus();
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
        if (mounted) _focoServicios.requestFocus();
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
      if (mounted) _focoPeso.requestFocus();
      return;
    }
    // 1.36 H-B3 (136-768): el umbral sigue la MISMA
    // doctrina estricta que el stock: un texto no vacío no
    // interpretable («5.0») o negativo es ERROR visible —
    // antes caía en silencio al 3 por defecto y el dueño
    // creía haber fijado otro umbral.
    final umbralTxt = _umbral.text.trim();
    final umbralParse = int.tryParse(umbralTxt);
    if ((umbralTxt.isNotEmpty && umbralParse == null) ||
        (umbralParse != null && umbralParse < 0)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el umbral',
          mensaje:
              'El umbral de stock bajo debe ser un número entero de 0 en adelante, o el campo vacío.',
          aceptar: 'Entendido',
          cancelar: '');
      if (mounted) _focoUmbral.requestFocus();
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
          if (mounted) _focoCosto.requestFocus();
          return;
        }
      }
      // Validado ANTES del try (136-768): vacío = 3 por
      // defecto legítimo; texto válido manda tal cual.
      final umbral = umbralParse ?? 3;
      // G#6 (Hy4): red al cambiar la moneda de un suplemento
      // existente — el precio NO se reconvierte solo: unos
      // 3000 CUP pasarían a ser 3000 USD. Antes de encolar
      // se confirma en voz alta, con el número que se
      // conserva y las dos monedas (el aviso breve
      // post-guardado de v1.4.6 llegaba con la op ya
      // encolada y sin mencionar el número).
      if (_editando && _moneda != _monedaIni) {
        final sigue = await DialogoApp.confirmar(context,
            titulo: 'Cambiaste la moneda',
            mensaje:
                'El precio oficial seguirá siendo '
                '${fmtMonto(precio)} pero en $_moneda '
                '(antes era $_monedaIni): el número NO se '
                'convierte solo. Si también querías cambiar '
                'el precio, cancela y ajústalo.',
            aceptar: 'Guardar así',
            cancelar: 'Cancelar');
        if (!sigue || !mounted) return;
      }
      final payload = {
        'nombre': nombre,
        'descripcion': _desc.text.trim(),
        'precio_oficial': precio,
        // v1.4.6: moneda del precio oficial; viaja siempre en la
        // op (crear y editar) para que el servidor la persista.
        'moneda': _moneda,
        // El stock VALIDADO arriba (136-768), no el parseo
        // blando inicial.
        'stock': stockParse ?? 0,
        'activo': _activo ? 1 : 0,
        // v1.2.1: categoría asignada.
        if (_categoriaId != null) 'categoria_id': _categoriaId,
        if (_editando) 'suplemento_id': widget.suplemento!['id'],
        // v1.3.7: costo solo lo envía el dueño (el campo UI ya lo
        // restringe); umbral siempre.
        if (AuthService().isOwner && costo != null && costo >= 0)
          'costo': costo,
        'umbral_stock': umbral,
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
      if (mounted) _salirEditor(true);
    } catch (e) {
      // 1.36 H-B3 (136-768): encolar el suplemento o su
      // foto puede fallar — el dueño lo VE y el formulario
      // queda abierto con sus datos (antes solo había
      // finally: la pantalla volvía sin guardar y sin
      // decir nada, y el error no quedaba ni en bitácora
      // desde esta pantalla).
      AppLog.error('ui', 'guardar_suplemento_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context,
            'No se pudo guardar: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
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
    // 1.36 H-B3 (136-771): salir con cambios sin guardar
    // pide confirmación (PopScope + foto de valores de
    // _hayCambiosSinGuardar); sin cambios, sale directo.
    return PopScope(
      canPop: _permitirSalida,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _alIntentarSalir();
      },
      child: Scaffold(
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
          const EncabezadoSeccion(
              titulo: 'Identificación',
              variante: VarianteEncabezado.pagina),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  // 1.36 H-B3 (136-769): la foto era un
                  // GestureDetector pelado — el lector de
                  // pantalla no la anunciaba como botón.
                  child: Semantics(
                    button: true,
                    label: _editando
                        ? 'Cambiar foto del suplemento'
                        : 'Agregar foto del suplemento',
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
                    _fotoNueva == null &&
                    widget.suplemento?['id'] is num) ...[
                  const SizedBox(height: AppEspacio.sm),
                  // 1.36 H-B3 (136-768): el aviso se decide
                  // por la cola real de fotos, no solo por
                  // foto_local (ver ChipFotoPendienteSuplemento).
                  Center(
                    child: ChipFotoPendienteSuplemento(
                        suplementoId:
                            (widget.suplemento!['id'] as num).toInt()),
                  ),
                ],
                const SizedBox(height: AppEspacio.md),
                CampoTexto(
                    controller: _nombre,
                    focusNode: _focoNombre,
                    etiqueta: 'Nombre',
                    hint: 'Ej. Creatina Monohidrato 500g'),
                const SizedBox(height: AppEspacio.md),
                CampoTexto(
                    controller: _desc,
                    etiqueta: 'Descripción (opcional)',
                    maxLineas: 2),
                // 1.36 H-B3 (136-769): mientras las
                // categorías cargan, el hueco se reserva con
                // su indicador — el selector ya no aparece
                // de golpe empujando el formulario.
                if (_categorias.isEmpty && _cargandoCategorias) ...[
                  const SizedBox(height: AppEspacio.md),
                  const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: AppEspacio.sm),
                      Text('Cargando categorías…',
                          style: AppTexto.secundario),
                    ],
                  ),
                ],
                // v1.2.1: selector de categoría.
                if (_categorias.isNotEmpty) ...[
                  const SizedBox(height: AppEspacio.md),
                  SelectorIronForm<int?>(
                    valorInicial: _categoriaId,
                    etiqueta: 'Categoría',
                    opciones: [
                      const OpcionSelector<int?>(
                        null,
                        'Sin categoría',
                      ),
                      for (final c in _categorias)
                        OpcionSelector<int?>(
                          c['id'] as int?,
                          '${c['nombre']}${(c['activa'] as int?) == 0 ? ' (inactiva)' : ''}',
                        ),
                    ],
                    alCambiar: (v) =>
                        setState(() => _categoriaId = v),
                  ),
                ],
              ],
            ),
          ),
          const EncabezadoSeccion(
              titulo: 'Presentación del envase',
              variante: VarianteEncabezado.pagina),
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
                          focusNode: _focoPeso,
                          etiqueta: 'Contenido del envase',
                          hint: 'Ej. 300',
                          teclado:
                              const TextInputType.numberWithOptions(
                                  decimal: true)),
                    ),
                    const SizedBox(width: AppEspacio.md),
                    Expanded(
                      child: SelectorIronForm<String?>(
                        valorInicial: _pesoUnidad,
                        etiqueta: 'Unidad',
                        opciones: [
                          const OpcionSelector<String?>(
                            null,
                            '—',
                          ),
                          for (final u in _unidadesEnvase)
                            OpcionSelector<String?>(u, u),
                          // Si el dato guardado trae una unidad fuera de
                          // la lista, se incluye para no romper el
                          // selector (mismo arreglo que en Categoría).
                          if (_pesoUnidad != null &&
                              !_unidadesEnvase.contains(_pesoUnidad))
                            OpcionSelector<String?>(
                              _pesoUnidad,
                              _pesoUnidad!,
                            ),
                        ],
                        alCambiar: (v) =>
                            setState(() => _pesoUnidad = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppEspacio.sm),
                CampoTexto(
                    controller: _servicios,
                    focusNode: _focoServicios,
                    etiqueta: 'Servicios por envase (opcional)',
                    hint: 'Ej. 60',
                    teclado: TextInputType.number),
              ],
            ),
          ),
          const EncabezadoSeccion(
              titulo: 'Precio',
              variante: VarianteEncabezado.pagina),
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
                          focusNode: _focoPrecio,
                          etiqueta: 'Precio oficial ($_moneda)',
                          teclado:
                              const TextInputType.numberWithOptions(
                                  decimal: true)),
                    ),
                    const SizedBox(width: AppEspacio.md),
                    // v1.4.6: selector de moneda del precio oficial.
                    Expanded(
                      flex: 2,
                      child: SelectorIronForm<String>(
                        valorInicial: _moneda,
                        etiqueta: 'Moneda',
                        opciones: const [
                          OpcionSelector('CUP', 'CUP'),
                          OpcionSelector('USD', 'USD'),
                        ],
                        alCambiar: (v) =>
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
                      focusNode: _focoCosto,
                      etiqueta: 'Costo por unidad (USD)',
                      teclado:
                          const TextInputType.numberWithOptions(
                              decimal: true)),
                ],
              ],
            ),
          ),
          const EncabezadoSeccion(
              titulo: 'Inventario',
              variante: VarianteEncabezado.pagina),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CampoTexto(
                    controller: _stock,
                    focusNode: _focoStock,
                    etiqueta: 'Stock',
                    teclado: TextInputType.number),
                const SizedBox(height: AppEspacio.sm),
                CampoTexto(
                    controller: _umbral,
                    focusNode: _focoUmbral,
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
      ),
    );
  }
}

/// 1.34 (C-48 · G-07): las opciones del filtro de stock y
/// su etiqueta legible (las palabras que llevaban los chips
/// antes del plegado).
const opcionesFiltroStock = <(String, String)>[
  ('todos', 'Todos'),
  ('con_stock', 'Con stock'),
  ('bajo', 'Stock bajo'),
  ('agotado', 'Agotados'),
];

String etiquetaFiltroStock(String clave) {
  for (final f in opcionesFiltroStock) {
    if (f.$1 == clave) return f.$2;
  }
  return 'Todos';
}
