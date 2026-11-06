// 1.25 T43 + T45: la matemática del anillo de salud del
// mes y del texto de diferencia hoy/ayer de la serie de 7
// días (helpers puros de home.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  test('T43: fracción y porcentaje del anillo', () {
    expect(fraccionSaludMes(30, 40), 0.75);
    expect(porcentajeSaludMes(30, 40), 75);
    expect(porcentajeSaludMes(1, 3), 33);
    // Más pagaron que activos (dato raro): el anillo se
    // acota a lleno, no se pasa de vuelta.
    expect(fraccionSaludMes(50, 40), 1.0);
    expect(porcentajeSaludMes(50, 40), 100);
  });

  test('T43: sin activos no se inventa el porcentaje', () {
    expect(fraccionSaludMes(0, 0), 0.0);
    expect(porcentajeSaludMes(5, 0), isNull);
  });

  test('T45: diferencia hoy contra ayer', () {
    List<Map<String, dynamic>> serie(double ayer, double hoy) => [
          {'dia': 'Ayer', 'monto': ayer},
          {'dia': 'Hoy', 'monto': hoy},
        ];
    expect(textoDiferenciaHoyAyer(serie(100, 150)), 'hoy +50% vs ayer');
    expect(textoDiferenciaHoyAyer(serie(200, 100)), 'hoy -50% vs ayer');
    expect(textoDiferenciaHoyAyer(serie(0, 80)), 'ayer sin cobros');
    expect(textoDiferenciaHoyAyer(serie(0, 0)), '');
    expect(textoDiferenciaHoyAyer(const []), '');
    expect(
        textoDiferenciaHoyAyer(const [
          {'dia': 'Hoy', 'monto': 10.0}
        ]),
        '');
  });

  test('T49: acento vivo de la cabecera por estado del día', () {
    expect(
        colorAcentoCabecera(vencenHoy: 0, atrasLeve: 0, atras30: 0),
        AppColores.exito);
    expect(
        colorAcentoCabecera(vencenHoy: 2, atrasLeve: 0, atras30: 0),
        AppColores.alerta);
    expect(
        colorAcentoCabecera(vencenHoy: 0, atrasLeve: 3, atras30: 0),
        AppColores.alerta);
    expect(
        colorAcentoCabecera(vencenHoy: 2, atrasLeve: 3, atras30: 1),
        AppColores.error);
  });
}
