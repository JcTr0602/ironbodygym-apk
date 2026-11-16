/// SL-X2 · G01-10 — la sombra de la cabecera del marco crece
/// con el scroll.
///
/// CabeceraMarco pintaba Material(elevation: 1) CONSTANTE,
/// hubiera o no desplazamiento. Corregido: acepta el estado
/// de scroll que la Home ya rastrea (conScroll) y su sombra
/// crece cuando hay scroll; sin scroll, la elevación de hoy.
/// home.dart le pasa ese estado (solo ese cableado).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/marco.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<double> _elevacion(WidgetTester t, {required bool conScroll}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          CabeceraMarco(
            rol: 'Dueño',
            nombre: 'Julio César Pérez Ramírez',
            onSyncTap: () {},
            onLupa: () {},
            onAccionPerfil: (_) {},
            conScroll: conScroll,
          ),
        ],
      ),
    ),
  ));
  await t.pumpAndSettle();
  final m = t.widget<Material>(find
      .descendant(of: find.byType(CabeceraMarco), matching: find.byType(Material))
      .first);
  return m.elevation;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'x');
    } catch (_) {}
  });

  testWidgets('G01-10 sin scroll: la elevación base de hoy (1)',
      (t) async {
    expect(await _elevacion(t, conScroll: false), 1);
  });

  testWidgets('G01-10 con scroll: la elevación crece', (t) async {
    final e = await _elevacion(t, conScroll: true);
    expect(e, greaterThan(1),
        reason: 'G01-10: bajando, la cabecera se despega del '
            'contenido con más sombra');
  });

  test('G01-10 home.dart pasa su estado de scroll a la cabecera',
      () {
    final src = File('lib/ui/home.dart').readAsStringSync();
    final i = src.indexOf('CabeceraMarco(');
    expect(i, greaterThanOrEqualTo(0));
    final llamada =
        src.substring(i, (i + 600).clamp(0, src.length));
    expect(llamada.contains('conScroll:'), isTrue,
        reason: 'G01-10: el cableado vive en la llamada de '
            'home.dart a CabeceraMarco');
  });
}
