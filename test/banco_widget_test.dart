/// Banco de pruebas widget en el host — batería v1 (opción 2,
/// aprobada por Jc 2026-10-30 «a ver cómo va»).
///
/// Qué es: pruebas widget que bombean piezas REALES de la app en
/// este host, sin emulador y sin app instalada. Cubren que la
/// pantalla construye, que los botones existen y que tocarlos
/// dispara su acción. NO cubren: la app instalada, el sync real
/// contra el servidor, el flujo con sesión de dueño (sin harness
/// de sesión Supabase: todo corre como NO dueño) ni el offline
/// con corte de red (eso lo cubren los tests unitarios de
/// ops_queue/sync). La ruta del dueño y los conteos exactos de
/// Home son v2, cuando se escriba el contrato de conteo de Home
/// y el harness de sesión.
///
/// LÍMITE DEL HARNESS (probado 2026-10-31, 3 sondas): bajo
/// FakeAsync, las lecturas FFI de LocalDb NO resuelven (ni con
/// 100 pumps): la pantalla queda en su estado de carga. Por eso
/// las pruebas de pantalla afirman SOLO el estado inicial
/// (título / aviso / rama sin dueño), nunca el contenido
/// cargado, y NUNCA usan pumpAndSettle sobre una pantalla con
/// spinner (el spinner anima para siempre y pumpAndSettle
/// agota su timeout). El contenido cargado lo cubren los tests
/// unitarios de negocio/servicios. Los avisos «database has
/// been locked» del log son el mismo fenómeno (lecturas
/// pendientes que nunca resuelven bajo FakeAsync), no un
/// problema de la app: en producción y en unitarios resuelven
/// en milisegundos.
///
/// Requisito de corrida: NO correr en paralelo con la suite
/// completa — ambas usan la misma BD de tests
/// (.dart_tool/sqflite_common_ffi/databases/ironbody.db) y los
/// setUp se la borran entre sí (fallos 5/522). El script
/// `banco-nocturno/correr_bateria.sh` corre solo la batería.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/dashboard.dart';
import 'package:ironbody_gym/ui/gympedia.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Widget _envolver(Widget hijo) =>
    MaterialApp(home: Scaffold(body: hijo));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // Sin sesión: todo corre como NO dueño (ver cabecera).
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db; // dispara onCreate
  });

  group('banco · sistema', () {
    testWidgets('BotonPrimario: tocar dispara, deshabilitado no',
        (tester) async {
      var toques = 0;
      await tester.pumpWidget(_envolver(BotonPrimario(
          texto: 'Guardar', onPressed: () => toques++)));
      await tester.tap(find.text('Guardar'));
      expect(toques, 1);
      await tester.pumpWidget(
          _envolver(const BotonPrimario(texto: 'Guardar')));
      await tester.tap(find.text('Guardar'));
      expect(toques, 1);
    });

    testWidgets('Tarjeta: onTap dispara al tocar', (tester) async {
      var toques = 0;
      await tester.pumpWidget(_envolver(Tarjeta(
          onTap: () => toques++,
          child: const Text('Contenido'))));
      await tester.tap(find.text('Contenido'));
      expect(toques, 1);
    });

    testWidgets('EstadoVacio: la acción dispara', (tester) async {
      var toques = 0;
      await tester.pumpWidget(_envolver(EstadoVacio(
          icono: Icons.inbox,
          titulo: 'Sin datos',
          textoAccion: 'Actualizar',
          onAccion: () => toques++)));
      await tester.tap(find.text('Actualizar'));
      expect(toques, 1);
    });

    testWidgets('EstadoError: Reintentar dispara', (tester) async {
      var toques = 0;
      await tester.pumpWidget(_envolver(EstadoError(
          detalle: 'Fallo de lectura',
          onReintentar: () => toques++)));
      await tester.tap(find.text('Reintentar'));
      expect(toques, 1);
    });
  });

  group('banco · pantallas (sin dueño)', () {
    // Sin pumpAndSettle (la cabecera lo prohíbe en pantallas con
    // spinner): avanzar el tiempo falso agota los temporizadores
    // FFI pendientes (10 s) y la pantalla alcanza su estado
    // inicial estable, igual que antes hacía el asentamiento.
    Future<void> avanzarTiempo(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 11));
      }
    }

    testWidgets('Home: construye y muestra el grid de módulos',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await avanzarTiempo(tester);
      expect(find.text('MÓDULOS'), findsOneWidget);
      expect(find.byType(GridView), findsWidgets);
    });

    testWidgets('Servicios: construye con título y estado de carga',
        (tester) async {
      // Sin pumpAndSettle: el spinner de carga anima para siempre
      // porque las lecturas FFI no resuelven bajo FakeAsync (ver
      // cabecera). Se afirma el estado inicial, no el cargado.
      await tester
          .pumpWidget(const MaterialApp(home: ServiciosScreen()));
      await tester.pump();
      expect(find.text('Servicios ⚡'), findsOneWidget);
      expect(find.text('Cargando servicios…'), findsOneWidget);
    });

    testWidgets('Dashboard: sin cifras, muestra el aviso de permisos',
        (tester) async {
      await tester
          .pumpWidget(const MaterialApp(home: DashboardScreen()));
      await avanzarTiempo(tester);
      expect(find.textContaining('Cargando tus permisos'), findsOneWidget);
    });

    testWidgets('GymPedia: sin dueño muestra el aviso, no carga',
        (tester) async {
      // La rama sin dueño se devuelve antes de _cargar: no hay
      // EstadoCargando que afirmar, sino el aviso directo.
      await tester
          .pumpWidget(const MaterialApp(home: GympediaScreen()));
      await tester.pump();
      expect(find.text('Solo el dueño administra la GymPedia.'),
          findsOneWidget);
    });
  });
}
