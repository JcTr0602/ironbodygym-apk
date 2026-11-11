/// 1.32 (Oleada 2, Fase 1 — desviación 1 de Argón): la hoja
/// «Liquidar Arqueo» como PUERTA ÚNICA con selector de modo.
///
/// Lo que se fija es el CABLEADO de la hoja, con la capa de
/// datos inyectada/falsa (las costuras de la propia hoja,
/// patrón de la casa): bajo FakeAsync las lecturas FFI de
/// LocalDb no resuelven — límite probado del banco de
/// widgets (2026-10-31) — así que el widget no puede cargar
/// contra la BD real. Los efectos reales de cada operación
/// (qué op encola y qué escribe en el libro) los cubren los
/// tests unitarios de crearLiquidacion y de
/// registrarEntregaEfectivo (liquidacion_panel115, turnos_122).
///
/// - El modo por defecto es «Liquidación de cierre» y al
///   deslizar llama a crearLiquidacion con el esperado del
///   arqueo y NO llama a registrarEntregaEfectivo.
/// - Al cambiar a «Entrega anticipada», el esperado pasa a
///   ser el delta del libro C1 y al deslizar llama a
///   registrarEntregaEfectivo y NO a crearLiquidacion.
/// Las dos operaciones NO se funden: cada modo corre la suya.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/hoja_liquidar_arqueo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Falsas que registran sus llamadas.
class _Falsas {
  int llamadasCrear = 0;
  int llamadasRegistrar = 0;
  double? entregadoCrear;
  double? esperadoCrear;
  double? entregadoRegistrar;
  int? tidRegistrar;

  Future<({double cup, double usd})> pendienteArqueo(int tid) async =>
      (cup: 2000.0, usd: 0.0);

  Future<double> pendienteDeltaC1(int tid) async => 1500.0;

  Future<Map<String, List<int>>> idsPendiente(
          int tid, String moneda) async =>
      {
        'pagos': [1, 2]
      };

  Future<String> crear({
    required int entrenadorTelegramId,
    required String entrenadorNombre,
    required double montoEsperado,
    required double montoEntregado,
    required Map<String, List<int>> opIds,
    required String moneda,
    String? nota,
  }) async {
    llamadasCrear++;
    esperadoCrear = montoEsperado;
    entregadoCrear = montoEntregado;
    return 'liq-falsa-1';
  }

  Future<String> registrar({
    required int entrenadorTelegramId,
    required double montoEntregado,
    required int autorDuenoId,
  }) async {
    llamadasRegistrar++;
    tidRegistrar = entrenadorTelegramId;
    entregadoRegistrar = montoEntregado;
    return 'uuid-entrega-falsa';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Sin sesión: AuthService().telegramId es null y la hoja
    // pasa 0 como autor a la falsa (en producción la sesión
    // del dueño siempre existe; la guarda real de la op está
    // cubierta por sus tests unitarios con sesión de dueño).
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  Future<void> abrirHoja(
      WidgetTester tester, _Falsas f, List<ResultadoHojaArqueo?> caja) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () async {
                caja[0] = await mostrarHojaLiquidarArqueo(
                  ctx,
                  telegramId: 111,
                  nombre: 'Entrenador',
                  pendienteArqueoFn: f.pendienteArqueo,
                  pendienteDeltaC1Fn: f.pendienteDeltaC1,
                  idsPendienteArqueoFn: f.idsPendiente,
                  crearLiquidacionFn: f.crear,
                  registrarEntregaFn: f.registrar,
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  Future<void> deslizar(WidgetTester tester) async {
    await tester.drag(find.byKey(const ValueKey('deslizar-pulgar')),
        const Offset(500, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // La cadena de la operación (falsas) + la animación de
    // salida de la hoja necesitan sus frames.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('modo cierre (defecto): deslizar llama a '
      'crearLiquidacion y no a registrarEntregaEfectivo',
      (tester) async {
    final f = _Falsas();
    final caja = <ResultadoHojaArqueo?>[null];
    await abrirHoja(tester, f, caja);
    // El selector de modo está y el defecto es el cierre:
    // el esperado visible es el del arqueo (2000), no el
    // delta del libro (1500).
    expect(find.text('Liquidación de cierre'), findsOneWidget);
    expect(find.text('Entrega anticipada'), findsOneWidget);
    expect(find.textContaining('Pendiente confirmado'),
        findsOneWidget);
    expect(find.textContaining('2000'), findsWidgets);
    await deslizar(tester);
    expect(find.byType(HojaLiquidarArqueo), findsNothing,
        reason: 'la hoja se cierra al liquidar');
    expect(f.llamadasCrear, 1);
    expect(f.esperadoCrear, 2000);
    expect(f.entregadoCrear, 2000);
    expect(f.llamadasRegistrar, 0,
        reason: 'el modo cierre NO ejecuta la op C1');
    final r = caja[0];
    expect(r, isNotNull);
    expect(r!.modo, ModoHojaArqueo.cierre);
    expect(r.liquidacion!.liqId, 'liq-falsa-1');
    expect(r.entregaUuid, isNull);
  });

  testWidgets('modo C1: deslizar llama a '
      'registrarEntregaEfectivo y no a crearLiquidacion',
      (tester) async {
    final f = _Falsas();
    final caja = <ResultadoHojaArqueo?>[null];
    await abrirHoja(tester, f, caja);
    await tester.tap(find.text('Entrega anticipada'));
    await tester.pump();
    // El esperado pasa a ser el delta del libro (1500).
    expect(find.textContaining('Pendiente en el libro de entregas'),
        findsOneWidget);
    expect(find.textContaining('1500'), findsWidgets);
    await deslizar(tester);
    expect(find.byType(HojaLiquidarArqueo), findsNothing,
        reason: 'la hoja se cierra al registrar la entrega');
    expect(f.llamadasRegistrar, 1);
    expect(f.tidRegistrar, 111);
    expect(f.entregadoRegistrar, 1500,
        reason: 'registra el delta del libro, no el arqueo');
    expect(f.llamadasCrear, 0,
        reason: 'el modo C1 NO crea la liquidación de cierre');
    final r = caja[0];
    expect(r, isNotNull);
    expect(r!.modo, ModoHojaArqueo.entregaC1);
    expect(r.entregaUuid, 'uuid-entrega-falsa');
    expect(r.liquidacion, isNull);
  });
}
