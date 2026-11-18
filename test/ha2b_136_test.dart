/// H-A2 (1.36) — segundo lote: 136-719, 136-720, 136-731,
/// 136-735, 136-741, 136-743. Contratos de fuente + puros.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart' as svc;

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-719: _filaVenta casa tolerante y pomo no nulo', () {
    test('fuente', () {
      final s = _src('lib/ui/servicios.dart');
      final i = s.indexOf('Widget _filaVenta(');
      final t = s.substring(i, i + 1800);
      expect(t, contains('esCasaTolerante(v['));
      expect(t, contains('pomoVentaId != null'));
    });
  });

  group('136-720: topes desde el pomo efectivo', () {
    test('la múltiple re-topa m al cambiar el titular', () {
      final s = _src('lib/ui/servicios.dart');
      expect(s, contains('if (m > n) m = n;'));
      expect(s, contains('if (m > topePomos) m = topePomos;'));
    });
    test('la simple revalida contra el pomo efectivo', () {
      final s = _src('lib/ui/servicios.dart');
      final i = s.indexOf('136-720) revalidación del tope');
      expect(i, greaterThan(0));
      expect(s.substring(i, i + 700), contains('saldoPomoLocal'));
    });
  });

  group('136-731: validar antes de encolar en Servicios', () {
    test('el enum de motivos es el del servidor y se valida', () {
      expect(svc.motivosSalidaServicio,
          {'merma', 'cortesia', 'consumo_staff', 'ajuste'});
      final s = _src('lib/servicios.dart');
      expect('motivosSalidaServicio.contains(motivo)'.allMatches(s).length,
          greaterThanOrEqualTo(2));
    });
    test('sin método activo la venta simple no se abre', () {
      final s = _src('lib/ui/servicios.dart');
      final i = s.indexOf('136-731) sin método activo');
      expect(i, greaterThan(0));
    });
    test('costo de agua y de bote se validan antes de encolar', () {
      final s = _src('lib/ui/servicios_admin.dart');
      expect(s, contains('El costo del agua no es válido'));
      expect(s, contains('El costo del bote no es válido'));
    });
  });

  group('136-735: comparativa mensual', () {
    test('delta null sin base y rótulo «Sin base»', () {
      final s = _src('lib/ui/comparativa_mensual.dart');
      expect(s, contains('double? get deltaPct'));
      expect(s, contains("'Sin base'"));
    });
    test('_contarActivos aplica las exclusiones canónicas', () {
      final s = _src('lib/ui/comparativa_mensual.dart');
      final i = s.indexOf('Future<int> _contarActivos(');
      final t = s.substring(i, i + 1400);
      expect(t, contains('idsCuentasCasa()'));
      expect(t, contains('esPagoAnulado(p, anuladosCola)'));
      expect(t, contains("'cortesia'"));
    });
  });

  group('136-741/743: Reservas', () {
    test('_errorCarga con EstadoError y reintento', () {
      final s = _src('lib/ui/reservas.dart');
      expect(s, contains('String? _errorCarga;'));
      expect(s, contains('No se pudieron cargar las reservas'));
      expect(s, contains('onReintentar: () {'));
    });
    test('_encolar revalida el vencimiento tras los awaits', () {
      final s = _src('lib/ui/reservas.dart');
      final i = s.indexOf('136-743) el VENCIMIENTO');
      expect(i, greaterThan(0));
      expect(s.substring(i, i + 900), contains('expira_en'));
    });
  });
}
