import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('SyncScope.resolver (matriz aprobada por Argón 2026-10-16)', () {
    test('papelera: clientes + pagos + pagos_diarios', () {
      final t = SyncScope.resolver('papelera');
      expect(t, containsAll(['clientes', 'pagos', 'pagos_diarios']));
      // clientes antes que pagos (FK)
      expect(t.indexOf('clientes'), lessThan(t.indexOf('pagos')));
    });

    test('clientes: igual que papelera', () {
      expect(SyncScope.resolver('clientes'),
          SyncScope.resolver('papelera'));
    });

    test('pagos/cobrar: clientes primero', () {
      for (final s in ['pagos', 'cobrar']) {
        final t = SyncScope.resolver(s);
        expect(t, containsAll(['clientes', 'pagos', 'pagos_diarios']));
        expect(t.indexOf('clientes'), lessThan(t.indexOf('pagos')));
      }
    });

    test('suplementos: categorías → inventario → ventas en orden', () {
      final t = SyncScope.resolver('suplementos');
      expect(
          t,
          containsAll(
              ['categorias_suplemento', 'suplementos', 'ventas_suplementos']));
      // Orden relativo aprobado por Argón (clientes puede intercalarse
      // por la FK de ventas_suplementos; es superset seguro).
      expect(t.indexOf('categorias_suplemento'),
          lessThan(t.indexOf('suplementos')));
      expect(t.indexOf('suplementos'),
          lessThan(t.indexOf('ventas_suplementos')));
    });

    test('servicios: solo tablas de la sección, catálogo primero', () {
      final t = SyncScope.resolver('servicios');
      expect(
          t,
          containsAll([
            'categorias_suplemento',
            'suplementos',
            'servicio_botes',
            'servicio_lotes',
            'servicio_ventas',
            'servicio_salidas',
            'servicio_agua_movimientos',
            'servicio_compras',
          ]));
      expect(t.indexOf('categorias_suplemento'),
          lessThan(t.indexOf('suplementos')));
      // Nada fuera de la sección: ni clientes ni pagos ni caja.
      expect(t, isNot(contains('clientes')));
      expect(t, isNot(contains('pagos')));
      expect(t, isNot(contains('ventas_suplementos')));
    });

    test('scope desconocido: lista vacía', () {
      expect(SyncScope.resolver('no_existe'), isEmpty);
    });

    test('sin duplicados en ningún scope', () {
      for (final s in [
        'papelera',
        'clientes',
        'pagos',
        'cobrar',
        'suplementos',
        'servicios',
        'pago_diario',
        'inscribir',
        'buscar_cliente',
      ]) {
        final t = SyncScope.resolver(s);
        expect(t.toSet().length, t.length, reason: 'scope $s');
      }
    });
  });
}
