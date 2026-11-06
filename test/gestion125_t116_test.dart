// 1.25 T116 (F1-09): el desglose de la señal de atención
// de Home — la fila dice QUÉ espera (inscripciones y/o
// reportes Plus), con singular/plural correctos.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';

void main() {
  test('sin nadie esperando: desglose vacío', () {
    expect(const SenalAtencion().desglose, '');
    expect(const SenalAtencion().visible, isFalse);
  });

  test('solo inscripciones', () {
    expect(const SenalAtencion(solicitudes: 1).desglose,
        '1 inscripción');
    expect(const SenalAtencion(solicitudes: 3).desglose,
        '3 inscripciones');
  });

  test('solo reportes Plus', () {
    expect(const SenalAtencion(reportesPlus: 1).desglose,
        '1 reporte Plus');
    expect(const SenalAtencion(reportesPlus: 2).desglose,
        '2 reportes Plus');
  });

  test('ambos: se unen con · y el total suma', () {
    const s = SenalAtencion(solicitudes: 2, reportesPlus: 1);
    expect(s.desglose, '2 inscripciones · 1 reporte Plus');
    expect(s.total, 3);
  });
}
