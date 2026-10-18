/// Vista previa de la App de Clientes (v1.3.9, F6).
/// Solo dueño. Muestra lo mismo que ve el cliente en su app,
/// vía el RPC `preview_datos_cliente` (cero efectos secundarios).
/// Estética cliente: naranja #FF6B00 / grafito #121214. Solo lectura.
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class VistaPreviaClienteScreen extends StatefulWidget {
  final int clienteId;
  final String nombreCliente;
  const VistaPreviaClienteScreen({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
  });
  @override
  State<VistaPreviaClienteScreen> createState() =>
      _VistaPreviaClienteScreenState();
}

class _VistaPreviaClienteScreenState
    extends State<VistaPreviaClienteScreen> {
  Map<String, dynamic>? _datos;
  bool _cargando = true;
  String? _error;

  // Colores de la app de clientes.
  static const _naranja = Color(0xFFFF6B00);
  static const _grafito = Color(0xFF121214);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('preview_datos_cliente', params: {
        'p_cliente_id': widget.clienteId,
      });
      final data = Map<String, dynamic>.from(res as Map);
      if (data['status'] != 200) {
        throw '${data['error'] ?? 'Error desconocido'}';
      }
      if (mounted) {
        setState(() {
          _datos = data;
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _cargando = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _grafito,
      appBar: AppBar(
        title: Text('Vista previa: ${widget.nombreCliente}'),
        backgroundColor: _grafito,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: _naranja,
            padding: const EdgeInsets.symmetric(
                vertical: 6, horizontal: 16),
            child: const Text(
              'VISTA PREVIA — lo que ve el cliente en su app',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(
                    child: CircularProgressIndicator(
                        color: _naranja))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!,
                              style: const TextStyle(
                                  color: Colors.white70),
                              textAlign:
                                  TextAlign.center),
                        ),
                      )
                    : _contenido(),
          ),
        ],
      ),
    );
  }

  Widget _contenido() {
    final d = _datos!;
    final cliente =
        Map<String, dynamic>.from(d['cliente'] as Map? ?? {});
    final pagos = List.from(d['historial_pagos'] as List? ?? []);
    final catalogo =
        List.from(d['catalogo_suplementos'] as List? ?? []);
    final meta =
        Map<String, dynamic>.from(d['meta'] as Map? ?? {});
    final turno =
        Map<String, dynamic>.from(meta['entrenador_turno'] as Map? ?? {});
    final plan = d['plan_nutricional'] as Map?;
    final compras =
        List.from(d['historial_compras'] as List? ?? []);

    final pagadoHasta = '${cliente['pagado_hasta'] ?? '—'}';
    final nombre = '${cliente['nombre'] ?? ''}';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Ficha destacada: fecha de vencimiento.
        _tarjetaCliente([
          _filaCliente('Nombre', nombre),
          _filaCliente('Estado', '${cliente['estado'] ?? '—'}'),
          _filaCliente('Vence', pagadoHasta,
              destacado: true),
          _filaCliente(
              'Mensualidad',
              '${cliente['monto_mensualidad'] ?? '—'} CUP'),
        ]),
        const SizedBox(height: 12),
        // Turno actual.
        if (turno.isNotEmpty)
          _tarjetaCliente([
            const Text('Entrenador de turno',
                style: TextStyle(
                    color: _naranja,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('${turno['entrenador_nombre'] ?? '—'}',
                style: const TextStyle(
                    color: Colors.white)),
            Text('Turno: ${turno['turno'] ?? '—'}',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13)),
          ])
        else
          _tarjetaCliente([
            const Text(
                'Gym cerrado en este momento',
                style: TextStyle(
                    color: Colors.white70)),
          ]),
        const SizedBox(height: 12),
        // Plan nutricional (solo ver).
        _tituloSeccion('Plan nutricional'),
        if (plan == null)
          const Text('Sin plan asignado',
              style:
                  TextStyle(color: Colors.white70))
        else
          _tarjetaCliente([
            Text('Objetivo: ${plan['objetivo'] ?? '—'}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600)),
            Text(
                'Actualizado: ${plan['actualizado_en'] ?? '—'}',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13)),
            // v1.3.9 (ajuste Argón): mostrar el detalle del plan.
            if ('${plan['detalle'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('${plan['detalle']}',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13)),
            ],
          ]),
        const SizedBox(height: 12),
        // Historial de pagos.
        _tituloSeccion('Historial de pagos (${pagos.length})'),
        if (pagos.isEmpty)
          const Text('Sin pagos registrados',
              style:
                  TextStyle(color: Colors.white70))
        else
          for (final p in pagos.take(5))
            _tarjetaCliente([
              Text(
                  '${p['fecha'] ?? '—'} · ${p['monto'] ?? '—'} CUP',
                  style: const TextStyle(
                      color: Colors.white)),
              Text(
                  '${p['periodo'] ?? ''} · ${p['metodo'] ?? ''}',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13)),
            ]),
        const SizedBox(height: 12),
        // v1.3.9 (ajuste Argón): historial de compras (paridad con el RPC).
        _tituloSeccion(
            'Historial de compras (${compras.length})'),
        if (compras.isEmpty)
          const Text('Sin compras registradas',
              style:
                  TextStyle(color: Colors.white70))
        else
          for (final vc in compras.take(5))
            _tarjetaCliente([
              Text(
                  '${vc['fecha'] ?? '—'} · ${vc['cantidad'] ?? '—'}x · ${vc['precio'] ?? '—'} CUP',
                  style: const TextStyle(
                      color: Colors.white)),
              Text('${vc['moneda'] ?? ''}',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13)),
            ]),
        const SizedBox(height: 12),
        // Catálogo con semáforo.
        _tituloSeccion(
            'Catálogo (${catalogo.length})'),
        for (final s in catalogo)
          _tarjetaCliente([
            Row(
              children: [
                Expanded(
                  child: Text('${s['nombre'] ?? ''}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight:
                              FontWeight.w600)),
                ),
                _chipDisponibilidad(
                    '${s['disponibilidad'] ?? ''}'),
              ],
            ),
            if ('${s['descripcion'] ?? ''}'
                .isNotEmpty)
              Text('${s['descripcion']}',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13)),
            Text('${s['precio_oficial'] ?? '—'} CUP',
                style: const TextStyle(
                    color: _naranja,
                    fontWeight: FontWeight.w600)),
          ]),
      ],
    );
  }

  Widget _tituloSeccion(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(t,
          style: const TextStyle(
              color: _naranja,
              fontSize: 16,
              fontWeight: FontWeight.bold)),
    );
  }

  Widget _tarjetaCliente(List<Widget> hijos) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: hijos,
      ),
    );
  }

  Widget _filaCliente(String etiqueta, String valor,
      {bool destacado = false}) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$etiqueta: ',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14)),
          Expanded(
            child: Text(valor,
                style: TextStyle(
                    color: destacado
                        ? _naranja
                        : Colors.white,
                    fontSize: 14,
                    fontWeight: destacado
                        ? FontWeight.bold
                        : FontWeight.normal)),
          ),
        ],
      ),
    );
  }

  Widget _chipDisponibilidad(String disp) {
    final color = disp == 'Disponible'
        ? Colors.green
        : disp == 'Últimas unidades'
            ? Colors.amber
            : Colors.red;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: color.withValues(alpha: 0.5)),
      ),
      child: Text(disp,
          style: TextStyle(
              color: color, fontSize: 11)),
    );
  }
}
