/// UI136-02 (adjudicación ARGON-136-UI, hallazgo H6): el estado de
/// sincronización se dice UNA sola vez (Regla 6 de Jc; precedente
/// 136-197 en la ficha). Fuera el SyncBanner duplicado del body de
/// las 8 pantallas hijas nombradas y el chip propio del cuadre de
/// Servicios. Los usos contextuales legítimos (ficha y demás
/// pantallas no nombradas) NO se tocan.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

const _sinBanner = [
  'lib/ui/mi_nomina.dart',
  'lib/ui/control_acceso.dart',
  'lib/ui/liquidaciones_historial.dart',
  'lib/ui/mi_turno.dart',
  'lib/ui/pagaron_mes.dart',
  'lib/ui/pago.dart',
  'lib/ui/pago_diario.dart',
  'lib/ui/historial_ventas.dart',
];

void main() {
  group('UI136-02 · SyncBanner fuera de las pantallas hijas', () {
    for (final a in _sinBanner) {
      test('$a no monta SyncBanner', () {
        expect(_src(a).contains('SyncBanner('), isFalse,
            reason: '$a sigue duplicando el estado de sync');
      });
    }
    test('servicios: fuera el chip «operaciones por sincronizar»', () {
      final s = _src('lib/ui/servicios.dart');
      expect(s.contains('_opsColaHoy'), isFalse,
          reason: 'el conteo del chip sigue vivo en el cuadre');
      expect(s.contains('Incluye \$_opsColaHoy'), isFalse,
          reason: 'el chip del cuadre sigue pintando estado de sync');
    });
    test('la ficha conserva sus usos contextuales (no es alcance)', () {
      // 136-197 dejó 3 usos contextuales legítimos en ficha.dart;
      // esta fila no los toca.
      expect(_src('lib/ui/ficha.dart').contains('SyncBanner('), isTrue);
    });
  });
}
