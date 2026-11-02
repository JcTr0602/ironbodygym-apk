/// Piloto P9 (verificación visual): golden tests de componentes
/// compartidos puramente presentacionales de lib/ui/componentes.dart.
///
/// Objetivo: probar que los golden tests son deterministas en esta
/// VM y dejar 2-3 referencias estables de la UI compartida (no
/// pantallas completas). Los componentes elegidos solo reciben datos
/// planos (sin BD, red ni providers):
///  - EstadoVacio: icono + título + subtítulo + acción.
///  - BadgeEstado: los tres estados de membresía (vía desdeDias).
///  - ChipEstado.semantico + ContadorBadge: chips por significado.
///
/// Generar/actualizar referencias:
///   flutter test --update-goldens test/golden_piloto_test.dart
/// Verificar:
///   flutter test test/golden_piloto_test.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

/// Envuelve [hijo] en la app con el tema REAL de la app y una
/// superficie fija (tamaño físico = lógico, ratio 1.0) para que el
/// golden no dependa del tamaño por defecto del tester.
Future<void> _pintar(
  WidgetTester tester,
  Widget hijo, {
  required Size tamano,
}) async {
  tester.view.physicalSize = tamano;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTema.claro(),
      home: Scaffold(body: hijo),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('golden: EstadoVacio con acción', (tester) async {
    await _pintar(
      tester,
      EstadoVacio(
        icono: Icons.search_off_rounded,
        titulo: 'Sin resultados',
        subtitulo: 'Ningún cliente coincide con ese criterio.',
        textoAccion: 'Limpiar filtros',
        onAccion: () {},
      ),
      tamano: const Size(420, 360),
    );
    await expectLater(
      find.byType(EstadoVacio),
      matchesGoldenFile('goldens/estado_vacio.png'),
    );
  });

  testWidgets('golden: BadgeEstado en sus tres estados', (tester) async {
    await _pintar(
      tester,
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BadgeEstado.desdeDias(30),
            const SizedBox(height: 12),
            BadgeEstado.desdeDias(3),
            const SizedBox(height: 12),
            BadgeEstado.desdeDias(0),
            const SizedBox(height: 12),
            BadgeEstado.desdeDias(-5),
          ],
        ),
      ),
      tamano: const Size(320, 260),
    );
    await expectLater(
      find.byType(Column),
      matchesGoldenFile('goldens/badge_estado.png'),
    );
  });

  testWidgets('golden: ChipEstado semántico y ContadorBadge',
      (tester) async {
    await _pintar(
      tester,
      const Center(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            ChipEstado.semantico(
                texto: 'Activo', significado: SignificadoChip.exito),
            ChipEstado.semantico(
                texto: 'Info', significado: SignificadoChip.info),
            ChipEstado.semantico(
                texto: 'Pronto', significado: SignificadoChip.alerta),
            ChipEstado.semantico(
                texto: 'Vencido', significado: SignificadoChip.error),
            ChipEstado.semantico(
                texto: 'Otro', significado: SignificadoChip.neutral),
            ChipEstado.semantico(
                texto: 'Agotado', significado: SignificadoChip.agotado),
            ContadorBadge(numero: 7),
            ContadorBadge(numero: 150),
          ],
        ),
      ),
      tamano: const Size(460, 200),
    );
    await expectLater(
      find.byType(Wrap),
      matchesGoldenFile('goldens/chip_estado.png'),
    );
  });
}
