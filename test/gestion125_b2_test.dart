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
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();
    expect(resultado, isFalse);
    expect(
        find.textContaining('No pude comprobar tus permisos'),
        findsOneWidget,
        reason: 'sin red no se finge una denegación real');
    expect(find.textContaining('Pídeselo a Jc'), findsNothing);
  });
}
