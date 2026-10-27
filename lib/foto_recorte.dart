/// Recorte real de fotos de cliente (v1.4.1, etapa 4 · Pieza F1).
///
/// Hasta la v1.4.0 el editor de foto era solo visual: el zoom/pan
/// no se aplicaba y se guardaba la foto completa. Aquí vive la
/// parte seria: la geometría del recorte (función pura, testeada),
/// la preparación de la copia de trabajo YA orientada (EXIF
/// aplicado, para que lo que se ve en el editor sea exactamente
/// lo que se recorta) y la aplicación del recorte a un archivo
/// nuevo con escritura atómica.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

/// Rectángulo de recorte en píxeles de la imagen, o null si la
/// vista no define un recorte válido.
///
/// [matriz] es la transformación del InteractiveViewer. El
/// contrato es traslación + escala uniforme SIN rotación,
/// cizalla, perspectiva ni espejado (lo único que produce el
/// visor de esta app): una matriz fuera de ese contrato se
/// rechaza con null, porque con rotación la región visible deja
/// de ser un rectángulo alineado a ejes y el recorte por
/// rectángulo no sería fiel. Cumplido el contrato, se invierte
/// la matriz y se transforman las 4 esquinas del [viewport]
/// para obtener la región visible del hijo.
/// El hijo ocupa exactamente el viewport y pinta la imagen con
/// BoxFit.cover centrada: el rectángulo pintado se intersecta con
/// la región visible y se convierte a píxeles de imagen.
/// Redondeo cerrado: floor en el origen, ceil en el extremo,
/// clamp a la imagen; si el resultado no llega a 1 px, es null.
/// Ningún valor derivado no finito llega al redondeo: todo se
/// valida antes (null en vez de excepción).
Rect? calcularRecorteFoto({
  required Matrix4 matriz,
  required Size viewport,
  required Size imagen,
}) {
  final vw = viewport.width;
  final vh = viewport.height;
  final iw = imagen.width;
  final ih = imagen.height;
  if (!(vw > 0) || !(vh > 0) || !(iw > 0) || !(ih > 0)) return null;
  if (!vw.isFinite || !vh.isFinite || !iw.isFinite || !ih.isFinite) {
    return null;
  }
  final s = matriz.storage;
  for (final v in s) {
    if (!v.isFinite) return null;
  }
  // Contrato traslación + escala uniforme: escala en [0]=[5],
  // positiva, y cero en rotación/cizalla [1][4], en la tercera
  // fila/columna y en perspectiva [15]=1.
  const eps = 1e-6;
  bool casiCero(double v) => v.abs() <= eps;
  if (!casiCero(s[1]) ||
      !casiCero(s[4]) ||
      !casiCero(s[2]) ||
      !casiCero(s[3]) ||
      !casiCero(s[6]) ||
      !casiCero(s[7]) ||
      !casiCero(s[11]) ||
      (s[15] - 1).abs() > eps) {
    return null;
  }
  final k = s[0];
  if (!(k > 0) || (s[5] - k).abs() > eps * math.max(1, k.abs())) {
    return null;
  }
  final det = matriz.determinant();
  if (det == 0 || !det.isFinite) return null;
  final inversa = Matrix4.copy(matriz)..invert();

  // Región visible del hijo: esquinas del viewport en coords del
  // hijo, y su rectángulo envolvente.
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final esquina in [
    Offset.zero,
    Offset(vw, 0),
    Offset(0, vh),
    Offset(vw, vh),
  ]) {
    final p = MatrixUtils.transformPoint(inversa, esquina);
    if (!p.dx.isFinite || !p.dy.isFinite) return null;
    minX = math.min(minX, p.dx);
    minY = math.min(minY, p.dy);
    maxX = math.max(maxX, p.dx);
    maxY = math.max(maxY, p.dy);
  }

  // Rectángulo pintado de la imagen dentro del hijo (cover).
  final s0 = math.max(vw / iw, vh / ih);
  if (!(s0 > 0) || !s0.isFinite) return null;
  final pLeft = (vw - iw * s0) / 2;
  final pTop = (vh - ih * s0) / 2;
  final pRight = pLeft + iw * s0;
  final pBottom = pTop + ih * s0;
  if (!pLeft.isFinite || !pTop.isFinite || !pRight.isFinite ||
      !pBottom.isFinite) {
    return null;
  }

  // Intersección región visible ∩ imagen pintada.
  final iLeft = math.max(minX, pLeft);
  final iTop = math.max(minY, pTop);
  final iRight = math.min(maxX, pRight);
  final iBottom = math.min(maxY, pBottom);
  if (iRight - iLeft <= 0 || iBottom - iTop <= 0) return null;

  // A píxeles de imagen, con redondeo hacia afuera y clamp.
  // (Se validan finitos ANTES de floor/ceil: con entradas
  // extremas un cociente infinito lanzaría en vez de dar null.)
  final dL = (iLeft - pLeft) / s0;
  final dT = (iTop - pTop) / s0;
  final dR = (iRight - pLeft) / s0;
  final dB = (iBottom - pTop) / s0;
  if (!dL.isFinite || !dT.isFinite || !dR.isFinite || !dB.isFinite) {
    return null;
  }
  var l = dL.floor();
  var t = dT.floor();
  var r = dR.ceil();
  var b = dB.ceil();
  l = math.max(0, math.min(l, iw.toInt() - 1));
  t = math.max(0, math.min(t, ih.toInt() - 1));
  r = math.max(l + 1, math.min(r, iw.toInt()));
  b = math.max(t + 1, math.min(b, ih.toInt()));
  if (r - l < 1 || b - t < 1) return null;
  return Rect.fromLTRB(
      l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble());
}

