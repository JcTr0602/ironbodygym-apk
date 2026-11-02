/// T14 (1.20): estado de revisión de tarifas especiales
/// por su vigente_hasta (sin fecha, vigente, por vencer
/// en ≤7 días, vencida). El estado es solo un aviso: la
/// tarifa sigue aplicando hasta que el dueño decida.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tarifa_especial.dart';

void main() {
  const hoy = '2026-11-01';
  Map<String, dynamic> fila(String? hasta) =>
      {'vigente_hasta': hasta};

  test('sin fecha: sin_fecha y no pide revisión', () {
    expect(estadoRevisionTarifa(fila(null), hoy), 'sin_fecha');
    expect(estadoRevisionTarifa(fila(''), hoy), 'sin_fecha');
    expect(tarifaPorRevisar(fila(null), hoy), isFalse);
  });

  test('lejos: vigente', () {
    expect(estadoRevisionTarifa(fila('2026-12-25'), hoy), 'vigente');
    expect(tarifaPorRevisar(fila('2026-12-25'), hoy), isFalse);
  });

  test('a 7 días o menos (incluido hoy): por_vencer', () {
    expect(estadoRevisionTarifa(fila('2026-11-08'), hoy), 'por_vencer');
    expect(estadoRevisionTarifa(fila('2026-11-01'), hoy), 'por_vencer');
    expect(tarifaPorRevisar(fila('2026-11-05'), hoy), isTrue);
  });

  test('ayer: vencida', () {
    expect(estadoRevisionTarifa(fila('2026-10-31'), hoy), 'vencida');
    expect(tarifaPorRevisar(fila('2026-10-31'), hoy), isTrue);
  });

  test('a 8 días: todavía vigente', () {
    expect(estadoRevisionTarifa(fila('2026-11-09'), hoy), 'vigente');
  });
}
