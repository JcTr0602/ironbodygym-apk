/// Centro de Compras y Extracto (E4, Bloque 2 NÚCLEO, 1.10.0,
/// EXTENDIDO en 1.13.0, Bloque 4: la vista de ventas SE LLAMA
/// Extracto y muestra el nombre visible del producto en cada fila
/// de servicio, sin duplicar el E4).
/// Argón AMARILLO ajuste 5).
///
/// «Un solo sitio» = esta pantalla dentro del Panel. La pantalla
/// operativa de Ventas diarias NO se toca: el turno sigue
/// despachando desde allí.
///
/// El Extracto unifica en LECTURA tres fuentes (sin duplicar nada):
/// - ventas_suplementos (ventas del turno),
/// - servicio_ventas (dosis y servicios del turno),
/// - compras manuales (tabla local `compras`: solo para compras
///   fuera del turno que el dueño registra desde aquí; las ventas
///   del turno ya aparecen solas y NO se vuelven a registrar).
///
/// Filtros: Todo | Suplementos | Servicios. La cabecera muestra
/// SIEMPRE Total General + Subtotal Suplementos + Subtotal Servicios
/// (sobre todas las filas no anuladas, no solo sobre el filtro).
///
/// Correcciones: una compra manual se anula desde aquí con motivo
/// (op anular_compra). Una venta del turno NO se corrige desde aquí:
/// su detalle lo dice y remite a su pantalla (decisión mínima para
/// no duplicar los flujos de reverso que ya existen).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../precio_cobro.dart';
import '../servicios.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'primitivas.dart';
import 'historial_ventas.dart';
import 'servicios_historial.dart';
import '../app_log.dart';

/// 1.25 T93, PURO: ¿la fecha cae en el período elegido
/// del Extracto? 'hoy' | 'semana' (desde el lunes) |
/// 'mes' | 'todo'. Fechas ISO comparables como texto;
/// la semana se calcula con aritmética de fecha pura
/// (sumarDiasIso), nunca con Duration sobre el reloj.
bool filaEnPeriodoExtracto(
    String fechaIso, String periodo, String hoyIso) {
  if (periodo == 'todo') return true;
  final f = fechaIso.length >= 10 ? fechaIso.substring(0, 10) : fechaIso;
  if (f.isEmpty) return false;
  final hoy = DateTime.tryParse(hoyIso);
  switch (periodo) {
    case 'hoy':
      return f == hoyIso;
    case 'semana':
      if (hoy == null) return false;
      final lunes = sumarDiasIso(hoyIso, -(hoy.weekday - 1));
      return f.compareTo(lunes) >= 0 && f.compareTo(hoyIso) <= 0;
    case 'mes':
      return hoyIso.length >= 7 &&
          f.length >= 7 &&
          f.substring(0, 7) == hoyIso.substring(0, 7);
    default:
      return true;
  }
}

/// Destino de «Ir a la venta» desde el Extracto (PURO): la venta del
/// turno se abre en su pantalla (suplementos → Historial de ventas,
/// servicios → Historial de servicios) con su id para resaltarla.
/// Las compras manuales no tienen pantalla de venta: null.
({String pantalla, int id})? destinoVentaExtracto(
    Map<String, dynamic> f) {
  final detalle = f['detalle'];
  if (detalle is! Map<String, dynamic>) return null;
  final id = (detalle['id'] as num?)?.toInt();
  if (id == null) return null;
  switch (f['origen']) {
    case 'suplemento':
      return (pantalla: 'historial_ventas', id: id);
    case 'servicio':
      return (pantalla: 'historial_servicios', id: id);
    default:
      return null;
  }
}

class CentroComprasScreen extends StatefulWidget {
  const CentroComprasScreen({super.key});
  @override
  State<CentroComprasScreen> createState() => _CentroComprasScreenState();
}

