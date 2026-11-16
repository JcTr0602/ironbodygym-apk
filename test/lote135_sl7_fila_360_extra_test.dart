/// SL-7 · G06-8 (escenas extra) — fila de venta EN COLA en
/// «Ventas de hoy» (con su chip) y fila del Historial, a
/// 360 dp con nombres largos: sin overflow.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:ironbody_gym/ui/servicios_historial.dart';

import 'jornada_ayudas.dart';

Future<List<Object>> _drenarRecogiendo(WidgetTester tester,
    {int vueltas = 10}) async {
  final excepciones = <Object>[];
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 50));
    var e = tester.takeException();
    while (e != null) {
      excepciones.add(e);
      e = tester.takeException();
    }
  }
  return excepciones;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('G06-8b · fila en cola a 360 dp sin overflow',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    final hoy = hoyHabanaIso();
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('suplementos', 5, {
        'id': 5,
        'nombre': 'Pre-entreno Ultra Concentrado SL7',
        'precio': 2500,
        'stock': 4,
      }, 1);
      await LocalDb.instance.upsertMirror('servicio_pomos', 8, {
        'id': 8,
        'activo': 1,
        'titular_telegram_id': 735772141,
        'es_principal': 1,
        'dosis_asignadas': 20,
        'dosis_repartidas': 0,
        'suplemento_id': 5,
      }, 1);
      await LocalDb.instance.upsertMirror('clientes', 20, {
        'id': 20,
        'nombre': 'Alejandro Maximiliano Fernández Domínguez del Toro',
        'estado': 'activo',
        'cuenta_casa': 0,
      }, 1);
      final db = await LocalDb.instance.db;
      await db.insert('ops_queue', {
        'op_uuid': 'op-sl7-cola-1',
        'tipo': 'venta_servicio',
        'payload': jsonEncode({
          'tipo': 'dosis_con_agua',
          'cantidad': 12,
          'precio_unitario': 900,
          'metodo': 'transferencia',
          'pomo_id': 8,
          'cliente_id': 20,
          'fecha': hoy,
          'hora': '09:15',
          'vendedor_id': 735772141,
        }),
        'estado': 'pendiente',
        'creada_ts': '${hoy}T09:15:00',
        'telegram_id': 735772141,
      });
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 735772141, 'nombre': 'Jc'},
          ]));
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: const ServiciosScreen(),
    ));
    var excepciones = await _drenarRecogiendo(tester);
    await tester.tap(find.text('Día'));
    excepciones += await _drenarRecogiendo(tester);
    await jornadaEsperar(
        tester,
        find.textContaining(
            'Alejandro Maximiliano Fernández Domínguez'));
    excepciones += await _drenarRecogiendo(tester, vueltas: 4);
    expect(excepciones, isEmpty,
        reason: 'fila en cola a 360 dp sin desborde: $excepciones');
    await jornadaCerrarCascara(tester);
  });

  testWidgets('G06-8c · fila del Historial a 360 dp sin overflow',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    final hoy = hoyHabanaIso();
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('servicio_ventas', 501, {
        'id': 501,
        'fecha': hoy,
        'hora': '09:15',
        'tipo': 'dosis_con_agua',
        'cantidad': 123,
        'precio_unitario': 900,
        'metodo': 'transferencia',
        'cliente_nombre':
            'Alejandro Maximiliano Fernández Domínguez del Toro',
        'registrado_por_nombre':
            'Julio César Pérez Ramírez Administrador General',
      }, 1);
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
        home: ServiciosHistorialScreen(
            esDueno: true, miTid: 735772141, personas: {})));
    final excepciones = await _drenarRecogiendo(tester);
    await jornadaEsperar(
        tester,
        find.textContaining(
            'Alejandro Maximiliano Fernández Domínguez'));
    expect(excepciones, isEmpty,
        reason: 'fila del historial a 360 dp sin desborde: '
            '$excepciones');
  });
}
