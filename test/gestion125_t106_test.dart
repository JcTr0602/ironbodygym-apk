/// 1.25 T106: configuración sin sintaxis — las puras
/// que arman metodos_aceptados y textos_base desde
/// interruptores y filas, con las formas exactas que
/// el servidor exige (lista y mapa).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';

void main() {
  group('metodosDesdeInterruptores', () {
    test('orden canónico y subconjuntos', () {
      expect(
          metodosDesdeInterruptores(
              efectivo: true, transferencia: true),
          ['efectivo', 'transferencia']);
      expect(
          metodosDesdeInterruptores(
              efectivo: true, transferencia: false),
          ['efectivo']);
      expect(
          metodosDesdeInterruptores(
              efectivo: false, transferencia: true),
          ['transferencia']);
      expect(
          metodosDesdeInterruptores(
              efectivo: false, transferencia: false),
          isEmpty,
          reason: 'vacío: el guardado lo rechaza, como antes');
    });
  });

  group('textosBaseDesdeFilas', () {
    test('arma el mapa; filas sin clave no entran', () {
      final m = textosBaseDesdeFilas([
        ('saludo', 'Hola'),
        ('', 'huérfano'),
        ('  ', 'solo espacios'),
        ('despedida', 'Nos vemos'),
      ]);
      expect(m, {'saludo': 'Hola', 'despedida': 'Nos vemos'});
    });

    test('clave repetida: gana la última fila', () {
      expect(textosBaseDesdeFilas([('a', '1'), ('a', '2')]), {'a': '2'});
    });

    test('sin filas: mapa vacío (limpio, como el guardado de antes)', () {
      expect(textosBaseDesdeFilas([]), isEmpty);
    });

    test('la clave se recorta; el texto va tal cual', () {
      expect(textosBaseDesdeFilas([(' saludo ', ' Hola ')]),
          {'saludo': ' Hola '});
    });
  });
}
