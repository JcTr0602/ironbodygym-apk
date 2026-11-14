/// 1.35 (UI-08): la insignia del segmento Vencimientos
/// cuenta vencen-hoy + atrasados sin avisar, con las
/// mismas funciones y filtros que Listas; en cero (o sin
/// lectura) no se pinta.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/pilar_clientes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<void> _sembrar(WidgetTester tester) async {
  const canalEventos = EventChannel('com.llfbandit.app_links/events');
  const canalMensajes = MethodChannel('com.llfbandit.app_links/messages');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          canalEventos, MockStreamHandler.inline(onListen: (_, __) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(canalMensajes, (_) async => null);
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    final hoy = ahoraHabana();
    Future<void> cli(int id, String nombre, DateTime hasta) =>
        LocalDb.instance.upsertMirror('clientes', id, {
          'id': id,
          'nombre': nombre,
          'telefono': '5819000$id',
          'pagado_hasta': _iso(hasta),
          'estado': 'activo',
          'activo': 1,
        }, 1);
    await cli(1, 'Vence Hoy', hoy);
    await cli(2, 'Atrasado Sin Avisar',
        hoy.subtract(const Duration(days: 10)));
    await cli(3, 'Atrasado Avisado',
        hoy.subtract(const Duration(days: 10)));
    await cli(4, 'Al Dia', hoy.add(const Duration(days: 10)));
    await cli(5, 'Atrasado Viejo',
        hoy.subtract(const Duration(days: 40)));
    await LocalDb.instance.marcarAvisado(3,
        pagadoHasta: _iso(hoy.subtract(const Duration(days: 10))));
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('el conteo suma hoy + atrasados sin avisar '
      '(el avisado y el al día no cuentan)', (tester) async {
    await _sembrar(tester);
    final n = await tester
        .runAsync(() => conteoInsigniaVencimientos());
    expect(n, 3);
  });

  testWidgets('el pilar pinta la insignia con la cifra '
      'cuando es mayor que cero', (tester) async {
    await _sembrar(tester);
    await tester.pumpWidget(
        const MaterialApp(home: PilarClientes(esDueno: true)));
    await tester.pumpAndSettle();
    final badge = find.byType(Badge);
    expect(badge, findsOneWidget);
    expect(tester.widget<Badge>(badge).isLabelVisible, isTrue);
    expect(find.text('3'), findsWidgets);
  });

  test('contrato: la insignia nace de la cifra y la '
      'regla del cero', () {
    final src = File('lib/ui/pilar_clientes.dart').readAsStringSync();
    expect(src, contains('conteoInsigniaVencimientos()'));
    expect(src, contains('_urgenciaVenc! > 0'));
    expect(src, contains('SyncPhase.idle'));
  });
}
