/// Pantalla de confirmación de cobro a pantalla completa.
/// Muestra check grande, nombre del cliente, monto y nuevo vencimiento.
///
/// Bloque 1 (Argón AMARILLO, 2026-10-24): este es el Paso B (Recibo,
/// DESPUÉS de guardar). Si viene [opUuid], muestra «Deshacer» durante
/// 15 segundos exactos. Deshacer solo funciona si la op sigue en el
/// teléfono (estado pendiente/error): la borra porque nunca subió.
/// Si ya subió, se esconde y la corrección queda solo en el panel
/// separado del dueño. Al cerrar la pantalla, la ventana termina.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../localdb.dart';
import 'componentes.dart';
import 'diseno.dart';

class ConfirmacionCobroScreen extends StatefulWidget {
  final String nombreCliente;
  final String monto;
  final String nuevoVencimiento;
  final String? fotoUrl;

  /// Op local del cobro. null = recibo sin deshacer (llamadas viejas).
  final String? opUuid;

  const ConfirmacionCobroScreen({
    super.key,
    required this.nombreCliente,
    required this.monto,
    required this.nuevoVencimiento,
    this.fotoUrl,
    this.opUuid,
  });

  @override
  State<ConfirmacionCobroScreen> createState() =>
      _ConfirmacionCobroScreenState();
}

class _ConfirmacionCobroScreenState
    extends State<ConfirmacionCobroScreen> {
  static const _ventanaSegundos = 15;
  Timer? _timer;
  int _segundos = _ventanaSegundos;
  bool _puedeDeshacer = false;
  bool _yaSubio = false;

  @override
  void initState() {
    super.initState();
    if (widget.opUuid != null) _verificarDeshacer();
  }

  Future<void> _verificarDeshacer() async {
    final estado = await _estadoOp();
    if (!mounted) return;
    if (estado == 'pendiente' || estado == 'error') {
      setState(() => _puedeDeshacer = true);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_segundos <= 1) {
          _timer?.cancel();
          setState(() {
            _segundos = 0;
            _puedeDeshacer = false;
          });
        } else {
          setState(() => _segundos--);
        }
      });
    } else {
      setState(() => _yaSubio = true);
    }
  }

  Future<String?> _estadoOp() async {
    final uuid = widget.opUuid;
    if (uuid == null) return null;
    try {
      final db = await LocalDb.instance.db;
      final rows = await db.query('ops_queue',
          columns: ['estado'],
          where: 'op_uuid = ?',
          whereArgs: [uuid],
          limit: 1);
      if (rows.isEmpty) return null;
      return '${rows.first['estado']}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _deshacer() async {
    final uuid = widget.opUuid;
    if (uuid == null) return;
    final estado = await _estadoOp();
    if (!mounted) return;
    if (estado != 'pendiente' && estado != 'error') {
      // Ya subió (o se forzó la sincronización): no se puede borrar
      // del teléfono porque el servidor ya la tiene.
      _timer?.cancel();
      setState(() {
        _puedeDeshacer = false;
        _yaSubio = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('El cobro ya subió: la corrección queda solo '
              'en el panel del dueño.')));
      return;
    }
    await LocalDb.instance.deleteOp(uuid);
    _timer?.cancel();
    if (!mounted) return;
    Navigator.of(context).pop('deshecho');
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColores.fondo(context),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Check grande animado
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: AppColores.exito.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle,
                size: 80,
                color: AppColores.exito,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              '¡Cobro registrado!',
              style: AppTexto.displayPequeno.copyWith(
                  color: AppColores.texto(context)),
            ),
            const SizedBox(height: 24),
            // Datos del cobro
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Tarjeta(
                child: Column(
                  children: [
                    _fila(context, 'Cliente', widget.nombreCliente),
                    const Divider(),
                    _fila(context, 'Monto', widget.monto),
                    const Divider(),
                    _fila(context, 'Nuevo vencimiento',
                        widget.nuevoVencimiento),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            if (_puedeDeshacer) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.undo, size: 18),
                    label: Text('Deshacer ($_segundos s)'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppColores.error),
                    onPressed: _deshacer,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  'Si deshaces, el cobro se borra del teléfono '
                  'porque aún no subió.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
            ] else if (_yaSubio) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  'El cobro ya subió: cualquier corrección posterior '
                  'es solo del dueño.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: BotonPrimario(
                texto: 'Entendido',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fila(BuildContext context, String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta,
              style: TextStyle(
                  color: AppColores.textoSecundario(context))),
          Flexible(
            child: Text(
              valor,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: AppColores.texto(context),
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
