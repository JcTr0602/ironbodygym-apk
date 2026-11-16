/// SL-4 · BG-06 — el `false` de `launchUrl` al abrir WhatsApp
/// desde el recibo del historial de ventas se ignoraba (un
/// false no lanza: el try/catch no lo veía) y el envío moría
/// sin ningún aviso. Corregido: false → snack de error de la
/// casa, el mismo del catch vecino.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
    // url_launcher responde FALSE: no hay app que abra el enlace.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
      if (call.method == 'launch') return false;
      if (call.method == 'canLaunch') return false;
      return null;
    });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null);
  });

  testWidgets(
      'BG-06: launchUrl = false en el recibo por WhatsApp → '
      'snack «No se pudo abrir WhatsApp»', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('suplementos', 7, {
        'id': 7,
        'nombre': 'Creatina SL4',
        'precio_cup': 3000,
      }, 1);
      await LocalDb.instance.upsertMirror('ventas_suplementos', 71, {
        'id': 71,
        'suplemento_id': 7,
        'cantidad': 1,
        'precio': 3000,
        'total': 3000,
        'moneda': 'CUP',
        'metodo': 'efectivo',
        'comprador_nombre': 'Cliente Externo',
        'registrado_por_nombre': 'Jc',
        'fecha': '2026-11-16',
      }, 2);
    });
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const HistorialVentasScreen()));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(
        tester, find.byTooltip('Recibo por WhatsApp'));
    await tester.tap(find.byTooltip('Recibo por WhatsApp').first);
    await jornadaDrenar(tester, vueltas: 5);
    await jornadaEsperar(tester, find.text('Recibo por WhatsApp'));
    // Sin teléfono en la ficha: el dueño lo escribe.
    await tester.enterText(
        find.byType(TextField).last, '58112233');
    await tester.pump();
    await tester.tap(find.text('Enviar por WhatsApp'));
    await jornadaDrenar(tester, vueltas: 6);
    expect(find.text('No se pudo abrir WhatsApp'), findsOneWidget,
        reason: 'un false de launchUrl también es un fallo: '
            'se avisa, no muere en silencio');
    Navigator.of(tester.element(find.byType(HistorialVentasScreen)))
        .pop();
    await jornadaDrenar(tester, vueltas: 4);
    await jornadaCerrarCascara(tester);
  });
}
