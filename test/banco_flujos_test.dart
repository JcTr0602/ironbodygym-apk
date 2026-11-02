/// Banco de pruebas — batería v2: FLUJOS reales (cobrar).
///
/// A diferencia de la v1 (estados iniciales bajo FakeAsync), esta
/// batería usa el factory FFI SIN isolate
/// (databaseFactoryFfiNoIsolate): las lecturas de LocalDb completan
/// con microtasks dentro de testWidgets (patrón diagnosticado el
/// 2026-10-27 en los tests del panel Grupo B), así que se pueden
/// manejar diálogos y pantallas completas con pumpAndSettle.
///
/// Flujos cubiertos: COBRAR una mensualidad de principio a fin
/// con las funciones reales de la app — pagoDialogo (Paso 1) →
/// cobrarConPreviewYRecibo (preview obligatorio → op 'pago_mensual'
/// retenida 15 s en ops_queue → espejo actualizado optimista →
/// recibo) — y el camino de DESHACER desde el recibo (la op se
/// borra y el espejo vuelve al valor anterior). INSCRIBIR un
/// cliente desde la pantalla real (formulario → confirmación →
/// op 'inscribir' en cola con su payload). VENDER un suplemento
/// desde la pantalla real (comprador externo → vista previa →
/// op 'venta_suplemento' en cola y stock del espejo descontado).
///
/// La sesión de dueño NO se puede fingir aquí: isOwner sale de la
/// sesión Supabase (email del JWT) y el Supabase local de pruebas
/// (127.0.0.1:9) no emite sesiones; el camino de dueño se razona y
/// lo cubren los unitarios de permisos. Este banco corre como
/// entrenador (sin sesión), que es el flujo de cobro diario.
///
/// Requisito de corrida: NO en paralelo con la suite completa (BD
/// de tests compartida). El script banco-nocturno/correr_bateria.sh
/// corre v1 + v2 juntas.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';
import 'package:ironbody_gym/ui/venta_suplemento.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// BD fresca + cliente 10 sembrado en el espejo. Toda la
/// preparación va en runAsync (zona real): dentro de testWidgets
/// corre FakeAsync y el I/O de dart:io no completa ahí.
Future<void> _preparar(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    await LocalDb.instance.upsertMirror('clientes', 10, {
      'id': 10,
      'nombre': 'Cliente Banco',
      'estado': 'activo',
      'pagado_hasta': null,
    }, 1);
  });
}

/// Monta un botón que ejecuta el flujo de cobro real completo
/// (diálogo → preview/recibo) y guarda el resultado en [alCerrar].
Widget _hostCobro(void Function(bool?) alCerrar) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final payload = await pagoDialogo(ctx, {
                'id': 10,
                'nombre': 'Cliente Banco',
                'estado': 'activo',
                'pagado_hasta': null,
              });
              if (payload == null || !ctx.mounted) {
                alCerrar(null);
                return;
              }
              final deshecho = await cobrarConPreviewYRecibo(
                context: ctx,
                nombreCliente: 'Cliente Banco',
                payload: payload,
              );
              alCerrar(deshecho);
            },
            child: const Text('cobrar'),
          ),
        ),
      ),
    ),
  );
}

/// Abre el flujo y confirma el cobro hasta ver el recibo.
Future<void> _cobrarHastaRecibo(WidgetTester tester) async {
  await tester.tap(find.text('cobrar'));
  await tester.pumpAndSettle();
  // Paso 1 del diálogo de pago (tipos del fallback: mensual 2000).
  expect(find.text('Continuar'), findsOneWidget);
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
  // Preview obligatorio.
  expect(find.text('Revisar cobro'), findsOneWidget);
  await tester.tap(find.text('Confirmar cobro'));
  await tester.pumpAndSettle();
  // Recibo con Deshacer y Entendido.
  expect(find.text('Entendido'), findsOneWidget);
}

