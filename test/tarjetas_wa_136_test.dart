/// 1.36 (136-291…294 + TJ-14): las tarjetas de WhatsApp.
/// - El comprobante FIADO no contiene «PAGADO» ni la banda
///   de promo en ninguna parte del árbol; el de contado sí
///   (sello + banda con el calificador «con tu pago en el
///   acto»).
/// - El recibo enseña sello y «Pagado hasta» en formato
///   completo; el aviso, la fecha completa protagonista.
/// - Con importe largo y nombre largo, ni el importe ni el
///   nombre se recortan (bloque indivisible / valor que
///   envuelve en 2 líneas, sin ellipsis).
/// - La captura con la escala de texto del sistema forzada
///   a ×1,45 sale con la escala propia de la tarjeta
///   (TJ-01): el lienzo mide lo mismo y no desborda.
/// Render a tamaño de tarjeta (360×450) en viewport de
/// teléfono real.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/confirmacion_cobro.dart';
import 'package:ironbody_gym/ui/tarjetas_wa.dart';

Future<void> _pintar(
  WidgetTester tester,
  Widget tarjeta, {
  double escalaSistema = 1.0,
}) async {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(escalaSistema),
        ),
        child: Scaffold(body: Center(child: tarjeta)),
      ),
    ),
  );
}

List<Text> _textos(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).toList();

