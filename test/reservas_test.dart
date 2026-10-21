// Reservas v2 — bandeja de Gestión: agrupación, orden, joins
// con los espejos y bloqueo por op encolada (helpers puros de
// lib/ui/reservas.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/reservas.dart';

Map<String, dynamic> _reserva(
  int id, {
  int cliente = 7,
  int suplemento = 3,
  int cantidad = 1,
  double precio = 3000,
  String estado = 'solicitada',
  String creada = '2026-10-21T10:00:00-04:00',
  String? expira,
  String? nota,
}) =>
    {
      'id': id,
      'cliente_id': cliente,
      'suplemento_id': suplemento,
      'cantidad': cantidad,
      'precio_unitario': precio,
      'estado': estado,
      'creada_ts': creada,
      'expira_en': expira,
      'nota_resolucion': nota,
    };

final _clientes = [
  {'id': 7, 'nombre': 'Ana'},
  {'id': 8, 'nombre': 'Luis'},
];
final _suplementos = [
  {'id': 3, 'nombre': 'Creatina', 'precio_oficial': 3200.0},
];

void main() {
  group('construirBandeja', () {
    test('agrupa por estado y resuelve nombres y precio vigente', () {
      final b = construirBandeja([
        _reserva(1),
        _reserva(2, estado: 'reservada', expira: '2026-10-24T10:00:00-04:00'),
        _reserva(3, estado: 'pagada'),
      ], _clientes, _suplementos);
      expect(b.solicitadas.map((r) => r.id), [1]);
      expect(b.reservadas.map((r) => r.id), [2]);
      expect(b.historial.map((r) => r.id), [3]);
      final r = b.solicitadas.single;
      expect(r.clienteNombre, 'Ana');
      expect(r.suplementoNombre, 'Creatina');
      expect(r.precioVigente, 3200.0);
      expect(r.totalFoto, 3000.0);
      expect(r.diferenciaTotal, 200.0);
    });

    test('sin joins: nombres de respaldo y diferencia nula', () {
      final b = construirBandeja(
          [_reserva(9, cliente: 99, suplemento: 88)], [], []);
      final r = b.solicitadas.single;
      expect(r.clienteNombre, 'Cliente #99');
      expect(r.suplementoNombre, 'Suplemento #88');
      expect(r.precioVigente, isNull);
      expect(r.diferenciaTotal, isNull);
    });

    test('solicitadas FIFO; reservadas por vencimiento; historial reciente', () {
      final b = construirBandeja([
        _reserva(2, creada: '2026-10-21T11:00:00-04:00'),
        _reserva(1, creada: '2026-10-21T09:00:00-04:00'),
        _reserva(3,
            estado: 'reservada',
            creada: '2026-10-20T09:00:00-04:00',
            expira: '2026-10-25T09:00:00-04:00'),
        _reserva(4,
            estado: 'reservada',
            creada: '2026-10-20T08:00:00-04:00',
            expira: '2026-10-23T09:00:00-04:00'),
        _reserva(5, estado: 'cancelada', creada: '2026-10-19T09:00:00-04:00'),
        _reserva(6, estado: 'expirada', creada: '2026-10-21T08:00:00-04:00'),
      ], _clientes, _suplementos);
      expect(b.solicitadas.map((r) => r.id), [1, 2]);
      expect(b.reservadas.map((r) => r.id), [4, 3]);
      expect(b.historial.map((r) => r.id), [6, 5]);
    });
  });

  group('reservasConOpPendiente', () {
    test('extrae los ids de las ops de reserva encoladas', () {
      final ops = [
        {
          'tipo': 'cobrar_reserva',
          'payload': jsonEncode({'reserva_id': 5, 'metodo': 'efectivo'}),
        },
        {
          'tipo': 'pago_mensual',
          'payload': jsonEncode({'cliente_id': 7}),
        },
        {
          'tipo': 'confirmar_reserva',
          'payload': jsonEncode({'reserva_id': 6}),
        },
        {
          'tipo': 'cancelar_reserva',
          'payload': 'no-es-json',
        },
      ];
      expect(reservasConOpPendiente(ops), {5, 6});
    });
  });

  group('textoVenceEn', () {
    final ahora = DateTime.parse('2026-10-21T10:00:00-04:00');
    test('días y horas', () {
      expect(textoVenceEn('2026-10-23T13:00:00-04:00', ahora),
          'Vence en 2 d 3 h');
    });
    test('solo horas / minutos', () {
      expect(textoVenceEn('2026-10-21T15:00:00-04:00', ahora),
          'Vence en 5 h');
      expect(textoVenceEn('2026-10-21T10:30:00-04:00', ahora),
          'Vence en 30 min');
    });
    test('vencida o sin fecha', () {
      expect(textoVenceEn('2026-10-21T09:00:00-04:00', ahora),
          'Vencida — se libera sola');
      expect(textoVenceEn(null, ahora), '');
      expect(textoVenceEn('basura', ahora), '');
    });
  });
}
