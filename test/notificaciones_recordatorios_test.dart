/// Notificaciones del sistema para recordatorios (23/25). Cubre
/// las funciones puras de `lib/notificaciones_recordatorios.dart`:
/// texto del aviso, instante 08:00 Habana (con DST) y la regla de
/// los 5 minutos cuando la hora ya pasó.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/notificaciones_recordatorios.dart';
import 'package:ironbody_gym/recordatorios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RecordatorioDebido debido({
    String tipo = 'cumpleanos',
    String? cliente,
  }) =>
      RecordatorioDebido(
        recordatorioId: 'r1',
        titulo: 'Cumpleaños',
        tipo: tipo,
        alcance: 'solo_mio',
        targetKey: cliente == null ? 'todos' : 'cliente:1',
        clienteNombre: cliente,
        yaDisparado: false,
        puedoDisparar: true,
      );

  test('texto: cumpleaños y vencimiento con nombre', () {
    expect(
        textoAvisoRecordatorio(debido(cliente: 'Ana')),
        (titulo: 'Cumpleaños', texto: 'Ana cumple años hoy'));
    expect(
        textoAvisoRecordatorio(
            debido(tipo: 'vencimiento', cliente: 'Luis')),
        (
          titulo: 'Cumpleaños',
          texto: 'La mensualidad de Luis vence pronto',
        ));
  });

  test('texto: sin cliente, mensaje genérico', () {
    expect(textoAvisoRecordatorio(debido()).texto,
        'Un cliente cumple años hoy');
    expect(
        textoAvisoRecordatorio(debido(tipo: 'personalizado')).texto,
        'Recordatorio para hoy');
  });

  test('instante: 08:00 Habana, verano UTC-4 e invierno UTC-5', () {
    // 2026-10-30: horario de verano (EDT, -4) → 12:00 UTC.
    expect(instanteAvisoHabana('2026-10-30'),
        DateTime.utc(2026, 10, 30, 12));
    // 2027-01-15: horario estándar (EST, -5) → 13:00 UTC.
    expect(instanteAvisoHabana('2027-01-15'),
        DateTime.utc(2027, 1, 15, 13));
  });

  test('debido: antes de las 8 avisa a las 8; después, en 5 min', () {
    expect(
        instanteAvisoDebido(
            fecha: '2026-10-30',
            ahoraUtc: DateTime.utc(2026, 10, 30, 10)),
        DateTime.utc(2026, 10, 30, 12));
    expect(
        instanteAvisoDebido(
            fecha: '2026-10-30',
            ahoraUtc: DateTime.utc(2026, 10, 30, 13)),
        DateTime.utc(2026, 10, 30, 13, 5));
  });

  test('clave de meta: id + target + fecha', () {
    expect(
        claveAvisoRecordatorio(
            recordatorioId: 'r1',
            targetKey: 'cliente:5',
            fecha: '2026-10-30'),
        'notif_prog_r1_cliente:5_2026-10-30');
  });
}
