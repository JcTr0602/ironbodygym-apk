/// 1.34 · Campo 2 (P-1) — test GUARDIÁN de acotación de
/// fotos de fila.
///
/// La auditoría de rendimiento (134_rendimiento, hallazgo
/// 11) encontró imágenes de lista decodificándose a
/// resolución completa: la foto del catálogo de Suplementos
/// era el culpable directo de los tirones, y el mismo
/// defecto vivía en Reservas, Pagaron el mes, Mi Día,
/// Usuarios, el avatar de entrenador, la miniatura de venta,
/// el comprobante del diálogo de pago y las fotos de
/// incidencia. Este contrato fija la corrección en los
/// archivos de esas superficies:
///
/// - todo `Image.file(` lleva `cacheWidth` en su llamada;
/// - todo `backgroundImage:` con foto va envuelto en
///   `providerFotoAcotada(FileImage(...))`.
///
/// Las superficies de UNA imagen protagonista (visor de la
/// ficha, editor de foto, detalle de suplemento) quedan
/// fuera a propósito: su coste es de apertura, no de
/// scroll, y no viven en estos archivos.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _archivos = [
  'lib/ui/suplementos.dart',
  'lib/ui/reservas.dart',
  'lib/ui/pagaron_mes.dart',
  'lib/ui/mi_dia.dart',
  'lib/ui/usuarios.dart',
  'lib/ui/avatar_entrenador.dart',
  'lib/ui/venta_suplemento.dart',
  'lib/ui/dialogo_pago.dart',
  'lib/ui/incidencias/detalle_incidencia.dart',
];

/// Extrae el texto de la llamada que empieza en [desde]
/// (índice del '(' de apertura) hasta su ')' en balance.
String _llamada(String src, int desde) {
  var prof = 0;
  for (var i = desde; i < src.length; i++) {
    final c = src[i];
    if (c == '(') prof++;
    if (c == ')') {
      prof--;
      if (prof == 0) return src.substring(desde, i + 1);
    }
  }
  return src.substring(desde);
}

void main() {
  for (final ruta in _archivos) {
    test('$ruta: ninguna foto de fila sin acotar', () {
      final src = File(ruta).readAsStringSync();

      // Image.file( ... ) siempre con cacheWidth.
      var i = 0;
      while (true) {
        i = src.indexOf('Image.file(', i);
        if (i < 0) break;
        final llamada = _llamada(src, i + 'Image.file'.length);
        expect(llamada.contains('cacheWidth'), isTrue,
            reason:
                '$ruta: Image.file sin cacheWidth cerca de '
                '«${src.substring(i, (i + 60).clamp(0, src.length))}»');
        i += 'Image.file('.length;
      }

      // backgroundImage: FileImage( crudo, prohibido.
      expect(src.contains('backgroundImage: FileImage('), isFalse,
          reason:
              '$ruta: backgroundImage con FileImage sin '
              'providerFotoAcotada');
    });
  }
}
