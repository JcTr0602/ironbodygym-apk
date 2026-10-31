import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/reservas.dart';

void main() {
  test('R1: cada estado de reserva tiene su color semántico', () {
    expect(colorEstadoReserva('solicitada'), AppColores.alerta);
    expect(colorEstadoReserva('reservada'), AppColores.info);
    expect(colorEstadoReserva('pagada'), AppColores.exito);
    expect(colorEstadoReserva('rechazada'), AppColores.error);
    expect(colorEstadoReserva('cancelada'), Colors.grey);
    expect(colorEstadoReserva('expirada'), Colors.grey);
    expect(colorEstadoReserva('otro'), Colors.grey);
  });
}
