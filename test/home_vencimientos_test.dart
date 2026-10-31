import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/home.dart';

void main() {
  group('urgenciaVencimientos (H2)', () {
    test('atrasados +30d = rojo y pestaña +30d', () {
      final r = urgenciaVencimientos(atrasLeve: 2, atras30: 1);
      expect(r.color, AppColores.error);
      expect(r.tabInicial, 3);
    });
    test('solo atrasados leves = ámbar y pestaña -30d', () {
      final r = urgenciaVencimientos(atrasLeve: 3, atras30: 0);
      expect(r.color, AppColores.alerta);
      expect(r.tabInicial, 2);
    });
    test('sin atrasados = ámbar y pestaña Hoy', () {
      final r = urgenciaVencimientos(atrasLeve: 0, atras30: 0);
      expect(r.color, AppColores.alerta);
      expect(r.tabInicial, 0);
    });
  });
}
