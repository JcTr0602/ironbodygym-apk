/// Hub de turnos (24/25). Cubre los puros nuevos de
/// `lib/turnos_resolucion.dart`: correspondencia cierre↔apertura,
/// viva resuelta contra cierres y estado de franja.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> ap({
    String? turnoId,
    String turno = 'manana',
    int? telegram,
    String nombre = 'Duany',
    String fecha = '2026-10-30',
    String hora = '2026-10-30T06:30:00-04:00',
  }) =>
      {
        if (turnoId != null) 'turno_id': turnoId,
        'turno': turno,
        if (telegram != null) 'telegram_id': telegram,
        'entrenador_nombre': nombre,
        'fecha_turno': fecha,
        'hora_apertura': hora,
      };

  Map<String, dynamic> ci({
    String? turnoId,
    String turno = 'manana',
    int? telegram,
    String nombre = 'Duany',
    String fecha = '2026-10-30',
  }) =>
      {
        if (turnoId != null) 'turno_id': turnoId,
        'turno': turno,
        if (telegram != null) 'telegram_id': telegram,
        'entrenador_nombre': nombre,
        'fecha': fecha,
      };

  test('cierre corresponde por turno_id aunque cambie el nombre', () {
    expect(
        cierreCorrespondeApertura(
            ci(turnoId: 't1', nombre: 'Otro'), ap(turnoId: 't1')),
        isTrue);
    expect(
        cierreCorrespondeApertura(
            ci(turnoId: 't2'), ap(turnoId: 't1')),
        isFalse);
  });

  test('sin turno_id: fecha + franja + telegram mandan', () {
    expect(
        cierreCorrespondeApertura(
            ci(telegram: 1), ap(telegram: 1)), isTrue);
    expect(
        cierreCorrespondeApertura(
            ci(telegram: 2), ap(telegram: 1)), isFalse);
    expect(
        cierreCorrespondeApertura(
            ci(turno: 'tarde', telegram: 1), ap(telegram: 1)),
        isFalse);
  });

  test('viva: cierre propio la apaga, ajeno no', () {
    final aps = aperturasHoyConViva(
      aperturas: [
        ap(telegram: 1),
        ap(telegram: 2, nombre: 'Gabriel', hora: '2026-10-30T14:30:00-04:00'),
        ap(fecha: '2026-10-29'),
        ap(nombre: '', telegram: 3),
      ],
      cierres: [ci(telegram: 1)],
      fechaIso: '2026-10-30',
    );
    expect(aps.length, 2);
    expect(aps.where((a) => a.nombre == 'Duany').single.viva,
        isFalse);
    expect(aps.where((a) => a.nombre == 'Gabriel').single.viva,
        isTrue);
  });

  test('estado de franja: abierto > cerrado > sin abrir', () {
    expect(
        estadoFranjaHub(
            hayVivaEnVentana: true, hayCierreFranja: true),
        'abierto');
    expect(
        estadoFranjaHub(
            hayVivaEnVentana: false, hayCierreFranja: true),
        'cerrado');
    expect(
        estadoFranjaHub(
            hayVivaEnVentana: false, hayCierreFranja: false),
        'sin_abrir');
  });

  test('estado completo: programado, mostrado y cubriendo', () {
    final hoy = DateTime(2026, 10, 30, 10, 0); // viernes, mañana
    final est = estadoFranjaCompleto(
      fecha: hoy,
      franja: 'manana',
      patron: {
        5: {'manana': 'Duany', 'tarde': 'Gabriel'},
      },
      excepciones: {},
      aperturas: [
        (
          nombre: 'Gabriel',
          aperturaEn: DateTime(2026, 10, 30, 9, 0),
          viva: true,
        ),
      ],
      cierres: [],
    );
    expect(est.programado, 'Duany');
    expect(est.mostrado, 'Gabriel');
    expect(est.cubriendo, isTrue);
    expect(est.estado, 'abierto');
  });
}
