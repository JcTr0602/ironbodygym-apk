/// Yunque de Sincronización · YS-8 — el refresco de token
/// sin red no es un «fatal».
///
/// Cadena del defecto (auditoría §4): gotrue refresca el
/// token por su cuenta → sin red, su excepción reintentable
/// escapa sin await → `PlatformDispatcher.onError` volcaba
/// TODO error async a `last_crash.json` → al reiniciar se
/// ingería como nivel `fatal`. Los 4 «fatales» de la
/// bitácora de Jc del 2026-11-10 fueron esto, con la app
/// sana y la subida limpia 36/36 ciclos.
///
/// Ahora el manejador clasifica primero con
/// `AppLog.esErrorAsyncNoFatal` (pura): el refresco sin red
/// se registra como error normal (`refresco_token_sin_red`)
/// y nunca toca `last_crash.json`. Todo lo demás sigue el
/// camino de crash intacto.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/app_log.dart';

/// Réplica de la forma de la excepción de gotrue: su
/// representación incluye el nombre del tipo.
class AuthRetryableFetchException implements Exception {
  AuthRetryableFetchException(this.message);
  final String message;
  @override
  String toString() => 'AuthRetryableFetchException: $message';
}

void main() {
  group('YS-8 · esErrorAsyncNoFatal (pura)', () {
    test('la excepción reintentable de gotrue ⇒ no fatal', () {
      expect(
          AppLog.esErrorAsyncNoFatal(AuthRetryableFetchException(
              'ClientException: Failed host lookup')),
          isTrue);
      // Aunque llegue ya convertida a texto.
      expect(
          AppLog.esErrorAsyncNoFatal(
              'AuthRetryableFetchException: otro envoltorio'),
          isTrue);
    });

    test('el endpoint de refresco con fallo de red ⇒ no fatal',
        () {
      expect(
          AppLog.esErrorAsyncNoFatal(
              'ClientException: Failed host lookup: '
              "'host.supabase.co' (OS Error: No address "
              'associated with hostname), '
              'uri=https://host.supabase.co/auth/v1/token'
              '?grant_type=refresh_token'),
          isTrue);
      expect(
          AppLog.esErrorAsyncNoFatal(
              'TimeoutException tras POST /auth/v1/token'),
          isTrue);
    });

    test('el endpoint SIN marcador de red ⇒ sigue siendo '
        'crash (un 500 del servidor no es «sin red»)', () {
      expect(
          AppLog.esErrorAsyncNoFatal(
              'AuthException: Internal Server Error en '
              '/auth/v1/token'),
          isFalse);
    });

    test('un error cualquiera ⇒ sigue siendo crash', () {
      expect(AppLog.esErrorAsyncNoFatal(StateError('boom')),
          isFalse);
      expect(AppLog.esErrorAsyncNoFatal('texto sin relación'),
          isFalse);
      expect(
          AppLog.esErrorAsyncNoFatal(
              Exception('Failed host lookup en otra pantalla')),
          isFalse,
          reason: 'sin el endpoint de refresco, un fallo de '
              'red genérico no se degrada: podría ser un crash '
              'real con ese texto en el detalle');
    });
  });

  group('YS-8 · cableado del manejador (estructural)', () {
    final src = File('lib/app_log.dart').readAsStringSync();

    test('onError clasifica ANTES de volcar y degrada a '
        'refresco_token_sin_red', () {
      final i = src.indexOf('PlatformDispatcher.instance.onError =');
      expect(i, isNonNegative);
      final cuerpo = src.substring(i, i + 1800);
      final iClasifica = cuerpo.indexOf('esErrorAsyncNoFatal(error)');
      final iVuelca = cuerpo.indexOf('_volcarCrashSync(');
      expect(iClasifica, isNonNegative,
          reason: 'el manejador ya no clasifica: todo error '
              'async vuelve a ser «fatal»');
      expect(iVuelca, isNonNegative,
          reason: 'el camino de crash desapareció: YS-8 no '
              'pide desactivarlo, solo degradar el refresco');
      expect(iClasifica < iVuelca, isTrue,
          reason: 'la clasificación va DESPUÉS del volcado: '
              'el refresco ya habría ensuciado last_crash.json');
      expect(cuerpo, contains('refresco_token_sin_red'));
    });
  });
}
