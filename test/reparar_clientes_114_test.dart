/// Tests 1.14 (Fix 3): la bandera forzar_redescarga_<tabla> solo se
/// consume cuando la reparación realmente ocurrió.
///
/// El bug: si la cola no estaba limpia al arrancar el pull, la tabla
/// ni entraba en tablasPurga, purgaValidada quedaba en su valor
/// inicial (true) y la bandera se borraba sin purgar. El fantasma
/// (cliente 196) sobrevivía y ningún ciclo futuro lo reintentaba,
/// porque la purga única v1.4.4 ya se había completado.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  test('sin reseteo forzado no se consume nada', () {
    expect(
        SyncEngine.banderaRedescargaSeConsume(
          esPurgable: true,
          fueReseteada: false,
          entroEnPurga: true,
          purgaValidada: true,
        ),
        isFalse);
  });

  test('tabla que no purga: el reseteo completo ya es la reparación',
      () {
    expect(
        SyncEngine.banderaRedescargaSeConsume(
          esPurgable: false,
          fueReseteada: true,
          entroEnPurga: false,
          purgaValidada: true,
        ),
        isTrue);
  });

  test('tabla que purga y purgó con validación: se consume', () {
    expect(
        SyncEngine.banderaRedescargaSeConsume(
          esPurgable: true,
          fueReseteada: true,
          entroEnPurga: true,
          purgaValidada: true,
        ),
        isTrue);
  });

  test('tabla que purga y purgó sin validar: sobrevive', () {
    expect(
        SyncEngine.banderaRedescargaSeConsume(
          esPurgable: true,
          fueReseteada: true,
          entroEnPurga: true,
          purgaValidada: false,
        ),
        isFalse);
  });

  test('EL FIX: tabla que purga pero ni entró en purga (cola sucia al '
      'arrancar el pull): la bandera sobrevive', () {
    expect(
        SyncEngine.banderaRedescargaSeConsume(
          esPurgable: true,
          fueReseteada: true,
          entroEnPurga: false,
          purgaValidada: true,
        ),
        isFalse);
  });
}
