import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../servicios.dart';
import 'diseno.dart';

/// Historial completo de Servicios (pedido de Jc 2026-10-28):
/// todas las operaciones de venta de raciones, combos y agua, más
/// las salidas sin venta, en orden de nuevas a viejas, con filtros
/// por tipo y (solo dueño) por vendedor. Solo lectura: no vende,
/// no revierte, no cambia nada.
///
/// Roles: el dueño ve todas las operaciones; el entrenador solo
/// las suyas (el llamador ya filtra por rol antes de pasar las
/// listas, con el mismo predicado que «Ventas de hoy»). Las
/// salidas sin venta solo las registra el dueño, así que al
/// entrenador no le llega ninguna. Solo operaciones sincronizadas
/// (espejo): una venta offline pendiente aparece aquí cuando
/// sincroniza.
class ServiciosHistorialScreen extends StatefulWidget {
  final List<Map<String, dynamic>> ventas;
  final List<Map<String, dynamic>> salidas;
  final Set<int> reversadas;
  final bool esDueno;
  final Map<int, String> personas;

  const ServiciosHistorialScreen({
    super.key,
    required this.ventas,
    required this.salidas,
    required this.reversadas,
    required this.esDueno,
    required this.personas,
  });

  @override
  State<ServiciosHistorialScreen> createState() =>
      _ServiciosHistorialScreenState();
}

