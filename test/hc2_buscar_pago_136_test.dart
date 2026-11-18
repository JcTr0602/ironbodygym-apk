/// H-C2 (1.36) G1 Buscar/pagos — 136-594, 136-610.
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
/// (filas PARCIALES: solo la parte confirmada).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';

void main() {
  group('136-594 errorSyncPosteriorABajada (ambos en pared Habana)', () {
    test('error posterior a la bajada (instante UTC) → vigente', () {
      // Bajada buena: 2026-11-18T15:00Z = 10:00 pared Habana.
      // Error en pared Habana 11:00 → posterior.
      final errPared = DateTime(2026, 11, 18, 11, 0);
      final real = DateTime.utc(2026, 11, 18, 15, 0);
      expect(errorSyncPosteriorABajada(errPared, real), isTrue);
    });

    test('error anterior a la bajada → NO vigente (sin desfase de zona)', () {
      // Bajada buena 15:00Z = 10:00 pared. Error pared 09:00:
      // anterior. Comparado contra el instante crudo (15:00)
      // también saldría anterior; el caso que muerde es el
      // contrario: error pared 12:00 con bajada 16:30Z
      // (=11:30 pared): el error es POSTERIOR en pared pero
      // «anterior» si se compara 12:00 contra 16:30 crudo.
      final errPared = DateTime(2026, 11, 18, 12, 0);
      final real = DateTime.utc(2026, 11, 18, 16, 30);
      expect(errorSyncPosteriorABajada(errPared, real), isTrue);
      // Y un error pared 11:00 con esa bajada (11:30 pared)
      // es anterior: no vigente.
      expect(
          errorSyncPosteriorABajada(
              DateTime(2026, 11, 18, 11, 0), real),
          isFalse);
    });

    test('sin bajada buena, el error cuenta; sin error, no', () {
      expect(
          errorSyncPosteriorABajada(DateTime(2026, 11, 18, 9), null),
          isTrue);
      expect(errorSyncPosteriorABajada(null, DateTime.utc(2026)), isFalse);
      expect(errorSyncPosteriorABajada(null, null), isFalse);
    });
  });

  group('136-610 normalizarFechaCobro para el «Vence:» del diálogo', () {
    test('ISO con hora UTC se convierte al día Habana', () {
      // 03:00Z = 22:00 del día anterior en La Habana (UTC-5).
      expect(normalizarFechaCobro('2026-12-01T03:00:00Z'), '2026-11-30');
      expect(normalizarFechaCobro('2026-12-01T06:00:00Z'), '2026-12-01');
    });

    test('fecha plana pasa igual; vacío/nulo → null (Sin vencimiento)', () {
      expect(normalizarFechaCobro('2026-12-01'), '2026-12-01');
      expect(normalizarFechaCobro(null), isNull);
      expect(normalizarFechaCobro(''), isNull);
      // Dinámico no-cadena (el cast viejo `as String?` lanzaba).
      expect(normalizarFechaCobro(20261201), isNull);
    });
  });
}
