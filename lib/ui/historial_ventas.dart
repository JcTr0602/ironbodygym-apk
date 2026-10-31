// Historial de ventas de suplementos.
//
// - Dueño: ve todas las ventas (quién vendió qué, cuándo, a cuánto).
// - Entrenador (v1.2.1, `soloMias: true`): ve solo SU propio historial.
// Las ventas con precio diferente al oficial se destacan en ámbar.
// Totales separados por moneda (CUP y USD no se mezclan).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../negocio.dart';
import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../cliente_protegido.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

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
    if ((v['moneda'] as String?) == 'USD') {
      usd += total;
    } else {
      cup += total;
    }
  }
  return (cup: cup, usd: usd);
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
  // Cliente protegido (2026-10-26, A5): mapa para resolver el
  // candado del comprador en cada fila (el espejo ya lo trae).
  Map<int, Map<String, dynamic>> _clientes = {};
  bool _cargando = true;
  // Resaltado (4/25): id + llave por fila para desplazar a la venta.
  int? _resaltado;
  final _llaves = <int, GlobalKey>{};
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
    super.dispose();
  }

  List<Map<String, dynamic>> get _ventasFiltradas =>
      filtrarVentasHistorial(
        ventas: _ventas,
        productos: _productos,
        texto: _texto,
        productoId: _productoId,
        moneda: _moneda,
        desde: _desde,
        hasta: _hasta,
      );

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
    });
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
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
    if (!mounted) return;
    setState(() {
      _ventas = ventas;
      _productos = mapa;
      _clientes = mapaClientes;
      _cargando = false;
    });
    if (widget.resaltarId != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _irAResaltado());
    }
  }

  /// Desplaza a la venta resaltada y la tiñe (4/25). Si no está en la
  /// lista (p. ej. otro entrenador con soloMias), no hace nada.
  void _irAResaltado() {
    final id = widget.resaltarId;
    if (id == null || !mounted) return;
    final ctx = _llaves[id]?.currentContext;
    if (ctx == null) return;
    setState(() => _resaltado = id);
    Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 400), alignment: 0.5);
  }

  Future<void> _anular(Map<String, dynamic> v) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Anular venta',
      icono: Icons.undo,
      peligro: true,
      mensaje: 'Se anulará esta venta y se restaurará el stock. '
          '¿Continuar?',
      aceptar: 'Anular venta',
    );
    if (!ok) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'anular_venta_suplemento',
      payload: {'venta_id': v['id']},
    );
    unawaited(SyncEngine.instance.push());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Venta anulada (se sincronizará)')));
      _cargar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              widget.soloMias ? 'Mis ventas' : 'Ventas de suplementos')),
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
        icono: Icons.receipt_long_outlined,
        titulo: 'Sin ventas registradas',
        subtitulo:
            'Las ventas de suplementos aparecerán aquí.',
      );
    }
    final filtradas = _ventasFiltradas;
    if (filtradas.isEmpty) {
      return EstadoVacio(
        icono: Icons.search_off_outlined,
        titulo: 'Sin ventas con esos filtros',
        subtitulo: 'Prueba con otro texto, producto o fecha.',
        textoAccion: _hayFiltros ? 'Limpiar filtros' : null,
        onAccion: _hayFiltros ? _limpiarFiltros : null,
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppEspacio.md),
        itemCount: filtradas.length,
        itemBuilder: (ctx, i) => _fila(filtradas[i]),
      ),
    );
  }

  /// Controles de filtro (3/25): buscador, producto, moneda y rango
  /// de fechas. Los totales de arriba ya reflejan lo filtrado.
  Widget _filtros() {
    final productos = _productos.values.toList()
      ..sort((a, b) =>
          '${a['nombre'] ?? ''}'.compareTo('${b['nombre'] ?? ''}'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _textoCtrl,
            onChanged: (v) => setState(() => _texto = v),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Buscar producto, cliente o vendedor…',
              suffixIcon: _texto.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _textoCtrl.clear();
                        setState(() => _texto = '');
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
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              Expanded(
                child: DropdownButton<int?>(
                  value: _productoId,
                  isExpanded: true,
                  hint: const Text('Todos los productos'),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('Todos los productos'),
                    ),
                    for (final p in productos)
                      DropdownMenuItem<int?>(
                        value: (p['id'] as num?)?.toInt(),
                        child: Text('${p['nombre'] ?? 'Producto'}'),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _productoId = v),
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              ChoiceChip(
                label: const Text('CUP'),
                selected: _moneda == 'CUP',
                onSelected: (_) => setState(
                    () => _moneda = _moneda == 'CUP' ? null : 'CUP'),
              ),
              const SizedBox(width: 4),
              ChoiceChip(
                label: const Text('USD'),
                selected: _moneda == 'USD',
                onSelected: (_) => setState(
                    () => _moneda = _moneda == 'USD' ? null : 'USD'),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_desde == null
                      ? 'Desde…'
                      : 'Desde $_desde'),
                  onPressed: () => _elegirFecha(esDesde: true),
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(
                      _hasta == null ? 'Hasta…' : 'Hasta $_hasta'),
                  onPressed: () => _elegirFecha(esDesde: false),
                ),
              ),
              if (_hayFiltros)
                TextButton(
                  onPressed: _limpiarFiltros,
                  child: const Text('Limpiar'),
                ),
            ],
          ),
        ],
      ),
    );
  }

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
                      icono: Icons.person_add),
                if (difiere && !ventaProtegida)
                  const ChipEstado(
                      texto: 'Precio diferente',
                      color: AppColores.alerta,
                      icono: Icons.warning_amber),
                // v1.2.1: anular es acción del dueño.
                if (AuthService().isOwner)
                  IconButton(
                    icon: const Icon(Icons.undo,
                        color: AppColores.error, size: 20),
                    tooltip: 'Anular venta',
                    onPressed: () => _anular(v),
                  ),
                // 13/25: recibo por WhatsApp (dueño; nunca en
                // ventas protegidas, cuyo total/fecha la lista
                // oculta a propósito).
                if (AuthService().isOwner && !ventaProtegida)
                  IconButton(
                    icon: const Icon(Icons.receipt_long,
                        color: AppColores.naranja, size: 20),
                    tooltip: 'Recibo por WhatsApp',
                    onPressed: () => _recibo(v),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // Cliente protegido (2026-10-26, Protegido 2 residual
            // #9): la tarjeta no muestra fecha ni total de la venta
            // (quedan producto + comprador + candado).
            if (!ventaProtegida)
              Text(
                lineaTotal,
                style: AppTexto.cuerpo,
              ),
            if (nota.isNotEmpty && !ventaProtegida)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    const Icon(Icons.sticky_note_2_outlined,
                        size: 13, color: Colors.grey),
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
                  const Icon(Icons.lock,
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
    final telCliente =
        cid != null ? '${_clientes[cid]?['telefono'] ?? ''}' : '';
    final waNum = normalizarTelefonoWaMe(telCliente);
    // El campo guarda 8 dígitos (como el resto de la app); el 53
    // va solo al armar el wa.me (igual que en ficha.dart).
    final telCtrl = TextEditingController(
        text: waNum.length == 10 ? waNum.substring(2) : '');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Recibo por WhatsApp',
        iconoTitulo: Icons.receipt_long,
        contenido: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(texto.replaceAll('*', '')),
              const SizedBox(height: 12),
              TextField(
                controller: telCtrl,
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('Enviar por WhatsApp'),
            onPressed: () async {
              final num =
                  normalizarTelefonoWaMe(telCtrl.text.trim());
              if (num.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                      content: Text('Escribe un móvil válido')),
                );
                return;
              }
              final url = Uri.parse(
                  'https://wa.me/$num?text=${Uri.encodeComponent(texto)}');
              try {
                await launchUrl(url,
                    mode: LaunchMode.externalApplication);
              } catch (_) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                        content: Text('No se pudo abrir WhatsApp')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  /// Detalle expandido de una venta con inscripción: dos bloques,
  /// "Cliente" (del espejo local si ya sincronizó) y "Venta".
  Future<void> _detalle(Map<String, dynamic> v) async {
    Map<String, dynamic>? cliente;
    final cid = (v['cliente_id'] as num?)?.toInt();
    if (cid != null) {
      final todos =
          await LocalDb.instance.allMirror('clientes');
      for (final c in todos) {
        if ((c['id'] as num?)?.toInt() == cid) {
          cliente = c;
          break;
        }
      }
    }
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
          padding: const EdgeInsets.only(bottom: 4),
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
        iconoTitulo: Icons.person_add,
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
                    Icon(Icons.lock,
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
              const SizedBox(height: AppEspacio.md),
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
