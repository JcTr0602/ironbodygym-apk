/// 1.35 (UI-23): la línea de contexto del Mostrador —
/// día, fecha y turno de un vistazo, compuesta por la
/// función pura `lineaContextoMostrador` con la
/// resolución única de turnos (el programado se muestra
/// desde el inicio de su franja; una apertura ajena viva
/// lo desplaza; la excepción manda sobre el patrón).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/turnos_resolucion.dart';

void main() {
  setUp(restablecerVentanasFranja);

  test('sábado por la mañana: el programado y su hora '
      'de fin de franja', () {
    final linea = lineaContextoMostrador(
      ahora: DateTime(2026, 11, 14, 10, 0),
      patron: const {
        6: {'manana': 'Duany'},
      },
      excepciones: const {},
      aperturas: const [],
    );
    expect(linea,
        'sábado 14 de noviembre · Turno de Duany hasta las 12:00');
  });

  test('lunes por la tarde: fin de franja 20:00', () {
    final linea = lineaContextoMostrador(
      ahora: DateTime(2026, 11, 16, 16, 0),
      patron: const {
        1: {'tarde': 'Gabriel'},
      },
      excepciones: const {},
      aperturas: const [],
    );
    expect(linea,
        'lunes 16 de noviembre · Turno de Gabriel hasta las 20:00');
  });

  test('sin nadie programado en la franja: se dice', () {
    final linea = lineaContextoMostrador(
      ahora: DateTime(2026, 11, 16, 16, 0),
      patron: const {},
      excepciones: const {},
      aperturas: const [],
    );
    expect(linea, 'lunes 16 de noviembre · Sin turno abierto');
  });

  test('domingo no hay franja: se dice', () {
    final linea = lineaContextoMostrador(
      ahora: DateTime(2026, 11, 15, 10, 0),
      patron: const {
        7: {'manana': 'Duany'},
      },
      excepciones: const {},
      aperturas: const [],
    );
    expect(linea, 'domingo 15 de noviembre · Sin turno abierto');
  });

  test('una apertura ajena viva desplaza al programado '
      '(quien cubre es el turno)', () {
    final linea = lineaContextoMostrador(
      ahora: DateTime(2026, 11, 14, 10, 0),
      patron: const {
        6: {'manana': 'Duany'},
      },
      excepciones: const {},
      aperturas: [
        (
          nombre: 'Gabriel',
          aperturaEn: DateTime(2026, 11, 14, 8, 0),
          viva: true,
          cubreA: 'Duany',
        ),
      ],
    );
    expect(linea,
        'sábado 14 de noviembre · Turno de Gabriel hasta las 12:00');
  });

  test('la excepción que anula la franja manda sobre '
      'el patrón', () {
    final linea = lineaContextoMostrador(
      ahora: DateTime(2026, 11, 14, 10, 0),
      patron: const {
        6: {'manana': 'Duany'},
      },
      excepciones: const {
        '2026-11-14': {'manana': null},
      },
      aperturas: const [],
    );
    expect(linea, 'sábado 14 de noviembre · Sin turno abierto');
  });

  test('contrato: el Mostrador pinta la línea sobre las '
      'secciones, en texto secundario y sin tarjeta', () {
    final home = File('lib/ui/home.dart').readAsStringSync();
    expect(home, contains("ValueKey('home-linea-contexto')"));
    expect(home, contains('_computarLineaContexto'));
    expect(home, contains('lineaContextoMostrador('));
    final i = home.indexOf("ValueKey('home-linea-contexto')");
    final segmento = home.substring(i, i + 400);
    expect(segmento, contains('AppTexto.secundario'));
    expect(segmento, isNot(contains('Tarjeta(')));
  });
}