/// Resultado de preparar la foto de trabajo del editor.
class FotoTrabajo {
  /// Archivo a mostrar y recortar (el original o la copia
  /// orientada).
  final File archivo;

  /// Dimensiones en píxeles de [archivo] (ya orientado).
  final int ancho;
  final int alto;

  const FotoTrabajo({
    required this.archivo,
    required this.ancho,
    required this.alto,
  });

  Size get tamano => Size(ancho.toDouble(), alto.toDouble());
}

/// Escribe [bytes] en [ruta] de forma atómica (tmp + rename).
/// Si la escritura o el renombrado fallan, el temporal se borra
/// antes de relanzar (corrección del panel: no dejar .tmp
/// huérfanos en ningún camino).
Future<void> _escribirAtomico(String ruta, List<int> bytes) async {
  final tmp = File('$ruta.tmp');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(ruta);
  } catch (_) {
    try {
      await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Prepara la copia de trabajo del editor: SIEMPRE un archivo
/// físico con los píxeles ya orientados en [rutaOrientada] (sin
/// depender de que el consumidor respete la etiqueta EXIF).
/// El decodificador JPEG de package:image APLICA la orientación
/// EXIF al decodificar y la consume (verificado con fixtures
/// reales de PIL, orientaciones 6 y 2); si un formato la expusiera
/// SIN aplicarla (exif presente y != 1 tras decodificar), se
/// hornea con bakeOrientation antes de escribir.
/// Devuelve null si la foto no se pudo decodificar o escribir
/// (el editor entonces avisa y ofrece usar la foto completa
/// sin recorte garantizado).
Future<FotoTrabajo?> prepararFotoTrabajo(
  File origen, {
  required String rutaOrientada,
}) async {
  try {
    final bytes = await origen.readAsBytes();
    final im = img.decodeImage(bytes);
    if (im == null) return null;
    // Argón #8-2: el trabajo SIEMPRE es un archivo físico con los
    // píxeles ya orientados. Devolver `origen` cuando el
    // decodificador ya aplicó el EXIF dejaba la etiqueta en disco
    // y cualquier consumidor que no respete EXIF (o la copia cruda
    // de `original` si la compresión falla) mostraba la foto girada.
    // bake solo si el decodificador NO aplicó la orientación
    // (post-decode != 1); si ya la aplicó, hornear de nuevo giraría
    // dos veces.
    final ifd = im.exif.imageIfd;
    final orientacion = ifd.hasOrientation ? ifd.orientation : null;
    final orientada = (orientacion != null && orientacion != 1)
        ? img.bakeOrientation(im)
        : im;
    await _escribirAtomico(
        rutaOrientada, img.encodeJpg(orientada, quality: 92));
    return FotoTrabajo(
      archivo: File(rutaOrientada),
      ancho: orientada.width,
      alto: orientada.height,
    );
  } catch (_) {
    // [rutaOrientada] es una ruta de trabajo del llamador
    // (nombre único del editor): si algo falló a mitad de camino
    // no se deja ni el archivo final parcial ni su temporal.
    try {
      await File(rutaOrientada).delete();
    } catch (_) {}
    try {
      await File('$rutaOrientada.tmp').delete();
    } catch (_) {}
    return null;
  }
}

/// Aplica [recorte] (píxeles) sobre [trabajo] y escribe el JPEG
/// resultante en [rutaDestino] (atómico). Devuelve el archivo o
/// null si algo falló (decodificar, recortar o escribir).
Future<File?> aplicarRecorteFoto({
  required File trabajo,
  required Rect recorte,
  required String rutaDestino,
}) async {
  try {
    final bytes = await trabajo.readAsBytes();
    final im = img.decodeImage(bytes);
    if (im == null) return null;
    final cortada = img.copyCrop(
      im,
      x: recorte.left.toInt(),
      y: recorte.top.toInt(),
      width: recorte.width.toInt(),
      height: recorte.height.toInt(),
    );
    await _escribirAtomico(
        rutaDestino, img.encodeJpg(cortada, quality: 88));
    return File(rutaDestino);
  } catch (_) {
    try {
      await File('$rutaDestino.tmp').delete();
    } catch (_) {}
    return null;
  }
}
