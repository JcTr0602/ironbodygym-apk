/// Tests v1.3.5 — chipEstadoOp con etiqueta legible para necesita_revision
/// (auditoría ChatGPT 2026-10-16).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/cola.dart';

void main() {
  testWidgets('necesita_revision muestra "Requiere revisión"',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: _ChipProbe('necesita_revision')),
      ),
    );
    expect(find.text('Requiere revisión'), findsOneWidget);
    expect(find.text('necesita_revision'), findsNothing);
  });

  testWidgets('rechazada sigue mostrando "Rechazada"', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: _ChipProbe('rechazada')),
      ),
    );
    expect(find.text('Rechazada'), findsOneWidget);
  });

  group('1.31 (Yunque A): horaCortaHabana convierte UTC a La Habana',
      () {
    test('invierno (UTC−5): 16:35Z se lee 11:35, el caso de campo',
        () {
      // El sello tal como lo parsea Dart de un ISO con Z.
      final d = DateTime.parse('2026-11-09T16:35:00Z');
      expect(d.isUtc, isTrue);
      expect(horaCortaHabana(d), '09/11 11:35');
    });

    test('verano (UTC−4): 16:35Z se lee 12:35', () {
      expect(horaCortaHabana(DateTime.parse('2026-07-15T16:35:00Z')),
          '15/07 12:35');
    });

    test('un instante que no viene en UTC no se toca', () {
      expect(horaCortaHabana(DateTime(2026, 11, 9, 11, 35)),
          '09/11 11:35');
    });

    test('sin fecha, el guion de siempre', () {
      expect(horaCortaHabana(null), '—');
    });
  });
}

/// Wrapper para poder usar chipEstadoOp (función top-level) en un test.
class _ChipProbe extends StatelessWidget {
  final String estado;
  const _ChipProbe(this.estado);
  @override
  Widget build(BuildContext context) => chipEstadoOp(estado);
}
