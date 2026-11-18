/// H-B1 (1.36): vista previa del cliente —
/// 136-484, 136-485, 136-486, 136-488, 136-492, 136-498,
/// 136-500, 136-501 (contratos de fuente).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final s = File('lib/ui/vista_previa_cliente.dart').readAsStringSync();

  test('136-484 · cuenta_casa de la RPC manda si la clave viene', () {
    expect(s, contains("_cliente.containsKey('cuenta_casa')"));
  });
  test('136-485 · la negación de disponibilidad se chequea primero', () {
    final i = s.indexOf('no dispon');
    final j = s.indexOf("t.contains('dispon')");
    expect(i, greaterThan(0));
    expect(j, greaterThan(i));
  });
  test('136-486 · turno sin contains(ma) suelto', () {
    final i = s.indexOf('String _turnoLegible');
    final cuerpo = s.substring(i, s.indexOf('\n  }', i));
    expect(cuerpo, isNot(contains("contains('ma')")));
    expect(cuerpo, contains("contains('matutino')"));
  });
  test('136-488 · plan vacío = sin plan', () {
    expect(s, contains('plan == null || plan.isEmpty'));
  });
  test('136-492 · diálogo de compra con tema oscuro', () {
    expect(s, contains('Brightness.dark'));
  });
  test('136-498 · denegación ofrece Volver', () {
    expect(s, contains("const Text('Volver')"));
    expect(s, contains("startsWith('Solo el dueño')"));
  });
  test('136-500 · rótulo dice qué pasa al tocar', () {
    expect(s,
        contains('Al tocar un botón se explica qué hace en su app'));
    expect(s, isNot(contains('las acciones están deshabilitadas')));
  });
  test('136-501 · enlaces del plan sin estilo de enlace', () {
    expect(s, contains('a: AppTexto.cuerpo'));
  });
}
