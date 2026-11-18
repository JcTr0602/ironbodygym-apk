/// H-B1 (1.36): secciones de la ficha —
/// 136-507, 136-509, 136-510, 136-512, 136-513, 136-514,
/// 136-516, 136-517.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  testWidgets('136-507 · FilaInfoFicha última sin borde inferior',
      (tester) async {
    BoxDecoration decoDe(Finder f) => tester
        .widget<Container>(f)
        .decoration! as BoxDecoration;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            FilaInfoFicha(
                icono: Icons.info_rounded,
                etiqueta: 'Una',
                valor: '1'),
            FilaInfoFicha(
                icono: Icons.info_rounded,
                etiqueta: 'Última',
                valor: '2',
                esUltima: true),
          ],
        ),
      ),
    ));
    final contenedores = find.byType(Container);
    expect(decoDe(contenedores.first).border, isNotNull);
    expect(decoDe(contenedores.last).border, isNull);
  });

  testWidgets('136-513 · la barra del período se anima (Tween)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BarraMesFicha(
          fechaInicioRaw:
              DateTime.now().toIso8601String().substring(0, 10),
          pagadoHastaRaw: DateTime.now()
              .add(const Duration(days: 20))
              .toIso8601String()
              .substring(0, 10),
        ),
      ),
    ));
    expect(find.byType(TweenAnimationBuilder<double>),
        findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
  });

  group('contratos de fuente · historial', () {
    final s = _src('lib/ui/ficha_secciones.dart');
    test('136-509 · tooltip limpiar + label persistente', () {
      expect(s, contains("tooltip: 'Limpiar búsqueda'"));
      expect(s, contains("labelText: 'Buscar en el historial'"));
    });
    test('136-510/514 · mes expandible anunciado y animado', () {
      expect(s, contains('expanded: _mesesAbiertos.contains'));
      expect(s, contains('AnimatedRotation('));
      expect(s, contains('AnimatedSize('));
    });
    test('136-512/516/517 · pie adaptable, visible buscando, ámbito',
        () {
      expect(s, contains("'Se muestran los últimos 10 pagos.'"));
      expect(s, contains('if (widget.onVerAnteriores != null)'));
      expect(s, contains('en Solo pagos'));
    });
  });
}
