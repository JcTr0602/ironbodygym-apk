/// 1.31 (Oleada de Mejoras · Día): el Historial elevado —
/// encabezado de día con totales, cliente como título de la
/// fila, toque que abre el detalle único y reversión
/// alcanzable también desde un día pasado (G-1/G-2).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/servicios_historial.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<bool> _esperarTexto(WidgetTester tester, String fragmento) async {
  for (var i = 0; i < 90; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.textContaining(fragmento).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Future<void> _venta(int id, String fecha, String tipo, double precio,
        String cliente) =>
    LocalDb.instance.upsertMirror('servicio_ventas', id, {
      'id': id,
      'fecha': fecha,
      'tipo': tipo,
      'cantidad': 1,
      'precio_unitario': precio,
      'cliente_nombre': cliente,
      'vendedor_id': 111,
      'registrado_por': 111,
      'registrado_por_nombre': 'Gabriel',
      'metodo': 'efectivo',
      'pomo_id': 5,
      'casa': 0,
    }, 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await _bdVacia();
    await LocalDb.instance.upsertMirror('suplementos', 3, {
      'id': 3,
      'nombre': 'Creatina',
    }, 1);
    await LocalDb.instance.upsertMirror('servicio_pomos', 5, {
      'id': 5,
      // Yunque 2.34 (E-2): la forma REAL del espejo
      // servicio_pomos. El fixture sembraba producto_id /
      // responsable_id, claves que la fila no trae — por eso
      // la resolución rota del Historial pasaba verde.
      'suplemento_id': 3,
      'titular_telegram_id': 111,
      'es_principal': 0,
      'activo': 1,
      'saldo_cache': 12,
    }, 1);
    // Dos ventas del mismo día pasado: 900 + 600 = 1500.
    await _venta(21, '2026-11-08 10:30:00', 'dosis_con_agua', 900,
        'Richard Dueñas');
    await _venta(
        22, '2026-11-08 09:15:00', 'dosis_sin_agua', 600, 'Ana Pérez');
  });

  testWidgets(
      'encabezado con totales, cliente de título y reversión '
      'desde el detalle de un día pasado', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ServiciosHistorialScreen(
        esDueno: true,
        miTid: 999,
        personas: {111: 'Gabriel'},
      ),
    ));
    expect(await _esperarTexto(tester, 'Richard Dueñas'), isTrue);
    // Totales del día en el encabezado (2 operaciones, neto).
    expect(find.textContaining('2 operaciones · 1500 CUP'),
        findsOneWidget);
    // El día va en palabras, no la fecha cruda.
    expect(find.textContaining('8 de noviembre'), findsOneWidget);

    // Tocar la fila abre el detalle único con Revertir.
    await tester.tap(find.text('Richard Dueñas'));
    expect(await _esperarTexto(tester, 'Revertir'), isTrue);
    expect(find.text('Cliente'), findsNothing); // sin fila «Cliente»
    expect(find.textContaining('900 CUP'), findsWidgets);

    // Revertir desde el historial: la hoja se abre igual que
    // desde «Ventas de hoy» (mismo flujo compartido).
    await tester.tap(find.text('Revertir'));
    expect(await _esperarTexto(tester, 'Motivo (obligatorio)'),
        isTrue);
  });
}
