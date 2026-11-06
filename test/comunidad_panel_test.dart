// test/comunidad_panel_test.dart
// 1.27 (Comunidad, Pieza G): el parseo de
// admin_comunidad_perfiles es tolerante y fiel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/ui/panel_comunidad.dart';

void main() {
  group('parsePerfilesComunidad', () {
    test('ok falso o forma rara: lista vacía', () {
      expect(parsePerfilesComunidad(const {'ok': false}), isEmpty);
      expect(parsePerfilesComunidad(const {}), isEmpty);
      expect(
          parsePerfilesComunidad(const {'ok': true, 'perfiles': 42}),
          isEmpty);
    });

    test('lee los perfiles con sus interruptores', () {
      final perfiles = parsePerfilesComunidad(const {
        'ok': true,
        'perfiles': [
          {
            'cliente_id': 5,
            'nombre': 'Ana',
            'visible': true,
            'oculto_admin': false,
            'mostrar_marcas': true,
            'mostrar_actividad': false,
            'mostrar_rutina': true,
            'mostrar_constancia': true,
          },
          {
            'cliente_id': 6,
            'nombre': 'Luis',
            'visible': false,
            'oculto_admin': true,
            'mostrar_marcas': false,
            'mostrar_actividad': false,
            'mostrar_rutina': false,
            'mostrar_constancia': false,
          },
          {'nombre': 'Sin id'}, // fila rara: se salta.
        ],
      });
      expect(perfiles.length, 2);
      expect(perfiles.first.nombre, 'Ana');
      expect(perfiles.first.bloquesActivos,
          ['Marcas', 'Rutina', 'Constancia']);
      expect(perfiles.last.ocultoAdmin, isTrue);
      expect(perfiles.last.bloquesActivos, isEmpty);
    });
  });

  testWidgets('la pantalla lista perfiles y ocultar '
      'llama con el valor invertido', (tester) async {
    int? clienteOcultado;
    bool? valorOcultar;
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => const {
          'ok': true,
          'perfiles': [
            {
              'cliente_id': 5,
              'nombre': 'Ana',
              'visible': true,
              'oculto_admin': false,
              'mostrar_marcas': true,
              'mostrar_actividad': true,
              'mostrar_rutina': false,
              'mostrar_constancia': false,
            },
          ],
        },
        ocultarPerfil: (id, ocultar) async {
          clienteOcultado = id;
          valorOcultar = ocultar;
          return const {'ok': true};
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Ana'), findsOneWidget);
    expect(find.textContaining('Visible en el directorio'),
        findsOneWidget);

    await tester.tap(find.text('Ocultar'));
    await tester.pumpAndSettle();
    expect(clienteOcultado, 5);
    expect(valorOcultar, isTrue);
    expect(find.text('Mostrar'), findsOneWidget);
    expect(find.textContaining('Oculto por administración'),
        findsOneWidget);
  });
}
