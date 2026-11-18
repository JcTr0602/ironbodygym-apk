// 1.36 H-B3 — contrato de Reservas (136-745/746/748/749):
// la op en error se distingue de la pendiente, las vencidas
// se separan de las vigentes, el vencimiento bajo un minuto
// dice «Vence ya» y un estado desconocido no se pinta crudo.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/reservas.dart';

ReservaVista vista(int id, String estado, String? expiraEn) =>
    ReservaVista(
      id: id,
      clienteId: 1,
      clienteNombre: 'Cliente $id',
      suplementoId: 1,
      suplementoNombre: 'Proteína',
      cantidad: 1,
      precioUnitario: 100,
      precioVigente: 100,
      estado: estado,
      creadaTs: '2026-11-18T08:00:00',
      expiraEn: expiraEn,
      notaResolucion: null,
    );

Map<String, dynamic> op(String tipo, String estado, int rid,
        {String? error}) =>
    {
      'tipo': tipo,
      'estado': estado,
      'payload': jsonEncode({'reserva_id': rid}),
      if (error != null) 'error': error,
    };

void main() {
  group('136-746 erroresOpsReserva', () {
    test('solo ops de reserva en estado error, con su detalle', () {
      final errores = erroresOpsReserva([
        op('confirmar_reserva', 'error', 5, error: 'sin stock'),
        op('cobrar_reserva', 'pendiente', 6),
        op('pago_mensual', 'error', 7, error: 'otro dominio'),
        op('cancelar_reserva', 'error', 8),
      ]);
      expect(errores.keys, {5, 8});
      expect(errores[5], 'sin stock');
      expect(errores[8], 'Sin detalle del error.');
    });

    test('la pendiente sigue en reservasConOpPendiente y no en errores',
        () {
      final ops = [op('confirmar_reserva', 'pendiente', 5)];
      expect(reservasConOpPendiente(ops), {5});
      expect(erroresOpsReserva(ops), isEmpty);
    });
  });

  group('136-749 partirSolicitadasVencidas', () {
    test('separa por solicitudVencida contra el ahora dado', () {
      final ahora = DateTime(2026, 11, 18, 12);
      final p = partirSolicitadasVencidas([
        vista(1, 'solicitada', '2026-11-18T11:00:00'),
        vista(2, 'solicitada', '2026-11-18T13:00:00'),
        vista(3, 'solicitada', null),
      ], ahora);
      expect(p.vencidas.map((r) => r.id), [1]);
      expect(p.vigentes.map((r) => r.id), [2, 3]);
    });
  });

  group('136-748 textos de la tarjeta', () {
    test('bajo un minuto dice «Vence ya», nunca «Vence en 0 min»', () {
      final ahora = DateTime(2026, 11, 18, 12, 0, 0);
      expect(textoVenceEn('2026-11-18T12:00:30', ahora), 'Vence ya');
      expect(textoVenceEn('2026-11-18T12:05:00', ahora),
          'Vence en 5 min');
    });

    test('estado desconocido no se pinta crudo', () {
      expect(etiquetaEstadoReserva('congelada_rara'),
          'Estado desconocido');
      expect(etiquetaEstadoReserva('solicitada'), 'Solicitada');
    });
  });
}
