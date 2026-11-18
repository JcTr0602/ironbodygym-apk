/// 1.32 (Oleada 2, Fase 3) — el pie ÚNICO de las
/// tarjetas en imagen que la app genera para WhatsApp
/// (plano maestro §6: «se unifica el motor visual que
/// genera el comprobante de pago en imagen (G-14), el
/// resumen de cierre de nómina (G-39, G-40) y la
/// tarjeta de felicitación de cumpleaños (G-16, G-30),
/// firmando siempre al pie con la línea oficial del
/// sistema de gestión y el número de contacto del
/// gym»).
///
/// La línea oficial es la de siempre
/// (negocio.lineaMensajeAutomatico, decisión de Jc
/// 2026-11-01) sin la sintaxis de WhatsApp: dentro de
/// una imagen no hay markdown que interpretar, y el
/// número de respuestas del gym — 58191577 — queda
/// visible en la propia foto, no solo en el texto que
/// la acompaña (que el cliente puede no reenviar).
library;

import 'package:flutter/material.dart';

import 'diseno.dart' show AppColores;

/// La línea oficial del sistema de gestión, en texto
/// plano para imagen (la misma promesa que cierra los
/// mensajes de texto de la app).
const String lineaOficialTarjetaImagen =
    'Mensaje automático de nuestro sistema de gestión';

/// La línea de contacto del pie: el número al que se
/// responde (el de Jc), visible en la imagen.
const String lineaContactoTarjetaImagen =
    'Si vas a responder, escríbenos al 58191577';

/// 1.35 (UX-07): la cabecera única de las tarjetas en
/// imagen — banda grafito con el arte del rayo y el
/// wordmark «IRON BODY GYM». La estrena el ticket de
/// cobro (UX-05) DENTRO del RepaintBoundary, así la
/// foto del comprobante que sale por WhatsApp hereda
/// la plantilla entera: cabecera, dato y pie firmado.
class CabeceraTarjetaIron extends StatelessWidget {
  const CabeceraTarjetaIron({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColores.grafitoTactico,
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(15)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset(
              'assets/arte_marca_rayo.jpg',
              width: 26,
              height: 26,
              fit: BoxFit.cover,
              // 1.36 H-B1 (136-388): si el arte de marca no
              // carga, la cabecera no se rompe — rayo de
              // marca de respaldo.
              errorBuilder: (_, __, ___) => const Icon(
                  Icons.bolt_rounded,
                  size: 26,
                  color: AppColores.naranja),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'IRON BODY GYM',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// El pie firmado de una tarjeta en imagen: wordmark
/// opcional (las tarjetas que ya lo llevan en la
/// cabecera no lo repiten), la línea oficial y la de
/// contacto con el 58191577 en peso fuerte.
class PieTarjetaImagen extends StatelessWidget {
  /// Color del wordmark y de la línea de contacto.
  final Color colorPrincipal;

  /// Color de la línea oficial (la secundaria).
  final Color colorSuave;

  /// 1.36 H-C1 (136-389): contrato — true SOLO en
  /// tarjetas SIN [CabeceraTarjetaIron] (que ya pinta el
  /// wordmark). Con cabecera, el pie va sin wordmark: el
  /// comprobante de cobro lo llevaba dos veces.
  final bool conWordmark;

  const PieTarjetaImagen({
    super.key,
    required this.colorPrincipal,
    required this.colorSuave,
    this.conWordmark = false,
  });

  @override
  Widget build(BuildContext context) {
    // 1.36 H-C1 (136-395): el pie trae su PROPIO padding
    // vertical y un cuerpo mayor (12): la imagen se
    // comparte por WhatsApp, que comprime, y el texto a
    // 10.5/11 se leía justo.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (conWordmark) ...[
          Text(
            'IRON BODY GYM',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colorPrincipal,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 3),
        ],
        Text(
          lineaOficialTarjetaImagen,
          textAlign: TextAlign.center,
          style: TextStyle(color: colorSuave, fontSize: 12),
        ),
        const SizedBox(height: 2),
        Text(
          lineaContactoTarjetaImagen,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colorPrincipal,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
      ),
    );
  }
}
