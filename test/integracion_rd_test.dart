/// 1.32 · Paso de integración — riesgos de diseño
/// RD-1…RD-12 del inventario de superficies
/// (~/workspace/cola-123/gestion/inventario_superficies_132.md).
///
/// Dos familias de pruebas:
/// - MEDICIÓN a teléfono real (420×800 y 360 de ancho):
///   el control mide lo que el RD afirma (altos reales,
///   desbordes reales), no la intención del código.
/// - PINES ESTRUCTURALES sobre la fuente (patrón de la
///   casa: B-25/2, capa1 B-11/B-12) para lo que no se
///   puede montar sin la cáscara entera (pestañas de la
///   Ficha, botón compacto de Momento, avatar del marco).
///
/// RD-11 y RD-12 se cerraron por VERIFICACIÓN (chip de
/// estado textual en cada fila; toda hoja con campos va
/// sobre HojaAccion o aplica viewInsets): aquí queda el
/// pin de la hoja crítica y del chip textual.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/marco.dart';
import 'package:ironbody_gym/ui/primitivas.dart';
import 'package:ironbody_gym/ui/skeleton.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('RD-1 · SegmentedButton con el tema de la app', () {
    testWidgets('ningún segmento queda por debajo de 48 dp',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTema.claro(),
          home: Scaffold(
            body: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'a', label: Text('Uno')),
                ButtonSegment(value: 'b', label: Text('Dos')),
              ],
              selected: const {'a'},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      );
      final size =
          tester.getSize(find.byType(SegmentedButton<String>));
      expect(size.height, greaterThanOrEqualTo(48),
          reason: 'RD-1: el suelo del tema era 44 (<48)');
    });

    test('el tema fija el suelo en 48×48', () {
      final diseno = _fuente('lib/ui/diseno.dart');
      expect(diseno.contains('Size(48, 48)'), isTrue,
          reason: 'segmentedButtonTheme.minimumSize');
    });
  });

  group('RD-4 · Dock del dueño a 360 dp', () {
    testWidgets(
        '«Suplemento» entero en una línea y pastillas uniformes',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTema.claro(),
          home: Scaffold(
            body: DockMostrador(
              esDueno: true,
              onCobrar: () {},
              onServicio: () {},
              onPase: () {},
              onInscribir: () {},
              onSuplemento: () {},
              onGasto: () {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull,
          reason: 'sin desborde a 360 dp');
      final claves = [
        'dock-cobrar',
        'dock-servicio',
        'dock-pase',
        'dock-inscribir',
        'dock-suplemento',
        'dock-gasto',
      ];
      final altos = <double>{};
      for (final c in claves) {
        final f = find.byKey(ValueKey(c));
        expect(f, findsOneWidget, reason: 'acción $c presente');
        altos.add(tester.getSize(f).height);
      }
      expect(altos, hasLength(1),
          reason: 'RD-4: todas las pastillas a la misma altura');
      final sup = find.text('Suplemento');
      expect(sup, findsOneWidget);
      expect(
        find.ancestor(of: sup, matching: find.byType(FittedBox)),
        findsOneWidget,
        reason: 'la etiqueta se encoge (scaleDown), no se parte',
      );
      expect(tester.widget<Text>(sup).maxLines, 1);
    });
  });

  group('RD-6 · SkeletonLista acotada', () {
    testWidgets('en alto limitado pinta solo las que caben',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTema.claro(),
          home: const Scaffold(
            body: SizedBox(
              height: 470,
              child: SkeletonLista(items: 5),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull,
          reason: 'RD-6: 5 tarjetas desbordaban ≈30 px');
      // (470 + 8) / 100 = 4 tarjetas; la 5ª no cabe.
      expect(find.byType(SkeletonTarjeta), findsNWidgets(4));
    });

    testWidgets('en alto infinito (dentro de scroll) salen todas',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTema.claro(),
          home: Scaffold(
            body: ListView(
              children: const [SkeletonLista(items: 5)],
            ),
          ),
        ),
      );
      expect(find.byType(SkeletonTarjeta), findsNWidgets(5));
    });
  });

  group('RD-8 · ScrollHorizontalConPista', () {
    testWidgets('la pista aparece y desaparece al llegar al final',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTema.claro(),
          home: const Scaffold(
            body: SizedBox(
              width: 200,
              child: ScrollHorizontalConPista(
                colorFondo: Colors.white,
                child: Row(
                  children: [
                    SizedBox(width: 150, height: 40),
                    SizedBox(width: 150, height: 40),
                    SizedBox(width: 150, height: 40),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      Finder degradados() => find.byWidgetPredicate((w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).gradient is LinearGradient);
      expect(degradados(), findsOneWidget,
          reason: 'con contenido a la derecha, la pista se ve');
      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(degradados(), findsOneWidget,
          reason: 'al final solo queda la pista izquierda');
      // La pista que queda es la del borde izquierdo.
      final caja = tester.widget<DecoratedBox>(degradados());
      final grad = (caja.decoration as BoxDecoration).gradient
          as LinearGradient;
      expect(grad.begin, Alignment.centerRight,
          reason: 'la pista restante degrada desde la izquierda');
    });
  });

  group('Pines estructurales', () {
    test('RD-2 · la pestaña de la Ficha tiene suelo de 48', () {
      final ficha = _fuente('lib/ui/ficha.dart');
      expect(ficha.contains('minHeight: 48'), isTrue);
    });

    test('RD-9 · el botón compacto de Momento mide 48 de alto', () {
      final ficha = _fuente('lib/ui/ficha.dart');
      expect(ficha.contains('minimumSize: const Size(0, 48)'),
          isTrue);
    });

    test('RD-3 · el avatar del marco suma 7 de aire (34+14=48)',
        () {
      final marco = _fuente('lib/ui/marco.dart');
      expect(marco.contains('EdgeInsets.all(7)'), isTrue);
      expect(marco.contains("ValueKey('marco-perfil')"), isTrue);
    });

    test('RD-5 · los chips de Buscar ya no usan densidad compacta',
        () {
      final buscar = _fuente('lib/ui/buscar.dart');
      final iFiltro = buscar.indexOf('Widget _chipFiltro');
      final iEdad = buscar.indexOf('Widget _chipEdad');
      expect(iFiltro, greaterThanOrEqualTo(0));
      expect(iEdad, greaterThan(iFiltro));
      final cuerpoFiltros = buscar.substring(iFiltro, iEdad);
      expect(
          cuerpoFiltros
              .contains('MaterialTapTargetSize.padded'),
          isTrue);
      expect(cuerpoFiltros.contains('VisualDensity.compact'),
          isFalse);
      final pilar = _fuente('lib/ui/pilar_negocio.dart');
      final iEnlaces = pilar.indexOf('Widget _filaEnlaces');
      expect(iEnlaces, greaterThanOrEqualTo(0));
      final cuerpoEnlaces =
          pilar.substring(iEnlaces, iEnlaces + 3000);
      expect(
          cuerpoEnlaces.contains('MaterialTapTargetSize.padded'),
          isTrue);
    });

    test('RD-5 · el conmutador de Suplementos sin compact', () {
      final sup = _fuente('lib/ui/suplementos.dart');
      expect(sup.contains('VisualDensity.compact'), isFalse);
    });

    test('RD-7 · el título de Por Decidir se acota a 2 líneas',
        () {
      final pd = _fuente('lib/ui/por_decidir.dart');
      final i = pd.indexOf('Efectivo de ');
      expect(i, greaterThanOrEqualTo(0));
      final ventana = pd.substring(i, i + 500);
      expect(ventana.contains('maxLines: 2'), isTrue);
      expect(ventana.contains('TextOverflow.ellipsis'), isTrue);
    });

    test('RD-8 · ambos pilares usan la pieza con pista', () {
      expect(
          _fuente('lib/ui/pilar_clientes.dart')
              .contains('ScrollHorizontalConPista'),
          isTrue);
      expect(
          _fuente('lib/ui/pilar_negocio.dart')
              .contains('ScrollHorizontalConPista'),
          isTrue);
    });

    test('RD-10 · las insignias del marco usan el token mínimo',
        () {
      final marco = _fuente('lib/ui/marco.dart');
      expect(marco.contains('fontSize: 10'), isFalse);
      expect(marco.contains('AppTexto.minuscula'), isTrue);
    });

    test('RD-11 · el estado de la fila es un chip con texto',
        () {
      final buscar = _fuente('lib/ui/buscar.dart');
      expect(buscar.contains('chipEstadoFila'), isTrue);
      // 1.36 (136-233): el chip compone dato-primero
      // («Hace N días · venció …»); la fuente ya no trae
      // el «Venció » inicial que este test fijaba.
      expect(buscar.contains('Hace '), isTrue);
      expect(buscar.contains('venció '), isTrue);
      expect(buscar.contains('Vence '), isTrue);
    });

    test('RD-12 · la hoja crítica suma el viewInsets del teclado',
        () {
      final hoja = _fuente('lib/ui/hoja_accion.dart');
      expect(hoja.contains('viewInsets.bottom'), isTrue);
    });
  });
}
