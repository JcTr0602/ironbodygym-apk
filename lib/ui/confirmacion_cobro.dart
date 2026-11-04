/// Pantalla de confirmación de operación a pantalla completa.
///
/// Bloque 4 (T5/T6, 1.23): UNA sola gramática de éxito para
/// cobrar y vender — marca animada (350 ms), ticket con el monto
/// destacado que cuenta hasta su valor ([MontoAnimado]), filas
/// de detalle, comprobante y acción extra opcionales, y la
/// misma salida («Entendido»). [ConfirmacionOperacionScreen] es
/// la pantalla compartida; [ConfirmacionCobroScreen] queda como
/// envoltorio fino del recibo de cobro para no romper a sus
/// llamadores (preview_cobro.dart).
///
/// Bloque 1 (Argón AMARILLO, 2026-10-24): el recibo del cobro es
/// el Paso B (DESPUÉS de guardar). Si viene [opUuid], muestra
/// «Deshacer» durante 15 segundos exactos. Deshacer solo
/// funciona si la op sigue en el teléfono (estado
/// pendiente/error): la borra porque nunca subió. Si ya subió,
/// se esconde y la corrección queda solo en el panel separado
/// del dueño. Al cerrar la pantalla, la ventana termina. El
/// Deshacer solo lo usa el cobro (único llamador con opUuid).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../localdb.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Acción extra opcional de la pantalla de confirmación (p. ej.
/// «Enviar por WhatsApp» con el comprobante de la venta). Se
/// muestra a ancho completo bajo el ticket y el comprobante.
class AccionExtraConfirmacion {
  final String texto;
  final IconData icono;
  final VoidCallback alPulsar;

  const AccionExtraConfirmacion({
    required this.texto,
    required this.icono,
    required this.alPulsar,
  });
}

/// Pantalla compartida de éxito de una operación (cobro, venta).
class ConfirmacionOperacionScreen extends StatefulWidget {
  /// Título de la confirmación («¡Cobro registrado!»,
  /// «¡Venta registrada!»).
  final String titulo;

  /// Monto destacado del ticket, ya formateado. Es el texto que
  /// se muestra si no viene [montoValor].
  final String monto;

  /// T6: valor numérico del monto. Si viene, el ticket lo pinta
  /// con [MontoAnimado] (cuenta hasta su valor) usando
  /// [montoFormato]; si es null, se muestra [monto] fijo, como
  /// hacían los llamadores históricos.
  final double? montoValor;
  final String Function(double)? montoFormato;

  /// Etiqueta de la fila del monto ('Monto' en el cobro,
  /// 'Total' en la venta).
  final String etiquetaMonto;

  /// Filas de detalle del ticket, bajo la línea de corte.
  final List<({String etiqueta, String valor})> detalles;

  /// Bloque opcional con el texto del comprobante (la venta lo
  /// trae; el cobro no). [comprobanteTitulo] por defecto es
  /// «Comprobante».
  final String? comprobanteTitulo;
  final String? comprobanteTexto;

  /// Acción extra opcional (WhatsApp en la venta).
  final AccionExtraConfirmacion? accionExtra;

  /// Op local del cobro. null = confirmación sin deshacer.
  final String? opUuid;

  const ConfirmacionOperacionScreen({
    super.key,
    required this.titulo,
    required this.monto,
    this.montoValor,
    this.montoFormato,
    this.etiquetaMonto = 'Monto',
    this.detalles = const [],
    this.comprobanteTitulo,
    this.comprobanteTexto,
    this.accionExtra,
    this.opUuid,
  });

  @override
  State<ConfirmacionOperacionScreen> createState() =>
      _ConfirmacionOperacionScreenState();
}

