/// 1.36 (136-291…294): las TARJETAS de WhatsApp de Gestión —
/// recibo de pago, comprobante de venta y aviso como imagen
/// 4:5 con la marca, enviadas por la hoja de compartir
/// (imagen + texto): el enlace wa.me no adjunta imágenes
/// (diseño aprobado por Jc el 2026-11-17, DISENO.md de
/// tarjetas_wa). El criterio TJ-14 (revisión Hy4 adjudicada)
/// es VINCULANTE y corrige al diseño común donde choca:
///  1. Sello «PAGADO» SOLO en ventas pagadas en el acto: el
///     comprobante FIADO va sin sello, con distintivo «FIADO ·
///     Pendiente de cobro» y sin la palabra PAGADO en todo el
///     árbol (adjudicación de forma fina del carril T).
///  2. La banda de promo lleva el calificador «con tu pago
///     en el acto» dentro de la banda; fiado nunca la lleva.
///  3. El importe es bloque indivisible: miles con espacio
///     duro (U+00A0) y moneda pegada, en un solo Text sin
///     envoltura ni recorte; se ajusta el resto del lienzo.
///  4. Nombres sin recortar: etiqueta de ancho fijo y valor
///     que envuelve en 2 líneas.
///  5. Sello con rotación leve, sin sombra, colocado sobre
///     la zona del título: no pisa la caja ámbar del total
///     ni el «Pagado hasta».
///  6. En el aviso, la fecha de vencimiento es protagonista
///     (titular naranja grande), no una fila más.
///  7. Lienzo OPACO: grafito hasta el borde, sin esquinas
///     transparentes al exportar (sin radio en el lienzo).
///  8. La marca se pinta desde el asset oficial ya
///     empaquetado (assets/logo.jpg); el wordmark va en
///     texto plano «IRON BODY GYM», sin el glifo ⚡.
///  9. Fechas completas en formato único en los tres
///     documentos: «Vence el 30 de noviembre» / «Pagado
///     hasta el 30 de noviembre» (fechaLargaCorta).
/// 10. Pie con tamaño mínimo del sistema (11) y el teléfono
///     canónico junto: 58191577.
/// TJ-01 (solo motor): la captura se renderiza con su
/// escala de texto PROPIA fijada dentro de la cáscara de
/// captura (TextScaler.noScaling), no con la del teléfono —
/// el mismo principio de la imagen de nómina (136-317).
/// EXCEPCIÓN «salida-imagen» (como cierre_nomina_imagen):
/// este archivo pinta el papel fijo que se COMPARTE; sus
/// literales viven solo dentro del lienzo.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../negocio.dart' show fechaLargaCorta, fmtMonto;
import 'componentes.dart' show mostrarSnackEnMessenger;
import 'confirmacion_cobro.dart' show conImagenTicket;
import 'diseno.dart' show AppColores;

// ── Formato del documento (PURO, testeable) ─────────────────

/// TJ-14.3: el importe de la tarjeta como bloque indivisible:
/// la cifra de fmtMonto con los miles separados por espacio
/// DURO (U+00A0) y la moneda pegada con el mismo espacio
/// duro — ni el render ni el chat pueden partirlo ni
/// recortarlo. Ej.: 4500 CUP → «4 500 CUP» (con U+00A0).
String importeTarjetaWa(num monto, String moneda) {
  final crudo = fmtMonto(monto);
  final signo = crudo.startsWith('-') ? '-' : '';
  final cuerpo = signo.isEmpty ? crudo : crudo.substring(1);
  final punto = cuerpo.indexOf('.');
  final entero = punto < 0 ? cuerpo : cuerpo.substring(0, punto);
  final decimales = punto < 0 ? '' : cuerpo.substring(punto);
  final buf = StringBuffer(signo);
  for (var i = 0; i < entero.length; i++) {
    if (i > 0 && (entero.length - i) % 3 == 0) buf.write('\u00A0');
    buf.write(entero[i]);
  }
  return '$buf$decimales\u00A0$moneda';
}

/// TJ-14.9: la fecha completa del documento, en el formato
/// único de la casa («30 de noviembre», de fechaLargaCorta).
/// ISO ilegible → '—'.
String fechaTarjetaWa(String? iso) => fechaLargaCorta(iso);

// ── Lienzo común ────────────────────────────────────────────

const double _anchoTarjetaWa = 360;
const double _altoTarjetaWa = 450; // 4:5

