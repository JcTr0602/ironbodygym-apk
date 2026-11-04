/// Tests de H-08 (1.23) — fix #4 de auth: el telegramId sale
/// de appMetadata (solo escribible por el servidor) con
/// prioridad sobre userMetadata (editable por el propio
/// usuario = suplantable). Se ejercita el resolvedor puro
/// AuthService.telegramIdDesdeMetadatos, que es lo que usa el
/// getter con la sesión viva.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';

void main() {
  group('H-08 fix #4: telegramId desde metadatos', () {
    test('appMetadata manda aunque userMetadata traiga otro', () {
      expect(
          AuthService.telegramIdDesdeMetadatos(
              {'telegram_id': 111}, {'telegram_id': 999}),
          111);
    });

    test('appMetadata como texto numérico también vale', () {
      expect(
          AuthService.telegramIdDesdeMetadatos(
              {'telegram_id': '1403501391'}, null),
          1403501391);
    });

    test('fallback a userMetadata solo si appMetadata no lo trae', () {
      expect(
          AuthService.telegramIdDesdeMetadatos({}, {'telegram_id': 222}),
          222);
      expect(
          AuthService.telegramIdDesdeMetadatos(null, {'telegram_id': 222}),
          222);
      expect(
          AuthService.telegramIdDesdeMetadatos(
              {'rol': 'entrenador'}, {'telegram_id': '333'}),
          333);
    });

    test('appMetadata con valor no parseable no bloquea el fallback', () {
      expect(
          AuthService.telegramIdDesdeMetadatos(
              {'telegram_id': 'no-es-numero'}, {'telegram_id': 444}),
          444);
    });

    test('sin dato en ningún lado: null', () {
      expect(AuthService.telegramIdDesdeMetadatos(null, null), isNull);
      expect(AuthService.telegramIdDesdeMetadatos({}, {}), isNull);
    });
  });
}
