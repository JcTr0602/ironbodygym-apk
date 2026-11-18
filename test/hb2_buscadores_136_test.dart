// 1.36 H-B2: contrato de 136-580 (panel buscador).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';

void main() {
  group('136-580 consultaPareceNombreOTelefono', () {
    test('teléfono de 4+ dígitos parece persona', () {
      expect(consultaPareceNombreOTelefono('5819'), isTrue);
      expect(consultaPareceNombreOTelefono('53 58191577'), isTrue);
    });
    test('nombre de dos palabras parece persona', () {
      expect(consultaPareceNombreOTelefono('juan perez'), isTrue);
    });
    test('una función de una palabra no parece persona', () {
      expect(consultaPareceNombreOTelefono('sync'), isFalse);
      expect(consultaPareceNombreOTelefono('precios'), isFalse);
      expect(consultaPareceNombreOTelefono(''), isFalse);
    });
  });
}