class _CentroComprasScreenState extends State<CentroComprasScreen> {
  var _cargando = true;
  var _filtro = 'todo'; // todo | suplemento | servicio
  // 1.25 T93: período y buscador del Extracto. Los
  // totales de la cabecera son LOS DEL PERÍODO (antes
  // «Total general» mezclaba todo el histórico y no
  // servía para cuadrar ningún período).
  var _periodo = 'todo'; // hoy | semana | mes | todo
  final _busquedaCtrl = TextEditingController();
  var _busqueda = '';
  List<Map<String, dynamic>> _filas = [];
  // Suplementos por id: la foto de las filas (T93).
  Map<int, Map<String, dynamic>> _supPorId = {};

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
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
    final ventas =
        await LocalDb.instance.allMirror('ventas_suplementos');
    final servicios =
        await LocalDb.instance.allMirror('servicio_ventas');
    final suplementos =
        await LocalDb.instance.allMirror('suplementos');
    final clientes = await LocalDb.instance.allMirror('clientes');
    // v1.13.0 (Extracto): nombre visible del producto en las filas
    // de servicio (venta → lote → bote → suplemento).
    final lotes =
        await LocalDb.instance.allMirror('servicio_lotes');
    final botes =
        await LocalDb.instance.allMirror('servicio_botes');
    // P2#6: nombre por pomo_id (servicio_pomos), con fallback a
    // lote_id. El nombre no es un conteo de dosis: no afecta al
    // pomo ciego.
    final pomos =
        await LocalDb.instance.allMirror('servicio_pomos');
    final supDePomo = <int, int>{
      for (final p in pomos)
        if ((p['id'] as num?) != null)
          (p['id'] as num).toInt():
              (p['suplemento_id'] as num?)?.toInt() ?? -1,
    };
    final casaIds = <int>{
      for (final c in clientes)
        if (c['cuenta_casa'] == 1 || c['cuenta_casa'] == true)
          if ((c['id'] as num?) != null) (c['id'] as num).toInt(),
    };
    bool esAnulada(Map<String, dynamic> v) =>
        (v['anulada'] as num?)?.toInt() == 1 ||
        v['anulada'] == true ||
        (v['anulado'] as num?)?.toInt() == 1 ||
        v['anulado'] == true ||
        '${v['estado'] ?? ''}' == 'anulada';
    bool esCasa(Map<String, dynamic> v) {
      if ((v['casa'] as num?)?.toInt() == 1 || v['casa'] == true) {
        return true;
      }
      final cid = (v['cliente_id'] as num?)?.toInt() ??
          (v['fiado_cliente_id'] as num?)?.toInt();
      return cid != null && casaIds.contains(cid);
    }
    final boteDeLote = <int, int>{
      for (final l in lotes)
        if ((l['id'] as num?) != null)
          (l['id'] as num).toInt(): (l['bote_id'] as num?)?.toInt() ?? -1,
    };
    final supDeBote = <int, int>{
      for (final b in botes)
        if ((b['id'] as num?) != null)
          (b['id'] as num).toInt():
              (b['suplemento_id'] as num?)?.toInt() ?? -1,
    };
    final nombreSup = <int, String>{};
    for (final s in suplementos) {
      final id = (s['id'] as num?)?.toInt();
      if (id != null) nombreSup[id] = '${s['nombre'] ?? 'Suplemento $id'}';
    }
    final nombreCli = <int, String>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) nombreCli[id] = '${c['nombre'] ?? 'Cliente $id'}';
    }
    final db = await LocalDb.instance.db;
    final manualesRaw = await db.query('compras', orderBy: 'fecha DESC');

    final filas = <Map<String, dynamic>>[];
    for (final v in ventas) {
      // P2#6: fuera anuladas y Casa (antes se fijaba 'anulada': 0
      // ignorando el origen y se sumaban).
      if (esAnulada(v) || esCasa(v)) continue;
      final precio = (v['precio'] as num?)?.toDouble() ?? 0;
      final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
      final total = (v['total'] as num?)?.toDouble() ?? precio * cant;
      final supId = (v['suplemento_id'] as num?)?.toInt();
      final cid = (v['cliente_id'] as num?)?.toInt();
      filas.add({
        'origen': 'suplemento',
        'tipo': 'suplemento',
        'suplemento_id': supId,
        'concepto': supId != null
            ? (nombreSup[supId] ?? 'Suplemento $supId')
            : 'Suplemento',
        'cliente': cid != null
            ? (nombreCli[cid] ?? 'Cliente $cid')
            : '—',
        'monto': total,
        // Corrección 2026-10-26: la venta trae su moneda (el espejo
        // publica la fila entera, moneda incluida). Antes se
        // ignoraba y todo se pintaba CUP.
        'moneda': '${v['moneda'] ?? 'CUP'}',
        'fecha': '${v['fecha'] ?? ''}',
        'anulada': 0,
        'detalle': v,
      });
    }
    // Argón #9 (ALTO parcial): el extracto no suma reversos ni
    // ventas reversadas (ver ventasServicioSinReversos). La pista
    // de auditoría completa sigue en ServiciosScreen.
    for (final v in ventasServicioSinReversos(servicios)) {
      // P2#6: fuera anuladas y Casa, igual que en suplementos.
      if (esAnulada(v) || esCasa(v)) continue;
      final precio = (v['precio_unitario'] as num?)?.toDouble() ?? 0;
      final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
      final cid = (v['cliente_id'] as num?)?.toInt();
      final subtipo = '${v['tipo'] ?? 'servicio'}';
      // P2#6: primero por pomo_id; si no hay pomo, fallback al
      // camino viejo (venta → lote → bote → suplemento).
      final supIdPomo =
          supDePomo[(v['pomo_id'] as num?)?.toInt()];
      final boteId = boteDeLote[(v['lote_id'] as num?)?.toInt()];
      final supId = supIdPomo != null && supIdPomo != -1
          ? supIdPomo
          : (boteId == null ? null : supDeBote[boteId]);
      final nombreProd =
          supId == null ? null : nombreSup[supId];
      final concepto = _conceptoServicio(subtipo, cant);
      filas.add({
        'origen': 'servicio',
        'tipo': 'servicio',
        'suplemento_id': supId,
        'concepto': nombreProd == null
            ? concepto
            : '$concepto · $nombreProd',
        'cliente': '${v['cliente_nombre'] ?? ''}'.isNotEmpty
            ? '${v['cliente_nombre']}'
            : (cid != null ? (nombreCli[cid] ?? 'Cliente $cid') : '—'),
        'monto': precio * cant,
        // Servicios (dosis/agua): servicio_ventas no tiene moneda;
        // sus precios son CUP por diseño.
        'moneda': 'CUP',
        'fecha': '${v['fecha'] ?? ''}',
        'anulada': 0,
        'detalle': v,
      });
    }
    for (final m in manualesRaw) {
      filas.add({
        'origen': 'manual',
        'tipo': '${m['tipo']}',
        'concepto': '${m['concepto']}',
        'cliente': '${m['cliente_nombre'] ?? ''}'.isNotEmpty
            ? '${m['cliente_nombre']}'
            : '—',
        'monto': (m['monto'] as num?)?.toDouble() ?? 0,
        // Compras manuales: el formulario es solo CUP.
        'moneda': 'CUP',
        'fecha': '${m['fecha'] ?? ''}',
        'anulada': (m['anulada'] as int?) ?? 0,
        'idManual': '${m['id']}',
      });
    }
    filas.sort((a, b) =>
        '${b['fecha']}'.compareTo('${a['fecha']}'));
    if (!mounted) return;
    setState(() {
      _filas = filas;
      _supPorId = {
        for (final s in suplementos)
          if ((s['id'] as num?) != null)
            (s['id'] as num).toInt(): s,
      };
      _cargando = false;
    });
  }

  static String _conceptoServicio(String subtipo, int cant) {
    switch (subtipo) {
      case 'dosis_con_agua':
        return 'Dosis con agua (x$cant)';
      case 'dosis_sin_agua':
        return 'Dosis (x$cant)';
      case 'agua_suelta':
        return 'Agua (x$cant)';
      case 'combo':
        // Subtipo legacy: era la dosis con agua.
        return 'Dosis con agua (x$cant)';
      default:
        return 'Servicio (x$cant)';
    }
  }

  /// Las filas del período elegido (sin el filtro de
  /// tipo ni la búsqueda): la base de los totales.
  List<Map<String, dynamic>> get _delPeriodo => _filas
      .where((f) => filaEnPeriodoExtracto(
          '${f['fecha'] ?? ''}', _periodo, hoyHabanaIso()))
      .toList();

  ResumenExtracto get _resumenPeriodo =>
      resumenExtracto(_delPeriodo);

  List<Map<String, dynamic>> get _visibles {
    var out = _delPeriodo;
    if (_filtro != 'todo') {
      out = out.where((f) => f['tipo'] == _filtro).toList();
    }
    final q = _busqueda.trim().toLowerCase();
    if (q.isNotEmpty) {
      out = out
          .where((f) =>
              '${f['concepto'] ?? ''}'
                  .toLowerCase()
                  .contains(q) ||
              '${f['cliente'] ?? ''}'.toLowerCase().contains(q))
          .toList();
    }
    return out;
  }

  String get _nombrePeriodo => switch (_periodo) {
        'hoy' => 'de hoy',
        'semana' => 'de esta semana',
        'mes' => 'de este mes',
        _ => 'general',
      };

  @override
  Widget build(BuildContext context) {
    // P2#6: guarda de dueño en build (antes solo el FAB la tenía).
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Extracto de compras'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      // v1.13.0: la vista de ventas se llama Extracto (E4 extendido,
      // no duplicado). El registro manual de compras sigue aquí.
      appBar: appBarIron(context, 'Extracto de compras'),
      floatingActionButton: AuthService().isOwner
          ? FloatingActionButton.extended(
              onPressed: () async {
                await _registrarManual(context);
                _cargar();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Registrar compra'),
            )
          : null,
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando compras…')
          : RefreshIndicator(
              onRefresh: _cargar,
              child: Column(
                children: [
                  _cabecera(),
                  _filtros(),
                  Expanded(
                    child: _visibles.isEmpty
                        ? const Center(
                            child: Text('Sin compras para este filtro.',
                                style: AppTexto.secundario))
                        : ListView(
                            padding: const EdgeInsets.all(AppEspacio.lg),
                            children: [
                              for (final f in _visibles)
                                _filaCompra(f),
                            ],
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _cabecera() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        color: AppColores.naranja.withValues(alpha: 0.10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                _periodo == 'todo'
                    ? 'Total general: ${textoMontosPorMoneda(_resumenPeriodo.total)}'
                    : 'Total $_nombrePeriodo: ${textoMontosPorMoneda(_resumenPeriodo.total)}',
                style: AppTexto.titulo),
            const SizedBox(height: 4),
            Text(
                'Subtotal Suplementos: '
                '${textoMontosPorMoneda(_resumenPeriodo.suplementos)} · '
                'Subtotal Servicios: '
                '${textoMontosPorMoneda(_resumenPeriodo.servicios)}',
                style: AppTexto.cuerpo),
            const Text(
              'Las anuladas no suman. Los totales son del período '
              'elegido (el filtro de tipo y la búsqueda solo '
              'recortan la lista). Las ventas del turno aparecen '
              'solas; desde aquí solo se registran compras fuera '
              'del turno.',
              style: AppTexto.secundario,
            ),
          ],
        ),
      );

  Widget _filtros() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'todo', label: Text('Todo')),
                ButtonSegment(
                    value: 'suplemento', label: Text('Suplementos')),
                ButtonSegment(
                    value: 'servicio', label: Text('Servicios')),
              ],
              selected: {_filtro},
              onSelectionChanged: (s) =>
                  setState(() => _filtro = s.first),
            ),
            const SizedBox(height: AppEspacio.sm),
            // 1.25 T93: el período del Extracto.
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'hoy', label: Text('Hoy')),
                ButtonSegment(
                    value: 'semana', label: Text('Semana')),
                ButtonSegment(value: 'mes', label: Text('Mes')),
                ButtonSegment(value: 'todo', label: Text('Todo')),
              ],
              selected: {_periodo},
              onSelectionChanged: (s) =>
                  setState(() => _periodo = s.first),
            ),
            const SizedBox(height: AppEspacio.sm),
            CampoTexto(
              controller: _busquedaCtrl,
              hint: 'Buscar por producto o cliente…',
              icono: Icons.search_rounded,
              onChanged: (v) => setState(() => _busqueda = v),
            ),
          ],
        ),
      );

  Widget _filaCompra(Map<String, dynamic> f) {
    final anulada = f['anulada'] == 1;
    final esManual = f['origen'] == 'manual';
    final sup = _supPorId[(f['suplemento_id'] as num?)?.toInt()];
    return Card(
      child: ListTile(
        // 1.25 T93: la fila lleva la foto del producto
        // cuando la venta lo resuelve (suplemento o
        // dosis de un pomo); si no, el icono de siempre.
        leading: sup != null
            ? _FotoExtracto(sup: sup, anulada: anulada)
            : Icon(
                f['tipo'] == 'servicio'
                    ? Icons.fitness_center_rounded
                    : Icons.shopping_bag_rounded,
                color: anulada ? Colors.grey : AppColores.naranja),
        title: Text(
            '${f['concepto']}'
            '${esManual ? ' (manual)' : ''}'
            '${anulada ? ' — ANULADA' : ''}',
            style: TextStyle(
                decoration:
                    anulada ? TextDecoration.lineThrough : null)),
        subtitle: Text('${f['fecha'] ?? ''} · ${f['cliente'] ?? '—'}'),
        trailing: Text(
            '${fmtMonto((f['monto'] as num).toDouble())} ${f['moneda'] ?? 'CUP'}',
            style: AppTexto.cuerpo),
        onTap: () => _detalle(f),
      ),
    );
  }

  Future<void> _detalle(Map<String, dynamic> f) async {
    final esManual = f['origen'] == 'manual';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: '${f['concepto']}',
        iconoTitulo: Icons.receipt_long_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fecha: ${f['fecha'] ?? '—'}'),
            Text('Cliente: ${f['cliente'] ?? '—'}'),
            Text(
                'Monto: ${fmtMonto((f['monto'] as num).toDouble())} ${f['moneda'] ?? 'CUP'}'),
            Text('Origen: ${esManual ? 'Manual (Panel)' : 'Venta del turno'}'),
            if (!esManual)
              const Padding(
                padding: EdgeInsets.only(top: AppEspacio.sm),
                child: Text(
                  'Las ventas del turno se corrigen desde su pantalla, '
                  'no desde aquí, para no duplicar los flujos de '
                  'reverso. Toca «Ir a la venta» para abrirla en su '
                  'pantalla.',
                  style: AppTexto.secundario,
                ),
              ),
          ],
        ),
        acciones: [
          if (esManual && f['anulada'] != 1)
            TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _anularManual(f['idManual'] as String);
                  _cargar();
                },
                child: const Text('Anular con motivo',
                    style: TextStyle(color: Colors.red))),
          if (!esManual)
            TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _irAVenta(f);
                },
                child: const Text('Ir a la venta')),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
        ],
      ),
    );
  }

  /// Abre la venta del Extracto en su pantalla, resaltada (4/25).
  /// Servicios: la pantalla carga sus propios datos (10/25); el
  /// Extracto es solo dueño, así que no se filtra por rol.
  Future<void> _irAVenta(Map<String, dynamic> f) async {
    final destino = destinoVentaExtracto(f);
    if (destino == null || !mounted) return;
    if (destino.pantalla == 'historial_ventas') {
      await Navigator.push(
        context,
        RutaIron(
          builder: (_) => HistorialVentasScreen(resaltarId: destino.id),
        ),
      );
      return;
    }
    final personas = <int, String>{};
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final ptid = LocalDb.normalizarTelegramId(p['telegram_user_id']);
      final nombre = '${p['registrado_por'] ?? ''}';
      if (ptid != null && nombre.isNotEmpty) {
        personas.putIfAbsent(ptid, () => nombre);
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      RutaIron(
        builder: (_) => ServiciosHistorialScreen(
          esDueno: true,
          personas: personas,
          resaltarId: destino.id,
        ),
      ),
    );
  }

  Future<void> _anularManual(String id) async {
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => const _DialogoAnularCompra(),
    );
    if (motivo == null || !mounted) return;
    final db = await LocalDb.instance.db;
    await db.transaction((txn) async {
      await txn.update(
          'compras',
          {'anulada': 1, 'motivo_anulacion': motivo},
          where: 'id=?',
          whereArgs: [id]);
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_compra',
        payload: {'id': id, 'motivo': motivo},
        txn: txn,
      );
    });
    if (!mounted) return;
    mostrarSnack(context, 'Compra anulada', significado: SignificadoChip.exito);
    // Argón #9 (BAJO): sin push, la op quedaba estancada hasta que
    // otra pantalla disparara un push.
    unawaited(SyncEngine.instance.push());
  }

  Future<void> _registrarManual(BuildContext context) async {
    final datos = await showDialog<_DatosCompraManual>(
      context: context,
      builder: (ctx) =>
          _DialogoRegistrarCompraManual(alElegirCliente: _elegirCliente),
    );
    if (datos == null || !context.mounted) return;
    final fechaSel = datos.fecha;
    final tipo = datos.tipo;
    final clienteNombre = datos.clienteNombre;
    final clienteId = datos.clienteId;
    final monto =
        double.tryParse(datos.monto.trim().replaceAll(',', '.'));
    String? error;
    if (datos.concepto.trim().isEmpty) {
      error = 'Falta el concepto.';
    } else if (monto == null || !monto.isFinite || monto <= 0) {
      // Autoauditoría 1.22 #2 (clase N-2): NaN/Infinity no son
      // <= 0 y llegaban a la fila local y al payload de la op.
      error = 'Monto inválido.';
    } else if (DateTime.tryParse(fechaSel) == null) {
      error = 'Fecha inválida.';
    }
    if (error != null) {
      if (!context.mounted) return;
      mostrarSnack(context, error, significado: SignificadoChip.error);
      return;
    }
    final id = const Uuid().v4();
    final ts = isoHabana(ahoraHabana());
    final db = await LocalDb.instance.db;
    await db.transaction((txn) async {
      await txn.insert('compras', {
        'id': id,
        'tipo': tipo,
        'concepto': datos.concepto.trim(),
        'monto': monto,
        'fecha': fechaSel,
        'cliente_id': clienteId,
        'cliente_nombre': clienteNombre ?? '',
        'metodo': 'efectivo',
        'anulada': 0,
        'motivo_anulacion': null,
        'creada_ts': ts,
        'op_uuid': null,
      });
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'upsert_compra',
        payload: {
          'id': id,
          'tipo': tipo,
          'concepto': datos.concepto.trim(),
          'monto': monto,
          'fecha': fechaSel,
          'cliente_id': clienteId,
          'cliente_nombre': clienteNombre ?? '',
        },
        txn: txn,
      );
    });
    if (!context.mounted) return;
    mostrarSnack(context, 'Compra registrada', significado: SignificadoChip.exito);
    // Argón #9 (BAJO): sin push, la op quedaba estancada hasta que
    // otra pantalla disparara un push.
    unawaited(SyncEngine.instance.push());
  }

  /// 1.25 T32: devuelve id Y nombre del cliente elegido;
  /// (id: null, nombre: '') = «Sin cliente» explícito;
  /// null = diálogo cerrado sin elegir (no cambia nada).
  Future<({int? id, String nombre})?> _elegirCliente(
      BuildContext context) async {
    final todos = await listaClientes('');
    return showDialog<({int? id, String nombre})>(
      context: context,
      builder: (ctx) => _DialogoElegirClienteCompras(todos: todos),
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Anular compra» como
/// StatefulWidget propio: posee y dispone su controlador
/// (antes se creaba en el llamador y nunca se liberaba).
/// Devuelve el motivo (vacío = null) o null si se cancela.
class _DialogoAnularCompra extends StatefulWidget {
  const _DialogoAnularCompra();

  @override
  State<_DialogoAnularCompra> createState() =>
      _DialogoAnularCompraState();
}

class _DialogoAnularCompraState extends State<_DialogoAnularCompra> {
  final _motivoCtrl = TextEditingController();

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Anular compra',
      iconoTitulo: Icons.cancel_rounded,
      contenido: TextField(
          controller: _motivoCtrl,
          decoration: const InputDecoration(
              hintText: 'Motivo de la anulación',
              border: OutlineInputBorder())),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context,
                _motivoCtrl.text.trim().isEmpty
                    ? null
                    : _motivoCtrl.text.trim()),
            child: const Text('Anular')),
      ],
    );
  }
}

