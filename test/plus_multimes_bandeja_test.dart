/// Multimes (0.6, pieza 4 de Gestión) — la bandeja «Reportes
/// App Plus» ROTULA el paquete: la fila del reporte enseña
/// «Paquete: N meses · X días» y el diálogo de confirmación
/// nombra los días del paquete (no un «30 días» fijo), con
/// aviso en vivo si el dueño edita el monto y descuadra del
/// precio del paquete (D3: los días no cambian; solo el
/// ingreso).
///
/// Harness: el servicio se inyecta con una RPC falsa y las
/// fechas de los reportes se derivan de ahoraHabana() (fresco
/// < 24 h: sin aviso de cotización vencida ni checkbox). Las
/// lecturas FFI no resuelven bajo FakeAsync: el sondeo usa
/// runAsync con esperas reales, como el banco de la casa.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/reportes_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _esperarTexto(WidgetTester tester, String texto,
    {int intentos = 14}) async {
  for (var i = 0; i < intentos; i++) {
    if (find.textContaining(texto).evaluate().isNotEmpty) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  return find.textContaining(texto).evaluate().isNotEmpty;
}

Map<String, dynamic> _fila({
  required int id,
  required String nombre,
  required int monto,
  required String referencia,
  int? meses,
}) {
  return {
    'id': id,
    'invitado_id': 'inv-$id',
    'nombre': nombre,
    'telefono': '58190000',
    'monto_cup': monto,
    'referencia': referencia,
    'banco': 'BANDEC',
    // Fresco: instanteServidorHabana devuelve el instante UTC
    // equivalente; a minutos del ahora real nunca dispara el
    // aviso de cotización vencida.
    'creado_en':
        ahoraHabana().subtract(const Duration(minutes: 5)).toUtc().toIso8601String(),
    if (meses != null) 'meses': meses,
    if (meses != null) 'dias': meses * 30,
  };
}

PlusReportesService _servicio() => PlusReportesService(
      rpc: (nombre, params) async => [
        _fila(
            id: 21,
            nombre: 'Laura',
            monto: 9600,
            referencia: 'REF21',
            meses: 12),
        _fila(id: 22, nombre: 'Pedro', monto: 1000, referencia: 'REF22'),
      ],
    );

Future<void> _abrirBandeja(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ReportesPlusScreen(servicio: _servicio(), esDueno: true),
  ));
  expect(await _esperarTexto(tester, 'Laura'), isTrue,
      reason: 'la bandeja carga los reportes del servicio falso');
}

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
    await LocalDb.instance.db; // dispara onCreate
  });

  testWidgets('la fila del reporte enseña su paquete junto al monto',
      (tester) async {
    await _abrirBandeja(tester);
    // El paquete de 12 meses, rotulado en la tarjeta…
    expect(find.text('Paquete: 12 meses · 360 días'), findsOneWidget);
    expect(find.text('9600 CUP'), findsOneWidget);
    // …y el reporte sin meses (anterior al multimes) se
    // rotula como lo que es: el mes suelto.
    expect(find.text('Paquete: 1 mes · 30 días'), findsOneWidget);
    expect(find.text('1000 CUP'), findsOneWidget);
  });

  testWidgets(
      'confirmar un paquete de 12: el diálogo dice 360 días y '
      'avisa en vivo si el monto descuadra', (tester) async {
    await _abrirBandeja(tester);
    // La primera tarjeta es la de Laura (FIFO por creado_en).
    await tester.tap(find.text('Confirmar').first);
    expect(await _esperarTexto(tester, 'Confirmar pago App Plus'),
        isTrue);
    // Los días SON los del paquete: nada de «recibe 30 días».
    expect(find.textContaining('recibe 360 días'), findsOneWidget);
    expect(find.textContaining('recibe 30 días'), findsNothing);
    expect(find.textContaining('Paquete: 12 meses · 360 días'),
        findsWidgets);
    // Sin editar, no hay aviso de descuadre.
    expect(find.textContaining('no coincide con el paquete'),
        findsNothing);
    // Editar el monto a otro valor: el aviso sale en vivo.
    await tester.enterText(find.byType(TextField), '9000');
    await tester.pump();
    expect(find.textContaining('no coincide con el paquete de 12 '
        'meses'), findsOneWidget);
    expect(find.textContaining('recibirá igualmente los 360 días'),
        findsOneWidget);
    // Volver al precio del paquete apaga el aviso.
    await tester.enterText(find.byType(TextField), '9600');
    await tester.pump();
    expect(find.textContaining('no coincide con el paquete'),
        findsNothing);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'confirmar el mes suelto: el diálogo dice 30 días (los '
      'suyos) y rotula 1 mes', (tester) async {
    await _abrirBandeja(tester);
    await tester.tap(find.text('Confirmar').last);
    expect(await _esperarTexto(tester, 'Confirmar pago App Plus'),
        isTrue);
    expect(find.textContaining('recibe 30 días'), findsOneWidget);
    expect(find.textContaining('Paquete: 1 mes · 30 días'),
        findsWidgets);
    expect(find.textContaining('no coincide con el paquete'),
        findsNothing);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'plu06_ H6a: confirmar deja la tarjeta en «Decisión '
      'encolada» y el reporte se encola UNA sola vez',
      (tester) async {
    // Servicio de UN solo reporte: los botones del árbol son
    // los de esta tarjeta y solo esta.
    final svc = PlusReportesService(
      rpc: (nombre, params) async => [
        _fila(id: 31, nombre: 'Marta', monto: 1000, referencia: 'REF31'),
      ],
    );
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: ReportesPlusScreen(servicio: svc, esDueno: true),
    ));
    expect(await _esperarTexto(tester, 'Marta'), isTrue,
        reason: 'la bandeja carga el reporte del servicio falso');
    // Confirmar desde la tarjeta y aceptar en el diálogo
    // (su «Confirmar» es el último del árbol: la ruta del
    // diálogo va encima de la bandeja).
    await tester.tap(find.text('Confirmar'));
    expect(await _esperarTexto(tester, 'Confirmar pago App Plus'),
        isTrue);
    await tester.tap(find.text('Confirmar').last);
    // La tarjeta pasa a «Decisión encolada» y los botones
    // de decisión desaparecen: no hay segundo toque posible.
    expect(
        await _esperarTexto(tester, 'Decisión encolada'), isTrue,
        reason: 'la tarjeta refleja la decisión encolada');
    expect(
        find.text('Decisión encolada: se aplica al sincronizar'),
        findsOneWidget);
    expect(find.text('Confirmar'), findsNothing);
    expect(find.text('Rechazar'), findsNothing);
    // Y en la cola hay EXACTAMENTE una op de confirmación
    // para este reporte.
    await tester.runAsync(() async {
      final ops = await LocalDb.instance.pendingOps();
      final delReporte = ops.where((op) {
        if (op['tipo'] != kTipoOpConfirmarPlus) return false;
        final p = op['payload'];
        final mapa = p is Map
            ? Map<String, dynamic>.from(p)
            : (p is String && p.isNotEmpty
                ? Map<String, dynamic>.from(
                    jsonDecode(p) as Map)
                : null);
        return mapa?['reporte_id']?.toString() == '31';
      }).toList();
      expect(delReporte.length, 1,
          reason: 'una sola op de confirmación por reporte');
    });
  });
}
