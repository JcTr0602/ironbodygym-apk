/// SL-X2 · G02-2 + G02-3 (buscar.dart)
///
/// G02-2: con el espejo vacío y la sync fallida / nunca
/// bajada, el vacío del Directorio invitaba a «Inscribir
/// cliente» (duplicar clientes que sí existen en el
/// servidor). Corregido: el vacío dice «sin verificar» con
/// Reintentar y NO ofrece inscribir.
///
/// G02-3: las dos hojas que quedaban crudas en buscar.dart
/// (_menuRapido y la pasada guiada de _avisarSeleccionados)
/// pasan a la hoja de la casa (showHojaIron / HojaAccion),
/// como hizo SL-3 en listas.dart. La guiada conserva su
/// comportamiento no-descartable (isDismissible: false):
/// showHojaIron no expone ese parámetro, así que su
/// presentación es HojaAccion sobre el mismo
/// showModalBottomSheet no-descartable (límite documentado
/// en la ficha).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'ironbody.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<bool> _esperar(WidgetTester tester, bool Function() cond,
    {int intentos = 30}) async {
  for (var i = 0; i < intentos; i++) {
    if (cond()) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 80));
  }
  return cond();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    const canalEventos = EventChannel('com.llfbandit.app_links/events');
    const canalMensajes = MethodChannel('com.llfbandit.app_links/messages');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            canalEventos, MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canalMensajes, (_) async => null);
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  testWidgets(
      'G02-2 espejo vacío + sync fallida: «sin verificar» con '
      'Reintentar, nunca «Inscribir cliente»', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await _bdVacia();
      // Sync marcada fallida y NINGUNA bajada buena registrada.
      await LocalDb.instance.setMeta('last_sync_error', 'sin_conexion');
      await LocalDb.instance.setMeta(
          'last_sync_error_ts', isoHabana(ahoraHabana()));
    });
    await tester.pumpWidget(const MaterialApp(home: BuscarScreen()));
    expect(
      await _esperar(
          tester,
          () =>
              find.textContaining('sin verificar').evaluate().isNotEmpty ||
              find.text('Inscribir cliente').evaluate().isNotEmpty),
      isTrue,
      reason: 'el vacío debe resolverse a uno de los dos textos',
    );
    expect(find.textContaining('sin verificar'), findsWidgets,
        reason: 'G02-2: sin bajada verificada, el vacío no '
            'afirma que no haya clientes');
    expect(find.text('Reintentar'), findsWidgets,
        reason: 'G02-2: la salida es reintentar la verificación');
    expect(find.text('Inscribir cliente'), findsNothing,
        reason: 'G02-2: inscribir aquí duplicaría clientes que '
            'sí existen en el servidor');
    expect(find.text('Aún no hay clientes en este teléfono'),
        findsNothing);
  });

  group('G02-3 · hojas de la casa en buscar.dart (fuente)', () {
    final src = File('lib/ui/buscar.dart').readAsStringSync();

    test('_menuRapido abre con showHojaIron, no con la hoja cruda',
        () {
      final i = src.indexOf('Future<void> _menuRapido');
      expect(i, greaterThanOrEqualTo(0));
      final cuerpo =
          src.substring(i, src.indexOf('String _tipoAvisoPorDias', i));
      expect(cuerpo.contains('showHojaIron'), isTrue,
          reason: 'G02-3: el menú rápido usa la hoja de la casa');
      expect(cuerpo.contains('showModalBottomSheet'), isFalse,
          reason: 'G02-3: fuera la hoja cruda del menú rápido');
      // El contrato de acciones no cambia.
      for (final a in [
        "'cobrar'",
        "'diario'",
        "'venta'",
        "'whatsapp'",
        "'llamar'",
        "'editar'",
        "'seleccionar'",
        "'acceso'",
      ]) {
        expect(cuerpo.contains(a), isTrue, reason: 'acción $a');
      }
    });

    test(
        'la pasada guiada se presenta con HojaAccion y sigue '
        'siendo no-descartable', () {
      final i = src.indexOf('Future<void> _avisarSeleccionados');
      expect(i, greaterThanOrEqualTo(0));
      final cuerpo = src.substring(
          i, src.indexOf('/// 1.25 T52', i) > i ? src.indexOf('/// 1.25 T52', i) : src.length);
      expect(cuerpo.contains('HojaAccion'), isTrue,
          reason: 'G02-3: la presentación visual es la hoja '
              'de la casa');
      expect(cuerpo.contains('isDismissible: false'), isTrue,
          reason: 'G02-3: la guiada conserva su comportamiento '
              'no-descartable (showHojaIron no lo expone)');
      expect(cuerpo.contains('SafeArea('), isFalse,
          reason: 'G02-3: fuera el SafeArea propio de la hoja cruda');
      for (final a in ["'abrir'", "'avise'", "'saltar'", "'fin'"]) {
        expect(cuerpo.contains(a), isTrue, reason: 'paso $a');
      }
    });
  });
}
