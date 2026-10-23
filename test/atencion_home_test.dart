/// Tests v1.8.0 (Frente 8) — SenalAtencion: la señal de «personas
/// esperando» del dueño en Home.
///
/// Agregación pura sobre los conteos que Home trae en segundo
/// pase desde las mismas RPC del Panel (solicitudes de
/// inscripción de invitados + reportes App Plus pendientes).
/// Contrato: la señal solo se pinta si hay alguien esperando; el
/// total es la suma de ambas fuentes; un conteo negativo (no
/// debería existir) se trata como 0 y nunca resta.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';

void main() {
  group('SenalAtencion', () {
    test('sin nadie esperando: total 0 y señal oculta', () {
      const s = SenalAtencion();
      expect(s.total, 0);
      expect(s.visible, isFalse);
    });

    test('suma solicitudes y reportes Plus', () {
      const s = SenalAtencion(solicitudes: 2, reportesPlus: 1);
      expect(s.total, 3);
      expect(s.visible, isTrue);
    });

    test('una sola fuente basta para mostrar la señal', () {
      expect(const SenalAtencion(solicitudes: 1).visible, isTrue);
      expect(const SenalAtencion(reportesPlus: 3).visible, isTrue);
    });

    test('conteos negativos se tratan como 0 (nunca restan)', () {
      const s = SenalAtencion(solicitudes: -2, reportesPlus: 1);
      expect(s.total, 1);
      expect(s.visible, isTrue);
      const z = SenalAtencion(solicitudes: -1, reportesPlus: -1);
      expect(z.total, 0);
      expect(z.visible, isFalse);
    });
  });
}