/// Espera bombeando frames hasta que [finder] aparece. Las
/// acciones que disparan lecturas FFI desde la UI (guardar una
/// inscripción, registrar una venta) no siempre se asientan con
/// pumpAndSettle dentro de testWidgets: este bucle acotado es el
/// patrón robusto del banco.
Future<void> _esperar(WidgetTester tester, Finder finder,
    {int intentos = 40}) async {
  for (var i = 0; i < intentos; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(finder, findsOneWidget,
      reason: 'no apareció tras ${intentos * 250} ms de frames');
}

/// Decodifica el payload de una op de la cola (en ops_queue se
/// guarda como String JSON).
Map<String, dynamic> _payloadDe(Map<String, dynamic> op) {
  final crudo = op['payload'];
  return crudo is String
      ? jsonDecode(crudo) as Map<String, dynamic>
      : Map<String, dynamic>.from(crudo as Map);
}

/// BD fresca sin cliente sembrado (flujo inscribir).
Future<void> _prepararVacia(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });
}

/// BD fresca con un suplemento vendible en el espejo.
Future<void> _prepararSuplemento(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    await LocalDb.instance.upsertMirror('suplementos', 5, {
      'id': 5,
      'nombre': 'Proteína Banco',
      'precio_oficial': 1500,
      'moneda': 'CUP',
      'stock': 4,
      'activo': 1,
    }, 1);
    // La tasa del día (en producción la pone el dueño en Admin):
    // sin ella la pantalla bloquea la venta para pedirla.
    await LocalDb.instance.setAjustes({'tasa_usd': 300});
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Las pantallas completas tocan servicios que leen la
    // sesión: Supabase dummy sin sesión (patrón de la casa) y
    // mocks de app_links para que el plugin no truene.
    const canalEventos = EventChannel('com.llfbandit.app_links/events');
    const canalMensajes =
        MethodChannel('com.llfbandit.app_links/messages');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(canalEventos,
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canalMensajes, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('banco v2 · flujo cobrar', () {
    testWidgets(
        'confirmar: op pago_mensual en cola y espejo actualizado',
        (tester) async {
      await _preparar(tester);
      bool? resultado;
      await tester.pumpWidget(_hostCobro((r) => resultado = r));
      await _cobrarHastaRecibo(tester);

      final ops = await LocalDb.instance.pendingOps();
      final pagos =
          ops.where((o) => o['tipo'] == 'pago_mensual').toList();
      expect(pagos, hasLength(1),
          reason: 'el cobro confirmado encola exactamente una op');
      // En ops_queue el payload se guarda como String JSON.
      final crudo = pagos.single['payload'];
      final payload = crudo is String
          ? jsonDecode(crudo) as Map<String, dynamic>
          : Map<String, dynamic>.from(crudo as Map);
      expect(payload['cliente_id'], 10);
      expect((payload['monto'] as num).toInt(), 2000);
      final nuevoHasta = '${payload['pagado_hasta'] ?? ''}';
      expect(nuevoHasta.length, greaterThanOrEqualTo(10));

      final filas = await LocalDb.instance.mirrorPorIds('clientes', [10]);
      expect(filas.single['pagado_hasta'], nuevoHasta.substring(0, 10),
          reason: 'el espejo refleja el nuevo vencimiento al instante');

      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();
      expect(resultado, isFalse,
          reason: 'confirmado y no deshecho devuelve false');
      await tester.pump(const Duration(seconds: 16));
    });

    testWidgets('deshacer: la op se borra y el espejo se restaura',
        (tester) async {
      await _preparar(tester);
      bool? resultado;
      await tester.pumpWidget(_hostCobro((r) => resultado = r));
      await _cobrarHastaRecibo(tester);

      expect(await LocalDb.instance.pendingOps(), isNotEmpty);
      await tester.tap(find.textContaining('Deshacer'));
      await tester.pumpAndSettle();
      expect(resultado, isTrue,
          reason: 'deshacer dentro de la ventana devuelve true');

      final ops = await LocalDb.instance.pendingOps();
      expect(ops.where((o) => o['tipo'] == 'pago_mensual'), isEmpty,
          reason: 'la op deshecha nunca sale del teléfono');
      final filas = await LocalDb.instance.mirrorPorIds('clientes', [10]);
      expect(filas.single['pagado_hasta'], isNull,
          reason: 'el espejo vuelve al vencimiento anterior (null)');
      await tester.pump(const Duration(seconds: 16));
    });
  });

  group('banco v2 · flujo inscribir', () {
    testWidgets('formulario → confirmación → op inscribir en cola',
        (tester) async {
      await _prepararVacia(tester);
      await tester.pumpWidget(
          const MaterialApp(home: InscribirScreen()));
      await tester.pumpAndSettle();

      // Nombre y carnet (6 dígitos con fecha real: 1990-05-15,
      // adulto — sin diálogos de fecha dudosa ni de duplicado
      // porque la BD está vacía).
      final campos = find.byType(TextFormField);
      await tester.ensureVisible(campos.at(0));
      await tester.enterText(campos.at(0), 'Nuevo Banco');
      await tester.ensureVisible(campos.at(2));
      await tester.enterText(campos.at(2), '900515');
      // El cursor del campo enfocado parpadea con un temporizador
      // y pumpAndSettle nunca se asienta: se quita el foco antes.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Guardar inscripción'));
      // Confirmación con resumen de la inscripción.
      await _esperar(tester, find.text('Confirmar inscripción'));
      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();

      final ops = await LocalDb.instance.pendingOps();
      final insc = ops.where((o) => o['tipo'] == 'inscribir').toList();
      expect(insc, hasLength(1),
          reason: 'la inscripción confirmada encola una sola op');
      final payload = _payloadDe(insc.single);
      expect(payload['nombre'], 'Nuevo Banco');
      expect(payload['carnet'], '900515');
      expect((payload['precio_aplicado'] as num).toInt(), 2000,
          reason: 'mensual en efectivo al precio estándar');
      expect(payload['fecha'], isNotEmpty);
    });
  });

  group('banco v2 · flujo vender suplemento', () {
    testWidgets('externo → vista previa → op de venta y stock -1',
        (tester) async {
      await _prepararSuplemento(tester);
      await tester.pumpWidget(const MaterialApp(
        home: VentaSuplementoScreen(suplemento: {
          'id': 5,
          'nombre': 'Proteína Banco',
          'precio_oficial': 1500,
          'moneda': 'CUP',
          'stock': 4,
          'activo': 1,
        }),
      ));
      await tester.pumpAndSettle();

      // Comprador externo genérico (sin cliente ni nombre). La
      // pantalla es un ListView: el selector está bajo el
      // pliegue y no se construye hasta desplazar hasta él.
      final externo = find.text('Cliente externo');
      for (var i = 0;
          i < 8 && externo.evaluate().isEmpty;
          i++) {
        await tester.drag(
            find.byType(ListView), const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(externo, findsOneWidget,
          reason: 'el selector de comprador aparece al desplazar');
      await tester.ensureVisible(externo);
      await tester.tap(externo);
      await tester.pumpAndSettle();

      // Barra fija: abre la vista previa del comprobante.
      await tester.tap(find.text('Confirmar venta'));
      await tester.pumpAndSettle();
      expect(find.text('Confirma la venta'), findsOneWidget);
      // El botón del diálogo es el último «Confirmar venta».
      await tester.tap(find.text('Confirmar venta').last);
      await tester.pumpAndSettle();

      final ops = await LocalDb.instance.pendingOps();
      final ventas =
          ops.where((o) => o['tipo'] == 'venta_suplemento').toList();
      expect(ventas, hasLength(1),
          reason: 'la venta confirmada encola una sola op');
      final payload = _payloadDe(ventas.single);
      expect(payload['suplemento_id'], 5);
      expect((payload['cantidad'] as num).toInt(), 1);
      expect((payload['precio_venta_centavos'] as num).toInt(),
          150000,
          reason: 'precio unitario oficial en centavos');

      final filas =
          await LocalDb.instance.mirrorPorIds('suplementos', [5]);
      expect((filas.single['stock'] as num).toInt(), 3,
          reason: 'el stock del espejo se descuenta en la venta');

      // Comprobante final de la venta.
      expect(find.text('Venta registrada'), findsOneWidget);
      await tester.tap(find.text('Cerrar'));
      await tester.pumpAndSettle();
    });
  });
}
