// Tests ligeros v1.3.4 Ítem 5 (QoS de fotos).
//
// Solo lógica pura de lib/fotos_qos.dart: sin red, sin BD, sin subir
// fotos reales. No toca fotos_cola.dart ni el lease/workers.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos_qos.dart';

void main() {
  group('originalPermitido', () {
    final ahora = DateTime(2026, 10, 16, 12, 0, 0);

    test('opsVaciaDesde null → false', () {
      expect(
          originalPermitido(
              opsVaciaDesde: null,
              ultimoDisplayRapido: true,
              ahora: ahora),
          isFalse);
    });

    test('display lento → false aunque haya holgura de sobra', () {
      expect(
          originalPermitido(
              opsVaciaDesde: ahora.subtract(const Duration(hours: 2)),
              ultimoDisplayRapido: false,
              ahora: ahora),
          isFalse);
    });

    test('exactamente 5 min → false (se exigen MÁS de 5 minutos)', () {
      expect(
          originalPermitido(
              opsVaciaDesde: ahora.subtract(const Duration(minutes: 5)),
              ultimoDisplayRapido: true,
              ahora: ahora),
          isFalse);
    });

    test('5 min y 1 s + display rápido → true', () {
      expect(
          originalPermitido(
              opsVaciaDesde:
                  ahora.subtract(const Duration(minutes: 5, seconds: 1)),
              ultimoDisplayRapido: true,
              ahora: ahora),
          isTrue);
    });

    test('holgura larga + display rápido → true', () {
      expect(
          originalPermitido(
              opsVaciaDesde: ahora.subtract(const Duration(hours: 3)),
              ultimoDisplayRapido: true,
              ahora: ahora),
          isTrue);
    });
  });

  group('chunkDisplayRapido', () {
    final i = DateTime(2026, 1, 1);

    test('128 KB en 4 s → rápido', () {
      expect(chunkDisplayRapido(128 * 1024, i, i.add(const Duration(seconds: 4))),
          isTrue);
    });

    test('128 KB en 6 s → lento', () {
      expect(chunkDisplayRapido(128 * 1024, i, i.add(const Duration(seconds: 6))),
          isFalse);
    });

    test('256 KB en 9 s → rápido (tasa equivalente)', () {
      expect(chunkDisplayRapido(256 * 1024, i, i.add(const Duration(seconds: 9))),
          isTrue);
    });

    test('50 KB en 1 s → rápido (tasa alta aunque el archivo sea chico)', () {
      expect(chunkDisplayRapido(50 * 1024, i, i.add(const Duration(seconds: 1))),
          isTrue);
    });

    test('0 bytes → false', () {
      expect(chunkDisplayRapido(0, i, i.add(const Duration(seconds: 1))), isFalse);
    });

    test('duración cero o negativa → false', () {
      expect(chunkDisplayRapido(1024 * 1024, i, i), isFalse);
      expect(chunkDisplayRapido(1024 * 1024, i, i.subtract(const Duration(seconds: 1))),
          isFalse);
    });
  });
}
