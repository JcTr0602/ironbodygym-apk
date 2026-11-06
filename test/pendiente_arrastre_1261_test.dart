// 1.26.1 — Ajustes del veredicto de Argón (APTO CON
// AJUSTES) sobre Cobrar Parcial:
//
// Ajuste 1: la reconstrucción optimista de tarjetas
// (reconstruirEntrenadores, models/pendiente.dart)
// conserva la tarjeta sintética «Solo saldo de cobros
// parciales» de quien sigue debiendo arrastre aunque
// ya no tenga pagos en los crudos. Sin ella, la
// tarjeta desaparecía de la vista optimista con el
// saldo aún vivo.
//
// Ajuste 3: componerCobroParcial redondea también el
// montoEntregado a 2 decimales.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cobro_parcial.dart';
import 'package:ironbody_gym/models/pendiente.dart';

Map<String, dynamic> _pago({
  required int id,
  required double monto,
  String nombre = 'Gabriel',
  int tid = 1403501391,
}) =>
    {
      'id': id,
      'monto': monto,
      'moneda': 'CUP',
      'creada_en': '2026-11-05',
      'tipo': 'mensual',
      'descripcion': '',
      'entrenador_nombre': nombre,
      'trainer_telegram_id': tid,
    };

void main() {
  group('ajuste 1 · reconstruirEntrenadores', () {
    test('un parcial consume todos los pagos y deja '
        'arrastre: la tarjeta muta a sintética con su '
        'nombre, no desaparece', () {
      // Estado tras el parcial: sin pagos de Gabriel en
      // los crudos, arrastre vivo de 500.
      final lista = reconstruirEntrenadores(
        const [],
        const {'1403501391': 500.0},
        nombresPrevios: const {'1403501391': 'Gabriel'},
      );
      expect(lista, hasLength(1));
      expect(lista.single.trainerTelegramId, '1403501391');
      expect(lista.single.nombre, 'Gabriel');
      expect(lista.single.dias, isEmpty);
    });

    test('la tarjeta que YA era sintética sobrevive a '
        'otro parcial menor (1000 de arrastre, cobro de '
        '400): sigue presente con 600 vivos', () {
      final lista = reconstruirEntrenadores(
        const [],
        const {'1403501391': 600.0},
        nombresPrevios: const {'1403501391': 'Gabriel'},
      );
      expect(lista, hasLength(1));
      expect(lista.single.dias, isEmpty);
    });

    test('arrastre en 0 y sin pagos: la tarjeta sale '
        'limpiamente de la lista', () {
      final lista = reconstruirEntrenadores(
        const [],
        const {'1403501391': 0.0},
        nombresPrevios: const {'1403501391': 'Gabriel'},
      );
      expect(lista, isEmpty);
    });

    test('con pagos Y arrastre no se duplica: manda la '
        'tarjeta de los pagos', () {
      final lista = reconstruirEntrenadores(
        [_pago(id: 7, monto: 2000)],
        const {'1403501391': 500.0},
        nombresPrevios: const {'1403501391': 'Gabriel'},
      );
      expect(lista, hasLength(1));
      expect(lista.single.dias, isNotEmpty);
    });

    test('la sintética de un entrenador sobrevive a la '
        'reconstrucción disparada por el cobro de OTRO',
        () {
      final lista = reconstruirEntrenadores(
        [_pago(id: 9, monto: 2000, nombre: 'Duany', tid: 969869611)],
        const {'1403501391': 500.0},
        nombresPrevios: const {'1403501391': 'Gabriel'},
      );
      expect(lista, hasLength(2));
      final gabriel =
          lista.singleWhere((e) => e.trainerTelegramId == '1403501391');
      expect(gabriel.dias, isEmpty);
      expect(gabriel.nombre, 'Gabriel');
    });

    test('sin nombre previo, la sintética cae a '
        '«Entrenador»', () {
      final lista = reconstruirEntrenadores(
        const [],
        const {'1403501391': 500.0},
      );
      expect(lista.single.nombre, 'Entrenador');
    });
  });

  group('ajuste 3 · redondeo del entregado', () {
    test('un monto con cola binaria viaja redondeado '
        'a 2 decimales y el arrastre cuadra', () {
      final c = componerCobroParcial(
          filasFifo: const [], arrastre: 1000, monto: 333.333)!;
      expect(c.montoEntregado, 333.33);
      expect(c.montoEsperado, 1000);
      expect(c.nuevoArrastre, 666.67);
    });
  });
}
