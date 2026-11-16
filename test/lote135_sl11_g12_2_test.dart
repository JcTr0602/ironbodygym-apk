/// SL-11 · G12-2 — «Cerrar mi turno» queda al final de la
/// lista siendo la acción de salida del entrenador.
///
/// Camino real: Mi Turno en un teléfono estrecho y bajo
/// (360×640). Hoy el botón de cierre es el último elemento
/// de un ListView largo: ni siquiera se construye sin hacer
/// scroll hasta el final.
///
/// Corregido: el cierre vive en una barra inferior fija de
/// la pantalla — visible y alcanzable sin scroll, una sola
/// vez.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/mi_turno.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _esperar(WidgetTester tester, bool Function() cond,
    {int intentos = 30}) async {
  for (var i = 0; i < intentos; i++) {
    if (cond()) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 80));
  }
  return cond();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    const dirFuentes =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ]) {
      final bytes = await File('$dirFuentes/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets(
      'G12-2: «Cerrar mi turno» visible sin hacer scroll '
      'hasta el final', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: MiTurnoScreen()));
    // La pantalla asienta (sale el estado de carga).
    expect(
        await _esperar(
            tester,
            () => find
                .text('Cobrado hoy')
                .evaluate()
                .isNotEmpty),
        isTrue);
    // Sin tocar la lista: el cierre ya está a la vista,
    // una sola vez y dentro del viewport.
    final cierre = find.text('Cerrar mi turno');
    expect(cierre, findsOneWidget,
        reason: 'G12-2: el cierre es la acción de salida: '
            'posición fija, no el final del scroll');
    final rect = tester.getRect(cierre);
    expect(rect.bottom, lessThanOrEqualTo(640),
        reason: 'el cierre cabe en la pantalla sin scroll');
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });
}
