/// SL-7 · G06-2 — «Salida sin venta» con UNA sola superficie:
/// la hoja validada de Vender. Desde Inventario, el diálogo
/// viejo aceptaba la cantidad con `tryParse ?? 0` y cerraba
/// (lo tecleado se perdía si el servicio rechazaba). La hoja
/// valida DENTRO: con 0 dosis no cierra y dice el error.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/servicios_admin.dart';
import 'package:ironbody_gym/ui/servicios_detalle.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G06-2 · desde Inventario, la salida abre la hoja y '
      'valida la cantidad sin cerrar', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('suplementos', 7, {
        'id': 7,
        'nombre': 'Creatina SL7',
        'precio': 2500,
        'stock': 4,
      }, 1);
      await LocalDb.instance.upsertMirror('servicio_pomos', 10, {
        'id': 10,
        'suplemento_id': 7,
        'titular_telegram_id': 969869611,
        'es_principal': 0,
        'dosis_asignadas': 40,
        'dosis_repartidas': 0,
        'activo': 1,
      }, 1);
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 969869611, 'nombre': 'Duany'},
          ]));
    });
    await tester.pumpWidget(
        const MaterialApp(home: ServiciosAdminScreen()));
    await jornadaEsperar(tester, find.text('Salida'));
    await tester.ensureVisible(find.text('Salida'));
    await tester.tap(find.text('Salida'));
    await jornadaDrenar(tester, vueltas: 6);

    // La superficie es la HOJA única (el botón del agua de la
    // misma pantalla también se llama «Salida sin venta»: se
    // busca la hoja por su tipo, no por el texto suelto).
    expect(find.byType(HojaSalidaSinVenta), findsOneWidget,
        reason: 'la entrada de Inventario abre la hoja única');
    expect(find.text('Registrar salida'), findsNothing,
        reason: 'el diálogo viejo de Inventario desapareció');

    // Cantidad inválida: la hoja NO cierra y valida dentro.
    final campoDosis = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.labelText == 'Dosis');
    expect(campoDosis, findsOneWidget);
    await tester.enterText(campoDosis, '0');
    await tester.tap(find.text('Registrar'));
    await jornadaDrenar(tester, vueltas: 4);
    expect(find.text('Escribe cuántas dosis salen (1 o más).'),
        findsOneWidget,
        reason: 'la hoja valida igual que desde Vender');
    expect(find.byType(HojaSalidaSinVenta), findsOneWidget,
        reason: 'la hoja sigue abierta: lo tecleado no se pierde');

    // Y ninguna op de salida se encoló con la cantidad mala.
    final ops = await jornadaOpsTodas('salida_servicio');
    expect(ops, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
