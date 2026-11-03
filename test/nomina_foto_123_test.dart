import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/nomina_foto.dart';

/// 1.23 (B3 Paso 3b): el neto total del dueño sobre la foto
/// compartida — la misma aritmética de filas que pinta la
/// pantalla de Nómina (base compartida, bono por entrenador,
/// comisión, adelantos y deuda del libro).
void main() {
  FotoNominaMes foto({
    Map<String, ({String id, int? telegramId, String nombre})> personas =
        const {},
    Map<String, ({int dosis, double total})> comision = const {},
    Map<String, MesLibroAdelantos> libro = const {},
    Map<String, bool> liquidadas = const {
      'duany': false,
      'gabriel': false,
    },
  }) =>
      (
        tarifa: 150,
        comisionDosis: comision,
        personas: personas,
        eventosPorEnt: const {},
        libroMes: libro,
        liquidadas: liquidadas,
        confirmaciones: const {},
      );

  MesLibroAdelantos mes(
          {double adelantos = 0, double deudaEntrante = 0}) =>
      MesLibroAdelantos(
        mes: '2026-11',
        bruto: 0,
        comisiones: 0,
        adelantos: adelantos,
        deudaEntrante: deudaEntrante,
        items: const [],
      );

  test('sin personas (usuarios_apk vacío) → null, nunca 0', () {
    expect(
        netoTotalDueno(foto(), clientesPagados: 40, bonos: const []),
        isNull);
  });

  test('base compartida ×2 entrenadores, sin extras', () {
    final f = foto(personas: {
      'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
      'gabriel': (id: 'g', telegramId: 2, nombre: 'Gabriel'),
    });
    // 40 clientes × 150 = 6000 por entrenador → 12000 total.
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        12000);
  });

  test('adelantos y deuda descuentan; el suelo es 0 por fila', () {
    final f = foto(
      personas: {
        'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
        'gabriel': (id: 'g', telegramId: 2, nombre: 'Gabriel'),
      },
      libro: {
        'duany': mes(adelantos: 1000, deudaEntrante: 500),
        // Gabriel debe más que su base: su fila paga 0 (la
        // deuda sigue en el libro, no se vuelve negativa).
        'gabriel': mes(adelantos: 9000),
      },
    );
    // Duany: 6000 - 1000 - 500 = 4500. Gabriel: 0. Total 4500.
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        4500);
  });

  test('bono «ambos» suma a los dos; el individual solo al suyo',
      () {
    final f = foto(personas: {
      'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
      'gabriel': (id: 'g', telegramId: 2, nombre: 'Gabriel'),
    });
    final bonos = <Map<String, dynamic>>[
      {'entrenador': 'ambos', 'monto': 300},
      {'entrenador': 'duany', 'monto': 200},
    ];
    // Duany 6000+300+200=6500; Gabriel 6000+300=6300 → 12800.
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: bonos),
        12800);
  });

  test('la comisión por dosis suma al neto', () {
    final f = foto(
      personas: {
        'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
        'gabriel': (id: 'g', telegramId: 2, nombre: 'Gabriel'),
      },
      comision: {
        'duany': (dosis: 4, total: 200.0),
      },
    );
    // Duany 6000+200=6200; Gabriel 6000 → 12200.
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        12200);
  });

  test('foto parcial (falta un entrenador) → null, no cifra '
      'disfrazada (delta del panel)', () {
    final f = foto(personas: {
      'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
    });
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        isNull);
  });

  test('persona con id vacío → null (su libro se omitió en el '
      'ensamblado)', () {
    final f = foto(personas: {
      'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
      'gabriel': (id: '', telegramId: 2, nombre: 'Gabriel'),
    });
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        isNull);
  });

  test('sin entrada en liquidadas (vuelta incompleta) → null',
      () {
    final f = foto(
      personas: {
        'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
        'gabriel': (id: 'g', telegramId: 2, nombre: 'Gabriel'),
      },
      liquidadas: const {'duany': false},
    );
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        isNull);
  });

  test('una nómina ya liquidada NO cuenta como «a pagar»', () {
    final f = foto(
      personas: {
        'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
        'gabriel': (id: 'g', telegramId: 2, nombre: 'Gabriel'),
      },
      liquidadas: const {'duany': true, 'gabriel': false},
    );
    // Solo Gabriel pendiente: 6000.
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        6000);
  });

  test('ambas liquidadas → pendiente 0 (cifra real, no null)',
      () {
    final f = foto(
      personas: {
        'duany': (id: 'd', telegramId: 1, nombre: 'Duany'),
        'gabriel': (id: 'g', telegramId: 2, nombre: 'Gabriel'),
      },
      liquidadas: const {'duany': true, 'gabriel': true},
    );
    expect(netoTotalDueno(f, clientesPagados: 40, bonos: const []),
        0);
  });
}