/// Datos que devuelve el diálogo de compra manual al guardar.
typedef _DatosCompraManual = ({
  String concepto,
  String monto,
  String fecha,
  String tipo,
  int? clienteId,
  String? clienteNombre,
});

/// 1.30 (Oleada 7, clase B): diálogo «Registrar compra
/// manual» como StatefulWidget propio: posee y dispone sus
/// controladores y su estado (fecha, tipo, cliente) — antes
/// vivían en el llamador y los controladores nunca se
/// liberaban. El selector de cliente sigue siendo el del
/// llamador, inyectado por [alElegirCliente].
class _DialogoRegistrarCompraManual extends StatefulWidget {
  final Future<({int? id, String nombre})?> Function(BuildContext)
      alElegirCliente;
  const _DialogoRegistrarCompraManual(
      {required this.alElegirCliente});

  @override
  State<_DialogoRegistrarCompraManual> createState() =>
      _DialogoRegistrarCompraManualState();
}

class _DialogoRegistrarCompraManualState
    extends State<_DialogoRegistrarCompraManual> {
  final _conceptoCtrl = TextEditingController();
  final _montoCtrl = TextEditingController();
  // 1.25 T93: la fecha se ELIGE en un selector, no se
  // teclea «AAAA-MM-DD» (el texto libre era la única
  // validación que fallaba al registrar a mano).
  var _fechaSel = hoyHabanaIso();
  var _tipo = 'suplemento';
  String? _clienteNombre;
  // 1.25 T32: el id viaja con el nombre (antes solo el
  // nombre y la fila nacía con cliente_id null: huérfana).
  int? _clienteId;

  @override
  void dispose() {
    _conceptoCtrl.dispose();
    _montoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Registrar compra manual',
      iconoTitulo: Icons.receipt_long_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Solo para compras fuera del turno. Las ventas del '
              'turno ya aparecen solas en el Extracto.',
              style: AppTexto.secundario,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _tipo,
              decoration: const InputDecoration(
                  labelText: 'Tipo', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(
                    value: 'suplemento', child: Text('Suplemento')),
                DropdownMenuItem(
                    value: 'servicio', child: Text('Servicio')),
              ],
              onChanged: (v) => setState(() => _tipo = v ?? _tipo),
            ),
            const SizedBox(height: 8),
            TextField(
                controller: _conceptoCtrl,
                decoration: const InputDecoration(
                    labelText: 'Concepto (ej: Whey 2 lb)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            // 1.32 (O2F2, Pieza 4): el importe de la compra
            // manual también se compone con el pad; el
            // guardado valida el texto como siempre.
            CampoMontoPad(
              etiqueta: 'Monto (CUP)',
              valor: _montoCtrl.text,
              sufijo: 'CUP',
              onTap: () async {
                final v = await mostrarHojaMontoPad(
                  context,
                  titulo: 'Monto de la compra (CUP)',
                  valorInicial: _montoCtrl.text,
                  sufijo: 'CUP',
                );
                if (v == null || !mounted) return;
                _montoCtrl.text = v;
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_month_rounded,
                  size: 18),
              label: Text('Fecha: $_fechaSel'),
              onPressed: () async {
                final hoy = ahoraHabana();
                final elegida = await showDatePicker(
                  context: context,
                  initialDate:
                      DateTime.tryParse(_fechaSel) ?? hoy,
                  firstDate: DateTime(2024, 1, 1),
                  lastDate:
                      DateTime(hoy.year, hoy.month, hoy.day),
                );
                if (elegida != null) {
                  setState(() {
                    _fechaSel =
                        '${elegida.year.toString().padLeft(4, '0')}-'
                        '${elegida.month.toString().padLeft(2, '0')}-'
                        '${elegida.day.toString().padLeft(2, '0')}';
                  });
                }
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                final elegido =
                    await widget.alElegirCliente(context);
                if (elegido != null) {
                  setState(() {
                    _clienteId = elegido.id;
                    _clienteNombre = elegido.nombre.isEmpty
                        ? null
                        : elegido.nombre;
                  });
                }
              },
              child: Text(_clienteNombre == null
                  ? 'Elegir cliente (opcional)'
                  : 'Cliente: $_clienteNombre'),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context, (
                  concepto: _conceptoCtrl.text,
                  monto: _montoCtrl.text,
                  fecha: _fechaSel,
                  tipo: _tipo,
                  clienteId: _clienteId,
                  clienteNombre: _clienteNombre,
                )),
            child: const Text('Guardar')),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): selector de cliente de Compras
/// como StatefulWidget propio: posee y dispone el
/// controlador del filtro (antes se creaba en el llamador y
/// nunca se liberaba). Devuelve (id, nombre); «Sin cliente»
/// devuelve (id: null, nombre: ''); cerrar sin elegir, null.
class _DialogoElegirClienteCompras extends StatefulWidget {
  final List<Map<String, dynamic>> todos;
  const _DialogoElegirClienteCompras({required this.todos});

  @override
  State<_DialogoElegirClienteCompras> createState() =>
      _DialogoElegirClienteComprasState();
}

class _DialogoElegirClienteComprasState
    extends State<_DialogoElegirClienteCompras> {
  final _filtro = TextEditingController();

  @override
  void dispose() {
    _filtro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _filtro.text.trim().toLowerCase();
    final visibles = q.isEmpty
        ? widget.todos
        : widget.todos
            .where((c) =>
                '${c['nombre'] ?? ''}'.toLowerCase().contains(q))
            .toList();
    return DialogoApp(
      titulo: 'Elegir cliente',
      iconoTitulo: Icons.person_rounded,
      contenido: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: Column(
          children: [
            TextField(
              controller: _filtro,
              decoration: const InputDecoration(
                  hintText: 'Filtrar por nombre',
                  border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final c in visibles)
                    ListTile(
                      dense: true,
                      title: Text('${c['nombre'] ?? ''}'),
                      onTap: () => Navigator.pop(context, (
                            id: (c['id'] as num?)?.toInt(),
                            nombre: '${c['nombre'] ?? ''}',
                          )),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed: () =>
                Navigator.pop(context, (id: null, nombre: '')),
            child: const Text('Sin cliente')),
      ],
    );
  }
}


/// 1.25 T93: miniatura del producto en las filas del
/// Extracto (mismo resolver que el catálogo; futuro en
/// el State, nunca dentro del build).
class _FotoExtracto extends StatefulWidget {
  final Map<String, dynamic> sup;
  final bool anulada;
  const _FotoExtracto({required this.sup, required this.anulada});

  @override
  State<_FotoExtracto> createState() => _FotoExtractoState();
}

class _FotoExtractoState extends State<_FotoExtracto> {
  late Future<File?> _futura;

  @override
  void initState() {
    super.initState();
    _futura = resolverFotoSuplemento(widget.sup);
  }

  @override
  void didUpdateWidget(covariant _FotoExtracto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sup['id'] != widget.sup['id'] ||
        oldWidget.sup['foto_local'] != widget.sup['foto_local'] ||
        oldWidget.sup['foto_storage'] !=
            widget.sup['foto_storage']) {
      _futura = resolverFotoSuplemento(widget.sup);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        final f = snap.data;
        if (f == null) {
          return Icon(Icons.shopping_bag_rounded,
              color: widget.anulada
                  ? Colors.grey
                  : AppColores.naranja);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadio.sm),
          child: Image(
            image: providerFotoAcotada(FileImage(f), ancho: 200),
            width: 40,
            height: 40,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }
}
