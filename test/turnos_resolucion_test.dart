// v1.8.0 — Resolución única de turnos: patrón ⊕ excepciones,
// semántica «el plan manda» (§4), colchón T1 y desplazamiento
// solo con apertura viva (T2), poda T3 y resolver T4.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gestion/turnos_resolucion.dart';

void main() {
  // 2026-10-26 = lunes; 2026-10-31 = sábado.
  final lunes = DateTime(2026, 10, 26);
  final sabado = DateTime(2026, 10, 31);
  final patron = parsePatronTurnos({
    '1': {'manana': 'Gabriel', 'tarde': 'Duany'},
    '6': {'manana': 'Gabriel'},
  });

  group('ventanas y franjas', () {
    test('mañana L–V 6–12, sábado 7–12, domingo nada', () {
      expect(ventanaFranja(lunes, 'manana'), (inicio: 360, fin: 720));
      expect(ventanaFranja(sabado, 'manana'), (inicio: 420, fin: 720));
      expect(ventanaFranja(sabado, 'tarde'), isNull);
      expect(ventanaFranja(DateTime(2026, 11, 1), 'manana'), isNull);
    });
    test('franjaDeInstante', () {
      expect(franjaDeInstante(DateTime(2026, 10, 26, 6, 0)), 'manana');
      expect(franjaDeInstante(DateTime(2026, 10, 26, 13, 0)), isNull);
      expect(franjaDeInstante(DateTime(2026, 10, 26, 14, 0)), 'tarde');
      expect(franjaDeInstante(DateTime(2026, 10, 31, 6, 30)), isNull);
      expect(franjaDeInstante(DateTime(2026, 10, 31, 7, 0)), 'manana');
    });
  });

  group('programado: excepción ⊕ patrón', () {
    test('sin excepción manda el patrón', () {
      expect(
          programadoEn(
              fecha: lunes,
              franja: 'manana',
              patron: patron,
              excepciones: const {}),
          'Gabriel');
    });
    test('la excepción con nombre desplaza al patrón', () {
      final exc = parseExcepcionesTurnos({
        '2026-10-26': {'manana': 'Duany'}
      });
      expect(
          programadoEn(
              fecha: lunes,
              franja: 'manana',
              patron: patron,
              excepciones: exc),
          'Duany');
    });
    test('la excepción null ANULA la franja (no cae al patrón)', () {
      final exc = parseExcepcionesTurnos({
        '2026-10-26': {'manana': null}
      });
      expect(
          programadoEn(
              fecha: lunes,
              franja: 'manana',
              patron: patron,
              excepciones: exc),
          isNull);
      // La otra franja del día sigue con el patrón.
      expect(
          programadoEn(
              fecha: lunes,
              franja: 'tarde',
              patron: patron,
              excepciones: exc),
          'Duany');
    });
  });

  group('mostrado: el plan manda (T1/T2)', () {
    AperturaTurno ap(String n, int h, int m, {bool viva = true}) => (
          nombre: n,
          aperturaEn: DateTime(2026, 10, 26, h, m),
          viva: viva
        );

    test('sin aperturas se muestra al programado', () {
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: const {},
          aperturas: const []);
      expect(r.nombre, 'Gabriel');
      expect(r.cubriendo, isFalse);
    });

    test('la apertura del propio programado no cambia nada', () {
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: const {},
          aperturas: [ap('Gabriel (APK)', 6, 5)]);
      expect(r.nombre, 'Gabriel');
      expect(r.cubriendo, isFalse);
    });

    test('apertura ajena VIVA desplaza (cubriendo)', () {
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: const {},
          aperturas: [ap('Duany', 6, 10)]);
      expect(r.nombre, 'Duany');
      expect(r.cubriendo, isTrue);
    });

    test('T2: apertura ajena ya CERRADA no desplaza', () {
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: const {},
          aperturas: [ap('Duany', 6, 10, viva: false)]);
      expect(r.nombre, 'Gabriel');
      expect(r.cubriendo, isFalse);
    });

    test('T1: abrir 10 min antes SÍ liga a la franja', () {
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: const {},
          aperturas: [ap('Duany', 5, 50)]);
      expect(r.nombre, 'Duany');
      expect(r.cubriendo, isTrue);
    });

    test('T1: abrir 60 min antes NO liga (fuera del colchón)', () {
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: const {},
          aperturas: [ap('Duany', 5, 0)]);
      expect(r.nombre, 'Gabriel');
      expect(r.cubriendo, isFalse);
    });

    test('franja anulada + apertura viva = cobertura sobre nadie',
        () {
      final exc = parseExcepcionesTurnos({
        '2026-10-26': {'manana': null}
      });
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: exc,
          aperturas: [ap('Duany', 6, 10)]);
      expect(r.nombre, 'Duany');
      expect(r.cubriendo, isTrue);
    });

    test('apertura de OTRA franja no pisa el plan de esta', () {
      // Duany abrió a las 15:00 (tarde); en la mañana manda Gabriel.
      final r = mostradoEn(
          fecha: lunes,
          franja: 'manana',
          patron: patron,
          excepciones: const {},
          aperturas: [ap('Duany', 15, 0)]);
      expect(r.nombre, 'Gabriel');
      expect(r.cubriendo, isFalse);
    });
  });

  group('poda T3 y resolver T4', () {
    test('podarExcepciones conserva hoy-180 en adelante', () {
      final exc = parseExcepcionesTurnos({
        '2026-04-29': {'manana': 'Duany'},
        '2026-04-28': {'manana': 'Duany'},
        '2026-10-26': {'tarde': 'Gabriel'},
      });
      final podado =
          podarExcepciones(exc, hoy: DateTime(2026, 10, 26));
      expect(podado.keys, containsAll(['2026-04-29', '2026-10-26']));
      expect(podado.containsKey('2026-04-28'), isFalse);
    });

    test('resolverIdPorNombre exige unicidad entre activos', () {
      final usuarios = [
        (id: 'u1', nombre: 'Duany', activo: true),
        (id: 'u2', nombre: 'Gabriel', activo: true),
        (id: 'u3', nombre: 'Duany', activo: false),
      ];
      expect(resolverIdPorNombre('duany', usuarios), 'u1');
      expect(resolverIdPorNombre('Gabriel (APK)', usuarios), 'u2');
      expect(resolverIdPorNombre('Nadie', usuarios), isNull);
      final ambiguos = [
        (id: 'u1', nombre: 'Duany', activo: true),
        (id: 'u4', nombre: 'Duany', activo: true),
      ];
      expect(resolverIdPorNombre('Duany', ambiguos), isNull);
    });
  });
}
