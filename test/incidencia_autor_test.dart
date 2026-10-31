/// Incidencias con autor real (22/25). Cubre las funciones puras
/// de `lib/modelos/incidencia.dart`: el autor que se guarda en
/// filas nuevas y el nombre que se muestra para autores viejos.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/modelos/incidencia.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('autor a guardar: nombre de sesión antes que telegram', () {
    expect(
        autorIncidenciaActual(
            displayName: 'Duany', telegramId: 969869611),
        'Duany');
  });

  test('autor a guardar: sin nombre, telegram; sin nada, vacío', () {
    expect(autorIncidenciaActual(telegramId: 1403501391),
        '1403501391');
    expect(autorIncidenciaActual(), '');
    expect(autorIncidenciaActual(displayName: '  '), '');
  });

  test('fiable: nombre sí; vacío, desconocido y UUID no', () {
    expect(autorIncidenciaFiable('Gabriel'), isTrue);
    expect(autorIncidenciaFiable(''), isFalse);
    expect(autorIncidenciaFiable('desconocido'), isFalse);
    expect(
        autorIncidenciaFiable(
            '123e4567-e89b-12d3-a456-426614174000'),
        isFalse);
    expect(autorIncidenciaFiable('969869611'), isTrue);
  });

  test('mostrar: vacío y desconocido dicen sin autor', () {
    expect(nombreAutorIncidencia(''), 'Sin autor registrado');
    expect(nombreAutorIncidencia('desconocido'),
        'Sin autor registrado');
    expect(nombreAutorIncidencia(null), 'Sin autor registrado');
  });

  test('mostrar: el UUID propio se traduce a su nombre', () {
    expect(
        nombreAutorIncidencia(
          '123e4567-e89b-12d3-a456-426614174000',
          userIdActual: '123e4567-e89b-12d3-a456-426614174000',
          displayNameActual: 'Duany',
        ),
        'Duany');
  });

  test('mostrar: nombre nuevo pasa tal cual; UUID ajeno no se inventa',
      () {
    expect(nombreAutorIncidencia('Gabriel'), 'Gabriel');
    expect(
        nombreAutorIncidencia(
          '123e4567-e89b-12d3-a456-426614174000',
          userIdActual: 'otro-uuid',
          displayNameActual: 'Duany',
        ),
        'Sin autor registrado');
  });
}
