/// Test 1.23 (Delta Argón 5ª#1): la marca 'entregado' nace
/// dentro de pagoDialogo SOLO para el dueño. Con la sesión
/// nula de los tests (no dueño = entrenador), el payload de
/// un cobro en efectivo NO trae 'entregado': el dinero queda
/// como pendiente a entregar, como siempre. La mitad dueño
/// no es montable sin sesión real; su flujo está verificado
/// por código: los 5 llamadores pasan el payload del diálogo
/// tal cual a cobrarConPreviewYRecibo y la condición es
/// `if (AuthService().isOwner)` en el punto único donde se
/// construye el resultado del diálogo.
///
/// Patrón de BD en zona real copiado de
/// dialogo_pago_panel_grupob_test.dart.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    // Sin Supabase inicializado a propósito: la lectura del
    // dueño dentro del diálogo es defensiva (try/catch, como
    // queueOp) y sin sesión el resultado es «no dueño» — el
    // camino bajo test. (Inicializar Supabase aquí disparaba
    // el canal app_links y ensuciaba la corrida en cadena.)
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'test_delta_argon_dialogo.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocalDb.nombreArchivoDbForzado = 'test_delta_argon_dialogo.db';

  testWidgets('5ª#1: sin sesión de dueño, el payload del '
      'diálogo NO marca entregado', (tester) async {
    await _bdVacia(tester);
    late Future<Map<String, dynamic>?> fut;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () {
            fut = pagoDialogo(ctx, {
              'id': 10,
              'nombre': 'Cliente 10',
              'estado': 'activo',
            });
          },
          child: const Text('cobrar'),
        ),
      ),
    ));
    await tester.tap(find.text('cobrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    final payload = await fut;
    expect(payload, isNotNull);
    expect(payload!.containsKey('entregado'), isFalse,
        reason: 'un entrenador no se marca entregado a sí mismo');
  });
}
