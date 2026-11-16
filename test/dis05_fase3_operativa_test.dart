/// DIS-05 · Fase 3 (Operativa sin cobro): los selectores de
/// incidencias, recordatorios y turnos viven en SelectorIron
/// con la misma conducta de hoy — en especial los efectos
/// laterales al elegir: cambiar el tipo de la incidencia
/// autocompleta la descripción desde su plantilla, y el
/// recordatorio personalizado guarda la frecuencia elegida.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
import 'package:ironbody_gym/ui/horario_turnos.dart';
import 'package:ironbody_gym/ui/incidencias/editar_incidencia.dart';
import 'package:ironbody_gym/ui/recordatorios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
}

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

void _mockAppLinks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (args, events) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (call) async => null);
}

Future<void> _asentarHasta(
    WidgetTester tester, bool Function() condicion) async {
  for (var i = 0; i < 60 && !condicion(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

/// Toca el campo cerrado [cerrado] y elige [opcion] en el panel.
Future<void> _elegir(
    WidgetTester tester, Finder cerrado, String opcion) async {
  await tester.ensureVisible(cerrado);
  await tester.pump();
  await tester.tap(cerrado);
  await _asentarHasta(
      tester, () => find.byType(HojaAccion).evaluate().isNotEmpty);
  expect(find.byType(HojaAccion), findsOneWidget);
  await tester.tap(find.descendant(
      of: find.byType(HojaAccion), matching: find.text(opcion)));
  await _asentarHasta(
      tester, () => find.byType(HojaAccion).evaluate().isEmpty);
  expect(find.byType(HojaAccion), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() {
    _mockAppLinks();
  });

  testWidgets(
      'EditarIncidencia: el tipo preselecciona el primero y '
      'cambiarlo autocompleta la plantilla; el entrenador '
      'asignado se elige por nombre', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      final d = await LocalDb.instance.db;
      await d.insert('incidencias_tipos', {
        'id': 'maquina',
        'nombre': 'Máquina rota',
        'icono': 'build',
        'color': 0xFF0000,
        'activo': 1,
        'orden': 1,
        'plantilla_descripcion': 'Revisar la máquina averiada',
      });
      await d.insert('incidencias_tipos', {
        'id': 'limpieza',
        'nombre': 'Limpieza',
        'icono': 'cleaning_services',
        'color': 0x00FF00,
        'activo': 1,
        'orden': 2,
        'plantilla_descripcion': 'Limpiar la zona indicada',
      });
      await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {'username': 'duany', 'nombre': 'Duany'},
          {'username': 'gabriel', 'nombre': 'Gabriel'},
        ]),
      );
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: EditarIncidenciaScreen()));
    // La BD trae sus tipos sembrados por el esquema («Equipos
    // y Poleas» es el primero por orden): el defecto de hoy es
    // «el primero de la lista», sea el que sea.
    await _asentarHasta(tester,
        () => find.text('Equipos y Poleas').evaluate().isNotEmpty);
    expect(find.text('Equipos y Poleas'), findsOneWidget);

    // Cambiar el tipo autocompleta la plantilla del nuevo
    // (el efecto lateral del onChanged, intacto).
    await _elegir(tester, find.text('Equipos y Poleas'), 'Limpieza');
    expect(find.text('Limpieza'), findsWidgets);
    expect(find.text('Limpiar la zona indicada'), findsOneWidget);

    // Responsable «Entrenador»: el selector nace en el primero
    // de la lista y cambia por nombre.
    await tester.tap(find.text('Entrenador').first);
    await _asentarHasta(
        tester, () => find.text('Duany').evaluate().isNotEmpty);
    expect(find.text('Duany'), findsOneWidget);
    await _elegir(tester, find.text('Duany'), 'Gabriel');
    expect(find.text('Gabriel'), findsOneWidget);
  });

  testWidgets(
      'Recordatorios: el personalizado enseña la frecuencia y '
      'el creado guarda la elegida', (tester) async {
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: RecordatoriosScreen()));
    await _asentarHasta(tester,
        () => find.byIcon(Icons.add_rounded).evaluate().isNotEmpty);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await _asentarHasta(
        tester, () => find.text('Vencimiento').evaluate().isNotEmpty);
    expect(find.text('Vencimiento'), findsOneWidget,
        reason: 'el tipo preselecciona «vencimiento», como hoy');
    expect(find.text('Solo para mí'), findsOneWidget,
        reason: 'el alcance preselecciona «solo_mio»');

    await tester.enterText(
        find.byType(TextField).first, 'Revisar el aire');
    await _elegir(tester, find.text('Vencimiento'), 'Personalizado');
    await _asentarHasta(tester,
        () => find.text('Solo esa fecha').evaluate().isNotEmpty);
    await _elegir(
        tester, find.text('Solo esa fecha'), 'Cada semana (ese día)');
    expect(find.text('Cada semana (ese día)'), findsOneWidget);

    await tester.tap(find.text('Crear'));
    // Esperar (tiempo real) a que el creado aterrice en la tabla.
    List<Map<String, dynamic>>? filas;
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      filas = await tester.runAsync(() async {
        final d = await LocalDb.instance.db;
        return d.query('recordatorio_config');
      });
      if (filas != null && filas.isNotEmpty) break;
    }

    final filasFinales = await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      return d.query('recordatorio_config');
    });
    expect(filasFinales, hasLength(1));
    expect(filasFinales!.single['tipo'], 'personalizado');
    expect(filasFinales.single['frecuencia'], 'semanal',
        reason: 'la frecuencia elegida en el selector es la guardada');

    // El creado dispara el empuje de recordatorios (push del
    // motor): su ciclo vive en la zona de tiempo falso del
    // test y su latido periódico solo muere cuando el ciclo
    // cierra. La fase pública NO sirve de señal (puede leer
    // «idle» con el ciclo en vuelo), así que se bombea tiempo
    // falso de sobra (300 s > el presupuesto de 4 min no se
    // alcanza: los fallos de transporte cortan antes) con
    // pausas reales para que el I/O contra el puerto muerto
    // complete y el ciclo se agote.
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets(
      'HorarioTurnos: la franja nace «Sin asignar» y el '
      'nombre elegido queda en el cerrado', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {
            'username': 'duany',
            'nombre': 'Duany',
            'rol': 'entrenador',
            'telegram_id': 111,
          },
          {
            'username': 'gabriel',
            'nombre': 'Gabriel',
            'rol': 'entrenador',
            'telegram_id': 222,
          },
        ]),
      );
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: HorarioTurnosScreen()));
    await _asentarHasta(tester,
        () => find.text('Sin asignar').evaluate().isNotEmpty);

    // La verificación es LOCAL a la franja tocada (la lista
    // es perezosa: contar «Sin asignar» en todo el árbol no
    // es estable porque las filas nacen al desplazarse).
    final primerSelector = find.byType(SelectorIron<String?>).first;
    expect(
        find.descendant(
            of: primerSelector, matching: find.text('Sin asignar')),
        findsOneWidget,
        reason: 'la primera franja nace sin asignar');
    await _elegir(tester, find.text('Sin asignar').first, 'Gabriel');
    expect(
        find.descendant(
            of: find.byType(SelectorIron<String?>).first,
            matching: find.text('Gabriel')),
        findsOneWidget,
        reason: 'el cerrado de la franja tocada enseña el nombre');
    expect(
        find.descendant(
            of: find.byType(SelectorIron<String?>).first,
            matching: find.text('Sin asignar')),
        findsNothing);
  });
}
