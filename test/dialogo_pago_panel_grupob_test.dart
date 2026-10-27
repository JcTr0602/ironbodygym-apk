/// Tests de cobertura del panel Grupo B 1.15 para pagoDialogo
/// (widget tests: el guard C4 vive dentro de la función del diálogo
/// y el init/restauración de fecha solo se observan en UI).
///
/// - C1: la fecha inicial del diálogo es la fecha Habana de hoy
///   (botón 'Pagado el: DD/MM/YYYY'), no DateTime.now() crudo.
/// - C3: cancelar el selector de fecha deja la fecha inicial intacta
///   (picked == null → return). Nota: la rama `r == null` que
///   restaura fechaAnterior/baseAnterior NO es alcanzable por UI:
///   el diálogo 'Cliente vencido' tiene barrierDismissible: false
///   y el mounted-check, así que solo un back del sistema o un
///   desmontaje la dispararía; queda verificada por código.
/// - M5: un solo toque en Continuar (Paso 1) devuelve el payload;
///   ya no existe el diálogo interno 'Confirmar pago'.
/// - C4: cliente con id inválido (0) → tras Continuar, null
///   (nunca se encola un cobro sin cliente).
///
/// Los clientes de prueba no están vencidos (sin pagado_hasta), así
/// que no aparece el diálogo previo 'Cliente vencido'. Los tipos
/// vienen del fallback fijo (BD de ajustes vacía): mensual 2000.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BD fresca. OJO: dentro de testWidgets corre una zona FakeAsync
/// y el borrado del archivo (I/O real de dart:io) NO completa ahí:
/// toda la preparación va en tester.runAsync (zona real). Sin eso,
/// el test se cuelga antes del primer pump (diagnosticado 2026-10-27:
/// se quedaba en File.delete() sin CPU).
Future<void> _bdVacia(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    // Sin isolate: las ops ffi van por llamadas síncronas en este
    // isolate y completan con microtasks, así que pagoDialogo (que
    // lee LocalDb dentro de la zona FakeAsync) no se cuelga.
    // Con databaseFactoryFfi (isolate por ports) las lecturas no
    // completan jamás en testWidgets (diagnosticado 2026-10-27).
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

/// Abre pagoDialogo y deja el Paso 1 en pantalla; devuelve el
/// futuro del payload (se completa al cerrar el diálogo).
Future<Future<Map<String, dynamic>?>> _abrirPaso1(
    WidgetTester tester, Map<String, dynamic> cliente) async {
  late Future<Map<String, dynamic>?> fut;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => ElevatedButton(
        onPressed: () {
          fut = pagoDialogo(ctx, cliente);
        },
        child: const Text('cobrar'),
      ),
    ),
  ));
  await tester.tap(find.text('cobrar'));
  await tester.pumpAndSettle();
  return fut;
}

String _botonFechaHoy() {
  final hoy = hoyHabanaIso().split('-'); // YYYY-MM-DD
  return 'Pagado el: ${hoy[2]}/${hoy[1]}/${hoy[0]}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pagoDialogo (panel Grupo B C1/C3/M5/C4)', () {
    testWidgets('C1: la fecha inicial es la fecha Habana de hoy',
        (tester) async {
      await _bdVacia(tester);
      await _abrirPaso1(tester, {
        'id': 10,
        'nombre': 'Cliente 10',
        'estado': 'activo',
      });
      expect(find.text(_botonFechaHoy()), findsOneWidget);
    });

    testWidgets('C3: cancelar el selector deja la fecha inicial',
        (tester) async {
      await _bdVacia(tester);
      await _abrirPaso1(tester, {
        'id': 10,
        'nombre': 'Cliente 10',
        'estado': 'activo',
      });
      final boton = _botonFechaHoy();
      expect(find.text(boton), findsOneWidget);
      await tester.tap(find.text(boton));
      await tester.pumpAndSettle();
      // Selector de fecha abierto (texto de ayuda propio).
      expect(find.text('Fecha del pago'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text(boton), findsOneWidget);
    });

    testWidgets('M5: un Continuar devuelve el payload sin segundo diálogo',
        (tester) async {
      await _bdVacia(tester);
      final fut = await _abrirPaso1(tester, {
        'id': 10,
        'nombre': 'Cliente 10',
        'estado': 'activo',
      });
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      final payload = await fut;
      expect(payload, isNotNull);
      expect(payload!['cliente_id'], 10);
      expect(payload['periodo'], 'mensual');
      expect(payload['monto'], 2000);
      expect(payload['metodo'], 'efectivo');
    });

    testWidgets('C4: id inválido → tras Continuar no hay payload',
        (tester) async {
      await _bdVacia(tester);
      final fut = await _abrirPaso1(tester, {
        'id': 0,
        'nombre': 'Sin id',
        'estado': 'activo',
      });
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(await fut, isNull);
    });
  });
}
