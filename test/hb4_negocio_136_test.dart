// test/hb4_negocio_136_test.dart
// 1.36 H-B4 G7: contratos puros de bloque2_resto.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';

void main() {
  group('136-1075 filaIngresoDesdeEspejo (pagos_diarios)', () {
    test('fila vieja sin método clasifica como efectivo', () {
      final f = filaIngresoDesdeEspejo('pagos_diarios', {
        'fecha': '2026-11-18',
        'total': 600,
      });
      expect(f, isNotNull);
      expect(f!.metodo, 'efectivo');
      expect(f.concepto, 'diarios');
    });
    test('método transferencia no se pinta como efectivo', () {
      final f = filaIngresoDesdeEspejo('pagos_diarios', {
        'fecha': '2026-11-18',
        'total': 600,
        'metodo': 'transferencia',
      });
      expect(f!.metodo, 'transferencia');
    });
  });

  group('136-1077 ajustesParaMostrar', () {
    test('solo claves visibles; las internas no salen', () {
      final s = ajustesParaMostrar({
        'tasa_usd': 120,
        'mensualidad': 2000,
        'clave_interna_xyz': 'no-debe-salir',
        'otra_cosa': 42,
      });
      expect(s, contains('tasa_usd'));
      expect(s, contains('mensualidad'));
      expect(s, isNot(contains('clave_interna_xyz')));
      expect(s, isNot(contains('no-debe-salir')));
      expect(s, isNot(contains('otra_cosa')));
    });
  });
}
