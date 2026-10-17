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
}

/// Wrapper para poder usar chipEstadoOp (función top-level) en un test.
class _ChipProbe extends StatelessWidget {
  final String estado;
  const _ChipProbe(this.estado);
  @override
  Widget build(BuildContext context) => chipEstadoOp(estado);
}
