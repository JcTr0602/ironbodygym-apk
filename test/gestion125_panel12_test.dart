// 1.25 Panel 12: vistas guardadas de Listas (modelo puro:
// alcance visible, coincidencia y JSON validado).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/listas.dart';

void main() {
  test('el alcance dice pestaña, orden y búsqueda', () {
    const v = VistaLista(
        nombre: 'Lunes', pestana: 2, orden: 'dias');
    expect(v.alcance, 'Atrasados -30d · Días restantes');
    const conBusqueda = VistaLista(
        nombre: 'X', pestana: 4, orden: 'nombre', busqueda: 'ana');
    expect(conBusqueda.alcance, 'Al día · Nombre · «ana»');
  });
  test('coincideCon compara los tres componentes', () {
    const v = VistaLista(
        nombre: 'L', pestana: 1, orden: 'vencimiento', busqueda: 'lu');
    expect(
        v.coincideCon(pestana: 1, orden: 'vencimiento', busqueda: 'lu'),
        isTrue);
    expect(
        v.coincideCon(pestana: 1, orden: 'nombre', busqueda: 'lu'),
        isFalse);
    expect(
        v.coincideCon(pestana: 0, orden: 'vencimiento', busqueda: 'lu'),
        isFalse);
  });
  test('toJson/fromJson dan la vuelta y validan rangos', () {
    const v = VistaLista(
        nombre: 'L', pestana: 3, orden: 'dias', busqueda: 'pe');
    final vuelta = VistaLista.fromJson(v.toJson());
    expect(vuelta?.nombre, 'L');
    expect(vuelta?.pestana, 3);
    expect(vuelta?.orden, 'dias');
    expect(vuelta?.busqueda, 'pe');
    expect(
        VistaLista.fromJson(
            {'nombre': 'L', 'pestana': 9, 'orden': 'dias'}),
        isNull);
    expect(
        VistaLista.fromJson(
            {'nombre': 'L', 'pestana': 1, 'orden': 'raro'}),
        isNull);
    expect(
        VistaLista.fromJson(
            {'nombre': ' ', 'pestana': 1, 'orden': 'dias'}),
        isNull);
  });
}
