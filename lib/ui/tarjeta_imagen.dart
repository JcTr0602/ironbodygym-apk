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

/// La línea oficial del sistema de gestión, en texto
/// plano para imagen (la misma promesa que cierra los
/// mensajes de texto de la app).
const String lineaOficialTarjetaImagen =
    'Mensaje automático de nuestro sistema de gestión';

/// La línea de contacto del pie: el número al que se
/// responde (el de Jc), visible en la imagen.
const String lineaContactoTarjetaImagen =
    'Si vas a responder, escríbenos al 58191577';

/// El pie firmado de una tarjeta en imagen: wordmark
/// opcional (las tarjetas que ya lo llevan en la
/// cabecera no lo repiten), la línea oficial y la de
/// contacto con el 58191577 en peso fuerte.
class PieTarjetaImagen extends StatelessWidget {
  /// Color del wordmark y de la línea de contacto.
  final Color colorPrincipal;

  /// Color de la línea oficial (la secundaria).
  final Color colorSuave;

  /// Las tarjetas sin marca propia en la cabecera (el
  /// ticket de cobro) firman también con el wordmark.
  final bool conWordmark;

  const PieTarjetaImagen({
    super.key,
    required this.colorPrincipal,
    required this.colorSuave,
    this.conWordmark = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (conWordmark) ...[
          Text(
            'IRON BODY GYM',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colorPrincipal,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 3),
        ],
        Text(
          lineaOficialTarjetaImagen,
          textAlign: TextAlign.center,
          style: TextStyle(color: colorSuave, fontSize: 10.5),
        ),
        const SizedBox(height: 2),
        Text(
          lineaContactoTarjetaImagen,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colorPrincipal,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
