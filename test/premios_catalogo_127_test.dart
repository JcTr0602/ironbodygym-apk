/// 1.27 (S2/G2) — Catálogo de Premios editable:
/// parseo de admin_premios_catalogo (orden del
/// catálogo de la app, último cambio) y la pestaña
/// con su editor (guardar válido, y el aviso de
/// «premio activo con 0 días» sin llamar al servidor).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/ui/panel_premios_catalogo.dart';

Map<String, dynamic> _jsonCatalogo() => {
      'ok': true,
      'items': [
        {
          'logro_id': 'veterano',
          'nombre': 'Veterano',
          'meta_dias': 1,
          'premio_dias': 0,
          'activo': false,
          'ultimo_cambio': null,
        },
        {
          'logro_id': 'constancia_real',
          'nombre': 'Constancia real',
          'meta_dias': 90,
          'premio_dias': 15,
          'activo': true,
          'ultimo_cambio': {
            'campo': 'premio_dias',
            'antes': '10',
            'despues': '15',
            'actor': 'jctr0602@ironbody.gym',
            'creado_en': '2026-11-06T10:00:00Z',
          },
        },
        {
          'logro_id': 'primer_paso',
          'nombre': 'Primer paso',
          'meta_dias': 1,
          'premio_dias': 0,
          'activo': false,
          'ultimo_cambio': null,
        },
      ],
    };

void main() {
  group('parseCatalogoPremios', () {
    test('ordena por el catálogo de la app y lee estados', () {
      final entradas = parseCatalogoPremios(_jsonCatalogo());
      expect(entradas.map((e) => e.logroId),
          ['primer_paso', 'constancia_real', 'veterano']);
      final c = entradas[1];
      expect(c.activo, isTrue);
      expect(c.estadoTexto, 'Activo: 90 días → 15 gratis');
      expect(c.ultimoCambioTexto,
          'Último cambio: premio_dias 10 → 15 · 2026-11-06');
      expect(entradas[0].sinPremio, isTrue);
      expect(entradas[0].estadoTexto, 'Sin premio');
    });

    test('json inválido degrada a vacío', () {
      expect(parseCatalogoPremios(null), isEmpty);
      expect(parseCatalogoPremios({'items': 'x'}), isEmpty);
    });
  });

  group('PremiosCatalogoTab', () {
    testWidgets('lista el catálogo y guarda una edición',
        (tester) async {
      (String, int, int, bool)? guardado;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PremiosCatalogoTab(
            cargarCatalogo: () async => _jsonCatalogo(),
            guardarEntrada: (id, meta, premio, activo) async {
              guardado = (id, meta, premio, activo);
              return {'ok': true, 'cambios': 2};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Constancia real'), findsOneWidget);
      expect(find.text('Activo: 90 días → 15 gratis'),
          findsOneWidget);
      // Editar «Veterano»: meta 30, premio 5, activo.
      await tester.tap(find.text('Veterano'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Meta (días entrenados verificados)'),
          '30');
      await tester.enterText(
          find.widgetWithText(
              TextField, 'Premio (días de mensualidad gratis)'),
          '5');
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(guardado, ('veterano', 30, 5, true));
    });

    testWidgets(
        'premio activo con 0 días: aviso al momento, sin guardar',
        (tester) async {
      var llamadas = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PremiosCatalogoTab(
            cargarCatalogo: () async => _jsonCatalogo(),
            guardarEntrada: (id, meta, premio, activo) async {
              llamadas++;
              return {'ok': true};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Veterano'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(llamadas, 0);
      expect(find.textContaining('apágalo en vez de ponerlo en 0'),
          findsOneWidget);
    });
  });
}
