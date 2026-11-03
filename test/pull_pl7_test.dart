/// 1.23 PL-7 (banco de pruebas, 2026-11-03): el pull paginado
/// acepta HTTP 206 como página válida.
///
/// PostgREST responde 206 (Partial Content) cuando la petición
/// lleva `Prefer: count=exact` — lo que piden las tablas que
/// purgan (clientes y pagos) para el conteo H-03 — y quedan
/// filas fuera del rango devuelto. El chequeo del lote solo
/// aceptaba 200 y lanzaba «bajada …: HTTP 206»: la bajada de
/// las dos tablas grandes moría en cuanto el resultado pasaba
/// de una página (instalación limpia, re-descarga tras cerrar
/// sesión, catch-up largo), el watermark no avanzaba y el
/// espejo quedaba sin las últimas filas.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('PL-7 esPaginaPullValida', () {
    test('200 y 206 son páginas utilizables', () {
      expect(esPaginaPullValida(200), isTrue);
      expect(esPaginaPullValida(206), isTrue);
    });

    test('los errores reales siguen sin serlo', () {
      for (final code in [400, 401, 403, 404, 409, 429, 500, 503]) {
        expect(esPaginaPullValida(code), isFalse, reason: 'HTTP $code');
      }
    });

    test('el chequeo del lote del pull usa la función ejercida', () {
      final src = File('lib/sync.dart').readAsStringSync();
      expect(src, contains('if (!esPaginaPullValida(r.statusCode))'));
    });
  });
}
