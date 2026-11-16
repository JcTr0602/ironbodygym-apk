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

// ---------------------------------------------------------------------------
// 1.35 (UX-11): la familia crece — los conceptos de diario
// (cobrar, pase del día, turno, vencimiento) y los cuatro
// pilares, de la misma mano que el pomo y la dosis:
// silueta llena sobre el lienzo de 24, huecos por
// paridad (evenOdd) y el mismo suelo de uso de 22 px.
// La familia se juzga ENTERA en su lámina
// (capturas/ux11_lamina.png) ANTES de colocar ninguno:
// nacen sin llamadores, como nacieron el pomo y la dosis.
// ---------------------------------------------------------------------------

/// Base común de la familia: pinta el [painter] al
/// tamaño dado con el color dado.
abstract class _IconoPropioBase extends StatelessWidget {
  final double tamano;
  final Color color;

  const _IconoPropioBase({
    super.key,
    this.tamano = 24,
    required this.color,
  });

  CustomPainter painter(Color color);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(tamano),
      painter: painter(color),
    );
  }
}

/// Cobrar: el billete con su círculo central hueco.
class IconoCobrar extends _IconoPropioBase {
  const IconoCobrar({super.key, super.tamano, required super.color})
      : assert(tamano >= 22,
            'IconoCobrar: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _CobrarPainter(color);
}

/// Pase del día: la tarjeta con el rayo hueco.
class IconoPase extends _IconoPropioBase {
  const IconoPase({super.key, super.tamano, required super.color})
      : assert(tamano >= 22, 'IconoPase: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _PasePainter(color);
}

/// Turno: el reloj de anillo con sus agujas.
class IconoTurno extends _IconoPropioBase {
  const IconoTurno({super.key, super.tamano, required super.color})
      : assert(tamano >= 22, 'IconoTurno: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _TurnoPainter(color);
}

/// Vencimiento: el calendario con el aviso hueco.
class IconoVencimiento extends _IconoPropioBase {
  const IconoVencimiento({super.key, super.tamano, required super.color})
      : assert(tamano >= 22,
            'IconoVencimiento: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _VencimientoPainter(color);
}

/// Pilar Mostrador: el toldo y el mostrador con su puerta.
class IconoMostrador extends _IconoPropioBase {
  const IconoMostrador({super.key, super.tamano, required super.color})
      : assert(tamano >= 22,
            'IconoMostrador: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _MostradorPainter(color);
}

/// Pilar Clientes: dos bustos, el de delante manda.
class IconoClientes extends _IconoPropioBase {
  const IconoClientes({super.key, super.tamano, required super.color})
      : assert(tamano >= 22,
            'IconoClientes: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _ClientesPainter(color);
}

/// Pilar Tienda: el matraz de los suplementos.
class IconoTienda extends _IconoPropioBase {
  const IconoTienda({super.key, super.tamano, required super.color})
      : assert(tamano >= 22,
            'IconoTienda: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _TiendaPainter(color);
}

/// Pilar Negocio: el maletín con su asa y su cierre.
class IconoNegocio extends _IconoPropioBase {
  const IconoNegocio({super.key, super.tamano, required super.color})
      : assert(tamano >= 22,
            'IconoNegocio: suelo de uso 22 px (1.29 D-10)');

  @override
  CustomPainter painter(Color color) => _NegocioPainter(color);
}

/// Pinta una silueta con huecos: las subformas pares
/// recortan (PathFillType.evenOdd).
void _silueta(Canvas canvas, Color color, Path path) {
  path.fillType = PathFillType.evenOdd;
  canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill);
}

Path _rrect(double t, double l, double top, double r, double b, double radio) {
  return Path()
    ..addRRect(RRect.fromRectAndRadius(
      Rect.fromLTRB(_e(l, t), _e(top, t), _e(r, t), _e(b, t)),
      Radius.circular(_e(radio, t)),
    ));
}

Path _circulo(double t, double cx, double cy, double radio) {
  return Path()
    ..addOval(Rect.fromCircle(
        center: Offset(_e(cx, t), _e(cy, t)), radius: _e(radio, t)));
}

class _CobrarPainter extends CustomPainter {
  final Color color;
  const _CobrarPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    final p = _rrect(t, 2, 6, 22, 18, 2)
      ..addPath(_circulo(t, 12, 12, 3.4), Offset.zero);
    _silueta(canvas, color, p);
  }

  @override
  bool shouldRepaint(_CobrarPainter old) => old.color != color;
}

class _PasePainter extends CustomPainter {
  final Color color;
  const _PasePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    // El rayo, hueco sobre la tarjeta.
    final rayo = Path()
      ..moveTo(_e(13.4, t), _e(5.2, t))
      ..lineTo(_e(7.8, t), _e(13.2, t))
      ..lineTo(_e(11, t), _e(13.2, t))
      ..lineTo(_e(10, t), _e(18.8, t))
      ..lineTo(_e(16.2, t), _e(10.8, t))
      ..lineTo(_e(12.9, t), _e(10.8, t))
      ..close();
    final p = _rrect(t, 4.5, 2.5, 19.5, 21.5, 2.5)..addPath(rayo, Offset.zero);
    _silueta(canvas, color, p);
  }

