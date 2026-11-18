// lib/ui/grafico_metrica.dart
// 1.25 T109: gráfico de evolución de gama alta para
// Gestión, con el estándar aprobado en Clientes 0.15:
// - Eje X de TIEMPO REAL: la posición horizontal sale
//   de la fecha, no del índice (3 días ya no ocupan lo
//   mismo que 3 meses).
// - Tocar un punto enseña su valor y su fecha en la
//   línea bajo el gráfico, con el punto resaltado.
// - La serie plana se dibuja CENTRADA (rango expandido),
//   no pegada al suelo.
// - Las guías (máx, promedio, mín) van ROTULADAS con su
//   valor a la izquierda.
// Sirve para cualquier métrica de las mediciones (peso,
// cintura, brazo, muslo...), no solo para el peso.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../tiempo.dart';
import 'diseno.dart';
import 'primitivas.dart';

/// Un punto de la serie: fecha (instante) y valor.
class PuntoSerie {
  final DateTime fecha;
  final double valor;
  const PuntoSerie(this.fecha, this.valor);
}

/// Posición horizontal 0..1 de cada fecha en el eje de
/// tiempo real. [fechas] deben venir ordenadas. Si todas
/// caen el mismo día no hay tiempo que representar y se
/// reparte por índice; con un solo punto, el centro.
List<double> fraccionesEjeTiempo(List<DateTime> fechas) {
  if (fechas.isEmpty) return const [];
  if (fechas.length == 1) return const [0.5];
  // Yunque R5-M9-5: el día del eje es el día HABANA, el
  // mismo que rotulan las etiquetas (fmtFechaHabana): con
  // los campos crudos, una medición de madrugada UTC se
  // agrupaba por un día distinto del que decía su rótulo.
  final dias = [
    for (final f in fechas)
      DateTime.utc(aHabana(f).year, aHabana(f).month, aHabana(f).day)
              .millisecondsSinceEpoch ~/
          86400000,
  ];
  final span = dias.last - dias.first;
  if (span <= 0) {
    return [for (var i = 0; i < fechas.length; i++) i / (fechas.length - 1)];
  }
  return [for (final d in dias) (d - dias.first) / span];
}

/// El rango visible de la serie: si es plana (máx ==
/// mín), se expande ±1 para dibujarla en el CENTRO en
/// vez de pegada al suelo. Si no es plana, Yunque
/// R5-M9-1: margen del 10 % del rango en cada extremo —
/// sin él, una variación mínima (99,9 → 100,1 kg) llenaba
/// todo el alto y se leía como un cambio enorme.
({double minE, double maxE}) rangoVisibleSerie(double min, double max) {
  if (max == min) return (minE: min - 1, maxE: max + 1);
  final margen = (max - min) * 0.1;
  return (minE: min - margen, maxE: max + margen);
}

/// El índice del punto cuya X (fracción × ancho) queda
/// más cerca del toque [dx]. -1 si no hay puntos.
int indicePuntoCercano(List<double> xs, double dx, double ancho) {
  if (xs.isEmpty || ancho <= 0) return -1;
  var mejor = 0;
  var mejorDist = double.infinity;
  for (var i = 0; i < xs.length; i++) {
    final dist = (xs[i] * ancho - dx).abs();
    if (dist < mejorDist) {
      mejorDist = dist;
      mejor = i;
    }
  }
  return mejor;
}

class GraficoMetricaGestion extends StatefulWidget {
  final String titulo;
  final String unidad;
  final List<PuntoSerie> puntos;
  final Color color;

  /// 1.35 (UX-08): el objetivo de la métrica (p. ej. el
  /// peso objetivo), si el llamador lo tiene: el gráfico
  /// lo marca con su banda y su palabra. Hoy NINGÚN
  /// llamador lo pasa — el modelo no guarda un objetivo
  /// por métrica — y la banda queda lista para cuando
  /// el dato exista, sin inventarlo.
  final double? objetivo;

  const GraficoMetricaGestion({
    super.key,
    required this.titulo,
    required this.unidad,
    required this.puntos,
    this.color = AppColores.naranja,
    this.objetivo,
  });

  @override
  State<GraficoMetricaGestion> createState() => _GraficoMetricaGestionState();
}

