/// SL-7 · G06-4 (método con etiqueta de la casa y fallbacks
/// sin #id), G06-6 (fmtFecha en la solicitud de relleno y en
/// la tarjeta semanal) y G06-7 (el éxito de pedir relleno va
/// por el aviso de la casa, con su icono, no un SnackBar crudo).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:ironbody_gym/ui/servicios_admin.dart';
import 'package:ironbody_gym/ui/servicios_estadisticas.dart';
import 'package:ironbody_gym/ui/servicios_historial.dart';

import 'jornada_ayudas.dart';

bool _hayTextoCon(String fragmento) =>
    find.textContaining(fragmento).evaluate().isNotEmpty;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G06-4 · historial: método capitalizado y salida sin '
      'pomo resuelto sin #id', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    final hoy = hoyHabanaIso();
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('servicio_ventas', 501, {
        'id': 501,
        'fecha': hoy,
        'hora': '09:15',
        'tipo': 'dosis_sin_agua',
        'cantidad': 1,
        'precio_unitario': 600,
        'metodo': 'efectivo',
        'cliente_nombre': 'Cliente Uno SL7',
        'registrado_por_nombre': 'Jc',
      }, 1);
      await LocalDb.instance.upsertMirror('servicio_salidas', 601, {
        'id': 601,
        'fecha': hoy,
        'tipo_item': 'dosis',
        'dosis': 2,
        'motivo': 'merma',
        'pomo_id': 999, // pomo que el espejo local no resuelve
      }, 1);
    });
    await tester.pumpWidget(const MaterialApp(
        home: ServiciosHistorialScreen(
            esDueno: true, miTid: 735772141, personas: {})));
    await jornadaEsperar(tester, find.text('Cliente Uno SL7'));
    expect(_hayTextoCon('· Efectivo'), isTrue,
        reason: 'el método se pinta con la etiqueta de la casa');
    expect(_hayTextoCon('· efectivo'), isFalse,
        reason: 'nada de método en minúscula cruda');
    expect(_hayTextoCon('#'), isFalse,
        reason: 'ninguna clave interna (#id) llega a pantalla');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'G06-6 · la solicitud de relleno pinta su fecha con '
      'fmtFecha, no cortando el ISO', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('suplementos', 7, {
        'id': 7,
        'nombre': 'C4 SL7',
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
      final db = await LocalDb.instance.db;
      await db.insert('solicitudes_relleno', {
        'id': 'sol-sl7',
        'data': jsonEncode({
          'id': 'sol-sl7',
          'entrenador_telegram_id': 969869611,
          'entrenador_nombre': 'Duany',
          'suplemento_id': 7,
          'suplemento_nombre': 'C4 SL7',
          'estado': 'pendiente',
          'creado_en': '2026-11-07T10:00:00',
        }),
        'sync_seq': 1,
      });
    });
    await tester.pumpWidget(
        const MaterialApp(home: ServiciosAdminScreen()));
    await jornadaEsperar(tester, find.textContaining('Pidió relleno'));
    expect(_hayTextoCon('07/11/2026'), isTrue,
        reason: 'la fecha de la solicitud va en formato legible');
    expect(_hayTextoCon('2026-11-07'), isFalse,
        reason: 'nada de ISO crudo en la bandeja');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'G06-6 · la tarjeta semanal de Estadísticas pinta el '
      'rango con fmtFecha, no en ISO', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: ServiciosEstadisticasScreen()));
    await jornadaEsperar(tester, find.text('Servicios'));
    // La tarjeta semanal vive al final de la lista: se baja
    // hasta ella.
    final rangoIso = RegExp(r'^\d{4}-\d{2}-\d{2} al \d{4}-\d{2}-\d{2}$');
    final rangoLegible =
        RegExp(r'^\d{2}/\d{2}/\d{4} al \d{2}/\d{2}/\d{4}$');
    var legible = false;
    var iso = false;
    for (var i = 0; i < 14 && !legible && !iso; i++) {
      for (final e in find.byType(Text).evaluate()) {
        final d = (e.widget as Text).data ?? '';
        if (rangoLegible.hasMatch(d)) legible = true;
        if (rangoIso.hasMatch(d)) iso = true;
      }
      if (legible || iso) break;
      await tester.drag(
          find.byType(ListView).first, const Offset(0, -500));
      await jornadaDrenar(tester, vueltas: 2, ms: 40);
    }
    expect(iso, isFalse,
        reason: 'el rango semanal no se pinta en ISO crudo');
    expect(legible, isTrue,
        reason: 'el rango semanal va con fmtFecha en ambos extremos');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'G06-7 · pedir relleno con éxito avisa por el aviso de '
      'la casa (con icono), no un SnackBar crudo', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('suplementos', 5, {
        'id': 5,
        'nombre': 'Pre-entreno SL7',
        'precio': 2500,
        'stock': 4,
      }, 1);
      await LocalDb.instance.upsertMirror('servicio_pomos', 7, {
        'id': 7,
        'activo': 1,
        'titular_telegram_id': 1403501391,
        'es_principal': 0,
        'dosis_asignadas': 10,
        'dosis_repartidas': 0,
        'suplemento_id': 5,
      }, 1);
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 1403501391, 'nombre': 'Gabriel'},
          ]));
    });
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const ServiciosScreen())),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Pedir relleno'));
    await tester.tap(find.text('Pedir relleno'));
    await jornadaDrenar(tester, vueltas: 4);
    await jornadaEsperar(tester, find.text('Enviar pedido'));
    await tester.tap(find.text('Enviar pedido'));
    await jornadaDrenar(tester, vueltas: 8);
    expect(find.text('Pedido enviado al dueño'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Icon)),
        findsOneWidget,
        reason: 'el aviso de la casa lleva su icono junto al '
            'texto; el SnackBar crudo era solo texto');
    Navigator.of(tester.element(find.byType(ServiciosScreen))).pop();
    await jornadaDrenar(tester, vueltas: 4);
    await jornadaCerrarCascara(tester);
  });
}