class _ConfirmacionOperacionScreenState
    extends State<ConfirmacionOperacionScreen> {
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
    // SA-03: si el borrado no tocó la fila, un push forzado la
    // subió entre la comprobación y aquí: no se anuncia deshecho.
    final borradas = await LocalDb.instance.deleteOp(uuid);
    _timer?.cancel();
    if (!mounted) return;
    if (borradas == 0) {
      setState(() {
        _puedeDeshacer = false;
        _yaSubio = true;
      });
      mostrarSnack(context, 'El cobro ya subió: la corrección queda solo '
              'en el panel del dueño.',
          significado: SignificadoChip.alerta);
      return;
    }
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
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 24),
                // Check grande animado (M9/T6): entra escalando en
                // 350 ms; confirmación visual inmediata.
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppEspacio.xxl),
                  child: Text(
                    widget.titulo,
                    textAlign: TextAlign.center,
                    style: AppTexto.displayPequeno.copyWith(
                        color: AppColores.texto(context)),
                  ),
                ),
                const SizedBox(height: 24),
                // Datos de la operación, como ticket (M3): el
                // importe arriba y la línea de corte punteada lo
                // separa del detalle.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppEspacio.xxl),
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
                        if (widget.detalles.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                16, 0, 16, 4),
                            child: Column(
                              children: [
                                for (var i = 0;
                                    i < widget.detalles.length;
                                    i++) ...[
                                  if (i > 0) const Divider(),
                                  _fila(
                                      context,
                                      widget.detalles[i].etiqueta,
                                      widget.detalles[i].valor),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.comprobanteTexto != null) ...[
                  const SizedBox(height: 24),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppEspacio.xxl),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColores.superficie(context),
                        borderRadius:
                            BorderRadius.circular(AppRadio.lg),
                        border: Border.all(
                            color: AppColores.borde(context)),
                      ),
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.receipt_long_rounded,
                                  size: 18,
                                  color: AppColores.textoSecundario(
                                      context)),
                              const SizedBox(width: 8),
                              Text(
                                widget.comprobanteTitulo ??
                                    'Comprobante',
                                style: AppTexto.secundario.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(widget.comprobanteTexto!,
                              style: AppTexto.cuerpo),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                if (widget.accionExtra != null) ...[
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 48),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: Icon(widget.accionExtra!.icono),
                        label: Text(widget.accionExtra!.texto),
                        onPressed: widget.accionExtra!.alPulsar,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
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
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fila(BuildContext context, String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta, style: AppTexto.secundario),
          const SizedBox(width: 16),
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
  /// T6: con [ConfirmacionOperacionScreen.montoValor] cuenta
  /// hasta su valor con [MontoAnimado]; sin él, texto fijo.
  Widget _filaMonto(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(widget.etiquetaMonto, style: AppTexto.secundario),
          const SizedBox(width: 16),
          Flexible(
            child: widget.montoValor != null
                ? MontoAnimado(
                    valor: widget.montoValor!,
                    formato:
                        widget.montoFormato ?? (_) => widget.monto,
                    style: AppTexto.metrica,
                  )
                : Text(
                    widget.monto,
                    style: AppTexto.metrica.copyWith(fontFeatures:
                        const [FontFeature.tabularFigures()]),
                    textAlign: TextAlign.right,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Recibo del cobro de mensualidad (Bloque 1): envoltorio fino
/// de [ConfirmacionOperacionScreen] con el título, las filas y
/// el Deshacer del cobro. La API histórica se conserva intacta
/// para preview_cobro.dart y demás llamadores.
class ConfirmacionCobroScreen extends StatelessWidget {
  final String nombreCliente;
  final String monto;
  final String nuevoVencimiento;

  /// Compatibilidad de la API histórica: la pantalla nunca lo
  /// pintó y sigue sin pintarlo.
  final String? fotoUrl;

  /// Op local del cobro. null = recibo sin deshacer (llamadas viejas).
  final String? opUuid;

  /// T6 (opcional): valor numérico del monto para pintarlo con
  /// [MontoAnimado]. Los llamadores que no lo pasen conservan el
  /// texto fijo de [monto].
  final double? montoValor;
  final String Function(double)? montoFormato;

  const ConfirmacionCobroScreen({
    super.key,
    required this.nombreCliente,
    required this.monto,
    required this.nuevoVencimiento,
    this.fotoUrl,
    this.opUuid,
    this.montoValor,
    this.montoFormato,
  });

  @override
  Widget build(BuildContext context) {
    return ConfirmacionOperacionScreen(
      titulo: '¡Cobro registrado!',
      monto: monto,
      montoValor: montoValor,
      montoFormato: montoFormato,
      detalles: [
        (etiqueta: 'Cliente', valor: nombreCliente),
        (etiqueta: 'Nuevo vencimiento', valor: nuevoVencimiento),
      ],
      opUuid: opUuid,
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
