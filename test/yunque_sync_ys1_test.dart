/// Yunque de Sincronización · YS-1 — ningún 401/403 quema una op.
///
/// La familia YS-2/NEW-1 no tenía NI UN test de comportamiento:
/// ningún archivo de test de sync contenía «401» ni «403». El
/// mecanismo (auditoría, §5.1): `_reqAuth` devuelve el 401
/// original cuando el refresco de token falla por red, y la rama
/// 4xx de `_uploadUnaPorUna` lo trataba como veredicto sobre la
/// op (markOp 'rechazada' + reversión del cobro); el camino en
/// lote derivaba TODO 4xx al una-por-una, así que un corte de
/// red durante el refresco podía quemar la cola entera.
///
/// Aquí se pincha la tabla completa de la función pura
/// `decisionAnte4xxPush` y, con el patrón estructural de la casa,
/// que ninguna rama del push puede llegar a 'rechazada' desde un
/// 401/403 sin pasar por la decisión.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('YS-1 · decisionAnte4xxPush (tabla completa)', () {
    test('401 → bumpAuth (el 401 del refresco imposible)', () {
      expect(SyncEngine.decisionAnte4xxPush(401, ''),
          Decision4xxPush.bumpAuth);
    });

    test('401 con cuerpo de error de red del refresco → bumpAuth',
        () {
      // El cuerpo que acompañaría a un refresco fallido no
      // cambia la clase: la sesión falló, la op no es culpable.
      expect(
          SyncEngine.decisionAnte4xxPush(
              401, 'AuthRetryableFetchException: Failed host lookup'),
          Decision4xxPush.bumpAuth);
    });

    test('403 → bumpAuth (directo o tras refresco válido)', () {
      expect(SyncEngine.decisionAnte4xxPush(403, ''),
          Decision4xxPush.bumpAuth);
      expect(
          SyncEngine.decisionAnte4xxPush(
              403, '{"message":"permission denied"}'),
          Decision4xxPush.bumpAuth);
    });

    test('401/403 mandan sobre el salvavidas 23514', () {
      // Aunque el cuerpo trajera el código del CHECK, un 401/403
      // es auth primero: no es un problema del tipo de la op.
      expect(
          SyncEngine.decisionAnte4xxPush(401, 'code: 23514'),
          Decision4xxPush.bumpAuth);
      expect(
          SyncEngine.decisionAnte4xxPush(403, 'code: 23514'),
          Decision4xxPush.bumpAuth);
    });

    test('400 sin código PG → rechazada (validación real)', () {
      expect(
          SyncEngine.decisionAnte4xxPush(
              400, '{"message":"invalid input"}'),
          Decision4xxPush.rechazada);
    });

    test('400 con 23514 → bumpCheck (el CHECK no conoce el tipo)',
        () {
      expect(
          SyncEngine.decisionAnte4xxPush(400,
              '{"code":"23514","message":"check constraint"}'),
          Decision4xxPush.bumpCheck);
    });

    test('422 sin código PG → rechazada', () {
      expect(SyncEngine.decisionAnte4xxPush(422, '{}'),
          Decision4xxPush.rechazada);
    });

    test('408/429/5xx → bumpTransitorio', () {
      expect(SyncEngine.decisionAnte4xxPush(408, ''),
          Decision4xxPush.bumpTransitorio);
      expect(SyncEngine.decisionAnte4xxPush(429, ''),
          Decision4xxPush.bumpTransitorio);
      expect(SyncEngine.decisionAnte4xxPush(500, ''),
          Decision4xxPush.bumpTransitorio);
      expect(SyncEngine.decisionAnte4xxPush(503, ''),
          Decision4xxPush.bumpTransitorio);
    });
  });

  group('YS-1 · cableado del push (estructural)', () {
    final sync = File('lib/sync.dart').readAsStringSync();

    test('la rama 4xx de _uploadUnaPorUna decide ANTES de '
        'marcar rechazada', () {
      final i = sync.indexOf('Future<int> _uploadUnaPorUna');
      expect(i, isNonNegative);
      final cuerpo = sync.substring(i, i + 9000);
      final iDecision = cuerpo.indexOf('decisionAnte4xxPush(');
      final iRechazada = cuerpo.indexOf("markOp(uuid, 'rechazada'");
      expect(iDecision, isNonNegative,
          reason: 'la rama 4xx ya no consulta la decisión pura');
      expect(iRechazada, isNonNegative);
      expect(iDecision, lessThan(iRechazada),
          reason: 'el markOp rechazada quedó alcanzable sin '
              'pasar por decisionAnte4xxPush: un 401 volvería '
              'a quemar la op');
      expect(cuerpo, contains('Decision4xxPush.bumpAuth'),
          reason: 'la rama ya no trata el 401/403 como auth');
    });

    test('el lote NO deriva un 401/403 al una-por-una', () {
      // 1.32 (O2F2S, F-9): _uploadOps devuelve además
      // `abortadoPorAuth` en su record — el localizador del
      // pin se actualiza a la firma nueva; la semántica
      // pineada (auth ANTES del una-por-una y aborto del
      // push) se conserva y se refuerza: el resultado
      // expone el aborto para que _doPush salte fotos,
      // comprobantes y el segundo intento.
      final i = sync.indexOf('_uploadOps({bool forzar = false})');
      expect(i, isNonNegative);
      final cuerpo = sync.substring(i, i + 16000);
      final iAuth = cuerpo.indexOf('Decision4xxPush.bumpAuth');
      final iFallback = cuerpo.indexOf('_uploadUnaPorUna(lote)');
      expect(iAuth, isNonNegative,
          reason: 'el camino en lote ya no detecta el auth');
      expect(iFallback, isNonNegative);
      expect(iAuth, lessThan(iFallback),
          reason: 'el lote deriva al una-por-una antes de '
              'mirar si el 4xx era de sesión: el 401 se '
              'repetiría op a op');
      expect(cuerpo, contains('abortarPush'),
          reason: 'el lote ya no aborta el push tras el auth');
      expect(cuerpo, contains('abortadoPorAuth: abortarPush'),
          reason: 'F-9: el aborto por auth ya no sale en el '
              'resultado de _uploadOps: _doPush volvería a '
              'intentar fotos/comprobantes y el segundo '
              '_uploadOps con la sesión muerta');
    });

    test('el bump auth del lote usa httpStatus (clasifica auth)',
        () {
      // Sin httpStatus, clasificarError no vería el 401 y el
      // bump podría caer en transitorio/permanente: la op
      // quedaría con backoff o en revisión en vez de en el
      // carril de sesión.
      final i = sync.indexOf('_uploadOps({bool forzar = false})');
      expect(i, isNonNegative);
      final cuerpo = sync.substring(i, i + 16000);
      final iAuth = cuerpo.indexOf('Decision4xxPush.bumpAuth');
      expect(iAuth, isNonNegative);
      final zona = cuerpo.substring(iAuth, iAuth + 1200);
      expect(zona, contains('httpStatus: r.statusCode'),
          reason: 'el bump del lote perdió el httpStatus');
      expect(zona, contains('_bumpConReversion'),
          reason: 'el auth del lote ya no pasa por el bump '
              'seguro (único embudo sin rechazo ni reversión)');
    });
  });
}