void main() {
  test('importeTarjetaWa: miles con espacio duro y moneda pegada', () {
    expect(importeTarjetaWa(2000, 'CUP'), '2\u00A0000\u00A0CUP');
    expect(importeTarjetaWa(4500, 'CUP'), '4\u00A0500\u00A0CUP');
    expect(importeTarjetaWa(1234567, 'CUP'), '1\u00A0234\u00A0567\u00A0CUP');
    expect(importeTarjetaWa(999, 'CUP'), '999\u00A0CUP');
    // Sin un solo espacio normal: el bloque no se puede partir.
    expect(importeTarjetaWa(1234567, 'CUP').contains(' '), isFalse);
  });

  test('fechaTarjetaWa: formato completo único', () {
    expect(fechaTarjetaWa('2026-11-30'), '30 de noviembre');
    expect(fechaTarjetaWa('2026-12-21'), '21 de diciembre');
  });

  testWidgets('136-293 FIADO: sin PAGADO, sin promo, con distintivo',
      (tester) async {
    await _pintar(
      tester,
      const TarjetaWaComprobante(
        cliente: 'Reinier Guerra',
        titulo: 'Suplemento',
        producto: 'Proteína de suero · 1 kg',
        cantidad: 1,
        fechaIso: '2026-11-17',
        total: 4500,
        esFiado: true,
        conPromo: false,
      ),
    );
    for (final t in _textos(tester)) {
      expect(t.data ?? '', isNot(contains('PAGADO')),
          reason: 'un fiado con «PAGADO» es un documento falso');
      expect(t.data ?? '', isNot(contains('mes de gym gratis')));
    }
    expect(find.text('FIADO'), findsOneWidget);
    expect(find.text('Pendiente de cobro'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
  });

  testWidgets('136-293 CONTADO: sello PAGADO y promo calificada',
      (tester) async {
    await _pintar(
      tester,
      const TarjetaWaComprobante(
        cliente: 'Reinier Guerra',
        titulo: 'Suplemento',
        producto: 'Proteína de suero · 1 kg',
        cantidad: 1,
        fechaIso: '2026-11-17',
        total: 4500,
        esFiado: false,
        conPromo: true,
      ),
    );
    expect(find.text('PAGADO'), findsOneWidget);
    expect(find.text('Total pagado'), findsOneWidget);
    expect(
      find.textContaining('con tu pago en el acto'),
      findsOneWidget,
    );
    expect(find.textContaining('mes de gym gratis'), findsOneWidget);
  });

  testWidgets('136-293 CONTADO sin promo: sello sí, banda no',
      (tester) async {
    await _pintar(
      tester,
      const TarjetaWaComprobante(
        cliente: 'Reinier Guerra',
        titulo: 'Servicio',
        producto: 'Dosis de proteína',
        cantidad: 2,
        fechaIso: '2026-11-17',
        total: 300,
        esFiado: false,
        conPromo: false,
      ),
    );
    expect(find.text('PAGADO'), findsOneWidget);
    expect(find.textContaining('mes de gym gratis'), findsNothing);
  });

  testWidgets('136-292 recibo: sello y Pagado hasta completo',
      (tester) async {
    await _pintar(
      tester,
      const TarjetaWaRecibo(
        cliente: 'Ana Barbara Duran',
        concepto: '30 días',
        metodo: 'Efectivo',
        fechaIso: '2026-11-17',
        total: 2000,
        pagadoHastaIso: '2026-12-21',
      ),
    );
    expect(find.text('PAGADO'), findsOneWidget);
    expect(find.text('Pagado hasta el 21 de diciembre'), findsOneWidget);
    expect(find.text('17 de noviembre'), findsOneWidget);
    expect(find.text('2\u00A0000\u00A0CUP'), findsOneWidget);
    expect(find.textContaining('58191577'), findsWidgets);
    // La marca sale del asset oficial, no de un glifo.
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('⚡'), findsNothing);
  });

  testWidgets('136-294 aviso: la fecha completa es protagonista',
      (tester) async {
    await _pintar(
      tester,
      const TarjetaWaAviso(
        nombre: 'Lilian Perez Gomez',
        vencimientoIso: '2026-11-30',
        precios: ['2 000 CUP en efectivo', '2 500 CUP por transferencia'],
      ),
    );
    final fecha = tester.widget<Text>(
        find.byKey(const ValueKey('fecha_aviso_tarjeta_wa')));
    expect(fecha.data, 'Vence el 30 de noviembre');
    expect(fecha.style?.fontSize, greaterThanOrEqualTo(22));
    expect(find.text('Hola, Lilian 👋'), findsOneWidget);
    expect(find.textContaining('58191577'), findsOneWidget);
    expect(find.text('PAGADO'), findsNothing);
  });

  testWidgets('TJ-14.3/4: importe largo y nombre largo sin recorte',
      (tester) async {
    await _pintar(
      tester,
      const TarjetaWaRecibo(
        cliente: 'Ana Barbara Duran Hernandez de la Torre',
        concepto: '30 días',
        metodo: 'Transferencia',
        fechaIso: '2026-11-17',
        total: 1234567,
        pagadoHastaIso: '2026-12-21',
      ),
    );
    expect(tester.takeException(), isNull);
    final importe = tester.widget<Text>(
        find.byKey(const ValueKey('importe_tarjeta_wa')));
    expect(importe.data, '1\u00A0234\u00A0567\u00A0CUP');
    expect(importe.softWrap, isFalse);
    expect(importe.overflow, TextOverflow.visible);
    final nombre = _textos(tester)
        .firstWhere((t) => (t.data ?? '').contains('Ana Barbara'));
    expect(nombre.maxLines, 2);
    expect(nombre.overflow, isNot(TextOverflow.ellipsis));
    expect(nombre.data, contains('de la Torre'));
  });

  testWidgets('entrada: la confirmación con tarjeta ofrece «Enviar tarjeta»',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: ConfirmacionOperacionScreen(
          titulo: '¡Cobro registrado!',
          monto: '2 000 CUP',
          tarjetaWa: TarjetaWaRecibo(
            cliente: 'Ana Barbara Duran',
            concepto: '30 días',
            metodo: 'Efectivo',
            fechaIso: '2026-11-17',
            total: 2000,
            pagadoHastaIso: '2026-12-21',
          ),
          tarjetaTexto: 'recibo',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Enviar tarjeta'), findsOneWidget);
  });

  testWidgets('TJ-01: escala del sistema ×1,45 no entra en la tarjeta',
      (tester) async {
    await _pintar(
      tester,
      const TarjetaWaRecibo(
        cliente: 'Ana Barbara Duran',
        concepto: '30 días',
        metodo: 'Efectivo',
        fechaIso: '2026-11-17',
        total: 2000,
        pagadoHastaIso: '2026-12-21',
      ),
      escalaSistema: 1.45,
    );
    expect(tester.takeException(), isNull);
    // El lienzo conserva su tamaño propio 4:5 pese a la
    // escala forzada del «teléfono».
    final lienzo = tester.getSize(find.byType(Image).first);
    expect(lienzo, const Size(52, 52));
    final caja = tester.getSize(
        find.byKey(const ValueKey('importe_tarjeta_wa')));
    expect(caja.height, lessThan(40));
    expect(find.text('PAGADO'), findsOneWidget);
  });
}
