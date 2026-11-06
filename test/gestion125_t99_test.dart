/// 1.25 T99: el Centro único de Precios — la lista de
/// claves es UNA (incluye la tasa USD, la única clave
/// exclusiva del difunto «Otros precios») y el
/// autoguardado por campo parsea con la regla de
/// siempre: finito y > 0.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/ui/config_precios_bancarios.dart';

void main() {
  group('la lista única cubre todo lo que editaba «Otros precios»', () {
    test('toda clave de clavesMontoConfig vive en C6', () {
      for (final (clave, _) in clavesMontoConfig) {
        expect(kClavesPreciosC6, contains(clave),
            reason: '$clave quedó huérfana al cerrar Otros precios');
      }
    });

    test('la tasa USD está en la fuente única', () {
      expect(kClavesPreciosC6, contains('tasa_usd'));
    });

    test('sin claves duplicadas en la lista única', () {
      expect(kClavesPreciosC6.toSet().length, kClavesPreciosC6.length);
    });
  });

  group('parsePrecioCampo (autoguardado por campo)', () {
    test('valores buenos', () {
      expect(parsePrecioCampo('2000'), 2000);
      expect(parsePrecioCampo(' 1500.5 '), 1500.5);
      expect(parsePrecioCampo('250'), 250);
    });

    test('rechaza lo que no puede regir como precio', () {
      expect(parsePrecioCampo(''), isNull);
      expect(parsePrecioCampo('abc'), isNull);
      expect(parsePrecioCampo('0'), isNull, reason: 'el 0 no es precio');
      expect(parsePrecioCampo('-5'), isNull);
      expect(parsePrecioCampo('Infinity'), isNull);
      expect(parsePrecioCampo('NaN'), isNull);
    });
  });
}
