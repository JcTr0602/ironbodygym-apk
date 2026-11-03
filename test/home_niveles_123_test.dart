/// 1.23 (B2, diseño de Argón): Home en dos niveles.
/// Cubre la función pura del contador de urgencias de la
/// pestaña «Hoy» (H-02): atrasados + incidencias + personas
/// esperando al dueño; la navegación entre niveles la cubre
/// el banco de widgets (banco_widget_test).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';

void main() {
  group('urgenciasHome (B2)', () {
    test('sin urgencias suma 0 (la pestaña no lleva contador)',
        () {
      expect(
          urgenciasHome(atras: 0, incidencias: 0, atencion: 0),
          0);
    });

    test('suma las tres fuentes', () {
      expect(
          urgenciasHome(atras: 3, incidencias: 2, atencion: 5),
          10);
    });

    test('solo atención del dueño también cuenta', () {
      expect(
          urgenciasHome(atras: 0, incidencias: 0, atencion: 1),
          1);
    });
  });
}
