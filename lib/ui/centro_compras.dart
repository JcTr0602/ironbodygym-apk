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

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../precio_cobro.dart';
import '../servicios.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'historial_ventas.dart';
import 'servicios_historial.dart';

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
  List<Map<String, dynamic>> _filas = [];
  ResumenExtracto _resumen = const ResumenExtracto({}, {}, {});

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
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
      _resumen = resumenExtracto(filas);
      _cargando = false;
    });
  }

  static String _conceptoServicio(String subtipo, int cant) {
    switch (subtipo) {
      case 'dosis_con_agua':
        return 'Dosis con agua (x$cant)';
      case 'dosis_sin_agua':
        return 'Dosis sin agua (x$cant)';
      case 'agua_suelta':
        return 'Agua suelta (x$cant)';
      case 'combo':
        return 'Combo (x$cant)';
      default:
        return 'Servicio (x$cant)';
    }
  }

  List<Map<String, dynamic>> get _visibles => _filtro == 'todo'
      ? _filas
      : _filas.where((f) => f['tipo'] == _filtro).toList();

  @override
  Widget build(BuildContext context) {
    // P2#6: guarda de dueño en build (antes solo el FAB la tenía).
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Extracto de compras')),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      // v1.13.0: la vista de ventas se llama Extracto (E4 extendido,
      // no duplicado). El registro manual de compras sigue aquí.
      appBar: AppBar(title: const Text('Extracto de compras')),
      floatingActionButton: AuthService().isOwner
          ? FloatingActionButton.extended(
              onPressed: () async {
                await _registrarManual(context);
                _cargar();
              },
              icon: const Icon(Icons.add),
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
                            padding: const EdgeInsets.all(16),
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
                'Total general: ${textoMontosPorMoneda(_resumen.total)}',
                style: AppTexto.titulo),
            const SizedBox(height: 4),
            Text(
                'Subtotal Suplementos: '
                '${textoMontosPorMoneda(_resumen.suplementos)} · '
                'Subtotal Servicios: '
                '${textoMontosPorMoneda(_resumen.servicios)}',
                style: AppTexto.cuerpo),
            const Text(
              'Las anuladas no suman. Las ventas del turno aparecen '
              'solas; desde aquí solo se registran compras fuera del '
              'turno.',
              style: AppTexto.secundario,
            ),
          ],
        ),
      );

  Widget _filtros() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'todo', label: Text('Todo')),
            ButtonSegment(value: 'suplemento', label: Text('Suplementos')),
            ButtonSegment(value: 'servicio', label: Text('Servicios')),
          ],
          selected: {_filtro},
          onSelectionChanged: (s) => setState(() => _filtro = s.first),
        ),
      );

  Widget _filaCompra(Map<String, dynamic> f) {
    final anulada = f['anulada'] == 1;
    final esManual = f['origen'] == 'manual';
    return Card(
      child: ListTile(
        leading: Icon(
            f['tipo'] == 'servicio'
                ? Icons.fitness_center
                : Icons.shopping_bag,
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
        iconoTitulo: Icons.receipt_long,
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
                padding: EdgeInsets.only(top: 8),
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
        MaterialPageRoute(
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
      MaterialPageRoute(
        builder: (_) => ServiciosHistorialScreen(
          esDueno: true,
          personas: personas,
          resaltarId: destino.id,
        ),
      ),
    );
  }

  Future<void> _anularManual(String id) async {
    final motivoCtrl = TextEditingController();
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Anular compra',
        iconoTitulo: Icons.cancel,
        contenido: TextField(
            controller: motivoCtrl,
            decoration: const InputDecoration(
                hintText: 'Motivo de la anulación',
                border: OutlineInputBorder())),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx,
                  motivoCtrl.text.trim().isEmpty
                      ? null
                      : motivoCtrl.text.trim()),
              child: const Text('Anular')),
        ],
      ),
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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Compra anulada')));
    // Argón #9 (BAJO): sin push, la op quedaba estancada hasta que
    // otra pantalla disparara un push.
    unawaited(SyncEngine.instance.push());
  }

  Future<void> _registrarManual(BuildContext context) async {
    final conceptoCtrl = TextEditingController();
    final montoCtrl = TextEditingController();
    final fechaCtrl = TextEditingController(text: hoyHabanaIso());
    var tipo = 'suplemento';
    String? clienteNombre;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Registrar compra manual',
          iconoTitulo: Icons.receipt_long,
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
                  value: tipo,
                  decoration: const InputDecoration(
                      labelText: 'Tipo', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(
                        value: 'suplemento', child: Text('Suplemento')),
                    DropdownMenuItem(
                        value: 'servicio', child: Text('Servicio')),
                  ],
                  onChanged: (v) => setS(() => tipo = v ?? tipo),
                ),
                const SizedBox(height: 8),
                TextField(
                    controller: conceptoCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Concepto (ej: Whey 2 lb)',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                TextField(
                    controller: montoCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Monto (CUP)',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                TextField(
                    controller: fechaCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Fecha (AAAA-MM-DD)',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    final nombre =
                        await _elegirClienteNombre(context);
                    if (nombre != null) {
                      setS(() => clienteNombre = nombre);
                    }
                  },
                  child: Text(clienteNombre == null
                      ? 'Elegir cliente (opcional)'
                      : 'Cliente: $clienteNombre'),
                ),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final monto =
        double.tryParse(montoCtrl.text.trim().replaceAll(',', '.'));
    String? error;
    if (conceptoCtrl.text.trim().isEmpty) {
      error = 'Falta el concepto.';
    } else if (monto == null || monto <= 0) {
      error = 'Monto inválido.';
    } else if (DateTime.tryParse(fechaCtrl.text.trim()) == null) {
      error = 'Fecha inválida (AAAA-MM-DD).';
    }
    if (error != null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final id = const Uuid().v4();
    final ts = isoHabana(ahoraHabana());
    final db = await LocalDb.instance.db;
    await db.transaction((txn) async {
      await txn.insert('compras', {
        'id': id,
        'tipo': tipo,
        'concepto': conceptoCtrl.text.trim(),
        'monto': monto,
        'fecha': fechaCtrl.text.trim(),
        'cliente_id': null,
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
          'concepto': conceptoCtrl.text.trim(),
          'monto': monto,
          'fecha': fechaCtrl.text.trim(),
          'cliente_nombre': clienteNombre ?? '',
        },
        txn: txn,
      );
    });
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Compra registrada')));
    // Argón #9 (BAJO): sin push, la op quedaba estancada hasta que
    // otra pantalla disparara un push.
    unawaited(SyncEngine.instance.push());
  }

  Future<String?> _elegirClienteNombre(BuildContext context) async {
    final todos = await listaClientes('');
    final filtro = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final q = filtro.text.trim().toLowerCase();
          final visibles = q.isEmpty
              ? todos
              : todos
                  .where((c) => '${c['nombre'] ?? ''}'
                      .toLowerCase()
                      .contains(q))
                  .toList();
          return DialogoApp(
            titulo: 'Elegir cliente',
            iconoTitulo: Icons.person,
            contenido: SizedBox(
              width: double.maxFinite,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    controller: filtro,
                    decoration: const InputDecoration(
                        hintText: 'Filtrar por nombre',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setS(() {}),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final c in visibles)
                          ListTile(
                            dense: true,
                            title: Text('${c['nombre'] ?? ''}'),
                            onTap: () => Navigator.pop(
                                ctx, '${c['nombre'] ?? ''}'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            acciones: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Sin cliente')),
            ],
          );
        },
      ),
    );
  }
}
