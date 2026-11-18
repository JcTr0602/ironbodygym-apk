/// H-B1 (1.36): widgets/gráficos/hoja —
/// 136-364, 136-365, 136-367, 136-369, 136-376, 136-381,
/// 136-385, 136-388, 136-391, 136-398, 136-399, 136-403,
/// 136-406.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/grafico_metrica.dart';
import 'package:ironbody_gym/ui/skeleton.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  testWidgets('136-391 · un solo punto se dice con su valor', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(
        body: GraficoMetricaGestion(
          titulo: 'Peso',
          unidad: 'kg',
          puntos: [PuntoSerie(DateTime(2026, 11, 10), 80.5)],
        ),
      ),
    ));
    expect(find.textContaining('Una sola medición por ahora'), findsOneWidget);
    expect(find.textContaining('80.5 kg'), findsOneWidget);
  });

  testWidgets('136-399 · la ayuda invita a tocar o arrastrar', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(
        body: GraficoMetricaGestion(
          titulo: 'Peso',
          unidad: 'kg',
          puntos: [
            PuntoSerie(DateTime(2026, 11, 1), 80),
            PuntoSerie(DateTime(2026, 11, 10), 81),
          ],
        ),
      ),
    ));
    expect(find.text('Toca o arrastra para explorar.'), findsOneWidget);
  });

  testWidgets('136-369 · la lista comparte UN solo pulso', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: const Scaffold(body: SkeletonLista(items: 3)),
    ));
    // Un único grupo (un controlador) para toda la lista…
    expect(find.byType(GrupoEsqueleto), findsOneWidget);
    // …y ninguna línea con pulso propio (_Pulso es privado;
    // se verifica por las FadeTransition: todas cuelgan de
    // la MISMA animación).
    final fundidos = t
        .widgetList<FadeTransition>(find.descendant(
            of: find.byType(SkeletonLista),
            matching: find.byType(FadeTransition)))
        .toList();
    expect(fundidos.length, greaterThan(3));
    final anim = fundidos.first.opacity;
    for (final f in fundidos) {
      expect(identical(f.opacity, anim), isTrue,
          reason: 'todas las líneas comparten la animación');
    }
  });

  group('contratos de fuente', () {
    test('136-364/365/367 · SyncBanner por variante', () {
      final s = _src('lib/ui/widgets.dart');
      expect(s, contains('_expandidoError'));
      expect(s, contains('_expandidoPendientes'));
      expect(s, isNot(contains('bool _expandido = false;')));
      expect(s, contains('color.withValues(alpha: 0.10)'));
      // El porcentaje ya no se pinta con el color del estado.
      expect(s, isNot(contains(".copyWith(color: color)),\n                      if (!enProgreso)")));
    });
    test('136-376/381/385 · AvatarEntrenador', () {
      final s = _src('lib/ui/avatar_entrenador.dart');
      expect(s, contains('if (mapa.isEmpty) _mapaFut = null;'));
      expect(s, contains('invalidarMapa'));
      expect(s, contains('AnimatedSwitcher('));
      expect(s, contains("ValueKey('avatar-respaldo')"));
    });
    test('136-388 · errorBuilder en la cabecera de tarjeta', () {
      expect(_src('lib/ui/tarjeta_imagen.dart'),
          contains('errorBuilder:'));
    });
    test('136-398 · Tacto al elegir punto', () {
      expect(_src('lib/ui/grafico_metrica.dart'),
          contains('Tacto.seleccion();'));
    });
    test('136-403/406 · HojaAccion con viewInsets y onDrag', () {
      final s = _src('lib/ui/hoja_accion.dart');
      expect(s, contains('useSafeArea: true'));
      expect(s,
          contains('ScrollViewKeyboardDismissBehavior.onDrag'));
      expect(s, contains('viewInsets.bottom),\n      child: ConstrainedBox('));
    });
  });
}
