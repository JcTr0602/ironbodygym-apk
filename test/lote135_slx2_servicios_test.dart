/// SL-X2 · G06-5 (parcial) — la sync se dice UNA sola vez
/// (el icono de cabecera), no por fila ni en la franja.
///
/// Alcance de esta ficha (y solo este):
/// - servicios.dart: el chip «Por sincronizar» de cada fila
///   de venta (_filaVenta) desaparece; la franja del día
///   (_franjaDelDia) conserva solo el dato del día (dosis y
///   efectivo), sin el conteo por sincronizar.
/// - servicios_detalle.dart: el chip «Por sincronizar» del
///   detalle de una venta desaparece.
///
/// FUERA de alcance (bloqueado por contrato, NO se toca):
/// el sello de Estadísticas «Ya no incluye 1 venta» y los
/// chips de Estadísticas (protegidos por
/// test/correcciones_hy4_g21_test.dart), y el chip del
/// cuadre «Incluye N operaciones por sincronizar» de la
/// zona Día — no es fila ni franja de Vender.
///
/// Discriminante de fuente por superficie (la pauta de la
/// casa para esta familia, cf. SL-3): en la base, las tres
/// superficies contienen la mención; corregidas, ninguna.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('G06-5 · menciones de sync por fila/franja', () {
    test('servicios.dart: _filaVenta sin chip «Por sincronizar»',
        () {
      final src = File('lib/ui/servicios.dart').readAsStringSync();
      final i = src.indexOf('Widget _filaVenta(');
      expect(i, greaterThanOrEqualTo(0));
      final cuerpo = src.substring(
          i, src.indexOf('class _DialogoCliente', i) > i ? src.indexOf('class _DialogoCliente', i) : i + 6000);
      expect(cuerpo.contains('Por sincronizar'), isFalse,
          reason: 'G06-5: la fila de venta ya no dice su sync; '
              'la sync se dice una sola vez en la cabecera');
    });

    test('servicios.dart: la franja del día conserva solo el '
        'dato del día', () {
      final src = File('lib/ui/servicios.dart').readAsStringSync();
      final i = src.indexOf('Widget _franjaDelDia()');
      expect(i, greaterThanOrEqualTo(0));
      final cuerpo = src.substring(i,
          src.indexOf('Widget _tarjetaCuadre()', i) > i ? src.indexOf('Widget _tarjetaCuadre()', i) : i + 3000);
      expect(cuerpo.contains('por sincronizar'), isFalse,
          reason: 'G06-5: la franja ya no cuenta ops por '
              'sincronizar');
      expect(cuerpo.contains('dosis'), isTrue,
          reason: 'la franja conserva el dato del día');
      expect(cuerpo.contains('efectivo'), isTrue);
    });

    test('servicios_detalle.dart: el detalle de venta sin chip '
        '«Por sincronizar»', () {
      final src =
          File('lib/ui/servicios_detalle.dart').readAsStringSync();
      expect(src.contains('Por sincronizar'), isFalse,
          reason: 'G06-5: el detalle de una venta ya no dice '
              'su sync por fila');
      // Los demás chips del detalle no se tocan.
      expect(src.contains('Revertida'), isTrue);
      expect(src.contains('Cuenta a la Casa'), isTrue);
    });

    test('servicios_historial.dart: sin mención por fila (ya '
        'estaba limpio; se fija para que no regrese)', () {
      final src =
          File('lib/ui/servicios_historial.dart').readAsStringSync();
      expect(src.contains('Por sincronizar'), isFalse);
    });
  });
}
