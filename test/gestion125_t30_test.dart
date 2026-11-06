// 1.25 T30: las franjas de turno salen del horario del gym
// guardado (sembrado vía fijarVentanasDesdeHorarioGym), no de
// constantes: editar el «Horario del Gym» mueve los turnos.
// Sin siembra mandan las constantes de fábrica (el horario
// vigente al nacer la costura).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';

void main() {
  tearDown(restablecerVentanasFranja);

  final lunes = DateTime(2026, 11, 2);
  final miercoles = DateTime(2026, 11, 4);
  final sabado = DateTime(2026, 11, 7);
  final domingo = DateTime(2026, 11, 8);

  test('sin siembra: constantes de fábrica', () {
    expect(ventanaFranja(lunes, 'manana'), (inicio: 360, fin: 720));
    expect(ventanaFranja(lunes, 'tarde'), (inicio: 840, fin: 1200));
    expect(ventanaFranja(sabado, 'manana'), (inicio: 420, fin: 720));
    expect(ventanaFranja(sabado, 'tarde'), isNull);
    expect(ventanaFranja(domingo, 'manana'), isNull);
    expect(ventanaFranja(domingo, 'tarde'), isNull);
  });

  test('con horario sembrado: las franjas son las del horario', () {
    fijarVentanasDesdeHorarioGym({
      // Miércoles: abre 8:00–12:00 y por la tarde CERRADO.
      3: (manana: (inicio: 480, fin: 720), tarde: null),
      // Domingo: el gym abre 9:00–11:00 (antes: sin franjas).
      7: (manana: (inicio: 540, fin: 660), tarde: null),
    });
    expect(ventanaFranja(miercoles, 'manana'), (inicio: 480, fin: 720));
    expect(ventanaFranja(miercoles, 'tarde'), isNull);
    expect(ventanaFranja(domingo, 'manana'), (inicio: 540, fin: 660));
    // franjaDeInstante sigue al horario: miércoles 9:00 es
    // mañana; miércoles 15:00 ya no es ninguna franja; domingo
    // 10:00 es mañana (con las constantes sería null).
    expect(
        franjaDeInstante(DateTime(2026, 11, 4, 9, 0)), 'manana');
    expect(franjaDeInstante(DateTime(2026, 11, 4, 15, 0)), isNull);
    expect(
        franjaDeInstante(DateTime(2026, 11, 8, 10, 0)), 'manana');
    // Un día NO sembrado conserva las constantes.
    expect(ventanaFranja(lunes, 'manana'), (inicio: 360, fin: 720));
  });

  test('restablecer vuelve a las constantes', () {
    fijarVentanasDesdeHorarioGym({
      7: (manana: (inicio: 540, fin: 660), tarde: null),
    });
    expect(ventanaFranja(domingo, 'manana'), isNotNull);
    restablecerVentanasFranja();
    expect(ventanaFranja(domingo, 'manana'), isNull);
  });
}
