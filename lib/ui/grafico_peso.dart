// lib/ui/grafico_peso.dart
// v1.3.9 Sprint 2: gráfico de evolución de peso (adaptado de app clientes v0.4).
// Usa el modelo Medicion local (pesoKg + createdAt).
import 'package:flutter/material.dart';
import '../tiempo.dart';
import 'pestana_progreso.dart';

/// Naranja Iron Body
const _naranja = Color(0xFFFF6B00);

class GraficoPesoEntrenador extends StatelessWidget {
  final List<Medicion> mediciones;

  const GraficoPesoEntrenador(
      {super.key, required this.mediciones});

  @override
  Widget build(BuildContext context) {
    final conPeso =
        mediciones.where((m) => m.pesoKg > 0).toList();
    if (conPeso.length < 2)
      return const SizedBox.shrink();

    // Ordenar por fecha ascendente
    final ordenado = List<Medicion>.from(conPeso)
      ..sort((a, b) =>
          a.createdAt.compareTo(b.createdAt));

    final pesos =
        ordenado.map((m) => m.pesoKg).toList();
    final max =
        pesos.reduce((a, b) => a > b ? a : b);
    final min =
        pesos.reduce((a, b) => a < b ? a : b);
    final prom =
        pesos.reduce((a, b) => a + b) / pesos.length;

    // v1.4.1 (Pieza 6): fecha del eje en hora de La Habana.
    String fmtFecha(DateTime d) => fmtFechaHabana(d);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.show_chart,
                    color: _naranja, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'EVOLUCIÓN DE PESO',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                Text(
                  '${ordenado.first.pesoKg.toStringAsFixed(1)} → ${ordenado.last.pesoKg.toStringAsFixed(1)} kg',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _naranja,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              width: double.infinity,
              child: CustomPaint(
                painter: _GraficoPesoPainter(
                  pesos: pesos,
                  max: max,
                  min: min,
                  prom: prom,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  fmtFecha(ordenado.first.createdAt),
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.grey),
                ),
                Text(
                  fmtFecha(ordenado.last.createdAt),
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GraficoPesoPainter extends CustomPainter {
  final List<double> pesos;
  final double max;
  final double min;
  final double prom;

  _GraficoPesoPainter({
    required this.pesos,
    required this.max,
    required this.min,
    required this.prom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (pesos.length < 2) return;

    final rango =
        (max - min) == 0 ? 1.0 : (max - min);
    final padY = 24.0;
    final altoUtil = size.height - padY * 2;

    Offset punto(int i) {
      final x = pesos.length == 1
          ? size.width / 2
          : (i / (pesos.length - 1)) *
              size.width;
      final y = padY +
          altoUtil * (1 - (pesos[i] - min) / rango);
      return Offset(x, y);
    }

    // 1. Líneas guía punteadas
    final guiaPaint = Paint()
      ..color = Colors.grey.withOpacity(0.3)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final valor in [max, prom, min]) {
      final y = padY +
          altoUtil * (1 - (valor - min) / rango);
      _lineaPunteada(canvas, Offset(0, y),
          Offset(size.width, y), guiaPaint);
    }

    // 2. Área con gradiente
    final puntos =
        List.generate(pesos.length, punto);
    final areaPath = Path()
      ..moveTo(puntos.first.dx, size.height)
      ..lineTo(
          puntos.first.dx, puntos.first.dy);
    for (var i = 1; i < puntos.length; i++) {
      areaPath.lineTo(
          puntos[i].dx, puntos[i].dy);
    }
    areaPath
      ..lineTo(puntos.last.dx, size.height)
      ..close();
    final gradiente = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        _naranja.withOpacity(0.25),
        _naranja.withOpacity(0.0),
      ],
    );
    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = gradiente.createShader(
            Rect.fromLTWH(
                0, 0, size.width, size.height)),
    );

    // 3. Línea principal
    final lineaPath = Path()
      ..moveTo(
          puntos.first.dx, puntos.first.dy);
    for (var i = 1; i < puntos.length; i++) {
      lineaPath.lineTo(
          puntos[i].dx, puntos[i].dy);
    }
    canvas.drawPath(
      lineaPath,
      Paint()
        ..color = _naranja
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 4. Puntos
    final puntoPaint = Paint()..color = _naranja;
    final bordePaint = Paint()
      ..color = Colors.white;
    for (final p in puntos) {
      canvas.drawCircle(p, 5, bordePaint);
      canvas.drawCircle(p, 3.5, puntoPaint);
    }

    // 5. Etiquetas
    _etiqueta(
        canvas,
        pesos.first.toStringAsFixed(1),
        puntos.first.translate(0, -16),
        size);
    _etiqueta(
        canvas,
        pesos.last.toStringAsFixed(1),
        puntos.last.translate(0, -16),
        size);
  }

  void _lineaPunteada(Canvas canvas, Offset a,
      Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 4.0;
    final dx = b.dx - a.dx;
    final dist = dx.abs();
    var x = a.dx;
    while (x < a.dx + dist) {
      final x2 =
          (x + dash).clamp(a.dx, b.dx);
      canvas.drawLine(
          Offset(x, a.dy),
          Offset(x2, a.dy),
          paint);
      x += dash + gap;
    }
  }

  void _etiqueta(Canvas canvas, String texto,
      Offset pos, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: texto,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: _naranja,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Clamp horizontal para que no se salga
    var dx = pos.dx - tp.width / 2;
    dx = dx.clamp(0.0, size.width - tp.width);
    tp.paint(canvas, Offset(dx, pos.dy));
  }

  @override
  bool shouldRepaint(
          covariant _GraficoPesoPainter old) =>
      old.pesos != pesos ||
      old.max != max ||
      old.min != min ||
      old.prom != prom;
}
