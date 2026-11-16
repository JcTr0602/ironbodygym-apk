/// SL-3 · G01-7 [VIS, aprobada por Jc] — el bloque «Hoy hay
/// que…» del Dashboard NO se pinta cuando no hay nada urgente.
///
/// En la base (ead3d63): `_bloqueHoyHayQue` devuelve una
/// Tarjeta entera con «Nada urgente hoy.» — una fila en cero
/// ocupando pantalla, contra la regla de Jc (lo en cero no
/// aparece). Corregido: sin urgencias no hay tarjeta; con una
/// urgencia, la tarjeta existe con su fila.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/dashboard.dart';

import 'jornada_ayudas.dart';

Future<void> _sembrarVenceHoy() async {
  final hoy = hoyHabanaIso();
  await LocalDb.instance.upsertMirror('clientes', 901, {
    'id': 901,
    'nombre': 'Vence Hoy Sl3',
    'telefono': '58112233',
    'estado': 'activo',
    'pagado_hasta': hoy,
    'fecha_inscripcion': '2026-08-01',
  }, 11);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('sin urgencias: la tarjeta «Nada urgente hoy» '
      'NO existe', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const DashboardScreen()));
    await jornadaDrenar(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Nada urgente hoy.'), findsNothing,
        reason: 'G01-7: sin urgencias la tarjeta no se pinta '
            '(regla de Jc: lo en cero no ocupa)');
    await jornadaCerrarCascara(tester);
  });

  testWidgets('con un cliente que vence hoy: la tarjeta '
      'existe con su fila', (tester) async {
    await jornadaPreparar(tester);
    await tester.runAsync(_sembrarVenceHoy);
    await jornadaSesionDueno(tester);
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const DashboardScreen()));
    await jornadaDrenar(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Vencen hoy: 1'), findsOneWidget,
        reason: 'con urgencia real, el bloque sí se pinta');
    await jornadaCerrarCascara(tester);
  });
}
