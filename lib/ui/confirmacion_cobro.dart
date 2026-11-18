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
/// 1.31 (Yunque A, Pieza 3): con [ConfirmacionOperacionScreen.comprobantePie]
/// la pantalla ofrece además «Enviar comprobante»: fotografía el
/// ticket (RepaintBoundary, patrón de la foto de nómina) y lo
/// comparte como PNG por el selector del sistema con el texto del
/// recibo como pie. Convive con el botón de texto (wa.me no admite
/// imágenes). Solo el cobro lo activa.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import 'componentes.dart';
import 'diseno.dart';
import 'tarjeta_imagen.dart';
import 'tarjetas_wa.dart' show mostrarCompartirTarjetaWa;

/// SL-4 · G10-6: genera los bytes PNG de [imagen] (el ticket
/// a resolución 3.0), los pasa a [usar] y libera la imagen
/// SIEMPRE (finally): también si [usar] falla a mitad del
/// envío. Antes la imagen creada en cada envío nunca se
/// liberaba — fuga de memoria nativa por envío.
Future<T> conImagenTicket<T>(
    ui.Image imagen, Future<T> Function(Uint8List bytes) usar) async {
  try {
    final datos =
        await imagen.toByteData(format: ui.ImageByteFormat.png);
    if (datos == null) throw StateError('sin imagen');
    return await usar(datos.buffer.asUint8List());
  } finally {
    imagen.dispose();
  }
}

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

  /// 1.31 (Yunque A, Pieza 3): pie de texto del comprobante en
  /// imagen. Si viene, la pantalla muestra «Enviar comprobante»
  /// bajo la acción extra: captura el ticket a PNG y lo comparte
  /// por el selector del sistema con este texto como pie.
  final String? comprobantePie;

  /// Op local del cobro. null = confirmación sin deshacer.
  final String? opUuid;

  /// 1.36 (136-291…294): la TARJETA de WhatsApp de la
  /// operación (recibo/comprobante ya pintado por el
  /// llamador). Si viene, la pantalla ofrece «Enviar
  /// tarjeta»: el motor la captura a PNG y la comparte
  /// imagen+texto por la hoja del sistema (wa.me no
  /// adjunta). El texto es [tarjetaTexto] o, en su
  /// defecto, el pie del comprobante / el comprobante.
  final Widget? tarjetaWa;
  final String? tarjetaTexto;
  final String tarjetaNombreArchivo;

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
    this.comprobantePie,
    this.opUuid,
    this.tarjetaWa,
    this.tarjetaTexto,
    this.tarjetaNombreArchivo = 'tarjeta_wa',
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

  /// 1.31 (Yunque A, Pieza 3): la foto del ticket del recibo.
  final GlobalKey _ticketKey = GlobalKey();
  bool _compartiendoComprobante = false;

  /// Fotografía el ticket y lo comparte como PNG con el texto
  /// del recibo como pie (patrón de la foto de nómina, M3-C3).
  Future<void> _enviarComprobante() async {
    if (_compartiendoComprobante) return;
    setState(() => _compartiendoComprobante = true);
    try {
      final boundary = _ticketKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      final imagen = await boundary.toImage(pixelRatio: 3.0);
      // SL-4 · G10-6: la imagen se libera tras generar los
      // bytes, también si compartir falla (conImagenTicket).
      await conImagenTicket(imagen, (bytes) async {
        final dir = await getTemporaryDirectory();
        final f = await File('${dir.path}/comprobante_cobro.png')
            .writeAsBytes(bytes);
        await Share.shareXFiles([XFile(f.path)],
            text: widget.comprobantePie);
      });
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo compartir la imagen',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _compartiendoComprobante = false);
    }
  }

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
                const SizedBox(height: AppEspacio.xl),
                // Check grande animado (M9/T6): entra escalando en
                // 350 ms; confirmación visual inmediata.
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.5, end: 1.0),
                  duration: AppMovimiento.larga,
                  curve: AppMovimiento.curvaPop,
                  builder: (context, escala, hijo) =>
                      Transform.scale(scale: escala, child: hijo),
                  // 1.35 (UX-05): la marca de hecho vive
                  // dentro del anillo naranja de marca; el
                  // check conserva su color de estado
                  // (norma de la casa: el estado no se
                  // tiñe de marca).
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color:
                          AppColores.naranja.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AppColores.naranja, width: 3),
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      size: 80,
                      color: AppColores.exito,
                    ),
                  ),
                ),
                const SizedBox(height: AppEspacio.xxl),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppEspacio.xxl),
                  child: Text(
                    widget.titulo,
                    textAlign: TextAlign.center,
                    style: AppTexto.displayPequeno.copyWith(
                        color: AppColores.texto(context)),
                  ),
                ),
                const SizedBox(height: AppEspacio.xl),
                // Datos de la operación, como ticket (M3): el
                // importe arriba y la línea de corte punteada lo
                // separa del detalle.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppEspacio.xxl),
                  child: RepaintBoundary(
                    // 1.31 (Yunque A, Pieza 3): el ticket es lo
                    // que se fotografía para «Enviar comprobante».
                    key: _ticketKey,
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
                        // 1.35 (UX-05/UX-07): la cabecera
                        // grafito de la plantilla «tarjeta
                        // Iron Body» DENTRO del ticket: la
                        // foto del comprobante hereda la
                        // cabecera, no solo el pie.
                        const CabeceraTarjetaIron(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                              16, 10, 16, 0),
                          child: _filaMonto(context),
                        ),
                        const SizedBox(height: AppEspacio.xs),
                        // 1.35 (UX-05): el corte del papel
                        // — línea punteada con las muescas
                        // laterales del ticket rasgado.
                        const _CorteTicket(),
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
                        // 1.32 (Fase 3): cuando el ticket es
                        // un comprobante compartible (hay
                        // pie de recibo), la FOTO firma al
                        // pie con la línea oficial y el
                        // 58191577 (plano §6 y pieza
                        // premium 7): el número viaja EN
                        // la imagen, no solo en el texto
                        // que la acompaña. Sin comprobante
                        // (confirmaciones internas) el
                        // ticket no se firma.
                        if (widget.comprobantePie != null) ...[
                          const SizedBox(height: AppEspacio.xs),
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
                                16, 8, 16, 12),
                            child: PieTarjetaImagen(
                              colorPrincipal:
                                  AppColores.texto(context),
                              colorSuave:
                                  AppColores.textoSecundario(
                                      context),
                              conWordmark: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                    ),
                  ),
                ),
                if (widget.comprobanteTexto != null) ...[
                  const SizedBox(height: AppEspacio.xl),
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
                              const SizedBox(width: AppEspacio.sm),
                              Text(
                                widget.comprobanteTitulo ??
                                    'Comprobante',
                                style: AppTexto.secundario.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppEspacio.sm),
                          Text(widget.comprobanteTexto!,
                              style: AppTexto.cuerpo),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppEspacio.xxl),
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
                  const SizedBox(height: AppEspacio.lg),
                ],
                // 1.31 (Yunque A, Pieza 3): el comprobante en
                // imagen, junto al envío de texto (wa.me no
                // admite imágenes: conviven los dos botones).
                if (widget.comprobantePie != null) ...[
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 48),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.image_rounded),
                        label: const Text('Enviar comprobante'),
                        onPressed: _compartiendoComprobante
                            ? null
                            : _enviarComprobante,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppEspacio.lg),
                ],
                // 1.36 (136-291…294): la tarjeta de WhatsApp
                // de la operación, imagen+texto por la hoja
                // de compartir (el motor de tarjetas_wa).
                if (widget.tarjetaWa != null) ...[
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 48),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.image_rounded),
                        label: const Text('Enviar tarjeta'),
                        onPressed: () => mostrarCompartirTarjetaWa(
                          context,
                          tarjeta: widget.tarjetaWa!,
                          texto: widget.tarjetaTexto ??
                              widget.comprobantePie ??
                              widget.comprobanteTexto ??
                              '',
                          nombreArchivo: widget.tarjetaNombreArchivo,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppEspacio.lg),
                ],
                // 1.36 H-B2 (136-612): el bloque de deshacer
                // entra/sale animado en altura y fundido al
                // pasar de «puede deshacer» a «ya subió».
                AnimatedSize(
                  duration: AppMovimiento.resuelta(
                      context, AppMovimiento.media),
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: AppMovimiento.resuelta(
                        context, AppMovimiento.media),
                    child: KeyedSubtree(
                      key: ValueKey(_puedeDeshacer
                          ? 'deshacer'
                          : (_yaSubio ? 'subio' : 'nada')),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                  // 1.28 (M4-C6): barra de tiempo de la
                  // ventana — el contador en texto solo se
                  // nota si se lee; la barra se VE vaciarse.
                  // Se anima suave hacia cada segundo (el
                  // Timer ya baja de 1 en 1).
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadio.sm),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                            end: (_segundos / 15).clamp(0.0, 1.0)),
                        // 1.35 (UI-13): NO es un token a
                        // propósito: la barra sigue a la
                        // cuenta atrás real de 15 s.
                        duration: const Duration(milliseconds: 950),
                        builder: (_, v, __) =>
                            LinearProgressIndicator(
                          value: v,
                          minHeight: 4,
                          color: AppColores.error,
                          backgroundColor: AppColores.borde(context),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 48),
                    child: Text(
                      'Si deshaces, el cobro se borra del teléfono '
                      'porque aún no subió.',
                      textAlign: TextAlign.center,
                      style: AppTexto.metadato,
                    ),
                  ),
                  const SizedBox(height: AppEspacio.lg),
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
                  const SizedBox(height: AppEspacio.lg),
                ],
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: BotonPrimario(
                    texto: 'Entendido',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(height: AppEspacio.xl),
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
          const SizedBox(width: AppEspacio.lg),
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
          const SizedBox(width: AppEspacio.lg),
          Flexible(
            // 1.35 (UX-05): el monto es el protagonista
            // del recibo — sube de métrica a display.
            child: widget.montoValor != null
                ? MontoAnimado(
                    valor: widget.montoValor!,
                    // 1.36 H-B2 (136-612): el formato por
                    // defecto es fmtMonto (el de la casa), no
                    // la cadena ya formateada del llamador.
                    formato:
                        widget.montoFormato ?? (v) => fmtMonto(v),
                    style: AppTexto.displayPequeno,
                  )
                : Text(
                    widget.monto,
                    style: AppTexto.displayPequeno.copyWith(
                        fontFeatures:
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

  /// 1.25 T66: el escalón que rigió el precio, como fila
  /// del ticket del recibo (el Preview lo lleva de chip).
  final String? escalonTexto;

  /// 1.25 T69: acción extra bajo el ticket (enviar el
  /// recibo por WhatsApp), la misma vía de la venta.
  final AccionExtraConfirmacion? accionExtra;

  /// 1.31 (Yunque A, Pieza 3): pie del comprobante en imagen
  /// (el texto del recibo); activa el botón «Enviar
  /// comprobante» de la pantalla.
  final String? comprobantePie;

  /// 1.36 (136-292): la tarjeta de recibo ya pintada.
  final Widget? tarjetaWa;
  final String? tarjetaTexto;

  const ConfirmacionCobroScreen({
    super.key,
    required this.nombreCliente,
    required this.monto,
    required this.nuevoVencimiento,
    this.fotoUrl,
    this.opUuid,
    this.montoValor,
    this.montoFormato,
    this.escalonTexto,
    this.accionExtra,
    this.comprobantePie,
    this.tarjetaWa,
    this.tarjetaTexto,
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
        // 1.25 T66: el sello del precio también en el
        // recibo, como fila del ticket.
        if (escalonTexto != null)
          (etiqueta: 'Precio según', valor: escalonTexto!),
      ],
      opUuid: opUuid,
      accionExtra: accionExtra,
      comprobantePie: comprobantePie,
      tarjetaWa: tarjetaWa,
      tarjetaTexto: tarjetaTexto,
      tarjetaNombreArchivo: 'tarjeta_recibo',
    );
  }
}

/// 1.35 (UX-05): el corte del ticket — la línea
/// punteada con las dos muescas laterales del papel
/// rasgado: círculos del color del fondo de la
/// pantalla que «muerden» los bordes del ticket (el
/// ticket no se recorta: las muescas se pintan encima
/// de sus esquinas del corte).
class _CorteTicket extends StatelessWidget {
  const _CorteTicket();

  @override
  Widget build(BuildContext context) {
    // 1.36 H-B2 (136-612): la muesca SIN borde — un círculo
    // del color del fondo se lee como el mordisco del papel
    // rasgado; con borde parecía una pegatina sobre el ticket.
    Widget muesca() => Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: AppColores.fondo(context),
            shape: BoxShape.circle,
          ),
        );
    return SizedBox(
      height: 14,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          SizedBox(
            height: 1.2,
            width: double.infinity,
            child: CustomPaint(
              painter: _PunteadaPainter(AppColores.borde(context)),
            ),
          ),
          Positioned(left: -7, child: muesca()),
          Positioned(right: -7, child: muesca()),
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
