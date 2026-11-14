/// 1.35 (UI-10): los vacíos artesanales convertidos pasan
/// por EstadoVacio (pantalla completa o en sección con
/// sinMarco). Contrato sobre las superficies tocadas y
/// render del componente en su forma de sección.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  testWidgets('EstadoVacio sinMarco pinta título y '
      'subtítulo sin medallón de pantalla', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EstadoVacio(
          sinMarco: true,
          icono: Icons.science_rounded,
          titulo: 'Sin botes abiertos todavía',
          subtitulo: 'Abre el primer bote.',
        ),
      ),
    ));
    expect(find.text('Sin botes abiertos todavía'), findsOneWidget);
    expect(find.text('Abre el primer bote.'), findsOneWidget);
    expect(find.byIcon(Icons.science_rounded), findsOneWidget);
  });

  test('contrato: los vacíos convertidos usan EstadoVacio '
      'y las frases sueltas ya no están', () {
    final permisos =
        File('lib/ui/panel_permisos.dart').readAsStringSync();
    expect(permisos, contains("titulo: 'No hay entrenadores registrados'"));
    expect(permisos,
        isNot(contains("Center(\n                    child: Text('No hay entrenadores registrados.')")));
    final arqueo = File('lib/ui/arqueo.dart').readAsStringSync();
    expect(arqueo, contains("titulo: 'Sin liquidaciones registradas'"));
    expect(arqueo, isNot(contains("Text('Sin liquidaciones registradas.'")));
    final servAdmin =
        File('lib/ui/servicios_admin.dart').readAsStringSync();
    expect(servAdmin, contains("titulo: 'Sin botes abiertos todavía'"));
    expect(servAdmin,
        isNot(contains("Text('Sin botes abiertos todavía.'")));
    final lupa = File('lib/ui/lupa_universal.dart').readAsStringSync();
    expect(lupa, contains("titulo: 'Sin resultados en este teléfono'"));
  });
}
