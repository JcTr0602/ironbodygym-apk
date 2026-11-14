/// 1.35 (UI-01): el fundido al cambiar de pilar/segmento
/// anima la entrada sin remontar el hijo y respeta
/// «reducir movimiento».
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/primitivas.dart';

class _HijoConEstado extends StatefulWidget {
  const _HijoConEstado();
  @override
  State<_HijoConEstado> createState() => _HijoConEstadoState();
}

class _HijoConEstadoState extends State<_HijoConEstado> {
  int toques = 0;
  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => setState(() => toques++),
      child: Text('toques=$toques'),
    );
  }
}

Widget _envoltura(int indice, {bool reducir = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducir),
      child: FundidoAlCambiar(
        indice: indice,
        child: IndexedStack(
          index: indice,
          children: const [
            _HijoConEstado(),
            Center(child: Text('otro')),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('al cambiar el índice, la entrada se funde '
      'y el estado del hijo sobrevive', (t) async {
    await t.pumpWidget(_envoltura(0));
    await t.tap(find.text('toques=0'));
    await t.pump();
    expect(find.text('toques=1'), findsOneWidget);

    await t.pumpWidget(_envoltura(1));
    // A mitad del fundido hay una Opacity parcial.
    await t.pump(const Duration(milliseconds: 60));
    final op = t.widgetList<Opacity>(find.byType(Opacity));
    expect(op, isNotEmpty);
    expect(op.first.opacity, lessThan(1));
    // Al terminar (220 ms) la opacidad vuelve a 1 y el
    // envoltorio queda en reposo (estructura constante).
    await t.pump(const Duration(milliseconds: 300));
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 1);

    // Volver al pilar 0: el estado del hijo sigue ahí.
    await t.pumpWidget(_envoltura(0));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('toques=1'), findsOneWidget);
  });

  testWidgets('con «reducir movimiento» el cambio es '
      'instantáneo, sin fundido', (t) async {
    await t.pumpWidget(_envoltura(0, reducir: true));
    await t.pumpWidget(_envoltura(1, reducir: true));
    await t.pump();
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 1);
    expect(find.text('otro'), findsOneWidget);
  });

  testWidgets('sin cambio de índice no hay animación',
      (t) async {
    await t.pumpWidget(_envoltura(0));
    await t.pumpWidget(_envoltura(0));
    await t.pump(const Duration(milliseconds: 60));
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 1);
  });
}