class _ServiciosHistorialScreenState
    extends State<ServiciosHistorialScreen> {
  // Filtros: tipo 'todas' | 'racion' | 'combo' | 'agua' | 'salida';
  // vendedor null = todos (solo dueño; el entrenador solo ve lo suyo).
  String _filtroTipo = 'todas';
  int? _filtroVendedor;

  late final List<Map<String, dynamic>> _entradas;

  /// Respaldo de nombre por tid (menor Argón adenda): nombre que
  /// traía la venta (registrado_por_nombre) cuando el tid no está
  /// en widget.personas (p. ej. ventas viejas o del dueño).
  late final Map<int, String> _respaldoPorTid;

  @override
  void initState() {
    super.initState();
    _entradas = entradasHistorialServicios(
      ventas: widget.ventas,
      salidas: widget.salidas,
      reversadas: widget.reversadas,
    );
    _respaldoPorTid = {};
    for (final e in _entradas) {
      if (e['kind'] != 'venta') continue;
      final tid = _vendedorDe(e);
      if (tid == null || _respaldoPorTid.containsKey(tid)) continue;
      final r = '${e['registradoPor'] ?? ''}';
      if (r.isNotEmpty) _respaldoPorTid[tid] = r;
    }
  }

  int? _vendedorDe(Map<String, dynamic> e) =>
      LocalDb.normalizarTelegramId(e['vendedorId']) ??
      LocalDb.normalizarTelegramId(e['registradoPorId']);

  String _nombreVendedor(int? tid, [String? respaldo]) {
    if (tid != null && widget.personas[tid] != null) {
      return widget.personas[tid]!;
    }
    if (respaldo != null && respaldo.isNotEmpty) return respaldo;
    return 'Entrenador';
  }

  List<Map<String, dynamic>> get _visibles {
    return _entradas.where((e) {
      final esVenta = e['kind'] == 'venta';
      switch (_filtroTipo) {
        case 'racion':
          if (!esVenta || e['tipo'] != 'dosis_sin_agua') return false;
        case 'combo':
          if (!esVenta || e['tipo'] != 'dosis_con_agua') return false;
        case 'agua':
          if (!esVenta || e['tipo'] != 'agua_suelta') return false;
        case 'salida':
          if (esVenta) return false;
      }
      if (_filtroVendedor != null) {
        if (!esVenta) return false;
        if (_vendedorDe(e) != _filtroVendedor) return false;
      }
      return true;
    }).toList();
  }

  List<int> get _vendedores {
    final tids = <int>{};
    for (final e in _entradas) {
      if (e['kind'] != 'venta') continue;
      final tid = _vendedorDe(e);
      if (tid != null) tids.add(tid);
    }
    final lista = tids.toList()..sort();
    return lista;
  }

  Widget _chip(String clave, String texto) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(texto),
        selected: _filtroTipo == clave,
        onSelected: (_) => setState(() => _filtroTipo = clave),
      ),
    );
  }

  Widget _filaEntrada(Map<String, dynamic> e) {
    final esVenta = e['kind'] == 'venta';
    final esReverso = e['esReverso'] == true;
    final yaReversada = e['yaReversada'] == true;
    final esCasa = e['casa'] == true;
    final fecha = '${e['fecha']}';
    final fecha10 = fecha.length >= 10 ? fecha.substring(0, 10) : fecha;
    final hora = '${e['hora']}';
    if (!esVenta) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.outbox, color: Colors.grey),
          title: const Text('Salida sin venta'),
          subtitle: Text(
            '${e['tipo'] == 'agua' ? 'Agua' : 'Dosis'} ×${e['cantidad']}'
            ' · ${e['motivo']}'
            ' · $fecha10',
          ),
        ),
      );
    }
    final tipoTxt = switch ('${e['tipo']}') {
      'dosis_sin_agua' => 'Ración',
      'dosis_con_agua' => 'Combo',
      'agua_suelta' => 'Agua suelta ×${e['cantidad']}',
      _ => '${e['tipo']}',
    };
    final icono = esReverso
        ? Icons.undo
        : esCasa
            ? Icons.star
            : e['tipo'] == 'dosis_sin_agua'
                ? Icons.science_rounded
                : e['tipo'] == 'dosis_con_agua'
                    ? Icons.local_drink_rounded
                    : Icons.water_drop_rounded;
    final colorIcono = esReverso
        ? AppColores.error
        : esCasa
            ? Colors.amber
            : e['tipo'] == 'agua_suelta'
                ? AppColores.info
                : AppColores.naranja;
    final titulo = '$tipoTxt'
        '${esReverso ? ' · Reverso' : yaReversada ? ' · Reversada' : ''}'
        '${esCasa ? ' · Casa' : ''}';
    final vendedor = widget.esDueno
        ? ' · Vend: ${_nombreVendedor(_vendedorDe(e), '${e['registradoPor'] ?? ''}')}'
        : '';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icono, color: colorIcono),
        title: Text(titulo),
        subtitle: Text(
          '${e['cliente']}'
          ' · $fecha10${hora.isNotEmpty ? ' $hora' : ''}'
          '$vendedor'
          '${esCasa ? '' : (e['metodo'] as String).isNotEmpty ? ' · ${e['metodo']}' : ''}',
        ),
        trailing: Text('${fmtMonto((e['monto'] as num).toDouble())} CUP',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: esReverso ? AppColores.error : null)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibles = _visibles;
    final vendedores = _vendedores;
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de Servicios')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip('todas', 'Todas'),
                  _chip('racion', 'Raciones'),
                  _chip('combo', 'Combos'),
                  _chip('agua', 'Agua'),
                  if (widget.esDueno) _chip('salida', 'Salidas'),
                ],
              ),
            ),
          ),
          if (widget.esDueno && vendedores.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
              child: Row(
                children: [
                  const Text('Vendedor: ',
                      style: AppTexto.secundario),
                  Expanded(
                    child: DropdownButton<int?>(
                      isExpanded: true,
                      value: _filtroVendedor,
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Todos'),
                        ),
                        for (final tid in vendedores)
                          DropdownMenuItem<int?>(
                            value: tid,
                            child: Text(_nombreVendedor(
                                tid, _respaldoPorTid[tid])),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _filtroVendedor = v),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: visibles.isEmpty
                ? Center(
                    child: Container(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: AppColores.textoSecundario(context)
                            .withValues(alpha: 0.08),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.history,
                            color: AppColores.textoSecundario(context)
                                .withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: AppEspacio.sm),
                          Text(
                              _entradas.isEmpty
                                  ? 'Sin operaciones registradas.'
                                  : 'Sin operaciones con ese filtro.',
                              style: AppTexto.cuerpo.copyWith(
                                  color: AppColores.textoSecundario(
                                      context))),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    itemCount: visibles.length + 1,
                    itemBuilder: (context, index) {
                      if (index < visibles.length) {
                        return _filaEntrada(visibles[index]);
                      }
                      return Padding(
                        padding:
                            const EdgeInsets.only(top: AppEspacio.sm),
                        child: Text(
                          'Solo operaciones sincronizadas: una venta '
                          'offline aparece aquí cuando sincroniza.',
                          style: AppTexto.secundario.copyWith(fontSize: 11),
                          textAlign: TextAlign.center,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
