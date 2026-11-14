/// Yunque 3 (K6-3): los lectores de ajustes de dinero/flags
/// que las pantallas de cobro y venta usan tras la corrección
/// (pago_diario, venta_suplemento, venta_suplemento_inscripcion,
/// detalle_suplemento, suplementos) son los tolerantes de
/// tipos_pago.dart. El blob de ajustes se edita también desde
/// el bot/SQL: un importe puede llegar como TEXTO y un flag
/// como BOOL; el cast duro `as num?` lanzaba TypeError y la
/// carga de la pantalla moría en silencio (Pago Diario cobraba
/// con el valor inicial; la tasa USD nunca se precargaba).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tipos_pago.dart';

void main() {
  group('montoAjusteTolerante con las formas de K6-3', () {
    test('el pago diario en texto se lee (no tumba la carga)', () {
      expect(montoAjusteTolerante('250'), 250);
    });

    test('la tasa USD en texto se lee (la venta USD no se bloquea)',
        () {
      expect(montoAjusteTolerante('490'), 490);
    });

    test('un bool en un importe degrada a null, sin TypeError', () {
      expect(montoAjusteTolerante(true), isNull);
      expect(montoAjusteTolerante(false), isNull);
    });

    test('ausente degrada a null (manda el valor por defecto)', () {
      expect(montoAjusteTolerante(null), isNull);
    });
  });

  group('flagAjusteTolerante (promo_suplementos)', () {
    test('activa con 1, 1.0, true y «1»', () {
      expect(flagAjusteTolerante(1), isTrue);
      expect(flagAjusteTolerante(1.0), isTrue);
      expect(flagAjusteTolerante(true), isTrue);
      expect(flagAjusteTolerante('1'), isTrue);
    });

    test('inactiva con 0, false, «0» y ausente — sin TypeError', () {
      expect(flagAjusteTolerante(0), isFalse);
      expect(flagAjusteTolerante(false), isFalse);
      expect(flagAjusteTolerante('0'), isFalse);
      expect(flagAjusteTolerante(null), isFalse);
    });
  });
}