class _GraficoMetricaGestionState extends State<GraficoMetricaGestion>
    with SingleTickerProviderStateMixin {
  int? _sel;

  /// 1.35 (UI-03): trazado de entrada de la línea (una
  /// sola vez, al primer pintado; un cambio de datos no
  /// re-anima). Con «reducir movimiento» nace puesta.
  late final AnimationController _trazo = AnimationController(
    vsync: this,
    duration: AppMovimiento.larga,
  );

  /// 1.36 H-C1 (136-397): transición CORTA del punto
  /// seleccionado (radio y guía crecen, no saltan). El
  /// trazo de entrada conserva su token largo (elección
  /// legítima UI-03, fuera de esta fila).
  late final AnimationController _transSel = AnimationController(
    vsync: this,
    duration: AppMovimiento.corta,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.of(context).disableAnimations) {
        _trazo.value = 1;
      } else {
        _trazo.forward();
      }
    });
  }

  @override
  void dispose() {
    _trazo.dispose();
    _transSel.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(GraficoMetricaGestion oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 1.36 H-C1 (136-387): se comparan fecha Y valor — con
    // solo valores, una fecha nueva con el mismo valor
    // dejaba la selección apuntando a otra fecha sin que
    // el widget lo notara.
    if (!listEquals(
        oldWidget.puntos
            .map((p) => (p.fecha, p.valor))
            .toList(),
        widget.puntos.map((p) => (p.fecha, p.valor)).toList())) {
      _sel = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ordenados = List<PuntoSerie>.from(widget.puntos)
      ..sort((a, b) => a.fecha.compareTo(b.fecha));
    // 1.36 H-B1 (136-391): con UN solo punto no hay línea
    // que trazar, pero el dato existe — se dice con su
    // valor y su fecha en vez de desaparecer en silencio.
    if (ordenados.length == 1) {
      final p = ordenados.single;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.lg),
          child: Text(
            'Una sola medición por ahora: '
            '${p.valor.toStringAsFixed(1)} ${widget.unidad} · '
            '${fmtFechaHabana(p.fecha)}',
            style: AppTexto.secundario,
          ),
        ),
      );
    }
    if (ordenados.isEmpty) return const SizedBox.shrink();
    final valores = ordenados.map((p) => p.valor).toList();
    final max = valores.reduce((a, b) => a > b ? a : b);
    final min = valores.reduce((a, b) => a < b ? a : b);
    final prom = valores.reduce((a, b) => a + b) / valores.length;
    final xs = fraccionesEjeTiempo([for (final p in ordenados) p.fecha]);
    final selValido = _sel != null && _sel! < ordenados.length;

    String fmt(double v) => v.toStringAsFixed(1);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart_rounded,
                    color: AppColores.textoSecundario(context), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.titulo.toUpperCase(),
                    style: AppTexto.minuscula.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.grey,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                Text(
                  '${fmt(ordenados.first.valor)} → ${fmt(ordenados.last.valor)} ${widget.unidad}',
                  style: AppTexto.secundario.copyWith(
                      color: widget.color, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, cons) => GestureDetector(
                onTapDown: (d) => _elegir(d.localPosition.dx, cons.maxWidth, xs),
                onHorizontalDragUpdate: (d) =>
                    _elegir(d.localPosition.dx, cons.maxWidth, xs),
                child: SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: AnimatedBuilder(
                    animation:
                        Listenable.merge([_trazo, _transSel]),
                    builder: (context, _) => CustomPaint(
                      painter: _GraficoMetricaGestionPainter(
                        valores: valores,
                        xs: xs,
                        max: max,
                        min: min,
                        prom: prom,
                        color: widget.color,
                        objetivo: widget.objetivo,
                        seleccion: selValido ? _sel : null,
                        selFactor: _transSel.value,
                        progreso:
                            AppMovimiento.curvaSuave.transform(_trazo.value),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(fmtFechaHabana(ordenados.first.fecha),
                    style:
                        AppTexto.minuscula.copyWith(color: Colors.grey)),
                Text(fmtFechaHabana(ordenados.last.fecha),
                    style:
                        AppTexto.minuscula.copyWith(color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              selValido
                  ? '${fmtFechaHabana(ordenados[_sel!].fecha)} · '
                      '${fmt(ordenados[_sel!].valor)} ${widget.unidad}'
                  // 1.36 H-B1 (136-399): la ayuda dice lo
                  // que el gesto permite de verdad.
                  : 'Toca o arrastra para explorar.',
              style: AppTexto.secundario.copyWith(
                fontWeight: selValido ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _elegir(double dx, double ancho, List<double> xs) {
    final i = indicePuntoCercano(xs, dx, ancho);
    if (i >= 0 && _sel != i) {
      // 1.36 H-B1 (136-398): cambiar de punto se siente.
      Tacto.seleccion();
      // 1.36 H-C1 (136-397): y se SUAVIZA con el token
      // corto (directo con «reducir movimiento»).
      if (MediaQuery.of(context).disableAnimations) {
        _transSel.value = 1;
      } else {
        _transSel.forward(from: 0);
      }
      setState(() => _sel = i);
    }
  }
}

class _GraficoMetricaGestionPainter extends CustomPainter {
  final List<double> valores;
  final List<double> xs;
  final double max;
  final double min;
  final double prom;
  final Color color;

  /// 1.35 (UX-08): el objetivo a marcar con su banda
  /// (null = sin banda: ningún llamador lo trae hoy).
  final double? objetivo;
  final int? seleccion;

  /// 1.36 H-C1 (136-397): factor 0..1 de la transición del
  /// punto seleccionado (radio y guía interpolados).
  final double selFactor;

  /// 1.35 (UI-03): fracción 0..1 del trazado de entrada —
  /// la línea, el área y los puntos solo existen hasta
  /// ese corte horizontal (las guías rotuladas nacen
  /// puestas: son el fondo, no el dato).
  final double progreso;

  _GraficoMetricaGestionPainter({
    required this.valores,
    required this.xs,
    required this.max,
    required this.min,
    required this.prom,
    required this.color,
    this.objetivo,
    this.seleccion,
    this.selFactor = 1,
    this.progreso = 1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (valores.length < 2) return;
    final plano = max == min;
    final r = rangoVisibleSerie(min, max);
    final rango = r.maxE - r.minE;
    final padY = 24.0;
    final altoUtil = size.height - padY * 2;

    double yDe(double v) => padY + altoUtil * (1 - (v - r.minE) / rango);
    Offset punto(int i) => Offset(xs[i] * size.width, yDe(valores[i]));

    // 1. Guías punteadas ROTULADAS (máx, promedio, mín).
    //    En serie plana coinciden: una sola guía.
    final guiaPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.3)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final (valor, rotulo) in plano
        ? [(prom, prom.toStringAsFixed(1))]
        : [
            (max, max.toStringAsFixed(1)),
            (prom, 'prom ${prom.toStringAsFixed(1)}'),
            (min, min.toStringAsFixed(1)),
          ]) {
      final y = yDe(valor);
      _lineaPunteada(canvas, Offset(0, y), Offset(size.width, y), guiaPaint);
      // 1.36 H-C1 (136-392): si este extremo ES el primer
      // punto, su etiqueta (centrada sobre x≈0) pisaría el
      // rótulo de la guía: el rótulo se desplaza a la
      // derecha de la etiqueta.
      final coincidePrimero =
          valores.isNotEmpty && valor == valores.first && xs.first < 0.05;
      _rotuloGuia(
          canvas, rotulo, Offset(coincidePrimero ? 56 : 2, y - 4), size);
    }

    // 1.35 (UX-08): la banda del objetivo, con su
    // palabra — una franja naranja suave centrada en el
    // valor objetivo y su rótulo a la derecha. Solo se
    // pinta si el objetivo cae dentro del lienzo.
    if (objetivo != null) {
      final yObj = yDe(objetivo!);
      if (yObj >= 0 && yObj <= size.height) {
        final semibanda = altoUtil * 0.035;
        canvas.drawRect(
          Rect.fromLTRB(0, yObj - semibanda, size.width, yObj + semibanda),
          Paint()..color = AppColores.naranja.withValues(alpha: 0.13),
        );
        _lineaPunteada(
          canvas,
          Offset(0, yObj),
          Offset(size.width, yObj),
          Paint()
            ..color = AppColores.naranja.withValues(alpha: 0.55)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
        final tp = TextPainter(
          text: TextSpan(
            text: 'objetivo ${objetivo!.toStringAsFixed(1)}',
            style: AppTexto.metadato.copyWith(
                color: AppColores.naranja, fontWeight: FontWeight.w700),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
            canvas, Offset(size.width - tp.width - 2, yObj - semibanda - tp.height - 1));
      }
    }

    // 2. Área con gradiente.
    canvas.save();
    canvas.clipRect(
        Rect.fromLTWH(0, 0, size.width * progreso.clamp(0.0, 1.0),
            size.height));
    final puntos = List.generate(valores.length, punto);
    final areaPath = Path()
      ..moveTo(puntos.first.dx, size.height)
      ..lineTo(puntos.first.dx, puntos.first.dy);
    for (var i = 1; i < puntos.length; i++) {
      areaPath.lineTo(puntos[i].dx, puntos[i].dy);
    }
    areaPath
      ..lineTo(puntos.last.dx, size.height)
      ..close();
    final gradiente = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        // 1.35 (UX-08): el velo bajo la curva se hace
        // un punto más presente (0.25 → 0.30).
        color.withValues(alpha: 0.30),
        color.withValues(alpha: 0.0),
      ],
    );
    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = gradiente.createShader(
            Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    // 3. Línea principal.
    final lineaPath = Path()..moveTo(puntos.first.dx, puntos.first.dy);
    for (var i = 1; i < puntos.length; i++) {
      lineaPath.lineTo(puntos[i].dx, puntos[i].dy);
    }
    canvas.drawPath(
      lineaPath,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 4. Guía vertical del punto seleccionado.
    if (seleccion != null && seleccion! < puntos.length) {
      final p = puntos[seleccion!];
      _lineaPunteada(
        canvas,
        Offset(p.dx, padY - 8),
        Offset(p.dx, size.height - padY + 8),
        Paint()
          ..color = color.withValues(alpha: 0.5 * selFactor)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }

    // 5. Puntos (el seleccionado, más grande).
    final puntoPaint = Paint()..color = color;
    final bordePaint = Paint()..color = Colors.white;
    for (var i = 0; i < puntos.length; i++) {
      final p = puntos[i];
      final esSel = i == seleccion;
      // 1.36 H-C1 (136-397): el radio del seleccionado se
      // interpola con selFactor, no salta de 5 a 7.
      canvas.drawCircle(p, esSel ? 5 + 2 * selFactor : 5, bordePaint);
      canvas.drawCircle(
          p, esSel ? 3.5 + 2 * selFactor : 3.5, puntoPaint);
    }

    // 6. Etiquetas del primer y último valor.
    _etiqueta(canvas, valores.first.toStringAsFixed(1),
        puntos.first.translate(0, -16), size);
    _etiqueta(canvas, valores.last.toStringAsFixed(1),
        puntos.last.translate(0, -16), size);
    canvas.restore();
  }

  void _rotuloGuia(Canvas canvas, String texto, Offset pos, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: texto,
        style: AppTexto.metadato.copyWith(color: Colors.grey),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx, pos.dy - tp.height));
  }

  void _lineaPunteada(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 4.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final d2 = (d + dash).clamp(0.0, total);
      canvas.drawLine(a + dir * d, a + dir * d2, paint);
      d += dash + gap;
    }
  }

  void _etiqueta(Canvas canvas, String texto, Offset pos, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: texto,
        style: AppTexto.metadato
            .copyWith(color: color, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = pos.dx - tp.width / 2;
    dx = dx.clamp(0.0, size.width - tp.width);
    tp.paint(canvas, Offset(dx, pos.dy));
  }

  @override
  bool shouldRepaint(covariant _GraficoMetricaGestionPainter old) =>
      !listEquals(old.valores, valores) ||
      !listEquals(old.xs, xs) ||
      old.max != max ||
      old.min != min ||
      old.prom != prom ||
      old.color != color ||
      old.objetivo != objetivo ||
      old.seleccion != seleccion ||
      old.selFactor != selFactor ||
      old.progreso != progreso;
}
