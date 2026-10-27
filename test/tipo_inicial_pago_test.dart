import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tipos_pago.dart';

/// Default del diálogo de pago, decisión de Jc 2026-10-25:
/// MIN menor/oferta como opción por defecto, NO aplicación automática.
/// El entrenador puede cambiar el tipo en el desplegable antes de
/// confirmar; estos tests cubren solo la preselección.
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

  double monto(TipoPago t) => t.monto;

  group('tipoInicialPago', () {
    test('menor con oferta más barata preselecciona la oferta', () {
      final r = tipoInicialPago([menores, semanal, ofertaBarata],
          menor: true, monto: monto);
      expect(r.id, 'oferta50');
    });

    test('menor con oferta más cara sigue en menores', () {
      final r = tipoInicialPago([menores, ofertaCara],
          menor: true, monto: monto);
      expect(r.id, 'menores');
    });

    test('menor sin oferta sigue en menores', () {
      final r = tipoInicialPago([menores, semanal],
          menor: true, monto: monto);
      expect(r.id, 'menores');
    });

    test('oferta semanal barata no compite con la mensualidad', () {
      final r = tipoInicialPago([menores, ofertaSemanal],
          menor: true, monto: monto);
      expect(r.id, 'menores');
    });

    test('empate entre menores y oferta mantiene menores', () {
      const ofertaIgual = TipoPago(
          id: 'oferta_igual',
          nombre: 'Oferta igual',
          monto: 1500,
          dias: 30);
      final r = tipoInicialPago([menores, ofertaIgual],
          menor: true, monto: monto);
      expect(r.id, 'menores');
    });

    test('1.15 M1d-01: empate mantiene menores aunque la oferta '
        'vaya primera en la lista', () {
      const ofertaIgual = TipoPago(
          id: 'oferta_igual',
          nombre: 'Oferta igual',
          monto: 1500,
          dias: 30);
      final r = tipoInicialPago([ofertaIgual, menores],
          menor: true, monto: monto);
      expect(r.id, 'menores');
    });

    test('1.15 M1d-01: lista vacía lanza ArgumentError claro', () {
      expect(() => tipoInicialPago([], menor: true, monto: monto),
          throwsArgumentError);
      expect(() => tipoInicialPago([], menor: false, monto: monto),
          throwsArgumentError);
    });

    test('adulto sigue en mensual aunque la oferta sea más barata', () {
      final r = tipoInicialPago([mensual, ofertaBarata],
          menor: false, monto: monto);
      expect(r.id, 'mensual');
    });

    test('adulto sin mensual cae al primer tipo', () {
      final r = tipoInicialPago([semanal, ofertaBarata],
          menor: false, monto: monto);
      expect(r.id, 'semanal');
    });
  });
}
