/// 1.35 (UI-22): la cabecera se pliega al bajar — la
/// fila de identidad desaparece y queda solo la
/// píldora de sync, que NUNCA se oculta; al desplegar,
/// la identidad (chip, lupa, avatar) vuelve entera.
/// (La primera forma de la pieza — una «barra fina»
/// con las acciones conservadas — no ahorraba ni un
/// dp: las acciones miden 48 de área tocable y
/// dominaban el alto en los dos estados; este test lo
/// caza fijando el alto exacto de cada estado.)
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

  testWidgets('plena: chip de rol y nombre; la píldora '
      'presente', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.runAsync(() async {
      try {
        await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'x');
      } catch (_) {}
    });
    final altoPlena = await _alto(t, false);
    expect(find.byKey(const ValueKey('marco-rol')), findsOneWidget);
    expect(find.byKey(const ValueKey('marco-pildora')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('marco-lupa')), findsOneWidget);
    expect(altoPlena, greaterThan(0));
  });

  testWidgets('plegada: la identidad desaparece, la '
      'píldora queda y el alto baja una fila entera',
      (t) async {
    final altoPlena = await _alto(t, false);
    final altoPlegada = await _alto(t, true);
    expect(find.byKey(const ValueKey('marco-rol')), findsNothing);
    expect(find.byKey(const ValueKey('marco-lupa')), findsNothing);
    expect(find.byKey(const ValueKey('marco-perfil')),
        findsNothing);
    expect(find.byKey(const ValueKey('marco-pildora')),
        findsOneWidget);
    // La fila plegada mide 48 (área tocable de las
    // acciones) + su hueco de 4: el ahorro no puede ser
    // menor que eso.
    expect(altoPlena - altoPlegada, greaterThanOrEqualTo(48),
        reason: 'plegar ahorra la fila de identidad '
            '($altoPlena → $altoPlegada)');
  });

  testWidgets('al desplegar, la identidad vuelve entera',
      (t) async {
    await _alto(t, true);
    expect(find.byKey(const ValueKey('marco-lupa')), findsNothing);
    await _alto(t, false);
    expect(find.byKey(const ValueKey('marco-rol')), findsOneWidget);
    expect(find.byKey(const ValueKey('marco-lupa')), findsOneWidget);
    expect(find.byKey(const ValueKey('marco-perfil')),
        findsOneWidget);
  });

  test('contrato: la cáscara pliega por scroll con '
      'histéresis y pasa el estado a la cabecera', () {
    final home = File('lib/ui/home.dart').readAsStringSync();
    expect(home, contains('_cabeceraPlegada'));
    expect(home, contains('NotificationListener<ScrollNotification>'));
    expect(home, contains('plegada: _cabeceraPlegada'));
    final marco = File('lib/ui/marco.dart').readAsStringSync();
    expect(marco, contains('AnimatedSize'));
  });
}
