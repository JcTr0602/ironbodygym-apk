/// Gestión 1.25 · Bloque 3 (ficha) — T13, T14, T15.
///
/// T14: totalesPagosCliente cuenta TODOS los pagos reales
/// del cliente (sin el recorte de 10 del historial y sin
/// cortesías). T13: la cabecera de un congelado enseña
/// «CONGELADO» (no «AL DÍA») y la barra del período se
/// pinta en pausa con su explicación.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('T14: totales de por vida sin recorte y sin cortesía',
      () async {
    final db = await LocalDb.instance.db;
    // 12 pagos reales de 100 + 1 cortesía: con el recorte
    // de 10 del historial saldría n<=10; de por vida n=12.
    for (var i = 1; i <= 12; i++) {
      await db.insert('pagos', {
        'id': i,
        'data': jsonEncode({
          'id': i,
          'cliente_id': 7,
          'fecha': '2026-0${(i % 9) + 1}-15',
          'monto': 100,
          'metodo': 'efectivo',
        }),
        'sync_seq': 100 + i,
        'cliente_id': 7,
        'fecha': '2026-0${(i % 9) + 1}-15',
      });
    }
    await db.insert('pagos', {
      'id': 99,
      'data': jsonEncode({
        'id': 99,
        'cliente_id': 7,
        'fecha': '2026-10-20',
        'monto': 0,
        'metodo': 'cortesia',
      }),
      'sync_seq': 300,
      'cliente_id': 7,
      'fecha': '2026-10-20',
    });
    final t = await totalesPagosCliente(7);
    expect(t.n, 12);
    expect(t.total, 1200);
  });

  test('T14b (Yunque 4 · L5-1): el de por vida salta el pago '
      'anulado (marca en el JSON y anulación viva en cola)',
      () async {
    final db = await LocalDb.instance.db;
    Future<void> pago(int id, int monto, {bool anulado = false}) =>
        db.insert('pagos', {
          'id': id,
          'data': jsonEncode({
            'id': id,
            'cliente_id': 7,
            'fecha': '2026-10-15',
            'monto': monto,
            'metodo': 'transferencia',
            if (anulado) 'anulado': 1,
          }),
          'sync_seq': 100 + id,
          'cliente_id': 7,
          'fecha': '2026-10-15',
        });
    await pago(1, 100);
    // Anulado con la marca optimista en el propio JSON.
    await pago(2, 2500, anulado: true);
    // Anulado solo por la cola (un pull reescribió el JSON
    // sin la marca; la op sigue viva en este teléfono).
    await pago(3, 500);
    await db.insert('ops_queue', {
      'op_uuid': 'op-anula-3',
      'tipo': 'anular_pago',
      'payload': jsonEncode({'pago_id': 3}),
      'estado': 'pendiente',
      'creada_ts': '2026-10-16T08:00:00.000-05:00',
    });
    final t = await totalesPagosCliente(7);
    expect(t.n, 1);
    expect(t.total, 100);
  });

  testWidgets('T13: cabecera de congelado dice CONGELADO',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CabeceraFicha(
          nombre: 'Cliente Frío',
          foto: null,
          colorMarco: Colors.blue,
          esCasa: false,
          dias: 20,
          congelado: true,
          heroTag: null,
          onFotoTap: null,
          onCambiarFoto: _nada,
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('CONGELADO'), findsOneWidget);
    expect(find.textContaining('AL DÍA'), findsNothing);
  });

  testWidgets(
      'Yunque de cambios 1.31 (M1): cabecera con la fusión de '
      'pausa y días vencidos dice CONGELADO, no VENCIDO',
      (tester) async {
    // El caso M1.5: la ficha pasa `congelado: pausado` (pausa
    // nueva en curso) con los días ya negativos — la insignia
    // debe salir de la rama de pausa, no de la de días.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CabeceraFicha(
          nombre: 'Cliente Pausado',
          foto: null,
          colorMarco: Colors.blue,
          esCasa: false,
          dias: -12,
          congelado: true,
          heroTag: null,
          onFotoTap: null,
          onCambiarFoto: _nada,
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('CONGELADO'), findsOneWidget);
    expect(find.textContaining('VENCIDO'), findsNothing);
  });

  testWidgets('T13: barra pausada explica la pausa',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: BarraMesFicha(
          fechaInicioRaw: '2026-11-01',
          pagadoHastaRaw: '2026-12-01',
          pausada: true,
        ),
      ),
    ));
    await tester.pump();
    expect(find.textContaining('Período en pausa'), findsOneWidget);
  });
}

void _nada() {}
