/// 1.35 (UI-04): verificación de la propuesta sobre la
/// base real — la barra de acción de Inscribir YA es fija
/// (V33) y al guardar incompleto el primer campo que falta
/// recibe el error y el foco (1.25 T19). Este test fija ese
/// comportamiento para que la ronda lo deje comprobado,
/// no supuesto.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

bool _supabaseListo = false;

Future<void> _preparar(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    if (!_supabaseListo) {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
      _supabaseListo = true;
    }
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'cache_permisos_entrenador_json@',
        jsonEncode({
          'can_cobrar_pagos': true,
          'can_inscribir_clientes': true,
          'can_editar_fichas': true,
          'can_gestionar_turnos': true,
          'can_registrar_gastos': true,
          'can_vender_suplementos': true,
          'can_view_payroll': true,
        }));
    await prefs.setBool('cache_entrenador_activo@', true);
    await prefs.setBool('cache_entrenador_habilitado@', true);
    PermisosEntrenador().limpiar();
    await PermisosEntrenador().cargar();
    await LocalDb.instance.db;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Patrón de la casa (banco v2): las pantallas completas
    // tocan app_links; sin mock, el plugin truena el test.
    const canalEventos = EventChannel('com.llfbandit.app_links/events');
    const canalMensajes =
        MethodChannel('com.llfbandit.app_links/messages');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(canalEventos,
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canalMensajes, (_) async => null);
  });

  testWidgets('la acción «Guardar inscripción» es visible '
      'sin bajar el formulario (barra fija)', (tester) async {
    await _preparar(tester);
    await tester
        .pumpWidget(const MaterialApp(home: InscribirScreen()));
    await tester.pumpAndSettle();
    // Sin ningún scroll: el botón se encuentra en el
    // árbol visible (no hace falta ensureVisible) — el
    // toque real lo ejerce el test siguiente.
    expect(find.text('Guardar inscripción'), findsOneWidget);
    final boton = find.ancestor(
      of: find.text('Guardar inscripción'),
      matching: find.byType(BotonPrimario),
    );
    expect(boton, findsOneWidget);
    expect(tester.getRect(boton).bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height /
            tester.view.devicePixelRatio));
  });

  testWidgets('guardar sin nombre: el error nace bajo el '
      'campo y el foco va a él', (tester) async {
    await _preparar(tester);
    await tester
        .pumpWidget(const MaterialApp(home: InscribirScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar inscripción'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el nombre'), findsOneWidget);
    // El campo de nombre (el primer EditableText) tiene
    // el foco: la pantalla «subió sola» hasta él.
    final primero =
        tester.widget<EditableText>(find.byType(EditableText).first);
    expect(primero.focusNode.hasFocus, isTrue);
  });
}
