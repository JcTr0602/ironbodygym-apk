/// B2 (cola 1.20): tests DIRECTOS del motor de precios
/// (calcularPrecioCobro, función pura). La precedencia
/// cerrada: Casa (0) > especial vigente del método y el
/// periodo > MIN(menores, Oferta) > estándar. Los casos de
/// Yennifer (id 145) y Kevin (id 70) son las tarifas
/// especiales reales del gym.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart' show esMenor;
import 'package:ironbody_gym/precio_cobro.dart';

const _precios = <String, double>{
  'mensual': 2000,
  'menores': 1500,
  'transfer': 2500,
  'semanal': 600,
  'quincenal': 1200,
};
const _hoy = '2026-11-01';

PrecioCobro _cobro({
  String periodo = 'mensual',
  String metodo = 'efectivo',
  bool esCasa = false,
  bool menor = false,
  Map<String, dynamic>? especial,
  double? oferta,
}) =>
    calcularPrecioCobro(
      periodo: periodo,
      metodo: metodo,
      esCasa: esCasa,
      esMenor: menor,
      precios: _precios,
      especial: especial,
      montoOferta: oferta,
      hoyHabana: _hoy,
    );

void main() {
  group('estándar', () {
    test('mensual efectivo 2000, transferencia 2500', () {
      expect(_cobro().monto, 2000);
      expect(_cobro().escalon, 'estandar');
      expect(_cobro(metodo: 'transferencia').monto, 2500);
    });
    test('el periodo manda sobre el método', () {
      expect(_cobro(periodo: 'semanal').monto, 600);
      expect(
          _cobro(periodo: 'quincenal', metodo: 'transferencia')
              .monto,
          1200);
    });
  });

  group('menores y oferta (MIN)', () {
    test('menor mensual paga 1500', () {
      final r = _cobro(menor: true);
      expect(r.monto, 1500);
      expect(r.escalon, 'menores');
    });
    test('menores NO aplica fuera del mensual', () {
      expect(_cobro(periodo: 'semanal', menor: true).monto, 600);
    });
    test('oferta más barata que menores rige la oferta', () {
      final r = _cobro(menor: true, oferta: 1000);
      expect(r.monto, 1000);
      expect(r.escalon, 'oferta');
    });
    test('oferta más cara que menores: rigen menores', () {
      final r = _cobro(menor: true, oferta: 1800);
      expect(r.monto, 1500);
      expect(r.escalon, 'menores');
    });
  });

  group('Casa', () {
    test('Casa paga 0 aunque tenga especial vigente', () {
      final r = _cobro(esCasa: true, especial: {
        'periodo': 'mensual',
        'monto_efectivo': 1000,
        'monto_transferencia': 1000,
      });
      expect(r.monto, 0);
      expect(r.escalon, 'casa');
      expect(r.avisos, isNotEmpty);
    });
  });

  group('especiales reales', () {
    test('Yennifer: 2000 por transferencia; en efectivo no '
        'aplica y cae al estándar', () {
      final esp = {
        'periodo': 'mensual',
        'monto_efectivo': null,
        'monto_transferencia': 2000,
      };
      final t = _cobro(metodo: 'transferencia', especial: esp);
      expect(t.monto, 2000);
      expect(t.escalon, 'especial');
      final e = _cobro(especial: esp);
      expect(e.monto, 2000);
      expect(e.escalon, 'estandar');
    });
    test('Kevin: 1000 solo en efectivo; por transferencia '
        'rigen los 2500 estándar', () {
      final esp = {
        'periodo': 'mensual',
        'monto_efectivo': 1000,
        'monto_transferencia': null,
      };
      final e = _cobro(especial: esp);
      expect(e.monto, 1000);
      expect(e.escalon, 'especial');
      final t = _cobro(metodo: 'transferencia', especial: esp);
      expect(t.monto, 2500);
      expect(t.escalon, 'estandar');
    });
    test('especial vencida: cae al estándar con aviso', () {
      final r = _cobro(especial: {
        'periodo': 'mensual',
        'monto_efectivo': 1000,
        'vigente_hasta': '2026-10-01',
      });
      expect(r.monto, 2000);
      expect(r.escalon, 'estandar');
      expect(r.avisos.join(), contains('vencida'));
    });
    test('especial aún no vigente: estándar con aviso', () {
      final r = _cobro(especial: {
        'periodo': 'mensual',
        'monto_efectivo': 1000,
        'vigente_desde': '2026-12-01',
      });
      expect(r.monto, 2000);
      expect(r.avisos.join(), contains('aún no vigente'));
    });
    test('especial de otro periodo no aplica al mensual', () {
      final r = _cobro(especial: {
        'periodo': 'semanal',
        'monto_efectivo': 300,
      });
      expect(r.monto, 2000);
      expect(r.escalon, 'estandar');
      expect(r.avisos, isEmpty);
    });
    test('menor con especial: rige la especial con aviso', () {
      final r = _cobro(menor: true, especial: {
        'periodo': 'mensual',
        'monto_efectivo': 1200,
      });
      expect(r.monto, 1200);
      expect(r.escalon, 'especial');
      expect(r.avisos, isNotEmpty);
    });
  });

  group('esMenor (B1: delega en edadDeCarnet)', () {
    test('adulto no es menor; joven de 17 sí', () {
      expect(esMenor('900515'), isFalse); // 1990
      expect(esMenor('090615'), isTrue); // 2009, 17 años
    });
    test('sin carnet o con fecha inválida: no es menor', () {
      expect(esMenor(null), isFalse);
      expect(esMenor(''), isFalse);
      expect(esMenor('991332'), isFalse); // mes 13
      expect(esMenor('123'), isFalse);
    });
  });
}
