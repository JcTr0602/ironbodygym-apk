/// 1.32 (Oleada 2, Fase 1 — desviación 3 de Argón): el
/// resolvedor de destinos por id es ÚNICO (abrirFuncionLupa)
/// y lo consumen la Lupa y el buscador del Panel clásico.
///
/// Se fija el contrato del que depende la delegación del
/// Panel (admin.dart llama con cerrarActual: false):
/// - Con cerrarActual: false, el destino se empuja ENCIMA y
///   la pantalla llamadora SIGUE en la pila (al volver, el
///   Panel recarga sus datos).
/// - Con el defecto (true, el gesto de la Lupa), la pantalla
///   llamadora se cierra antes de empujar el destino.
/// - El futuro devuelto completa cuando el destino se cierra
///   (la recarga al volver del Panel cuelga de él).
/// El contenido cargado del destino no se afirma: bajo
/// FakeAsync las lecturas FFI no resuelven (límite probado
/// del banco de widgets); se afirma la navegación.
/// La lanzadera se empuja como ruta (igual que la Lupa real
/// sobre la cáscara): como ruta raíz no podría cerrarse.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/cumpleanos.dart';
import 'package:ironbody_gym/ui/lupa_universal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Lanzadera extends StatelessWidget {
  final void Function(BuildContext) alTocar;
  const _Lanzadera({required this.alTocar});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: FilledButton(
            onPressed: () => alTocar(ctx),
            child: const Text('ir'),
          ),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  /// Monta la raíz y empuja la lanzadera como ruta.
  Future<void> montar(WidgetTester tester,
      void Function(BuildContext) alTocar) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                    builder: (_) => _Lanzadera(alTocar: alTocar)),
              ),
              child: const Text('entrar'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('entrar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('cerrarActual: false deja al llamador en la '
      'pila y el futuro completa al volver', (tester) async {
    var volvio = false;
    await montar(tester, (ctx) async {
      await abrirFuncionLupa(ctx, 'cumpleanos', cerrarActual: false);
      volvio = true;
    });
    await tester.tap(find.text('ir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CumpleanosScreen), findsOneWidget);
    expect(find.byType(_Lanzadera, skipOffstage: false),
        findsOneWidget,
        reason: 'el llamador sigue montado debajo del destino');
    expect(volvio, isFalse,
        reason: 'el futuro no completa con el destino abierto');
    // Volver: el destino sale y el futuro completa.
    Navigator.of(tester.element(find.byType(CumpleanosScreen)))
        .pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(CumpleanosScreen), findsNothing);
    expect(volvio, isTrue);
  });

  testWidgets('el defecto (la Lupa) cierra al llamador antes '
      'de empujar el destino', (tester) async {
    await montar(tester, (ctx) => abrirFuncionLupa(ctx, 'cumpleanos'));
    await tester.tap(find.text('ir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CumpleanosScreen), findsOneWidget);
    expect(find.byType(_Lanzadera, skipOffstage: false),
        findsNothing,
        reason: 'la pantalla pasajera se cerró (gesto Lupa)');
  });
}
