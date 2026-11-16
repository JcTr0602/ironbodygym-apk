/// SL-7 · G06-8 — la fila de venta de Servicios a 360 dp con
/// nombres largos no desborda (captura de Jc). Camino real:
/// hub de Servicios del dueño, zona Día, venta de hoy con el
/// cliente y el registrador de nombres muy largos.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/servicios.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('G06-8 · fila de venta a 360 dp sin overflow',
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
      await LocalDb.instance.upsertMirror('servicio_ventas', 501, {
        'id': 501,
        'fecha': hoy,
        'hora': '09:15',
        'tipo': 'dosis_con_agua',
        'cantidad': 12,
        'precio_unitario': 900,
        'metodo': 'transferencia',
        'pomo_id': 8,
        'cliente_nombre':
            'Alejandro Maximiliano Fernández Domínguez del Toro',
        'registrado_por': 735772141,
        'registrado_por_nombre':
            'Julio César Pérez Ramírez Administrador General',
        'vendedor_id': 735772141,
      }, 1);
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
    final excepciones = <Object>[];
    Future<void> drenarRecogiendo({int vueltas = 10}) async {
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
    }

    await drenarRecogiendo();
    await tester.tap(find.text('Día'));
    await drenarRecogiendo();
    await jornadaEsperar(
        tester,
        find.textContaining(
            'Alejandro Maximiliano Fernández Domínguez'));
    await drenarRecogiendo(vueltas: 4);
    expect(excepciones, isEmpty,
        reason: 'a 360 dp la fila de venta no desborda: '
            '$excepciones');
    await jornadaCerrarCascara(tester);
  });
}
