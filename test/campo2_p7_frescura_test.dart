/// 1.34 Campo 2 (P-7): frescura para la regla del gesto
/// de Jc y honestidad del alcance (T-3).
///
/// - syncEsFresca: ≤10 min desde la última bajada buena
///   = fresco (solo relectura local); más = viejo (bajar
///   primero). Sin bajada registrada, nunca fresco; una
///   marca en el futuro no es frescura (reloj movido).
/// - El alcance 'bandeja' resuelve sus tres espejos.
/// - T-3 (contrato): el resultado del alcance declara
///   parcial/fallidas y el resumen emitido no anuncia
///   «Sincronizado» cuando hubo filas fallidas.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('syncEsFresca (P-7, regla de Jc)', () {
    final ahora = DateTime(2026, 11, 14, 12, 0);

    test('sin bajada registrada nunca es fresca', () {
      expect(syncEsFresca(null, ahora), isFalse);
    });

    test('dentro de los 10 min es fresca (borde incluido)', () {
      expect(
          syncEsFresca(ahora.subtract(const Duration(minutes: 9)), ahora),
          isTrue);
      expect(
          syncEsFresca(
              ahora.subtract(const Duration(minutes: 10)), ahora),
          isTrue);
    });

    test('pasados los 10 min está vieja: toca bajar', () {
      expect(
          syncEsFresca(
              ahora.subtract(const Duration(minutes: 10, seconds: 1)),
              ahora),
          isFalse);
      expect(
          syncEsFresca(ahora.subtract(const Duration(hours: 3)), ahora),
          isFalse);
    });

    test('una marca en el futuro no cuenta como fresca', () {
      expect(syncEsFresca(ahora.add(const Duration(minutes: 5)), ahora),
          isFalse);
    });
  });

  group('alcance bandeja (P-7)', () {
    test('resuelve solicitudes, borradores y permisos', () {
      final tablas = SyncScope.resolver('bandeja', esAdmin: true);
      expect(tablas, contains('gympedia_solicitudes'));
      expect(tablas, contains('espejo_gympedia_borradores'));
      expect(tablas, contains('permisos_bandeja'));
    });
  });

  group('T-3 · el alcance parcial no se anuncia al día '
      '(contrato de fuente)', () {
    final src = File('lib/sync.dart').readAsStringSync();

    test('el resultado declara parcial y fallidas', () {
      expect(src, contains('parcial: fallidasScope > 0'));
      expect(src, contains('fallidas: fallidasScope'));
    });

    test('el resumen distingue la bajada parcial', () {
      expect(src, contains("'Bajada parcial de \$nombreScope: '"));
    });

    test('el atajo booleano no da la parcial por buena', () {
      expect(src,
          contains('return r.corrio && !r.error && !r.parcial;'));
    });

    test('el gesto con la regla vive en componentes', () {
      final comp = File('lib/ui/componentes.dart').readAsStringSync();
      expect(comp, contains('refrescoScopeIron'));
      expect(comp, contains('refrescoGeneralIron'));
      expect(comp, contains('datosFrescos()'));
    });
  });
}
