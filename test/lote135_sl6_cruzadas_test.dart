/// SL-6 · fichas cruzadas G10 reancladas a venta_suplemento:
/// - G10-7: el diálogo de confirmación (la vista previa del
///   comprobante) ordena los campos como la hoja de venta:
///   producto → cantidad/precio → comprador.
/// - G10-11: si el registro no se guarda, el aviso lleva el
///   motivo conocido traducido (mensajeErrorAmable), nunca un
///   «No se pudo guardar» genérico. La evidencia de
///   comportamiento (el motivo «Suplemento no encontrado» en
///   el diálogo de fallo) vive en el test G05-1 de
///   lote135_sl6_venta_test.dart, sobre la misma superficie.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/venta_suplemento.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G10-7: la vista previa ordena los campos como la hoja '
      'de venta (producto, cantidad, comprador)', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.setAjustes({'tasa_usd': 250});
      await LocalDb.instance.upsertMirror('suplementos', 5, {
        'id': 5,
        'nombre': 'Proteína Orden',
        'precio_oficial': 2500,
        'moneda': 'CUP',
        'stock': 4,
        'activo': 1,
      }, 1);
    });
    // Viewport alto: la hoja entera se construye y el orden
    // vertical de sus secciones se puede medir.
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: VentaSuplementoScreen(
        suplemento: {
          'id': 5,
          'nombre': 'Proteína Orden',
          'precio_oficial': 2500,
          'moneda': 'CUP',
          'stock': 4,
          'activo': 1,
        },
        clienteIdInicial: 20,
        clienteNombreInicial: 'Cliente Orden',
      ),
    ));
    await jornadaDrenar(tester, vueltas: 6);
    await jornadaEsperar(tester, find.text('Confirmar venta'));
    // Orden de la HOJA: producto (cabecera) → «Cantidad y
    // cobro» → «Comprador».
    final dyProducto =
        tester.getTopLeft(find.text('Proteína Orden')).dy;
    final dyCantidad =
        tester.getTopLeft(find.text('Cantidad y cobro')).dy;
    final dyComprador =
        tester.getTopLeft(find.text('Comprador')).dy;
    expect(dyProducto, lessThan(dyCantidad));
    expect(dyCantidad, lessThan(dyComprador),
        reason: 'orden de la hoja: producto, cantidad, comprador');
    // Abrir el diálogo de confirmación (vista previa).
    await tester.tap(find.text('Confirmar venta'));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Confirma la venta'));
    final textos = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(Dialog), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .toList();
    final comprobante =
        textos.firstWhere((t) => t.contains('Producto:'), orElse: () => '');
    expect(comprobante, isNotEmpty,
        reason: 'la vista previa trae el comprobante');
    final iProd = comprobante.indexOf('Producto:');
    final iCant = comprobante.indexOf('Cantidad:');
    final iPrecio = comprobante.indexOf('Precio:');
    final iComprador = comprobante.indexOf('Comprador:');
    expect(iProd, lessThan(iCant));
    expect(iCant, lessThan(iPrecio));
    expect(iPrecio, lessThan(iComprador),
        reason: 'G10-7: el diálogo ordena producto → cantidad '
            '→ precio → comprador, como la hoja de venta');
  });

  test('G10-11 (fuente): el fallo al guardar la venta lleva '
      'el motivo amable, no un genérico', () {
    final venta =
        File('lib/ui/venta_suplemento.dart').readAsStringSync();
    expect(venta, contains('mensaje: mensajeErrorAmable(e)'),
        reason: 'el aviso del fallo de registro lleva el '
            'motivo conocido traducido por la casa');
    expect(venta, isNot(contains('No se pudo guardar')),
        reason: 'sin «No se pudo guardar» genérico en la '
            'pantalla de venta');
  });
}
