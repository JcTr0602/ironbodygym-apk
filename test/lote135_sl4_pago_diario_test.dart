/// SL-4 · Pago diario:
/// - G10-1 🚩: el atajo de 1 día pasa por la MISMA comprobación
///   de permiso que el camino largo; sin permiso, aviso y 0 ops.
/// - G10-10: el atajo se llama «Registrar 1 día» (su hecho);
///   «Cobro parcial» queda solo para saldar el fiado.
/// - G10-8: el reporte no pinta tarjetas de turno en cero
///   (regla de Jc: lo que está en cero no aparece).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/pago_diario.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'jornada_ayudas.dart';

/// Re-siembra la foto de Gabriel SIN can_cobrar_pagos y la
/// carga en el singleton (la RPC del arnés no responde: manda
/// la caché, fail-closed pero con foto).
Future<void> _sinPermisoCobrar(WidgetTester tester) async {
  await tester.runAsync(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'cache_permisos_entrenador_json@gabriel',
        jsonEncode({
          'can_cobrar_pagos': false,
          'can_inscribir_clientes': true,
          'can_editar_fichas': true,
          'can_gestionar_turnos': true,
          'can_registrar_gastos': true,
          'can_vender_suplementos': true,
          'can_view_payroll': true,
        }));
    await prefs.setBool('cache_entrenador_activo@gabriel', true);
    await prefs.setBool('cache_entrenador_habilitado@gabriel', true);
    PermisosEntrenador().limpiar();
    await PermisosEntrenador().cargar();
  });
}

/// El atajo de 1 día: el TextButton bajo el botón principal
/// cuyo rótulo empieza por «Registrar» (el principal dice
/// «Registrar N · … CUP» y es BotonPrimario, no TextButton).
Finder _atajo() => find.byWidgetPredicate((w) =>
    w is TextButton &&
    w.child is Text &&
    ((w.child as Text).data ?? '').startsWith('Registrar'));

Future<void> _montarDiario(WidgetTester tester) async {
  jornadaViewport(tester);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: const PagoDiarioScreen()));
  await jornadaDrenar(tester, vueltas: 6);
  await jornadaEsperar(tester, find.textContaining('Pago diario ·'));
}

Future<void> _cantidadDos(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.add_circle_rounded));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('SL-4 · pago diario', () {
    testWidgets(
        'G10-1: sin permiso de cobrar, el atajo de 1 día NO '
        'encola y avisa', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await _sinPermisoCobrar(tester);
      await _montarDiario(tester);
      await _cantidadDos(tester);
      expect(_atajo(), findsOneWidget);
      await tester.tap(_atajo());
      await jornadaDrenar(tester, vueltas: 8);
      final ops = await jornadaOpsTodas('pago_diario');
      expect(ops, isEmpty,
          reason: 'sin permiso, el atajo no puede encolar: la op '
              'rebotaría en el servidor tras anunciar «guardado»');
      expect(
          find.textContaining('permiso para cobrar pagos').evaluate().isNotEmpty ||
              find.textContaining('No pude comprobar tus permisos')
                  .evaluate()
                  .isNotEmpty,
          isTrue,
          reason: 'sin permiso se avisa, no se finge el guardado');
      Navigator.of(tester.element(find.byType(PagoDiarioScreen))).pop();
      await jornadaDrenar(tester, vueltas: 4);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'G10-10: el atajo se llama «Registrar 1 día» y la pantalla '
        'no dice «Cobro parcial»', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await _montarDiario(tester);
      await _cantidadDos(tester);
      expect(find.text('Registrar 1 día'), findsOneWidget);
      expect(find.text('Registrar solo 1'), findsNothing);
      expect(find.textContaining('Cobro parcial'), findsNothing);
      Navigator.of(tester.element(find.byType(PagoDiarioScreen))).pop();
      await jornadaDrenar(tester, vueltas: 4);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'G10-8: el reporte sin cobros no pinta tarjetas de turno',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _montarDiario(tester);
      await tester.tap(find.text('Reporte'));
      await jornadaDrenar(tester, vueltas: 8);
      expect(find.text('Sin registros este día'), findsOneWidget);
      // Las tarjetas de turno en cero («Mañana — 0 CUP» /
      // «Tarde — 0 CUP») no se pintan: en cero, no aparecen.
      expect(find.text('Mañana'), findsNothing);
      expect(find.text('Tarde'), findsNothing);
      Navigator.of(tester.element(find.byType(PagoDiarioScreen))).pop();
      await jornadaDrenar(tester, vueltas: 4);
      await jornadaCerrarCascara(tester);
    });
  });
}
