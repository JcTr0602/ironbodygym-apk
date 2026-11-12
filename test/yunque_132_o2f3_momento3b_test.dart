/// 1.32 (Oleada 2, Fase 3 — Momento 3B del plano): el
/// diálogo de adelantos (G-42) avisa EN VIVO, antes de
/// guardar, cuando el monto supera la nómina acumulada
/// del mes (contra G-40): «Este adelanto supera la
/// nómina acumulada de [Nombre] en X CUP; el excedente
/// pasará como deuda arrastrada al próximo mes». El
/// aviso no bloquea (arrastrar deuda es legítimo) y se
/// apaga fuera del mes en curso, porque las cifras
/// son de este mes. Aquí se fija la regla pura; el
/// diálogo la evalúa en cada repintado (el pad y la
/// fecha hacen setState).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/nomina.dart';

void main() {
  group('Momento 3B — avisoAdelantoQueExcedeNomina', () {
    test('supera: el texto del plano con el exceso exacto',
        () {
      expect(
          avisoAdelantoQueExcedeNomina(
            nombreEntrenador: 'Duany',
            monto: 9000,
            nominaAcumulada: 8400,
            enMesActual: true,
          ),
          'Este adelanto supera la nómina acumulada de '
          'Duany en 600 CUP; el excedente pasará como '
          'deuda arrastrada al próximo mes');
    });

    test('no supera o iguala: sin aviso (el borde exacto '
        'no arrastra deuda)', () {
      expect(
          avisoAdelantoQueExcedeNomina(
            nombreEntrenador: 'Duany',
            monto: 8400,
            nominaAcumulada: 8400,
            enMesActual: true,
          ),
          isNull);
      expect(
          avisoAdelantoQueExcedeNomina(
            nombreEntrenador: 'Duany',
            monto: 100,
            nominaAcumulada: 8400,
            enMesActual: true,
          ),
          isNull);
    });

    test('fecha fuera del mes en curso: el aviso se apaga '
        '(no compara contra el mes equivocado)', () {
      expect(
          avisoAdelantoQueExcedeNomina(
            nombreEntrenador: 'Duany',
            monto: 9000,
            nominaAcumulada: 8400,
            enMesActual: false,
          ),
          isNull);
    });

    test('nómina acumulada en 0 o negativa (ya arrastra '
        'deuda): cualquier adelanto positivo excede', () {
      expect(
          avisoAdelantoQueExcedeNomina(
            nombreEntrenador: 'Gabriel',
            monto: 500,
            nominaAcumulada: 0,
            enMesActual: true,
          ),
          contains('en 500 CUP'));
      expect(
          avisoAdelantoQueExcedeNomina(
            nombreEntrenador: 'Gabriel',
            monto: 500,
            nominaAcumulada: -250,
            enMesActual: true,
          ),
          contains('en 750 CUP'));
    });
  });
}
