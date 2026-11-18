/// Gestión 1.25 · Bloque 2 (B2-1) — La compuerta de
/// permisos refresca ANTES de denegar.
///
/// El caso Duany: foto de permisos vacía tras reinstalar y
/// la app le dijo «no autorizado» con todo correcto en el
/// servidor. Ahora permisoOperativoOkConRefresco intenta
/// un refresco y el cartel distingue denegación real
/// (refresco OK) de denegación por foto vieja (sin red).
/// Aquí se prueba el camino sin red (Supabase contra un
/// puerto muerto): cargar() devuelve false, el sello de
/// refresco queda null y la compuerta avisa «no pude
/// comprobar» en vez de «no tienes permiso».
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/permisos_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() {
    PermisosEntrenador().limpiar();
  });

  test('cargar() sin red: false y sin sello de refresco', () async {
    final ok = await PermisosEntrenador().cargar();
    expect(ok, isFalse);
    expect(PermisosEntrenador().ultimoRefrescoOk, isNull);
  });

  testWidgets('con el permiso en la foto: pasa sin tocar la red',
      (tester) async {
    var resultado = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              resultado = await permisoOperativoOkConRefresco(
                  ctx, () => true, 'cobrar pagos');
            },
            child: const Text('ir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ir'));
    await tester.pump();
    expect(resultado, isTrue);
  });

  testWidgets(
      'sin permiso y sin red: deniega con el cartel honesto',
      (tester) async {
    var resultado = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              resultado = await permisoOperativoOkConRefresco(
                  ctx, () => false, 'gestionar turnos');
            },
            child: const Text('ir'),
          ),
        ),
      ),
    ));
    // La RPC muere contra el puerto cerrado: trabajo real
    // fuera de la zona falsa (patrón de la casa).
    await tester.runAsync(() async {
      await tester.tap(find.text('ir'));
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await tester.pump();
    // CONTRATO MOVIDO (1.36, cierre de Aplica-136): la fila
    // 136-868 (H-B4) acortó el aviso sin conexión a un snack
    // corto («Sin conexión: no pude comprobar tus permisos.»)
    // y movió el detalle a un DIÁLOGO («Permisos sin
    // comprobar») que la función espera antes de devolver.
    // La versión anterior fijaba el snack largo de la 1.25 y
    // el resultado inmediato. La vigilancia se conserva: sin
    // red no se finge una denegación real (nada de «Pídeselo a
    // Jc») y, aceptado el aviso, el resultado es false.
    expect(find.text('Permisos sin comprobar'), findsOneWidget);
    expect(
        find.textContaining('no pude comprobar tus permisos'),
        findsOneWidget,
        reason: 'sin red no se finge una denegación real');
    expect(find.textContaining('Pídeselo a Jc'), findsNothing);
    await tester.tap(find.text('Entendido'));
    await tester.pump();
    // Latido real para que la llamada cierre tras el pop.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    expect(resultado, isFalse);
  });
}
