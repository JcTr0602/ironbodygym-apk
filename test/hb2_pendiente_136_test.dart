import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/models/pendiente.dart';
import 'package:ironbody_gym/tiempo.dart';

// 1.36 H-B2 (136-682): contratos del modelo de pendiente.
void main() {
  group('136-682 PagoPendiente.tryFromMap', () {
    test('acepta id como num double y como texto', () {
      final a = PagoPendiente.tryFromMap({
        'id': 7.0,
        'monto': 100,
        'fecha': '2026-11-10',
        'tipo': 'mensual',
      });
      expect(a?.id, 7);
      final b = PagoPendiente.tryFromMap({
        'id': '8',
        'monto': 100,
        'fecha': '2026-11-10',
        'tipo': 'mensual',
      });
      expect(b?.id, 8);
    });
    test('id no numérico devuelve null (no lanza)', () {
      expect(
          PagoPendiente.tryFromMap({
            'id': 'abc',
            'monto': 100,
            'fecha': '2026-11-10',
          }),
          isNull);
    });
  });

  group('136-682 PendienteDia.etiquetaFecha', () {
    test('una fecha futura no dice «HACE -N DÍAS»', () {
      final manana = ahoraHabana().add(const Duration(days: 2));
      final dia = PendienteDia(fecha: manana, pagos: const []);
      expect(dia.etiquetaFecha, isNot(contains('-')));
      expect(dia.etiquetaFecha, contains('/'));
    });
    test('hoy y ayer conservan su etiqueta', () {
      final hoy = PendienteDia(fecha: ahoraHabana(), pagos: const []);
      expect(hoy.etiquetaFecha, 'HOY');
      final ayer = PendienteDia(
          fecha: ahoraHabana().subtract(const Duration(days: 1)),
          pagos: const []);
      expect(ayer.etiquetaFecha, 'AYER');
    });
  });

  group('136-682 procesarPendientes ordena el día', () {
    test('dentro del día, lo más reciente primero', () {
      final ents = procesarPendientes([
        {
          'id': 1,
          'monto': 10,
          'moneda': 'CUP',
          'tipo': 'mensual',
          'creada_en': '2026-11-10T08:00:00',
          'entrenador_nombre': 'A',
          'trainer_telegram_id': 1,
        },
        {
          'id': 2,
          'monto': 20,
          'moneda': 'CUP',
          'tipo': 'mensual',
          'creada_en': '2026-11-10T15:00:00',
          'entrenador_nombre': 'A',
          'trainer_telegram_id': 1,
        },
      ]);
      expect(ents.single.dias.single.pagos.map((p) => p.id), [2, 1]);
    });
  });
}