const _fondoWa = AppColores.grafitoTactico;
const _naranjaWa = AppColores.naranja;
const _textoSuaveWa = Color(0xFFB9C0CC);
const _verdeWa = Color(0xFF2FBF71);
const _ambarCajaWa = Color(0xFF3A2C17);

/// La cáscara del lienzo: tamaño fijo 4:5, grafito OPACO
/// hasta el borde (TJ-14.7), banda naranja superior,
/// cabecera con el logo oficial (TJ-14.8) y escala de
/// texto propia fijada (TJ-01).
class _LienzoTarjetaWa extends StatelessWidget {
  const _LienzoTarjetaWa({
    required this.tipo,
    required this.hijos,
    this.pieAutomatico = false,
  });

  /// El tipo del documento en naranja y versalitas.
  final String tipo;
  final List<Widget> hijos;

  /// true en el aviso (pie = línea automática estándar);
  /// false en recibo/comprobante (pie = gracias + contacto).
  final bool pieAutomatico;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.noScaling),
      child: Container(
        width: _anchoTarjetaWa,
        // 4:5 de referencia: alto MÍNIMO 450; si el contenido
        // lo exige (nombres largos que envuelven, promo), el
        // lienzo crece en vez de recortar (TJ-14.3/4).
        constraints: const BoxConstraints(minHeight: _altoTarjetaWa),
        color: _fondoWa,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(height: 8, color: _naranjaWa),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/logo.jpg',
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'IRON BODY GYM',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'TRINIDAD · CUBA',
                          style: TextStyle(
                            color: _textoSuaveWa,
                            fontSize: 11,
                            letterSpacing: 2.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Text(
                tipo.toUpperCase(),
                style: const TextStyle(
                  color: _naranjaWa,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 24, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: hijos,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Divider(color: Color(0xFF333B47), height: 1),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
              child: pieAutomatico
                  ? const Text(
                      '🤖 Mensaje automático de nuestro sistema de '
                      'gestión; no lo envía una persona. Si vas a '
                      'responder, escríbenos al 58191577.',
                      style: TextStyle(
                          color: _textoSuaveWa, fontSize: 11),
                    )
                  : const Text(
                      '💪 Gracias por entrenar con nosotros. Si vas '
                      'a responder, escríbenos al 58191577.',
                      style: TextStyle(
                          color: _textoSuaveWa, fontSize: 11),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// TJ-14.4: fila etiqueta/valor del documento — etiqueta de
/// ancho fijo; el valor envuelve en hasta 2 líneas, jamás
/// se recorta con puntos suspensivos.
class _FilaTarjetaWa extends StatelessWidget {
  const _FilaTarjetaWa(this.etiqueta, this.valor, {this.valorVerde = false});

  final String etiqueta;
  final String valor;
  final bool valorVerde;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              etiqueta,
              style: const TextStyle(color: _textoSuaveWa, fontSize: 14),
            ),
          ),
          Expanded(
            child: Text(
              valor,
              maxLines: 2,
              softWrap: true,
              overflow: TextOverflow.visible,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: valorVerde ? _verdeWa : Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TJ-14.3/5: la caja ámbar del importe protagonista. El
/// importe va en UN solo Text sin envoltura (softWrap
/// false, overflow visible): es bloque indivisible.
class _CajaImporteWa extends StatelessWidget {
  const _CajaImporteWa({required this.etiqueta, required this.importe});

  final String etiqueta;
  final String importe;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _ambarCajaWa,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _naranjaWa.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Text(
            etiqueta,
            style: const TextStyle(color: _textoSuaveWa, fontSize: 14),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              importe,
              key: const ValueKey('importe_tarjeta_wa'),
              softWrap: false,
              overflow: TextOverflow.visible,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: _naranjaWa,
                fontSize: 25,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TJ-14.5: el sello «PAGADO» — rotación leve, sin sombra,
/// y quien lo coloca lo pone sobre la zona del título,
/// lejos de la caja ámbar y del «Pagado hasta».
class _SelloPagadoWa extends StatelessWidget {
  const _SelloPagadoWa();

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.09,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: _verdeWa, width: 2.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'PAGADO',
          style: TextStyle(
            color: _verdeWa,
            fontSize: 21,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}

/// El distintivo del comprobante FIADO (adjudicación de
/// forma fina de TJ-14.1): ámbar, visible, sin la palabra
/// prohibida — la venta no está pagada y el documento lo
/// dice tal cual.
class _DistintivoFiadoWa extends StatelessWidget {
  const _DistintivoFiadoWa();

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.09,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFFBBF24), width: 2.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'FIADO',
          style: TextStyle(
            color: Color(0xFFFBBF24),
            fontSize: 21,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}

/// Título del documento con el sello/distintivo a su
/// derecha, en la misma banda (TJ-14.5: el sello vive
/// aquí, nunca sobre la caja del importe).
class _TituloConSelloWa extends StatelessWidget {
  const _TituloConSelloWa({required this.titulo, this.sello});

  final String titulo;
  final Widget? sello;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            titulo,
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.visible,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 27,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (sello != null) ...[
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: sello!,
          ),
        ],
      ],
    );
  }
}

// ── 136-292 · Recibo de pago ────────────────────────────────

class TarjetaWaRecibo extends StatelessWidget {
  const TarjetaWaRecibo({
    super.key,
    required this.cliente,
    required this.concepto,
    required this.metodo,
    required this.fechaIso,
    required this.total,
    this.moneda = 'CUP',
    required this.pagadoHastaIso,
  });

  final String cliente;

  /// El concepto/período del título («Mensualidad»).
  final String concepto;
  final String metodo;

  /// Fecha del cobro, ISO (yyyy-MM-dd…).
  final String fechaIso;
  final double total;
  final String moneda;

  /// El nuevo vencimiento, ISO.
  final String pagadoHastaIso;

  @override
  Widget build(BuildContext context) {
    return _LienzoTarjetaWa(
      tipo: 'Recibo de pago',
      hijos: [
        const _TituloConSelloWa(
          titulo: 'Mensualidad',
          sello: _SelloPagadoWa(),
        ),
        const SizedBox(height: 10),
        _FilaTarjetaWa('Cliente', cliente),
        _FilaTarjetaWa('Concepto', concepto),
        _FilaTarjetaWa('Método', metodo),
        _FilaTarjetaWa('Fecha', fechaTarjetaWa(fechaIso)),
        _CajaImporteWa(
          etiqueta: 'Total pagado',
          importe: importeTarjetaWa(total, moneda),
        ),
        const SizedBox(height: 8),
        _FilaTarjetaWa(
          'Pagado hasta',
          'Pagado hasta el ${fechaTarjetaWa(pagadoHastaIso)}',
          valorVerde: true,
        ),
      ],
    );
  }
}

// ── 136-293 · Comprobante de venta ──────────────────────────

class TarjetaWaComprobante extends StatelessWidget {
  const TarjetaWaComprobante({
    super.key,
    required this.cliente,
    required this.titulo,
    required this.producto,
    required this.cantidad,
    required this.fechaIso,
    required this.total,
    this.moneda = 'CUP',
    required this.esFiado,
    required this.conPromo,
  });

  final String cliente;

  /// «Suplemento» / «Servicio» — el título del documento.
  final String titulo;
  final String producto;
  final int cantidad;
  final String fechaIso;
  final double total;
  final String moneda;

  /// TJ-14.1: fiado ⇒ sin sello, sin promo, con distintivo.
  final bool esFiado;

  /// La promo SOLO nace de ventas pagadas en el acto: el
  /// llamador la calcula con la regla de la casa
  /// (conPromoVentaSuplemento ya excluye el fiado); aquí se
  /// vuelve a guardar la verdad: fiado nunca la pinta.
  final bool conPromo;

  bool get _promoVisible => conPromo && !esFiado;

  @override
  Widget build(BuildContext context) {
    return _LienzoTarjetaWa(
      tipo: 'Comprobante de venta',
      hijos: [
        _TituloConSelloWa(
          titulo: titulo,
          sello: esFiado ? const _DistintivoFiadoWa() : const _SelloPagadoWa(),
        ),
        if (esFiado)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Pendiente de cobro',
              style: TextStyle(
                color: Color(0xFFFBBF24),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        const SizedBox(height: 10),
        _FilaTarjetaWa('Cliente', cliente),
        _FilaTarjetaWa('Producto', producto),
        _FilaTarjetaWa('Cantidad', '$cantidad'),
        _FilaTarjetaWa('Fecha', fechaTarjetaWa(fechaIso)),
        _CajaImporteWa(
          etiqueta: esFiado ? 'Total' : 'Total pagado',
          importe: importeTarjetaWa(total, moneda),
        ),
        if (_promoVisible) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF14352A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _verdeWa.withValues(alpha: 0.6)),
            ),
            child: const Text(
              '🎁 Tu compra incluye 1 mes de gym gratis con tu '
              'pago en el acto. ¡Aprovéchalo!',
              style: TextStyle(
                color: Color(0xFFB9F5D5),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ── 136-294 · Aviso ─────────────────────────────────────────

class TarjetaWaAviso extends StatelessWidget {
  const TarjetaWaAviso({
    super.key,
    required this.nombre,
    required this.vencimientoIso,
    this.precios = const [],
    this.yaVencido = false,
  });

  /// El nombre completo del cliente (el saludo usa el
  /// primer nombre, como los textos de la casa).
  final String nombre;

  /// La fecha de vencimiento, ISO — la protagonista.
  final String vencimientoIso;

  /// Precios vigentes ya formateados («2 000 CUP en
  /// efectivo»); vacío = sin bloque de precios.
  final List<String> precios;
  final bool yaVencido;

  @override
  Widget build(BuildContext context) {
    final primerNombre = nombre.trim().split(' ').first;
    return _LienzoTarjetaWa(
      tipo: 'Aviso importante',
      pieAutomatico: true,
      hijos: [
        Text(
          yaVencido
              ? 'Tu mensualidad\nestá vencida'
              : 'Tu mensualidad\nvence pronto',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 27,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Hola, $primerNombre 👋',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        const SizedBox(height: 10),
        // TJ-14.6: la fecha de vencimiento manda en el
        // aviso — titular naranja grande, formato único.
        Text(
          yaVencido
              ? 'Venció el ${fechaTarjetaWa(vencimientoIso)}'
              : 'Vence el ${fechaTarjetaWa(vencimientoIso)}',
          key: const ValueKey('fecha_aviso_tarjeta_wa'),
          style: const TextStyle(
            color: _naranjaWa,
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Renueva a tiempo para no perder tu ritmo de '
          'entrenamiento ni tu puesto en el horario.',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        if (precios.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Divider(color: Color(0xFF333B47), height: 1),
          const SizedBox(height: 8),
          _FilaTarjetaWa('Mensualidad', precios.first),
          for (final p in precios.skip(1))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                p,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

// ── 136-291 · Motor: captura PNG + hoja de compartir ────────

/// Muestra la tarjeta en un diálogo (la misma gramática de
/// la foto de nómina: vista + «Compartir imagen») y la
/// comparte como PNG con [texto] de pie por la hoja del
/// sistema. La captura usa la cáscara propia de la tarjeta
/// (escala fijada en el lienzo, TJ-01) a pixelRatio 3.0
/// sobre el lienzo de 360×450 → PNG de 1080×1350.
Future<void> mostrarCompartirTarjetaWa(
  BuildContext context, {
  required Widget tarjeta,
  required String texto,
  required String nombreArchivo,
}) async {
  final boundaryKey = GlobalKey();
  var compartiendo = false;
  final messenger = ScaffoldMessenger.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: SingleChildScrollView(
        child: RepaintBoundary(key: boundaryKey, child: tarjeta),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cerrar'),
        ),
        StatefulBuilder(
          builder: (ctx, setLocal) => FilledButton.icon(
            icon: const Icon(Icons.share_rounded, size: 18),
            label: const Text('Compartir imagen'),
            onPressed: compartiendo
                ? null
                : () async {
                    setLocal(() => compartiendo = true);
                    try {
                      final boundary = boundaryKey.currentContext!
                          .findRenderObject() as RenderRepaintBoundary;
                      final imagen =
                          await boundary.toImage(pixelRatio: 3.0);
                      await conImagenTicket(imagen, (bytes) async {
                        final dir = await getTemporaryDirectory();
                        final f = await File('${dir.path}/$nombreArchivo.png')
                            .writeAsBytes(bytes);
                        await Share.shareXFiles([XFile(f.path)],
                            text: texto);
                      });
                    } catch (_) {
                      mostrarSnackEnMessenger(
                          messenger, 'No se pudo compartir la imagen');
                    } finally {
                      setLocal(() => compartiendo = false);
                    }
                  },
          ),
        ),
      ],
    ),
  );
}

/// Solo para tests del motor: expone el tamaño del lienzo.
@visibleForTesting
Size get tamanoLienzoTarjetaWa =>
    const Size(_anchoTarjetaWa, _altoTarjetaWa);
