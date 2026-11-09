// Gestión 1.30 · Oleada D4 — pantallas de dinero
// (UI130-11, 12, 13).
//
// Lo que fijan estos tests:
// - La partición de la barra de Clientes es DISJUNTA y
//   suma siempre el total de activos (UI130-11), con sus
//   acotaciones ante conteos desfasados.
// - La barra pinta los tres segmentos tocables y, con 0
//   activos, la barra neutra con la leyenda en ceros.
// - FilaLibro (el componente nuevo del libro) pinta
//   concepto, detalle y monto, con y sin icono.
// - La hoja de agregar bono (UI130-12) valida el monto
//   con la regla de siempre (montoTolerante: admite
//   negativos y coma decimal; el 0 no pasa) y entrega
//   los valores capturados a su callback.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/dashboard.dart';
import 'package:ironbody_gym/ui/nomina.dart';

void main() {
  group('UI130-11 · segmentosBarraClientes (partición)', () {
    test('el caso del mockup: 128 = 96 + 19 + 13', () {
      final seg = segmentosBarraClientes(
          activos: 128, porVencer: 19, morosos: 13);
      expect(seg.alDia, 96);
      expect(seg.porVencer, 19);
      expect(seg.vencidos, 13);
      expect(seg.alDia + seg.porVencer + seg.vencidos, 128);
    });

    test('sin por vencer ni vencidos, todo es al día', () {
      final seg = segmentosBarraClientes(
          activos: 40, porVencer: 0, morosos: 0);
      expect(seg.alDia, 40);
      expect(seg.porVencer, 0);
      expect(seg.vencidos, 0);
    });

    test('0 activos: todo a cero', () {
      final seg = segmentosBarraClientes(
          activos: 0, porVencer: 0, morosos: 0);
      expect(seg.alDia, 0);
      expect(seg.porVencer, 0);
      expect(seg.vencidos, 0);
    });

    test('conteos desfasados se acotan y la suma manda', () {
      // porVencer + morosos por encima de activos no puede
      // dar segmentos negativos ni sumar más que el total.
      final seg = segmentosBarraClientes(
          activos: 10, porVencer: 8, morosos: 7);
      expect(seg.vencidos, 7);
      expect(seg.porVencer, 3);
      expect(seg.alDia, 0);
      expect(seg.alDia + seg.porVencer + seg.vencidos, 10);
    });
  });

  group('UI130-11 · BarraClientesSegmentos (widget)', () {
    testWidgets('tres segmentos tocables y leyenda con conteos',
        (tester) async {
      var toques = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BarraClientesSegmentos(
            activos: 128,
            porVencer: 19,
            morosos: 13,
            onAlDia: () => toques.add('alDia'),
            onPorVencer: () => toques.add('porVencer'),
            onVencidos: () => toques.add('vencidos'),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('seg-al-dia')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('seg-por-vencer')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('seg-vencidos')),
          findsOneWidget);
      // La leyenda rotula la PARTICIÓN (96, no el «al día»
      // amplio del conteo de la tarjeta).
      expect(find.text('96 al día'), findsOneWidget);
      expect(find.text('19 por vencer'), findsOneWidget);
      expect(find.text('13 vencidos'), findsOneWidget);
      // Las proporciones mandan: el segmento al día es el
      // más ancho y el de vencidos el más estrecho.
      final anchoAlDia =
          tester.getSize(find.byKey(const ValueKey('seg-al-dia'))).width;
      final anchoVencidos = tester
          .getSize(find.byKey(const ValueKey('seg-vencidos')))
          .width;
      expect(anchoAlDia, greaterThan(anchoVencidos));
      await tester.tap(find.byKey(const ValueKey('seg-vencidos')));
      await tester.tap(find.byKey(const ValueKey('seg-por-vencer')));
      expect(toques, ['vencidos', 'porVencer']);
    });

    testWidgets('con 0 activos, barra neutra y leyenda en ceros',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: BarraClientesSegmentos(
            activos: 0,
            porVencer: 0,
            morosos: 0,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('seg-neutra')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('seg-al-dia')),
          findsNothing);
      expect(find.text('0 al día'), findsOneWidget);
      expect(find.text('0 por vencer'), findsOneWidget);
      expect(find.text('0 vencidos'), findsOneWidget);
    });
  });

  group('UI130-12/13 · FilaLibro', () {
    testWidgets('pinta concepto, detalle y monto sin icono',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: FilaLibro(
            concepto: 'Base',
            detalle: '84 clientes × 150 CUP',
            monto: '12 600 CUP',
          ),
        ),
      ));
      expect(find.text('Base'), findsOneWidget);
      expect(find.text('84 clientes × 150 CUP'), findsOneWidget);
      expect(find.text('12 600 CUP'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsNothing);
    });

    testWidgets('con icono lleva el avatar tintado', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: FilaLibro(
            icono: Icons.payments_rounded,
            colorIcono: AppColores.exito,
            concepto: 'Mensualidad — efectivo',
            detalle: '8 de noviembre · 1 mes(es)',
            monto: '2 000 CUP',
          ),
        ),
      ));
      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(find.text('Mensualidad — efectivo'), findsOneWidget);
      expect(find.text('2 000 CUP'), findsOneWidget);
    });
  });

  group('UI130-12 · HojaAgregarBono', () {
    Future<void> abrirHoja(
      WidgetTester tester, {
      required Future<bool> Function({
        required String entrenador,
        required double monto,
        required String nota,
      }) alGuardar,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => HojaAgregarBono(alGuardar: alGuardar),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.byType(HojaAgregarBono), findsOneWidget);
    }

    testWidgets('entrega monto negativo y nota, y se cierra',
        (tester) async {
      String? entCapturado;
      double? montoCapturado;
      String? notaCapturada;
      await abrirHoja(tester, alGuardar: (
          {required entrenador, required monto, required nota}) async {
        entCapturado = entrenador;
        montoCapturado = monto;
        notaCapturada = nota;
        return true;
      });
      // Campo 0 = monto, campo 1 = nota (tras el selector).
      await tester.enterText(
          find.byType(TextFormField).at(0), '-500');
      await tester.enterText(
          find.byType(TextFormField).at(1), 'Cubrió el sábado');
      await tester.tap(find.text('Guardar bono'));
      await tester.pumpAndSettle();
      expect(entCapturado, 'ambos');
      expect(montoCapturado, -500);
      expect(notaCapturada, 'Cubrió el sábado');
      expect(find.byType(HojaAgregarBono), findsNothing);
    });

    testWidgets('la coma decimal vale como punto', (tester) async {
      double? montoCapturado;
      await abrirHoja(tester, alGuardar: (
          {required entrenador, required monto, required nota}) async {
        montoCapturado = monto;
        return true;
      });
      await tester.enterText(find.byType(TextFormField).at(0), '1,5');
      await tester.tap(find.text('Guardar bono'));
      await tester.pumpAndSettle();
      expect(montoCapturado, 1.5);
    });

    testWidgets('monto en cero no guarda y avisa, sin cerrar',
        (tester) async {
      var llamadas = 0;
      await abrirHoja(tester, alGuardar: (
          {required entrenador, required monto, required nota}) async {
        llamadas++;
        return true;
      });
      await tester.enterText(find.byType(TextFormField).at(0), '0');
      await tester.tap(find.text('Guardar bono'));
      await tester.pump();
      expect(llamadas, 0);
      expect(find.text('Ingresa un monto válido'), findsOneWidget);
      expect(find.byType(HojaAgregarBono), findsOneWidget);
    });
  });
}
