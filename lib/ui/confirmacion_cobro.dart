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
      mostrarSnack(context, 'El cobro ya subió: la corrección queda solo '
              'en el panel del dueño.', significado: SignificadoChip.alerta);
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
            // Check grande animado (M9): entra escalando en
            // 350 ms; confirmación visual inmediata del cobro.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.5, end: 1.0),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutBack,
              builder: (context, escala, hijo) =>
                  Transform.scale(scale: escala, child: hijo),
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: AppColores.exito.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  size: 80,
                  color: AppColores.exito,
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              '¡Cobro registrado!',
              style: AppTexto.displayPequeno.copyWith(
                  color: AppColores.texto(context)),
            ),
            const SizedBox(height: 24),
            // Datos del cobro, como ticket (M3): el importe
            // arriba y la línea de corte punteada lo separa del
            // detalle.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColores.superficie(context),
                  borderRadius:
                      BorderRadius.circular(AppRadio.lg),
                  border:
                      Border.all(color: AppColores.borde(context)),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          16, 4, 16, 0),
                      child: _filaMonto(context),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 1.2,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _PunteadaPainter(
                            AppColores.borde(context)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          16, 0, 16, 4),
                      child: Column(
                        children: [
                          _fila(context, 'Cliente',
                              widget.nombreCliente),
                          const Divider(),
                          _fila(context, 'Nuevo vencimiento',
                              widget.nuevoVencimiento),
                        ],
                      ),
                    ),
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
                    icon: const Icon(Icons.undo_rounded, size: 18),
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
                  style: AppTexto.metadato,
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
                  style: AppTexto.metadato,
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
          Text(etiqueta, style: AppTexto.secundario),
          Flexible(
            child: Text(
              valor,
              style: AppTexto.cuerpo
                  .copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  /// V21: el monto del recibo es el ancla visual (metrica).
  Widget _filaMonto(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Monto', style: AppTexto.secundario),
          Flexible(
            child: Text(
              widget.monto,
              style: AppTexto.metrica.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()]),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

/// M3: línea punteada de corte del ticket del comprobante.
class _PunteadaPainter extends CustomPainter {
  final Color color;
  const _PunteadaPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    const dash = 6.0;
    const gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      final fin = (x + dash).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, 0), Offset(fin, 0), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_PunteadaPainter oldDelegate) =>
      oldDelegate.color != color;
}
