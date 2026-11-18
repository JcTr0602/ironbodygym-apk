/// H-B1 (1.36): ficha de acceso, sección Acceso App y
/// congelación — 136-518…136-533.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ficha_congelacion.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-532 · textoCierreCongelacion por vigencia', () {
    final hoy = DateTime(2026, 11, 18);
    test('futura → se cancela con 0 días', () {
      final t = textoCierreCongelacion(
          hoy: hoy, inicio: DateTime(2026, 12, 1));
      expect(t, contains('aún no ha empezado'));
      expect(t, contains('0 días'));
    });
    test('en curso → días hasta ayer', () {
      final t = textoCierreCongelacion(
          hoy: hoy, inicio: DateTime(2026, 11, 13));
      expect(t, contains('los 5 días'));
      expect(t, contains('termina ayer'));
    });
    test('en curso con materializados → los dice', () {
      final t = textoCierreCongelacion(
          hoy: hoy,
          inicio: DateTime(2026, 11, 13),
          diasYaAplicados: 3);
      expect(t, contains('3 ya están aplicados'));
    });
    test('sin inicio → texto genérico en curso', () {
      final t = textoCierreCongelacion(hoy: hoy);
      expect(t, contains('termina ayer'));
    });
  });

  group('contratos de fuente', () {
    final fa = _src('lib/ui/ficha_acceso.dart');
    final app = _src('lib/ui/ficha_acceso_app.dart');
    final cg = _src('lib/ui/ficha_congelacion.dart');

    test('136-518 · sesión sin vencimiento conocido', () {
      expect(fa, contains('Sí (vencimiento desconocido)'));
    });
    test('136-519/526 · chips por significado', () {
      expect(fa, contains('SignificadoChip.error'));
      expect(app, contains('SignificadoChip.error'));
      expect(fa, isNot(contains('Colors.grey')));
    });
    test('136-520 · booleanos «Sí» unificados', () {
      expect(fa, isNot(contains("'SÍ'")));
    });
    test('136-521 · error con Reintentar y vacíos de la casa', () {
      expect(fa, contains('EstadoError('));
      expect(fa, contains('onReintentar: _cargar'));
      expect('EstadoVacio('.allMatches(fa).length,
          greaterThanOrEqualTo(2));
    });
    test('136-522 · revocar en bloque final «Zona delicada»', () {
      expect(fa, contains("'Zona delicada'"));
      expect(fa.indexOf("'Zona delicada'"),
          greaterThan(fa.indexOf('Más acciones')));
    });
    test('136-524 · sello «Verificación guardada»', () {
      expect(app, contains('Verificación guardada: '));
      expect(app, isNot(contains('sin conexión ahora')));
    });
    test('136-525 · sin conexión con AvisoEstado.error', () {
      expect(app, contains('TipoAviso.error'));
    });
    test('136-528 · placeholder del Plus con AnimatedSize', () {
      expect(app, contains('Verificando Plus…'));
      expect(app, contains('AnimatedSize('));
    });
    test('136-529 · refresco al entrar aunque haya caché', () {
      expect(app,
          contains('_verificando = !AccesoAppCache.instance.cargado;'));
    });
    test('136-531 · congelación: significado y un solo glifo', () {
      expect(cg, contains('significado: SignificadoChip.exito'));
      expect(cg, isNot(contains("_cabeceraCongelacion('❄️")));
      expect(cg, isNot(contains("_cabeceraCongelacion(\n                    '❄️")));
      expect(cg, contains('AppEspacio.xs'));
    });
    test('136-533 · «Cerrando…» con progreso', () {
      expect('Cerrando…'.allMatches(cg).length,
          greaterThanOrEqualTo(2));
    });
  });
}
