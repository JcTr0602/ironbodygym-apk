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

    testWidgets('Home: dos niveles — Hoy por defecto y Módulos '
        'a un toque con su grid', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await avanzarTiempo(tester);
      // En este entorno sin sesión, Home abre el diálogo de
      // «Cuenta no habilitada» (barrera modal, no descartable):
      // se acepta como haría el usuario y la barrera se retira.
      // Sin este paso ningún toque llega a la pantalla. El
      // diálogo llega por una lectura REAL asíncrona (permisos):
      // los pumps de tiempo falso no la hacen avanzar; runAsync
      // deja correr ~2 s reales y el diálogo aparece (medido).
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await tester.pump(const Duration(milliseconds: 300));
      // Puede haber DOS diálogos apilados al abrir (permisos,
      // con botón «ENTENDIDO», y «Lo nuevo en esta versión»,
      // con botón «Entendido»): se aceptan en cadena hasta
      // que no quede ninguno tapando la pantalla.
      // 1.23 (integración Bloque 5): descartar por TOQUE es
      // frágil aquí, medido en corrida: (a) el orden del
      // árbol de los dos AlertDialog no coincide con el
      // orden visual de apilado — el toque al botón del de
      // abajo lo absorbía el contenido del de arriba; (b) un
      // diálogo en animación de salida sigue en el árbol
      // pero ignora punteros, y el toque cae a la pantalla;
      // (c) el diálogo de permisos llega por una lectura
      // REAL asíncrona y bajo carga puede aparecer DESPUÉS
      // del primer descarte. Descarte determinista: cerrar
      // la ruta del diálogo con el propio Navigator (sin
      // hit-test). El botón de permisos además dispararía
      // signOut: efecto incidental que esta prueba no
      // necesita (su fin es destapar Home). El toque al
      // selector va en un ciclo descartar→tocar por si un
      // diálogo tardío tapa el primer toque.
      Future<void> descartarDialogos() async {
        for (var i = 0; i < 6; i++) {
          if (find.byType(AlertDialog).evaluate().isEmpty) break;
          // popUntil a la PRIMERA ruta (la propia Home): cierra
          // todos los diálogos apilados en una pasada y jamás
          // puede cerrar Home. (Un pop() por vuelta resultó
          // peligroso: con el diálogo aún en animación de
          // salida, la siguiente vuelta podía cerrar la ruta
          // de Home y dejar el Navigator vacío.)
          Navigator.of(tester.element(find.byType(HomeScreen)))
              .popUntil((r) => r.isFirst);
          await tester.pump(const Duration(milliseconds: 400));
        }
      }

      await descartarDialogos();
      // Nivel 1 por defecto: el selector se ve y el grid no.
      expect(find.text('Hoy'), findsOneWidget);
      expect(find.text('Módulos'), findsOneWidget);
      expect(find.text('MÓDULOS'), findsNothing);
      for (var intento = 0; intento < 3; intento++) {
        if (find.byType(AlertDialog).evaluate().isNotEmpty) {
          await descartarDialogos();
          continue;
        }
        if (find.text('Módulos').evaluate().isEmpty) break;
        await tester.tap(find.text('Módulos'));
        await tester.pump(const Duration(milliseconds: 600));
        if (find.text('MÓDULOS').evaluate().isNotEmpty) break;
      }
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
