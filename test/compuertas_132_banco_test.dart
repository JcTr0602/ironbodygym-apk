/// Compuertas 1.32 — BLOQUE 2: banco de compuertas de
/// campo (reglas 2026-11-11) sobre el candidato.
///
/// 1. «Por Decidir» bajo RED HOSTIL (regla de la Compuerta
///    1 del rediseño): con la fuente remota COLGADA (un
///    futuro que nunca completa) o devolviendo null en
///    todas sus fuentes, la bandeja pinta los locales en el
///    primer cuadro y JAMÁS afirma «Todo al día · 0
///    decisiones pendientes» (error ≠ vacío). Con todo
///    verificado en cero, el «Todo al día» SÍ sale
///    (control: las negativas no son vacuosas).
/// 2. Umbral n−1/n de la bandeja: las filas de arqueo se
///    cortan en 2 (take(2)); con 2 entran las 2, con 3 la
///    tercera no se pinta.
/// 3. ESCALA REAL: el fixture de estrés del Paso 0 (2.225
///    clientes / 6.000 pagos) sembrado por la vía del pull
///    (espejos en bloque + `actualizarFtsClientesBloque`),
///    con búsqueda del Directorio y conteo de morosos
///    correctos sobre el padrón entero.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _cargarRobotoReal() async {
  const dir =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf'
  ]) {
    final bytes = await File('$dir/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Widget _envolver(BandejaPorDecidir b) => MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: Scaffold(body: SingleChildScrollView(child: b)),
    );

BandejaPorDecidir _bandeja({
  required Future<ConteosRemotosPorDecidir> Function() remotas,
  int incidencias = 0,
  List<Map<String, dynamic>> arqueos = const [],
}) {
  return BandejaPorDecidir(
    incidencias: incidencias,
    rellenos: 0,
    adelantos: 0,
    onIr: (_) {},
    cargarRemotas: remotas,
    cargarCongelaciones: () async => (ok: true, pendientes: 0),
    cargarArqueos: () async => arqueos,
    cargarCatalogo: () async => 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _cargarRobotoReal();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Banco · Por Decidir bajo red hostil (Compuerta 1)', () {
    testWidgets('remota COLGADA: locales al primer cuadro y '
        '«Todo al día» jamás aparece', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Un futuro que NUNCA completa: el timeout colgado,
      // no un error rápido.
      final nunca = Completer<ConteosRemotosPorDecidir>();
      await tester.pumpWidget(_envolver(_bandeja(
        remotas: () => nunca.future,
        incidencias: 2,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Los locales están desde el primer pintado útil.
      expect(find.text('Incidencias de sincronización'),
          findsOneWidget);
      expect(find.text('Todo al día · 0 decisiones pendientes'),
          findsNothing);
      expect(find.text('bandejas remotas sin verificar (sin conexión)'),
          findsOneWidget,
          reason: 'sin foto previa y sin verificar, la bandeja '
              'lo DECLARA en vez de afirmar el cero');
      // Ni un minuto de reloj falso después: sigue sin
      // afirmar el cero (la remota sigue colgada).
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 10));
      }
      expect(find.text('Todo al día · 0 decisiones pendientes'),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('remota en ERROR (todo null): tampoco hay '
        '«Todo al día» y los locales mandan', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_envolver(_bandeja(
        remotas: () async => const ConteosRemotosPorDecidir(),
        incidencias: 1,
      )));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Incidencias de sincronización'),
          findsOneWidget);
      expect(find.text('1 decisión pendiente'), findsOneWidget,
          reason: 'el titular suma el local verificado y no '
              'finge el cero remoto');
      expect(find.text('Todo al día · 0 decisiones pendientes'),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('control: todo verificado en cero SÍ dice '
        '«Todo al día»', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_envolver(_bandeja(
        remotas: () async => const ConteosRemotosPorDecidir(
            vales: 0, plus: 0, comunidad: 0, solicitudes: 0),
      )));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Todo al día · 0 decisiones pendientes'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Banco · umbral de arqueos de la bandeja (n−1 / n)', () {
    Future<void> montarCon(WidgetTester tester,
        List<Map<String, dynamic>> arqueos) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_envolver(_bandeja(
        remotas: () async => const ConteosRemotosPorDecidir(
            vales: 0, plus: 0, comunidad: 0, solicitudes: 0),
        arqueos: arqueos,
      )));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('con 2 arqueos (el tope) se pintan los 2',
        (tester) async {
      await montarCon(tester, [
        {'nombre': 'Duany', 'cup': 1500.0, 'usd': 0.0},
        {'nombre': 'Gabriel', 'cup': 800.0, 'usd': 0.0},
      ]);
      expect(find.text('Efectivo de Duany por recoger'),
          findsOneWidget);
      expect(find.text('Efectivo de Gabriel por recoger'),
          findsOneWidget);
      expect(
          find.widgetWithText(FilledButton, 'Liquidar Arqueo'),
          findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('con 3 arqueos (tope+1) la tercera fila NO '
        'se pinta', (tester) async {
      await montarCon(tester, [
        {'nombre': 'Duany', 'cup': 1500.0, 'usd': 0.0},
        {'nombre': 'Gabriel', 'cup': 800.0, 'usd': 0.0},
        {'nombre': 'El Chino', 'cup': 200.0, 'usd': 0.0},
      ]);
      expect(find.text('Efectivo de Duany por recoger'),
          findsOneWidget);
      expect(find.text('Efectivo de Gabriel por recoger'),
          findsOneWidget);
      expect(find.text('Efectivo de El Chino por recoger'),
          findsNothing,
          reason: 'la bandeja corta en 2 filas de arqueo '
              '(take(2)): la tercera espera su turno');
      expect(
          find.widgetWithText(FilledButton, 'Liquidar Arqueo'),
          findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('Banco · escala real (fixture del Paso 0)', () {
    test('2.225 clientes / 6.000 pagos: conteos, morosos y '
        'búsqueda del Directorio correctos', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      final db = await LocalDb.instance.db;

      const apellidos = ['Garcia', 'Perez', 'Lopez', 'Diaz', 'Ruiz'];
      final filasFts = <({int id, String dataJson, String? oldFoto})>[];
      await db.transaction((txn) async {
        final lote = txn.batch();
        for (var i = 0; i < 2225; i++) {
          final id = 1000 + i;
          // 1 de cada 5, moroso (pagado_hasta vencido); el
          // resto, al día. Un apellido raro ×3 y un nombre
          // único para la búsqueda distintiva.
          final nombre = i == 7
              ? 'Zzqxwv Unico'
              : i % 97 == 0
                  ? 'Cliente$i Marrero'
                  : 'Cliente$i ${apellidos[i % 5]}';
          final data = {
            'id': id,
            'nombre': nombre,
            'telefono': '58${100000 + i}',
            'estado': 'activo',
            'pagado_hasta': i % 5 == 0 ? '2026-10-01' : '2027-01-01',
            'fecha_inscripcion': '2026-01-15',
          };
          lote.insert('clientes', {
            'id': id,
            'data': jsonEncode(data),
            'sync_seq': 5000 + i,
          });
          filasFts.add(
              (id: id, dataJson: jsonEncode(data), oldFoto: null));
        }
        for (var j = 0; j < 6000; j++) {
          lote.insert('pagos', {
            'id': 5000 + j,
            'data': jsonEncode({
              'id': 5000 + j,
              'cliente_id': 1000 + (j % 2225),
              'monto': 2000,
              'metodo': 'efectivo',
              'fecha': '2026-11-05',
            }),
            'sync_seq': 9000 + j,
          });
        }
        await lote.commit(noResult: true);
        // La indexación FTS por la vía del pull (en bloque).
        await LocalDb.instance
            .actualizarFtsClientesBloque(filasFts, txn: txn);
      });

      expect((await LocalDb.instance.allMirror('clientes')).length,
          2225);
      expect((await LocalDb.instance.allMirror('pagos')).length,
          6000);
      // Morosos construidos: i % 5 == 0 → 445 exactos.
      expect(await morosos(), 445,
          reason: 'el conteo de morosos sobre el padrón de '
              'estrés debe ser el construido');

      final reloj = Stopwatch()..start();
      final unica = await buscarClientes('Zzqxwv');
      reloj.stop();
      // ignore: avoid_print
      print('buscarClientes distintiva sobre 2.225: '
          '${reloj.elapsedMilliseconds} ms');
      expect(unica, hasLength(1));
      expect(unica.single['nombre'], 'Zzqxwv Unico');
      expect(reloj.elapsedMilliseconds, lessThan(20000),
          reason: 'la búsqueda del Directorio sobre el '
              'padrón de estrés no puede degradarse a '
              'segundos de espera (Paso 0: 1,9 s en bloque '
              'antes del FTS; el margen es 10×)');
      final marrero = await buscarClientes('Marrero');
      expect(marrero.length, 23,
          reason: 'i % 97 == 0 en 0..2224 → 23 clientes '
              'Marrero, todos encontrables');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
