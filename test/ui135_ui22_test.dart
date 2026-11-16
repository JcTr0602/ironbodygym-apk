/// 1.35 (UI-22 + M-6 + CAMPO-4): la cabecera fina.
///
/// Contrato original de UI-22: al bajar, la identidad se
/// pliega y la señal de sync NUNCA se oculta. M-6 y el
/// campo nº 4 re-contratan la forma: la cabecera es UNA
/// fila (~56 dp) — avatar con el nombre dentro de su
/// toque, lupa, icono de estado de sync junto a la lupa
/// y Modo Sol — sin chip de rol suelto y sin la fila
/// entera de la píldora a lo ancho (que medía ~48 dp en
/// cada pantalla, para siempre: ese es ahora el ahorro,
/// no el plegado). Al bajar, el nombre se recoge y quedan
/// el avatar y los iconos; al volver arriba, regresa.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ironbody_gym/ui/marco.dart';

Future<double> _alto(WidgetTester t, bool plegada) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      // Como en la cáscara real: la cabecera es hija de
      // una Column (alto el de su contenido, no el de la
      // pantalla).
      body: Column(
        children: [
          CabeceraMarco(
            rol: 'Dueño',
            nombre: 'Julio César Pérez Ramírez',
            onSyncTap: () {},
            onLupa: () {},
            onAccionPerfil: (_) {},
            plegada: plegada,
          ),
        ],
      ),
    ),
  ));
  await t.pumpAndSettle();
  return t.getSize(find.byType(CabeceraMarco)).height;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'x');
    } catch (_) {}
  });

  testWidgets('plena: nombre junto al avatar, icono de '
      'sync, lupa y perfil; UNA fila fina', (t) async {
    final alto = await _alto(t, false);
    expect(find.byKey(const ValueKey('cabecera-nombre-pleno')),
        findsOneWidget);
    expect(find.text('Julio César Pérez Ramírez'), findsOneWidget);
    expect(find.byKey(const ValueKey('marco-pildora')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('marco-lupa')), findsOneWidget);
    expect(find.byKey(const ValueKey('marco-perfil')),
        findsOneWidget);
    // Sin chip de rol como pieza separada (M-6).
    expect(find.byType(Chip), findsNothing);
    // La fila única: la cabecera vieja de dos filas
    // medía ~108 dp; la fina vive en ~56.
    expect(alto, lessThanOrEqualTo(64),
        reason: 'cabecera de una fila: $alto dp');
  });

  testWidgets('plegada: el nombre se recoge; el icono de '
      'sync y los demás iconos quedan', (t) async {
    final altoPlena = await _alto(t, false);
    final altoPlegada = await _alto(t, true);
    expect(find.byKey(const ValueKey('cabecera-nombre-pleno')),
        findsNothing);
    expect(find.byKey(const ValueKey('marco-pildora')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('marco-lupa')), findsOneWidget);
    expect(find.byKey(const ValueKey('marco-perfil')),
        findsOneWidget);
    // Misma fila: el plegado ya no ahorra alto (el ahorro
    // fue estructural, la fila de la píldora), ahorra
    // ancho para los iconos.
    expect((altoPlena - altoPlegada).abs(), lessThan(8));
  });

  testWidgets('al desplegar, el nombre vuelve entero',
      (t) async {
    await _alto(t, true);
    expect(find.text('Julio César Pérez Ramírez'), findsNothing);
    await _alto(t, false);
    expect(find.text('Julio César Pérez Ramírez'), findsOneWidget);
  });

  test('contrato: la cáscara pliega por scroll con '
      'histéresis y pasa el estado a la cabecera', () {
    final home = File('lib/ui/home.dart').readAsStringSync();
    expect(home, contains('_cabeceraPlegada'));
    expect(home, contains('NotificationListener<ScrollNotification>'));
    expect(home, contains('plegada: _cabeceraPlegada'));
    final marco = File('lib/ui/marco.dart').readAsStringSync();
    expect(marco, contains('IconoSyncCabecera'));
    expect(marco, isNot(contains('anchoCompleto')));
  });
}
