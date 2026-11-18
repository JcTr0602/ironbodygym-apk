/// H-C2 (1.36) G3 Inscribir/servicios/reservas —
/// 136-714, 136-747.
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
/// (filas PARCIALES: solo la parte confirmada).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/aviso_duplicado.dart';
import 'package:ironbody_gym/ui/reservas.dart';

void main() {
  group('136-714 haceTextoDuplicado (normaliza a Habana y acota a 0)', () {
    final ahora = DateTime(2026, 11, 18, 12, 0); // pared Habana

    test('sello UTC posterior a ahora → «hace un momento», nunca negativo',
        () {
      // 17:30Z = 12:30 pared Habana: 30 min EN EL FUTURO
      // respecto a ahora (reloj del servidor adelantado).
      final creada = DateTime.utc(2026, 11, 18, 17, 30);
      expect(haceTextoDuplicado(creada, ahora), ' (hace un momento)');
    });

    test('sello UTC de hace 45 min → «hace 45 min»', () {
      // 16:15Z = 11:15 pared Habana.
      final creada = DateTime.utc(2026, 11, 18, 16, 15);
      expect(haceTextoDuplicado(creada, ahora), ' (hace 45 min)');
    });

    test('sin sello → texto vacío', () {
      expect(haceTextoDuplicado(null, ahora), '');
    });
  });

  group('136-747 textoVenceEn para el mensaje de confirmación', () {
    test('el plazo sale del expiraEn real, no de un literal', () {
      final ahora = DateTime(2026, 11, 18, 12, 0);
      // Vence en 2 días y 3 horas desde ahora (pared).
      final iso = DateTime(2026, 11, 20, 15, 0).toIso8601String();
      expect(textoVenceEn(iso, ahora), 'Vence en 2 d 3 h');
      expect(textoVenceEn(null, ahora), '');
    });
  });
}