  @override
  bool shouldRepaint(_PasePainter old) => old.color != color;
}

class _TurnoPainter extends CustomPainter {
  final Color color;
  const _TurnoPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    // Anillo (círculo menos su interior) + agujas llenas.
    final anillo = _circulo(t, 12, 12, 9.6)
      ..addPath(_circulo(t, 12, 12, 6.9), Offset.zero);
    _silueta(canvas, color, anillo);
    final relleno = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final agujas = Path()
      // Agujas: la corta hacia arriba, la larga a la derecha.
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTRB(_e(11.15, t), _e(7.6, t), _e(12.85, t), _e(12.6, t)),
          Radius.circular(_e(0.85, t))))
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTRB(_e(11.15, t), _e(11.15, t), _e(16.4, t), _e(12.85, t)),
          Radius.circular(_e(0.85, t))));
    canvas.drawPath(agujas, relleno);
  }

  @override
  bool shouldRepaint(_TurnoPainter old) => old.color != color;
}

class _VencimientoPainter extends CustomPainter {
  final Color color;
  const _VencimientoPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    final p = _rrect(t, 3, 4.5, 21, 21, 2)
      // La banda de la cabecera del calendario.
      ..addPath(_rrect(t, 3, 9.3, 21, 10.9, 0), Offset.zero)
      // El signo de aviso: trazo y punto, huecos.
      ..addPath(_rrect(t, 11.1, 12.6, 12.9, 17, 0.9), Offset.zero)
      ..addPath(_circulo(t, 12, 19.1, 1.05), Offset.zero);
    _silueta(canvas, color, p);
  }

  @override
  bool shouldRepaint(_VencimientoPainter old) => old.color != color;
}

class _MostradorPainter extends CustomPainter {
  final Color color;
  const _MostradorPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    final toldo = Path()
      ..moveTo(_e(2.8, t), _e(3.8, t))
      ..lineTo(_e(21.2, t), _e(3.8, t))
      ..lineTo(_e(19.4, t), _e(9, t))
      ..lineTo(_e(4.6, t), _e(9, t))
      ..close();
    canvas.drawPath(
        toldo,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill);
    final cuerpo = _rrect(t, 5.6, 11, 18.4, 20.6, 1)
      ..addPath(_rrect(t, 10.1, 14, 13.9, 20.6, 1), Offset.zero);
    _silueta(canvas, color, cuerpo);
  }

  @override
  bool shouldRepaint(_MostradorPainter old) => old.color != color;
}

class _ClientesPainter extends CustomPainter {
  final Color color;
  const _ClientesPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    final relleno = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final figuras = Path()
      // El de detrás (derecha): cabeza y hombros menores.
      ..addPath(_circulo(t, 17, 9.3, 2.9), Offset.zero)
      ..addPath(_rrect(t, 12.6, 14.6, 21.4, 20.8, 3), Offset.zero)
      // El de delante: cabeza y hombros que mandan.
      ..addPath(_circulo(t, 9, 8.4, 3.7), Offset.zero)
      ..addPath(_rrect(t, 2.6, 13.4, 15.4, 21, 3.6), Offset.zero);
    canvas.drawPath(figuras, relleno);
  }

  @override
  bool shouldRepaint(_ClientesPainter old) => old.color != color;
}

class _TiendaPainter extends CustomPainter {
  final Color color;
  const _TiendaPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    final matraz = Path()
      ..addPath(_rrect(t, 10, 2.8, 14, 8, 0.8), Offset.zero)
      ..moveTo(_e(10, t), _e(8, t))
      ..lineTo(_e(4.9, t), _e(18.6, t))
      ..quadraticBezierTo(
          _e(4.4, t), _e(21.2, t), _e(7.2, t), _e(21.2, t))
      ..lineTo(_e(16.8, t), _e(21.2, t))
      ..quadraticBezierTo(
          _e(19.6, t), _e(21.2, t), _e(19.1, t), _e(18.6, t))
      ..lineTo(_e(14, t), _e(8, t))
      ..close();
    canvas.drawPath(
        matraz,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_TiendaPainter old) => old.color != color;
}

class _NegocioPainter extends CustomPainter {
  final Color color;
  const _NegocioPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final t = size.width;
    final p = _rrect(t, 3, 8, 21, 20.6, 2)
      // El asa: su aro exterior suma, su hueco recorta.
      ..addPath(_rrect(t, 8.4, 3.4, 15.6, 8.8, 1.6), Offset.zero)
      ..addPath(_rrect(t, 10.2, 5.2, 13.8, 8.2, 1), Offset.zero)
      // La banda central del cierre, hueca.
      ..addPath(_rrect(t, 3, 13.4, 21, 15.1, 0), Offset.zero);
    _silueta(canvas, color, p);
    // El cierre metálico: una pieza llena sobre la banda.
    _silueta(canvas, color, _rrect(t, 10.6, 12.5, 13.4, 16, 0.8));
  }

  @override
  bool shouldRepaint(_NegocioPainter old) => old.color != color;
}

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
