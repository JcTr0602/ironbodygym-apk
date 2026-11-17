/// CAMPO-16 (orden de Jc, 2026-11-16) — el botón de
/// actividad reciente va junto a la lupa en la cabecera
/// de la pantalla principal.
///
/// Antes la Actividad solo se abría desde dos enlaces de
/// texto dentro de tarjetas del Mostrador («Ver actividad
/// reciente →» al pie de Mi Turno y en el pliegue del
/// informe del dueño). La cabecera persistente — la de la
/// lupa — no tenía la puerta. CAMPO-16 la pone AHÍ: un
/// botón con el icono de la casa para la actividad
/// (history_rounded, el mismo de la portada del Panel),
/// pegado a la izquierda de la lupa, sin tocar el
/// comportamiento: abre la misma ActividadScreen.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/marco.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _pintarCabecera(
  WidgetTester t, {
  VoidCallback? onActividad,
  VoidCallback? onLupa,
}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          CabeceraMarco(
            rol: 'Dueño',
            nombre: 'Jc',
            onSyncTap: () {},
            onLupa: onLupa ?? () {},
            onActividad: onActividad,
            onAccionPerfil: (_) {},
          ),
        ],
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'x');
    } catch (_) {}
  });

  testWidgets(
      'CAMPO-16: el botón de actividad vive en la cabecera, '
      'pegado a la izquierda de la lupa', (t) async {
    await _pintarCabecera(t, onActividad: () {});
    final actividad = find.byKey(const ValueKey('marco-actividad'));
    final lupa = find.byKey(const ValueKey('marco-lupa'));
    expect(actividad, findsOneWidget,
        reason: 'CAMPO-16: la cabecera lleva el botón de '
            'actividad reciente');
    expect(lupa, findsOneWidget);
    final rAct = t.getRect(actividad);
    final rLupa = t.getRect(lupa);
    expect(rAct.right, lessThanOrEqualTo(rLupa.left),
        reason: 'CAMPO-16: la actividad va A LA IZQUIERDA '
            'de la lupa (la pareja lupa–sync de CAMPO-4/M-6 '
            'no se toca)');
    expect((rLupa.left - rAct.right).abs(), lessThan(1),
        reason: 'CAMPO-16: pegado a la lupa, sin ninguna '
            'pieza entre ambos');
    final boton = t.widget<IconButton>(actividad);
    expect((boton.icon as Icon).icon, Icons.history_rounded,
        reason: 'CAMPO-16: el icono de la casa para la '
            'actividad reciente');
    expect(boton.tooltip, 'Actividad reciente');
  });

  testWidgets(
      'CAMPO-16: tocar el botón dispara su acción y la '
      'lupa sigue con la suya', (t) async {
    var actividades = 0;
    var lupas = 0;
    await _pintarCabecera(
      t,
      onActividad: () => actividades++,
      onLupa: () => lupas++,
    );
    await t.tap(find.byKey(const ValueKey('marco-actividad')));
    await t.pumpAndSettle();
    expect(actividades, 1,
        reason: 'CAMPO-16: el toque abre la actividad '
            '(el destino lo cablea Home, sin cambiar)');
    expect(lupas, 0);
    await t.tap(find.byKey(const ValueKey('marco-lupa')));
    await t.pumpAndSettle();
    expect(lupas, 1, reason: 'la lupa conserva su comportamiento');
    expect(actividades, 1);
  });

  testWidgets(
      'CAMPO-16: sin acción de actividad cableada, la '
      'cabecera no pinta el botón (construcciones de '
      'tests y previews intactas)', (t) async {
    await _pintarCabecera(t);
    expect(find.byKey(const ValueKey('marco-actividad')),
        findsNothing);
    expect(find.byKey(const ValueKey('marco-lupa')),
        findsOneWidget);
  });

  testWidgets(
      'CAMPO-16: con el botón presente y un nombre largo, '
      'la cabecera NO desborda a 420 dp (el nombre cede '
      'con elipsis, los iconos no)', (t) async {
    t.view.physicalSize = const Size(420, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            CabeceraMarco(
              rol: 'Entrenador',
              nombre: 'Julio César Pérez Ramírez',
              onSyncTap: () {},
              onLupa: () {},
              onActividad: () {},
              onAccionPerfil: (_) {},
            ),
          ],
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull,
        reason: 'CAMPO-16: la fila de la cabecera cabe '
            'con los 4 iconos y el nombre largo — la '
            'matriz 1.32 cazó aquí un desborde de 4,8 px '
            'con Roboto real en la cáscara del entrenador');
    expect(find.byKey(const ValueKey('marco-actividad')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('marco-lupa')),
        findsOneWidget);
  });

  test('CAMPO-16: Home cablea el botón a la ActividadScreen '
      'de siempre', () {
    final src = File('lib/ui/home.dart').readAsStringSync();
    expect(
        src.contains(
            'onActividad: () => _ir(const ActividadScreen())'),
        isTrue,
        reason: 'CAMPO-16: el cableado vive en la llamada '
            'de home.dart a CabeceraMarco y el destino es '
            'la ActividadScreen de siempre, por la vía '
            '_ir de la casa');
  });
}
