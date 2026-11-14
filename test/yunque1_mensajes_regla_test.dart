/// Yunque 1.34 · C6-3 y C6-4: la regla de mensajes
/// automáticos de Jc (2026-11-01). Todo mensaje que la app
/// compone sola cierra con la línea 🤖; la ÚNICA excepción
/// es el regalo de cumpleaños, que abre con 📩 y cierra
/// con 📲.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  group('C6-3 · mensajeCumpleConRegalo usa el formato del regalo', () {
    test('con fecha anterior: apertura 📩 y cierre 📲, sin la línea común',
        () {
      final m = mensajeCumpleConRegalo(
        nombre: 'Ana',
        anteriorIso: '2026-11-01',
        nuevoIso: '2026-12-01',
      );
      expect(
          m,
          startsWith(
              '📩 Mensaje enviado por el sistema de gestión de Iron Body Gym:'));
      expect(m, contains('Te hemos regalado 1 mensualidad'));
      expect(m, endsWith('📲 _Si vas a responder, escríbenos al 58191577._'));
      expect(m, isNot(contains('🤖')),
          reason: 'el regalo NO lleva la línea automática común');
    });

    test('sin fecha anterior: mismo formato de excepción', () {
      final m = mensajeCumpleConRegalo(
        nombre: 'Luis',
        anteriorIso: null,
        nuevoIso: '2026-12-05',
      );
      expect(m, startsWith('📩 Mensaje enviado'));
      expect(m, endsWith('📲 _Si vas a responder, escríbenos al 58191577._'));
      expect(m, isNot(contains('🤖')));
    });
  });

  group('C6-4 · mensajes automáticos con la línea de cierre', () {
    test('el comprobante de compra cierra con la línea automática', () {
      final t = textoComprobanteCompra(
        nombreProducto: 'Mutant',
        cantidad: 1,
        precio: 25,
        moneda: 'USD',
        total: 25,
        nombreComprador: 'Lorena',
        fechaIso: '2026-10-23',
      );
      expect(t, endsWith(lineaMensajeAutomatico.trim()));
    });

    test('el mensaje de PIN (fuente única) cierra con la línea automática',
        () {
      final m = mensajePinAcceso(
          nombre: 'Ana', telefono8: '58191577', pin: '1234');
      expect(m, contains('Teléfono: 58191577'));
      expect(m, contains('PIN: 1234'));
      expect(m, endsWith(lineaMensajeAutomatico.trim()));
    });
  });
}
