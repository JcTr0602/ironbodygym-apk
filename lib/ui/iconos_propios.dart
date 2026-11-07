/// Iconos propios de Gestión (1.29 OG-0, D-10): siluetas
/// dibujadas con CustomPainter para los dos conceptos que
/// la familia de Material no tiene — el POMO (el envase de
/// suplemento del que salen las dosis) y la DOSIS (la
/// cucharada medidora). Sin paquetes nuevos.
///
/// Gobierno (tabla del estudio 1.29 §4.2): lienzo de
/// diseño 24, trazo mínimo 2 px, suelo de uso 22 px —
/// NUNCA en chips de 16 ni como adorno diminuto. Nacen sin
/// llamadores en la fundación; los estrena Servicios en
/// la oleada 4.
library;

import 'package:flutter/material.dart';

/// Silueta de un pomo de suplemento: tapa, cuello y cuerpo.
///
/// [tamano] es el lado del cuadrado donde se pinta; el
/// suelo de la casa es 22 (se aserta en debug).
class IconoPomo extends StatelessWidget {
  final double tamano;
  final Color color;

  const IconoPomo({
    super.key,
    this.tamano = 24,
    required this.color,
  }) : assert(tamano >= 22,
            'IconoPomo: suelo de uso 22 px (1.29 D-10); prohibido en chips de 16');

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(tamano),
      painter: _PomoPainter(color),
    );
  }
}

/// Silueta de una dosis: la cucharada medidora con su
/// cazoleta y el mango en diagonal.
///
/// [tamano] es el lado del cuadrado donde se pinta; el
/// suelo de la casa es 22 (se aserta en debug).
class IconoDosis extends StatelessWidget {
  final double tamano;
  final Color color;

  const IconoDosis({
    super.key,
    this.tamano = 24,
    required this.color,
  }) : assert(tamano >= 22,
            'IconoDosis: suelo de uso 22 px (1.29 D-10); prohibido en chips de 16');

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(tamano),
      painter: _DosisPainter(color),
    );
  }
}

/// Escala un punto del lienzo de diseño (24) al tamaño real.
double _e(double v, double tamano) => v * tamano / 24;

class _PomoPainter extends CustomPainter {
  final Color color;
  const _PomoPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    final pintura = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final cuerpo = Path()
      // Tapa: banda superior redondeada.
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(_e(7, t), _e(2.5, t), _e(17, t), _e(6.5, t)),
        Radius.circular(_e(1.5, t)),
      ))
      // Cuello: anillo entre la tapa y el cuerpo.
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(_e(6, t), _e(6.5, t), _e(18, t), _e(8.5, t)),
        Radius.circular(_e(1, t)),
      ))
      // Cuerpo: el envase, más ancho, esquinas suaves.
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(_e(4.5, t), _e(8.5, t), _e(19.5, t), _e(21.5, t)),
        Radius.circular(_e(3, t)),
      ));
    canvas.drawPath(cuerpo, pintura);
  }

  @override
  bool shouldRepaint(_PomoPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _DosisPainter extends CustomPainter {
  final Color color;
  const _DosisPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    // Cazoleta: media cazoleta llena (el cuenco de la
    // cucharada), abierta por arriba.
    final relleno = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final cazoleta = Path()
      ..moveTo(_e(2.5, t), _e(13, t))
      ..arcTo(
        Rect.fromCircle(
            center: Offset(_e(9, t), _e(13, t)), radius: _e(6.5, t)),
        0,
        3.141592653589793,
        false,
      )
      ..close();
    canvas.drawPath(cazoleta, relleno);
    // Mango: trazo grueso (≥ 2 px en el lienzo de diseño)
    // en diagonal desde la cazoleta.
    final trazo = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _e(2.5, t)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(_e(13.5, t), _e(11.5, t)),
      Offset(_e(21, t), _e(5, t)),
      trazo,
    );
  }

  @override
  bool shouldRepaint(_DosisPainter oldDelegate) =>
      oldDelegate.color != color;
}
