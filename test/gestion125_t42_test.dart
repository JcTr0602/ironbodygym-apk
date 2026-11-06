// 1.25 T42: las dos sintaxis de variables conviven — el render
// de plantillas ({{variable}}) acepta también la simple de
// Campañas ({variable}), y la lista blanca manda igual en
// ambas: lo no permitido queda literal y se reporta.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/plantilla_mensaje.dart';

void main() {
  const datos = {
    'nombre': 'Ana',
    'dias_restantes': '5',
    'notas_internas': 'NO DEBE SALIR',
  };

  test('sintaxis doble de siempre', () {
    final r = renderPlantilla(
        'Hola {{nombre}}, te quedan {{dias_restantes}} días.', datos);
    expect(r.texto, 'Hola Ana, te quedan 5 días.');
    expect(r.bloqueadas, isEmpty);
  });

  test('sintaxis simple de Campañas también sustituye', () {
    final r = renderPlantilla(
        'Hola {nombre}, te quedan {dias_restantes} días.', datos);
    expect(r.texto, 'Hola Ana, te quedan 5 días.');
    expect(r.bloqueadas, isEmpty);
  });

  test('mezcla de ambas en el mismo cuerpo', () {
    final r = renderPlantilla('{{nombre}} / {nombre}', datos);
    expect(r.texto, 'Ana / Ana');
  });

  test('la prohibida queda literal en AMBAS sintaxis y se reporta', () {
    final r = renderPlantilla(
        'Doble {{notas_internas}} y simple {notas_internas}.', datos);
    expect(r.texto, 'Doble {{notas_internas}} y simple {notas_internas}.');
    expect(r.bloqueadas, ['notas_internas']);
  });

  test('variable desconocida queda literal y se reporta', () {
    final r = renderPlantilla('Hola {apodo}.', datos);
    expect(r.texto, 'Hola {apodo}.');
    expect(r.bloqueadas, ['apodo']);
  });
}
