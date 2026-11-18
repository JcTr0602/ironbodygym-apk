/// Corrección ARG136-01 (adjudicación Argón 1.36, V1 —
/// CRÍTICA reincidente): el Extracto de compras
/// (centro_compras.dart → _cargarDatos) filtraba anuladas
/// y Casa pero NO el fiado pendiente: una venta de
/// suplemento fiada y sin saldar entraba en las filas y en
/// el «Total general» como si fuera dinero cobrado,
/// contra el predicado canónico `esFiadoPendienteVenta`
/// que el resto de la app sí aplica (filaIngresoDesdeEspejo
/// lo excluye en C5). La venta fiada SÍ aparece cuando se
/// salda. La moneda de la fila pasa además por
/// `LocalDb.monedaDe`, el normalizador de la casa.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/centro_compras.dart';

import 'jornada_ayudas.dart';

Future<void> _sembrar() async {
  final hoy = hoyHabanaIso();
  final db = LocalDb.instance;
  await db.upsertMirror('suplementos', 1, {
    'id': 1,
    'nombre': 'Normalina',
    'precio_oficial': 500,
    'stock': 9,
    'moneda': 'CUP',
    'activo': 1,
  }, 1);
  await db.upsertMirror('suplementos', 2, {
    'id': 2,
    'nombre': 'Fiadox',
    'precio_oficial': 700,
    'stock': 9,
    'moneda': 'CUP',
    'activo': 1,
  }, 2);
  await db.upsertMirror('suplementos', 3, {
    'id': 3,
    'nombre': 'Saldada',
    'precio_oficial': 300,
    'stock': 9,
    'moneda': 'CUP',
    'activo': 1,
  }, 3);
  // Venta normal: suma.
  await db.upsertMirror('ventas_suplementos', 1, {
    'id': 1,
    'suplemento_id': 1,
    'cantidad': 1,
    'precio': 500,
    'total': 500,
    'moneda': 'CUP',
    'fecha': hoy,
    'anulada': 0,
  }, 4);
  // Venta FIADA sin saldar: no es dinero cobrado.
  await db.upsertMirror('ventas_suplementos', 2, {
    'id': 2,
    'suplemento_id': 2,
    'cantidad': 1,
    'precio': 700,
    'total': 700,
    'moneda': 'CUP',
    'fecha': hoy,
    'anulada': 0,
    'es_fiado': 1,
    'fiado_saldado': 0,
  }, 5);
  // Venta fiada ya SALDADA: sí suma.
  await db.upsertMirror('ventas_suplementos', 3, {
    'id': 3,
    'suplemento_id': 3,
    'cantidad': 1,
    'precio': 300,
    'total': 300,
    'moneda': 'CUP',
    'fecha': hoy,
    'anulada': 0,
    'es_fiado': 1,
    'fiado_saldado': 1,
  }, 6);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('el fiado pendiente no entra en las filas ni '
      'en el total; la normal y la saldada sí', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(_sembrar);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: CentroComprasScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.textContaining('Normalina'));
    expect(find.textContaining('Normalina'), findsWidgets);
    expect(find.textContaining('Saldada'), findsWidgets);
    expect(find.textContaining('Fiadox'), findsNothing,
        reason: 'una venta fiada sin saldar no es una '
            'compra cobrada: fuera de la lista');
    final cabecera = find.textContaining('Total general:');
    await jornadaEsperar(tester, cabecera);
    final texto =
        tester.widget<Text>(cabecera.first).data ?? '';
    expect(texto, contains('800'),
        reason: '500 de la normal + 300 de la saldada');
    expect(texto, isNot(contains('1500')),
        reason: 'con el fiado dentro, el total diría 1500');
    expect(tester.takeException(), isNull);
  });
}
