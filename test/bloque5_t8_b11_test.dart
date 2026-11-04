/// 1.23 Bloque 5 — T8 (física de gama alta) y B11 (tamaños
/// táctiles).
///
/// T8: el MaterialApp aplica ComportamientoScrollSuave
/// (BouncingScrollPhysics con padre AlwaysScrollable) y el
/// pull-to-refresh sigue disparando con esa física; el speed
/// dial de Home despliega con rebote (easeOutBack en la
/// escala, easeOutCubic intacto en fade/deslizamiento).
///
/// B11: las zonas tocables hechas a mano dentro del alcance
/// (home.dart, widgets.dart) quedan con área ≥ 48 sin cambiar
/// el dibujo: pines por fuente + alturas reales de los dos
/// componentes reutilizables (SyncBanner compacto, SyncPill).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('T8 scroll global', () {
    testWidgets('un ListView bajo el comportamiento nuevo '
        'usa la física de rebote', (t) async {
      await t.pumpWidget(MaterialApp(
        scrollBehavior: const ComportamientoScrollSuave(),
        home: Scaffold(
          body: ListView(children: const [Text('fila')]),
        ),
      ));
      // La física EFECTIVA vive en la posición (el campo del
      // widget Scrollable no trae la resuelta por el
      // ScrollBehavior en esta versión de Flutter). El
      // framework envuelve la cadena con su propio
      // AlwaysScrollableScrollPhysics por fuera, así que el
      // pin busca el eslabón Bouncing DENTRO de la cadena y
      // exige su padre AlwaysScrollable (el contrato T8:
      // rebote + siempre desplazable).
      final posicion =
          t.state<ScrollableState>(find.byType(Scrollable)).position;
      ScrollPhysics? eslabon = posicion.physics;
      BouncingScrollPhysics? rebote;
      while (eslabon != null) {
        if (eslabon is BouncingScrollPhysics) {
          rebote = eslabon;
          break;
        }
        eslabon = eslabon.parent;
      }
      expect(rebote, isNotNull,
          reason: 'la cadena resuelta debe contener el rebote');
      expect(rebote!.parent, isA<AlwaysScrollableScrollPhysics>());
      // Y la clase, evaluada directa, resuelve lo mismo.
      final ctx = t.element(find.byType(ListView));
      final fisica =
          const ComportamientoScrollSuave().getScrollPhysics(ctx);
      expect(fisica, isA<BouncingScrollPhysics>());
      expect(fisica.parent, isA<AlwaysScrollableScrollPhysics>());
    });

    testWidgets('el pull-to-refresh SIGUE disparando con la '
        'física de rebote (lista corta)', (t) async {
      var refrescos = 0;
      await t.pumpWidget(MaterialApp(
        scrollBehavior: const ComportamientoScrollSuave(),
        home: Scaffold(
          body: RefreshIndicator(
            onRefresh: () async {
              refrescos++;
            },
            child: ListView(
              children: [
                for (var i = 0; i < 3; i++)
                  SizedBox(height: 60, child: Text('fila $i')),
              ],
            ),
          ),
        ),
      ));
      // Lista corta (180 dp): solo se puede tirar gracias al
      // padre AlwaysScrollable; el RefreshIndicator debe
      // recibir el overscroll del borde y disparar igual.
      await t.drag(find.byType(ListView), const Offset(0, 360));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(refrescos, 1);
    });

    test('main.dart aplica el comportamiento en el '
        'MaterialApp', () {
      final main = _fuente('lib/main.dart');
      expect(
          main.contains(
              'scrollBehavior: const ComportamientoScrollSuave()'),
          isTrue);
    });

    testWidgets('sin glow de overscroll: el indicador devuelve '
        'el hijo sin envolver (panel, ajuste 2)', (t) async {
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      final ctx = t.element(find.byType(SizedBox));
      const hijo = SizedBox(key: ValueKey('hijo'));
      final devuelto = const ComportamientoScrollSuave()
          .buildOverscrollIndicator(
        ctx,
        hijo,
        ScrollableDetails(
          direction: AxisDirection.down,
          controller: ScrollController(),
        ),
      );
      // Ni GlowingOverscrollIndicator ni Stretching: el mismo
      // widget, tal cual. El rebote lo pone la física.
      expect(identical(devuelto, hijo), isTrue);
    });
  });

  group('T8 speed dial de Home', () {
    test('el despliegue gana rebote: escala con easeOutBack; '
        'el fade sigue en easeOutCubic', () {
      final home = _fuente('lib/ui/home.dart');
      expect(home.contains('Curves.easeOutBack'), isTrue);
      expect(home.contains('_animsPildoraEscala'), isTrue);
      expect(home.contains('ScaleTransition'), isTrue);
      // El fade/deslizamiento NO hereda la curva con
      // sobreimpulso (rompería el FadeTransition).
      expect(home.contains('Curves.easeOutCubic'), isTrue);
      expect(home.contains('begin: 0.82, end: 1.0'), isTrue);
    });
  });

  group('B11 pines por fuente', () {
    test('home.dart: los 6 arreglos están aplicados', () {
      final home = _fuente('lib/ui/home.dart');
      // Marcadores de los 6 sitios corregidos: segmento de
      // niveles, avatar, «Mi Turno Hoy», banner sin reporte,
      // X de descarte y filas de «Atención hoy».
      expect('1.23 B11'.allMatches(home).length, 6);
      // Tres garantías de alto mínimo exactas.
      expect('minHeight: 48'.allMatches(home).length, 3);
      // La X crece por padding (icono intacto en 16).
      expect(
          home.contains('padding: EdgeInsets.all(AppEspacio.lg)'),
          isTrue);
      expect(home.contains('Icons.close_rounded'), isTrue);
    });

    test('widgets.dart: SyncBanner compacto y SyncPill a 48',
        () {
      final w = _fuente('lib/ui/widgets.dart');
      expect('1.23 B11'.allMatches(w).length, 2);
      expect('height: 48'.allMatches(w).length, 2);
      expect('widthFactor: 1'.allMatches(w).length, 2);
    });
  });

  group('B11 alturas reales', () {
    setUpAll(_bdVacia);

    testWidgets('SyncPill: el área tocable mide 48 de alto',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: SyncPill(onTap: () {})),
        ),
      ));
      await t.pump();
      final tam = t.getSize(find.byType(InkWell));
      expect(tam.height, 48);
    });

    testWidgets('SyncBanner compacto: el área tocable mide '
        '48 de alto', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [SyncBanner(compact: true)],
          ),
        ),
      ));
      await t.pump();
      final ink = find.descendant(
          of: find.byType(SyncBanner), matching: find.byType(InkWell));
      expect(t.getSize(ink).height, 48);
    });
  });
}
