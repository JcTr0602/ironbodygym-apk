/// Yunque de cambios 1.31 · RONDA 2 · R2-X1 (transversal):
/// las pantallas cuya carga solo bajaba la bandera
/// «cargando» en el camino feliz quedan corregidas con la
/// red de la casa (envoltorio try/finally que baja la
/// bandera SIEMPRE, patrón mi_turno T84 / gastos M2-A A7).
/// Clase de la lección de la ficha 2026-11-02: si una
/// lectura local lanza a mitad, la pantalla enseñaba un
/// spinner eterno, sin error ni salida.
///
/// Dos capas, como manda la casa:
/// 1) CONDUCTUAL: dos pantallas representativas de dos
///    familias (espejo genérico y meta) se montan con la
///    lectura rota (tabla espejo borrada de una BD ya
///    abierta) y deben SALIR de «cargando», sin excepción
///    sin cazar, enseñando su estado vacío honesto.
/// 2) CONTRATO DE FUENTE: el catálogo entero de la ronda
///    lleva la red (envoltorio + cuerpo renombrado).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/avisos.dart';
import 'package:ironbody_gym/ui/cuentas_cobrar.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _src(String ruta) => File(ruta).readAsStringSync();

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    for (final nombre in ['ironbody.db', 'ironbody_$pid.db']) {
      try {
        await File(p.join(dir, nombre) + sufijo).delete();
      } catch (_) {}
    }
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// Drenaje realista (patrón de oleada3/_drenar): los
/// futuros de sqflite_ffi no completan solo con pumps.
Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('r2x1_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
  });

  setUp(() async {
    await _bdVacia();
  });

  group('conductual · la lectura rota no cuelga la pantalla', () {
    testWidgets('CuentasCobrar (familia espejo): sin la tabla '
        'clientes, sale de «cargando» y no revienta', (tester) async {
      await tester.runAsync(() async {
        final d = await LocalDb.instance.db;
        await d.execute('DROP TABLE clientes');
      });
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: CuentasCobrarScreen(incrustada: true))));
      await _drenar(tester);
      expect(tester.takeException(), isNull,
          reason: 'la excepción de la lectura no debe escapar '
              'sin cazar (era el spinner eterno)');
      expect(find.text('Cargando cuentas por cobrar…'), findsNothing,
          reason: 'la bandera bajó pese al fallo de la lectura');
    });

    testWidgets('Avisos (familia meta): sin la tabla meta, '
        'sale de «cargando» y no revienta', (tester) async {
      await tester.runAsync(() async {
        final d = await LocalDb.instance.db;
        await d.execute('DROP TABLE meta');
      });
      await tester.pumpWidget(const MaterialApp(home: AvisosScreen()));
      await _drenar(tester);
      expect(tester.takeException(), isNull,
          reason: 'la excepción de la lectura no debe escapar '
              'sin cazar (era el spinner eterno)');
      expect(find.text('Cargando avisos…'), findsNothing,
          reason: 'la bandera bajó pese al fallo de la lectura');
    });
  });

  group('contrato de fuente · el catálogo lleva la red', () {
    // ruta → bandera que el finally vigila.
    const catalogo = <String, String>{
      // R2-M1 · Caja y cierre
      'lib/ui/detalle_pendiente.dart': '_cargando',
      'lib/ui/historial_caja.dart': '_cargando',
      'lib/ui/cuentas_cobrar.dart': '_cargando',
      'lib/ui/cuentas_por_cobrar.dart': '_cargando',
      'lib/ui/pago.dart': '_cargandoCobros',
      // R2-M2 · Nómina y adelantos
      'lib/ui/nomina.dart': '_cargando',
      'lib/ui/mi_nomina.dart': '_cargando',
      'lib/ui/solicitudes_adelanto.dart': '_cargando',
      // R2-M4 · Mi Día
      'lib/ui/mi_dia.dart': '_cargando',
      // R2-M5 · Suplementos y servicios
      'lib/ui/reservas.dart': '_cargando',
      'lib/ui/suplementos.dart': '_cargando',
      'lib/ui/centro_compras.dart': '_cargando',
      'lib/ui/categorias_suplemento.dart': '_cargando',
      'lib/ui/historial_ventas.dart': '_cargando',
      'lib/ui/reporte_margenes.dart': '_cargando',
      'lib/ui/reporte_mensual_diarios.dart': '_cargando',
      'lib/ui/servicios_admin.dart': '_cargando',
      'lib/ui/servicios_historial.dart': '_cargando',
      'lib/ui/servicios_precios.dart': '_cargando',
      'lib/ui/ranking_servicios.dart': '_cargando',
      'lib/ui/servicios_estadisticas.dart': '_cargando',
      // R2-M9 · Auditoría y actividad
      'lib/ui/auditoria.dart': '_cargando',
      'lib/ui/actividad.dart': '_cargando',
      'lib/ui/actividad_cliente.dart': '_cargandoLista',
      // Entrenadores
      'lib/ui/detalle_entrenador.dart': '_cargando',
      'lib/ui/historial_entrenador.dart': '_cargando',
      'lib/ui/comparativa_entrenadores.dart': '_cargando',
      // Incidencias
      'lib/ui/incidencias/lista_incidencias.dart': '_cargando',
      // R2-M3 · Panel del dueño
      'lib/ui/panel_resto_config.dart': '_cargando',
      'lib/ui/riesgo.dart': '_cargando',
      'lib/ui/tarifas_especiales.dart': '_cargando',
      // Mostrador y comunicación
      'lib/ui/pago_diario.dart': '_cargandoReporte',
      'lib/ui/avisos_entrenador.dart': '_cargando',
      'lib/ui/guia_lista.dart': '_cargando',
      'lib/ui/gympedia.dart': '_cargando',
      // Menores
      'lib/ui/avisos.dart': '_cargando',
    };

    test('cada pantalla del catálogo envuelve su carga en '
        'try/finally con la bandera vigilada', () {
      for (final e in catalogo.entries) {
        final src = _src(e.key);
        expect(src.contains('(Yunque R2-X1)'), isTrue,
            reason: '${e.key}: falta la marca de la red R2-X1');
        expect(src.contains('} finally {'), isTrue,
            reason: '${e.key}: la carga no cierra en finally');
        expect(
            src.contains('setState(() => ${e.value} = false)'), isTrue,
            reason: '${e.key}: el finally no baja ${e.value}');
      }
    });

    test('panel_bloque2: las TRES cargas del archivo llevan '
        'la red', () {
      final src = _src('lib/ui/panel_bloque2.dart');
      expect('(Yunque R2-X1)'.allMatches(src).length, 3,
          reason: 'Casa, suplementos en mal estado y '
              'vencimientos: una red por carga');
      expect('Future<void> _cargarDatos()'.allMatches(src).length, 3);
    });

    test('nomina conserva su guarda de generación en la red '
        '(solo baja la generación vigente)', () {
      final src = _src('lib/ui/nomina.dart');
      expect(src.contains('gen == _genCarga'), isTrue,
          reason: 'la red no debe pisar la guarda M2-A A4');
      expect(src.contains('await _cargarDatos(gen);'), isTrue);
    });

    test('ajustes: sin bandera que bajar, el fallo de la '
        'carga del perfil se MARCA y se avisa (no defaults '
        'en silencio)', () {
      final src = _src('lib/ui/ajustes.dart');
      expect(src.contains('_cargaPerfilFallo = true'), isTrue);
      expect(src.contains('await _cargarDatos();'), isTrue);
    });
  });
}
