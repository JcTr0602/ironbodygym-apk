/// SL-7 · G06-1 — las cinco pantallas de Servicios que tragaban
/// el fallo de carga y pintaban vacío (admin, estadísticas,
/// historial, precios y ranking) enseñan EstadoError con
/// Reintentar, como la principal. El fallo se inyecta por el
/// camino real: se retira de la BD la tabla que la pantalla
/// lee al cargar, así su lectura lanza de verdad.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/ranking_servicios.dart';
import 'package:ironbody_gym/ui/servicios_admin.dart';
import 'package:ironbody_gym/ui/servicios_estadisticas.dart';
import 'package:ironbody_gym/ui/servicios_historial.dart';
import 'package:ironbody_gym/ui/servicios_precios.dart';

import 'jornada_ayudas.dart';

Future<void> _romperTabla(WidgetTester tester, String tabla) async {
  await tester.runAsync(() async {
    final db = await LocalDb.instance.db;
    await db.execute('DROP TABLE IF EXISTS "$tabla"');
  });
}

Future<void> _esperarError(WidgetTester tester) async {
  await jornadaDrenar(tester, vueltas: 10);
  expect(find.byType(EstadoError), findsOneWidget,
      reason: 'el fallo de carga se ve con el EstadoError de la casa');
  expect(find.text('Reintentar'), findsOneWidget,
      reason: 'el error ofrece Reintentar');
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('G06-1 · Inventario: carga rota → EstadoError',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await _romperTabla(tester, 'servicio_agua_movimientos');
    await tester.pumpWidget(
        const MaterialApp(home: ServiciosAdminScreen()));
    await _esperarError(tester);
  });

  testWidgets('G06-1 · Estadísticas: carga rota → EstadoError',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await _romperTabla(tester, 'servicio_ventas');
    await tester.pumpWidget(
        const MaterialApp(home: ServiciosEstadisticasScreen()));
    await _esperarError(tester);
  });

  testWidgets('G06-1 · Historial: carga rota → EstadoError',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await _romperTabla(tester, 'servicio_ventas');
    await tester.pumpWidget(const MaterialApp(
        home: ServiciosHistorialScreen(
            esDueno: true, miTid: 735772141, personas: {})));
    await _esperarError(tester);
  });

  testWidgets('G06-1 · Precios: carga rota → EstadoError',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await _romperTabla(tester, 'meta');
    await tester.pumpWidget(
        const MaterialApp(home: ServiciosPreciosScreen()));
    await _esperarError(tester);
  });

  testWidgets('G06-1 · Ranking: carga rota → EstadoError',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await _romperTabla(tester, 'servicio_ventas');
    await tester.pumpWidget(
        const MaterialApp(home: RankingServiciosScreen()));
    await _esperarError(tester);
  });
}
