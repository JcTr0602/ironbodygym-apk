/// Yunque de Sincronización · H16 (revisión de Argón,
/// PARCIAL: (a)+(b) confirmados, (c) refutado) — las fotos
/// de incidencias subían CRUDAS por PUT monolítico.
///
/// El defecto: `subirFotosIncidencias` leía el archivo de
/// cámara y subía los bytes tal cual (3–8 MB) por
/// `_subirFotoSimple`, sin pasar por `_comprimirFoto` — la
/// política común (máx. 1024 px, JPEG 80, ~150–300 KB) que
/// sí reciben las fotos de clientes. En datos móviles
/// lentos la subida monolítica moría casi siempre y la foto
/// caía a 'error' tras 5 ciclos; sin foto, una incidencia
/// de Mantenimiento no se puede cerrar.
///
/// La corrección de este lote es SOLO la compresión; la
/// migración del transporte a la cola reanudable TUS queda
/// diferida (ver el informe de correcciones).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ironbody_gym/sync.dart';

Uint8List _jpegGrande() {
  final imagen = img.Image(width: 2048, height: 1024);
  img.fill(imagen, color: img.ColorRgb8(120, 60, 30));
  img.drawString(imagen, 'evidencia de prueba H16',
      font: img.arial24, x: 10, y: 10);
  return Uint8List.fromList(img.encodeJpg(imagen, quality: 100));
}

void main() {
  test('H16: una foto de cámara grande sale comprimida a '
      'la política común (ancho 1024)', () {
    final cruda = _jpegGrande();
    final salida =
        SyncEngine.instance.comprimirFotoParaTest(cruda);
    final dec = img.decodeImage(salida);
    expect(dec, isNotNull);
    expect(dec!.width, 1024,
        reason: 'la foto de incidencia no pasó por la '
            'compresión común: subiría cruda');
    expect(salida.length, lessThan(cruda.length));
  });

  test('H16: una foto ya pequeña pasa intacta', () {
    final chica = img.Image(width: 800, height: 600);
    img.fill(chica, color: img.ColorRgb8(10, 20, 30));
    final bytes =
        Uint8List.fromList(img.encodeJpg(chica, quality: 90));
    final salida =
        SyncEngine.instance.comprimirFotoParaTest(bytes);
    expect(salida, bytes,
        reason: 'la compresión no debe tocar lo que ya '
            'cumple la política');
  });

  test('H16: pin — subirFotosIncidencias comprime los bytes '
      'antes de subirlos', () {
    final sync = File('lib/sync.dart').readAsStringSync();
    final i =
        sync.indexOf('Future<void> subirFotosIncidencias()');
    expect(i, isNonNegative);
    // La función vive cerca del fin del archivo: se lee
    // hasta el fin en vez de una ventana fija.
    final cuerpo = sync.substring(i);
    expect(
        cuerpo,
        contains('_comprimirFoto(await file.readAsBytes())'),
        reason: 'la vía de incidencias volvió a leer los '
            'bytes crudos: en datos móviles la foto de '
            'evidencia no sube');
  });
}
