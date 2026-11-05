import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

/// 1.24 Bloque 3 (O-5 de la auditoría de permisos): el motivo
/// de un rebote por permiso revocado se lee en lenguaje claro
/// en la cola, no como el código crudo del servidor.
void main() {
  group('motivoRechazo — PERMISO_DENEGADO (1.24 B3)', () {
    test('traduce la clave a la acción revocada', () {
      expect(
          motivoRechazo(null, 'PERMISO_DENEGADO:can_cobrar_pagos'),
          'El dueño te quitó el permiso para cobrar pagos: '
          'la operación no se aplicó.');
      expect(
          motivoRechazo(null, 'PERMISO_DENEGADO:can_gestionar_turnos'),
          contains('gestionar turnos'));
    });

    test('también traduce si el código viene en el resultado', () {
      expect(
          motivoRechazo(
              {'error': 'PERMISO_DENEGADO:can_inscribir_clientes'}, null),
          contains('inscribir clientes'));
    });

    test('PERMISO_DENEGADO sin clave conocida: mensaje genérico', () {
      expect(motivoRechazo(null, 'PERMISO_DENEGADO'),
          contains('te quitó el permiso para esta operación'));
    });

    test('SOLO_ADMIN y entrenador inactivo también se traducen', () {
      expect(motivoRechazo(null, 'SOLO_ADMIN'),
          contains('solo puede hacerla el dueño'));
      expect(motivoRechazo(null, 'ENTRENADOR_INACTIVO'),
          contains('no está activa'));
    });

    test('un motivo ordinario pasa intacto (sin traducir)', () {
      expect(motivoRechazo(null, 'El cliente no existe'),
          'El cliente no existe');
      expect(motivoRechazo({'error': 'saldo insuficiente'}, null),
          'saldo insuficiente');
      expect(motivoRechazo(null, null), isNull);
      expect(motivoRechazo(null, ''), isNull);
    });
  });
}
