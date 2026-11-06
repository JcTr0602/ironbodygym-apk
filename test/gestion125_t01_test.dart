/// Gestión 1.25 · T01 — «Nunca pintar ceros ni vacíos como datos»
/// en el Hub de Turnos.
///
/// Antes: si la carga fallaba, el catch apagaba el spinner y la
/// pantalla pintaba sus listas vacías («Nada pendiente.») como si
/// fueran el dato real. Ahora: el fallo se dice con su cartel y su
/// Reintentar, y «Nada pendiente.» solo aparece cuando la carga
/// tuvo éxito y de verdad no hay pendientes.
///
/// Harness: como en banco_widget_test, las lecturas FFI no
/// resuelven bajo FakeAsync; el sondeo usa runAsync con esperas
/// reales y busca el texto hasta que la pantalla asienta.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/hub_turnos.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _esperarTexto(WidgetTester tester, String texto,
    {int intentos = 14}) async {
  for (var i = 0; i < intentos; i++) {
    if (find.textContaining(texto).evaluate().isNotEmpty) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  return find.textContaining(texto).evaluate().isNotEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // Sin sesión: la pantalla corre como entrenador (ver
    // banco_widget_test). Lo que se prueba es el ESTADO de la
    // carga, no el rol.
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    // SIN borrar a mano el archivo compartido ironbody.db:
    // resetParaTest ya limpia el archivo que ESTE proceso
    // usa (con IRONBODY_TEST_DB=1, ironbody_<pid>.db). El
    // borrado manual, copiado de bancos viejos, tumbó en la
    // suite paralela el test de paridad de guia_localdb
    // (SQLITE_READONLY_DBMOVED: su proceso tenía abierto el
    // archivo compartido cuando este setUp lo eliminó).
    await LocalDb.resetParaTest();
    await LocalDb.instance.db; // dispara onCreate
  });

  testWidgets('carga sana sin pendientes: «Nada pendiente.» es verdad',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: HubTurnosScreen()));
    expect(await _esperarTexto(tester, 'Nada pendiente.'), isTrue,
        reason: 'con la BD vacía y la carga sana, el cero es real');
    expect(find.textContaining('No se pudo cargar'), findsNothing);
  });

  testWidgets('carga fallida: se dice, no se pinta «Nada pendiente.»',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // Romper la lectura del espejo ANTES de montar: allMirror
    // lanza y _cargar cae en su catch. La FFI va en runAsync:
    // un await real dentro del cuerpo del test (zona falsa) se
    // congela y el test se cuelga sin decir nada.
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      await db.execute('DROP TABLE IF EXISTS turnos_apertura');
    });
    await tester.pumpWidget(const MaterialApp(home: HubTurnosScreen()));
    expect(await _esperarTexto(tester, 'Reintentar'), isTrue,
        reason: 'el fallo debe ofrecer reintento');
    expect(find.textContaining('No se pudo cargar la información'),
        findsOneWidget);
    expect(find.text('Nada pendiente.'), findsNothing,
        reason: 'un fallo jamás se disfraza de «todo bien»');
  });
}
