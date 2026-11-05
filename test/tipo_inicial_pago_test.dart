import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tipos_pago.dart';

/// Default del diálogo de pago para menores, decisión de Jc
/// 2026-11-04 (1.24 Bloque 1, B H-1): el menor SIEMPRE abre en
/// su tarifa ('menores', 1500 por defecto). DEROGA la regla del
/// 2026-10-25 («la opción de 30 días más barata por defecto»),
/// que preseleccionaba ofertas puntuales a menores (caso Keren:
/// oferta_50 dos días seguidos). La oferta sigue elegible a
/// mano en el desplegable; estos tests cubren solo la
/// preselección.
void main() {
  const menores = TipoPago(
      id: 'menores',
      nombre: 'Mensualidad menores',
      monto: 1500,
      dias: 30,
      soloMenores: true);
  const mensual = TipoPago(
      id: 'mensual', nombre: 'Mensualidad', monto: 2000, dias: 30);
  const ofertaBarata = TipoPago(
      id: 'oferta50', nombre: 'Oferta 50%', monto: 1000, dias: 30);
  const ofertaCara = TipoPago(
      id: 'oferta_cara', nombre: 'Oferta cara', monto: 2000, dias: 30);
  const ofertaSemanal = TipoPago(
      id: 'oferta_sem', nombre: 'Oferta semanal', monto: 500, dias: 7);
  const semanal = TipoPago(
      id: 'semanal', nombre: 'Semana', monto: 600, dias: 7);

  group('tipoInicialPago', () {
    test('1.24: menor con oferta más barata SIGUE en menores', () {
      final r = tipoInicialPago([menores, semanal, ofertaBarata],
          menor: true);
      expect(r.id, 'menores');
    });

    test('menor con oferta más cara sigue en menores', () {
      final r = tipoInicialPago([menores, ofertaCara], menor: true);
      expect(r.id, 'menores');
    });

    test('menor sin oferta sigue en menores', () {
      final r = tipoInicialPago([menores, semanal], menor: true);
      expect(r.id, 'menores');
    });

    test('oferta semanal barata no compite con la mensualidad', () {
      final r = tipoInicialPago([menores, ofertaSemanal], menor: true);
      expect(r.id, 'menores');
    });

    test('menores gana sin importar el orden de la lista', () {
      const ofertaIgual = TipoPago(
          id: 'oferta_igual',
          nombre: 'Oferta igual',
          monto: 1500,
          dias: 30);
      final r =
          tipoInicialPago([ofertaIgual, menores], menor: true);
      expect(r.id, 'menores');
    });

    test('menor sin tipo menores en la lista cae al primer tipo', () {
      final r = tipoInicialPago([ofertaBarata, semanal], menor: true);
      expect(r.id, 'oferta50');
    });

    test('lista vacía lanza ArgumentError claro', () {
      expect(() => tipoInicialPago([], menor: true),
          throwsArgumentError);
      expect(() => tipoInicialPago([], menor: false),
          throwsArgumentError);
    });

    test('adulto sigue en mensual aunque la oferta sea más barata',
        () {
      final r = tipoInicialPago([mensual, ofertaBarata],
          menor: false);
      expect(r.id, 'mensual');
    });

    test('adulto sin mensual cae al primer tipo', () {
      final r = tipoInicialPago([semanal, ofertaBarata],
          menor: false);
      expect(r.id, 'semanal');
    });
  });
}
