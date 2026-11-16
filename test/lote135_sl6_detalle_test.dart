/// SL-6 · ficha del suplemento:
/// - G05-11: si la lectura de ajustes de stock FALLA, la
///   ficha enseña EstadoError con Reintentar — no el falso
///   vacío «Sin movimientos registrados».
/// - G05-8 (fuente): la ficha usa appBarIron, la barra de
///   la casa, no una AppBar a pelo.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G05-11: con la lectura de ajustes lanzando, la ficha '
      'muestra EstadoError y no «Sin movimientos»',
      (tester) async {
    await jornadaPreparar(tester);
    await tester.runAsync(() async {
      // La lectura real lanza: la tabla del espejo de
      // ajustes no existe en esta BD de prueba.
      final db = await LocalDb.instance.db;
      await db.execute('DROP TABLE suplemento_ajustes');
    });
    // Viewport alto: la sección de movimientos se construye
    // sin tener que desplazar la ficha entera.
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: DetalleSuplementoScreen(
        suplemento: {
          'id': 3,
          'nombre': 'Producto Error',
          'precio_oficial': 100,
          'moneda': 'CUP',
          'stock': 5,
          'activo': 1,
        },
        categoriaNombre: 'Proteínas',
      ),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    expect(find.byType(EstadoError), findsOneWidget,
        reason: 'G05-11: el fallo de lectura se enseña como '
            'error, con su Reintentar');
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.text('Sin movimientos registrados.'),
        findsNothing,
        reason: 'el error ya no se disfraza de vacío');
  });

  test('G05-8 (fuente): la ficha usa la barra de la casa',
      () {
    final det =
        File('lib/ui/detalle_suplemento.dart').readAsStringSync();
    expect(det, contains('appBarIron('),
        reason: 'appBarIron, como su sección');
    expect(det, isNot(contains('appBar: AppBar(')),
        reason: 'fuera la AppBar directa');
  });
}
