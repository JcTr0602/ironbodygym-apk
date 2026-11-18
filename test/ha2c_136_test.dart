/// H-A2 (1.36) — tercer lote: 136-750, 136-754, 136-764.
/// Contratos de fuente + puros (filtrarVentasHistorial).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-750: venta rápida', () {
    test('Confirmar bloqueado hasta cargar promo/clientes', () {
      final s = _src('lib/ui/detalle_suplemento.dart');
      expect(s, contains('bool _cargandoDatos = true;'));
      expect(s,
          contains('if (_cargandoDatos || _errorCargaDatos != null) return false;'));
    });
    test('error de carga con reintento', () {
      final s = _src('lib/ui/detalle_suplemento.dart');
      expect(s, contains('venta_rapida_cargar_fallo'));
      expect(s, contains("_errorCargaDatos = 'No se pudieron cargar"));
    });
    test('con fiado no se anuncia la promo (regla de Jc)', () {
      final s = _src('lib/ui/detalle_suplemento.dart');
      expect(s, contains('if (_conCliente && _promoActiva && !_esFiado)'));
      expect(s, contains('Venta fiada: no aplica la promo'));
    });
    test('stock releído al confirmar', () {
      final s = _src('lib/ui/detalle_suplemento.dart');
      final i = s.indexOf('136-750) el stock se RELEE');
      expect(i, greaterThan(0));
      expect(s.substring(i, i + 800), contains('stockVigente'));
    });
  });

  group('136-754: venta de suplemento — bandera desde el inicio', () {
    test('_confirmar activa _confirmando antes del primer await', () {
      final s = _src('lib/ui/venta_suplemento.dart');
      final i = s.indexOf('Future<void> _confirmar() async {');
      final t = s.substring(i, i + 700);
      expect(t, contains('setState(() => _confirmando = true);'));
      expect(t, contains('await _confirmarFlujo();'));
      expect(t, contains('finally'));
    });
    test('el botón se deshabilita con _confirmando', () {
      final s = _src('lib/ui/venta_suplemento.dart');
      expect(s, contains('onPressed: (_confirmando ||'));
    });
  });

  group('136-764: historial de ventas', () {
    test('el filtro de moneda usa LocalDb.monedaDe (puro)', () {
      final ventas = <Map<String, dynamic>>[
        {'id': 1, 'moneda': 'USD', 'fecha': '2026-11-01'},
        {'id': 2, 'fecha': '2026-11-01'}, // sin moneda = CUP
        {'id': 3, 'moneda': 'CUP', 'fecha': '2026-11-01'},
      ];
      final usd = filtrarVentasHistorial(
          ventas: ventas, productos: const {}, moneda: 'USD');
      expect(usd.map((v) => v['id']), [1]);
      final cup = filtrarVentasHistorial(
          ventas: ventas, productos: const {}, moneda: 'CUP');
      expect(cup.map((v) => v['id']), [2, 3]);
    });
    test('ventaProtegida con esDueno y EstadoError con reintento', () {
      final s = _src('lib/ui/historial_ventas.dart');
      expect(s, contains('esDueno: AuthService().isOwner'));
      expect(s, contains('No se pudo cargar el historial de ventas'));
      expect(s, contains('String? _errorCarga;'));
    });
  });
}
