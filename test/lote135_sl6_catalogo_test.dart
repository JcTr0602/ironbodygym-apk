/// SL-6 · catálogo de Suplementos:
/// - G05-9: dar de alta vive en UN solo sitio permanente
///   (la cabecera «Nuevo»); no hay botón flotante duplicado.
/// - G05-10: la promo va PLEGADA tras el botón
///   «Promo · activa/inactiva»; su interruptor no ocupa
///   espacio permanente y aparece al desplegar.
/// - G05-13 (fuente): fuera el placeholder a mano
///   _PlaceholderFoto de la rejilla; manda el único
///   PlaceholderSuplemento de la casa.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/suplementos.dart';

import 'jornada_ayudas.dart';

Future<void> _sembrarUno() async {
  await LocalDb.instance.upsertMirror('suplementos', 1, {
    'id': 1,
    'nombre': 'Producto Catálogo',
    'precio_oficial': 1000,
    'stock': 5,
    'moneda': 'CUP',
    'activo': 1,
  }, 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G05-9: un solo acceso permanente a dar de alta '
      '(cabecera) y ningún flotante', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(_sembrarUno);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: SuplementosScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Producto Catálogo'));
    expect(find.byType(FloatingActionButton), findsNothing,
        reason: 'sin segundo sitio flotante para el alta');
    expect(find.text('Nuevo'), findsOneWidget,
        reason: 'el alta vive en la cabecera, un solo sitio');
  });

  testWidgets(
      'G05-10: la promo nace plegada tras «Promo · activa» '
      'y su interruptor sale al desplegar', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(() async {
      await _sembrarUno();
      await LocalDb.instance
          .setAjustes({'promo_suplementos': 1});
    });
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: SuplementosScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Producto Catálogo'));
    expect(find.text('Promo · activa'), findsOneWidget,
        reason: 'el botón resume el estado de la promo');
    expect(find.byType(Switch), findsNothing,
        reason: 'G05-10: plegada, la banda no ocupa su '
            'espacio permanente (sin interruptor a la vista)');
    await tester.tap(find.text('Promo · activa'));
    await jornadaDrenar(tester, vueltas: 4);
    expect(find.byType(Switch), findsOneWidget,
        reason: 'desplegando, la promo está con su '
            'interruptor');
  });

  test('G05-13 (fuente): la rejilla ya no usa el '
      'placeholder a mano de gradiente', () {
    final sup =
        File('lib/ui/suplementos.dart').readAsStringSync();
    expect(sup, isNot(contains('_PlaceholderFoto')),
        reason: 'una sola marca de foto genérica: '
            'PlaceholderSuplemento');
    expect(sup, contains('PlaceholderSuplemento('));
    final centro =
        File('lib/ui/centro_compras.dart').readAsStringSync();
    expect(centro, contains('PlaceholderSuplemento('),
        reason: 'el Extracto también usa la marca única '
            'cuando el producto no tiene foto');
  });
}
