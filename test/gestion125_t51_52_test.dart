// 1.25 T52: la decisión de la «próxima acción» de una
// fila de Buscar según su estado (función pura).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/buscar.dart';

void main() {
  String? accion({
    int? dias = 10,
    bool esCasa = false,
    bool protegido = false,
    bool seleccion = false,
    bool tel = true,
  }) =>
      accionPrincipalBuscar(
        dias: dias,
        esCasa: esCasa,
        protegido: protegido,
        seleccion: seleccion,
        tieneTelefonoWa: tel,
      );

  test('vencido o sin fecha → cobrar', () {
    expect(accion(dias: -1), 'cobrar');
    expect(accion(dias: -40), 'cobrar');
    expect(accion(dias: null), 'cobrar');
  });

  test('por vencer con teléfono → avisar; sin teléfono → nada', () {
    expect(accion(dias: 0), 'avisar');
    expect(accion(dias: 7), 'avisar');
    expect(accion(dias: 3, tel: false), isNull);
  });

  test('al día → ninguna; Casa/protegido/selección → ninguna', () {
    expect(accion(dias: 8), isNull);
    expect(accion(dias: 30), isNull);
    expect(accion(dias: -5, esCasa: true), isNull);
    expect(accion(dias: -5, protegido: true), isNull);
    expect(accion(dias: -5, seleccion: true), isNull);
  });
}
