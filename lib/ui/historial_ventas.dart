// Historial de ventas de suplementos (solo dueño).
//
// Muestra quién vendió qué, cuándo, a cuánto y a quién.
// Las ventas con precio diferente al oficial se destacan en ámbar.
// Totales separados por moneda (CUP y USD no se mezclan).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class HistorialVentasScreen extends StatefulWidget {
  const HistorialVentasScreen({super.key});

  @override
  State<HistorialVentasScreen> createState() =>
      _HistorialVentasScreenState();
}

class _HistorialVentasScreenState
    extends State<HistorialVentasScreen> {
  List<Map<String, dynamic>> _ventas = [];
  Map<int, Map<String, dynamic>> _productos = {};
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final ventas =
        await LocalDb.instance.allMirror('ventas_suplementos');
    final prods =
        await LocalDb.instance.allMirror('suplementos');
    final mapa = <int, Map<String, dynamic>>{};
    for (final p in prods) {
      final id = (p['id'] as num?)?.toInt();
      if (id != null) mapa[id] = p;
    }
    ventas.sort((a, b) =>
        '${b['fecha'] ?? ''}'.compareTo('${a['fecha'] ?? ''}'));
    if (!mounted) return;
    setState(() {
      _ventas = ventas;
      _productos = mapa;
      _cargando = false;
    });
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
      appBar: AppBar(title: const Text('Ventas de suplementos')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          _totales(),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _totales() {
    double cup = 0, usd = 0;
    for (final v in _ventas) {
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
            _totalCol('Ventas', '${_ventas.length}'),
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_ventas.isEmpty) {
      return const EstadoVacio(
        icono: Icons.receipt_long_outlined,
        titulo: 'Sin ventas registradas',
        subtitulo:
            'Las ventas de suplementos aparecerán aquí.',
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppEspacio.md),
        itemCount: _ventas.length,
        itemBuilder: (ctx, i) => _fila(_ventas[i]),
      ),
    );
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
    final esUsd = moneda == 'USD';
    final tasa = (v['usd_tasa'] as num?)?.toDouble();
    final total =
        (v['total'] as num?)?.toDouble() ?? precio * cant;
    final vendedor =
        '${v['registrado_por_nombre'] ?? v['registrado_por'] ?? '?'}';
    final comprador = '${v['comprador_nombre'] ?? '?'}';
    final fecha = '${v['fecha'] ?? ''}'.length >= 10
        ? '${v['fecha']}'.substring(0, 10)
        : '${v['fecha'] ?? ''}';
    final conPromo = (v['promo_mes'] as int?) == 1;
    final viaInscripcion =
        (v['via_inscripcion'] as num?)?.toInt() == 1;

    final lineaTotal = esUsd
        ? '$cant x ${precio.toStringAsFixed(2)} USD'
            '${tasa != null ? ' · tasa ${tasa.toStringAsFixed(2)}' : ''}'
            ' = ${total.toStringAsFixed(2)} USD'
            '${tasa != null ? ' (≈ ${(total * tasa).toStringAsFixed(0)} CUP)' : ''}'
        : '$cant x ${precio.toStringAsFixed(2)} $moneda'
            ' = ${total.toStringAsFixed(2)} $moneda';

    return Padding(
      padding:
          const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.md),
        color: difiere
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
                if (difiere)
                  const ChipEstado(
                      texto: 'Precio diferente',
                      color: AppColores.alerta,
                      icono: Icons.warning_amber),
                IconButton(
                  icon: const Icon(Icons.undo,
                      color: AppColores.error, size: 20),
                  tooltip: 'Anular venta',
                  onPressed: () => _anular(v),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              lineaTotal,
              style: AppTexto.cuerpo,
            ),
            const SizedBox(height: 4),
            Text(
              '$fecha · $vendedor → $comprador'
              '${conPromo ? ' · +1 mes gratis' : ''}',
              style: AppTexto.secundario,
            ),
          ],
        ),
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
              if (cliente != null) ...[
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
              fila('Total',
                  esUsd
                      ? '${total.toStringAsFixed(2)} USD'
                          '${tasa != null ? ' (≈ ${(total * tasa).toStringAsFixed(0)} CUP)' : ''}'
                      : '${total.toStringAsFixed(0)} $moneda'),
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
