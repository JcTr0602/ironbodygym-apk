/// Lote 1.35 · SL-10 — Incidencias.
///
/// BG-09: el modelo resuelve `warning`/`info` igual que el
/// selector del CRUD (una sola verdad por nombre de icono).
/// BG-10b: un comentario sin `creado_en` NO se fecha «hoy»:
/// hereda la fecha del padre o se muestra «sin fecha».
/// G13-3: el detalle humaniza estado/prioridad y el
/// historial `campo: antes → después`, como la lista.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/modelos/incidencia.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/incidencias/detalle_incidencia.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_lote135_sl10_incidencias.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void _mockAppLinks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (args, events) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (call) async => null);
}

Future<void> _asentar(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    if (find.text('Comentarios').evaluate().isNotEmpty) break;
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocalDb.nombreArchivoDbForzado = 'test_lote135_sl10_incidencias.db';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _mockAppLinks();
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('BG-09 · iconoData del modelo', () {
    test('warning e info se resuelven como en el CRUD', () {
      expect(
        const TipoIncidencia(id: '1', nombre: 'Aviso', icono: 'warning')
            .iconoData,
        Icons.warning_amber_rounded,
      );
      expect(
        const TipoIncidencia(id: '2', nombre: 'Info', icono: 'info')
            .iconoData,
        Icons.info_rounded,
      );
      // Los ya conocidos no cambian.
      expect(
        const TipoIncidencia(id: '3', nombre: 'X', icono: 'build')
            .iconoData,
        Icons.build_rounded,
      );
      expect(
        const TipoIncidencia(id: '4', nombre: 'X').iconoData,
        Icons.label_rounded,
      );
    });
  });

  group('BG-10b + G13-3 · detalle de incidencia', () {
    testWidgets(
        'comentario sin creado_en no se fecha hoy; estado, prioridad '
        'e historial van humanizados', (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
        final d = await LocalDb.instance.db;
        await d.insert('incidencias_local', {
          'id': 'inc-sl10',
          'tipo_id': null,
          'descripcion': 'Máquina de remo rota',
          'detalle': null,
          'estado': 'en_proceso',
          'asignado_a': null,
          'prioridad': 'alta',
          'fecha_limite': null,
          'ubicacion': null,
          'creada_por': 'Duany',
          'creada_en': null,
          'resuelta_por': null,
          'resuelta_en': null,
          'nota_resolucion': null,
          'version': 1,
          'sync_estado': 'synced',
          'actualizado_en': null,
        });
        await d.insert('incidencias_comentarios', {
          'id': 'com-sl10',
          'incidencia_id': 'inc-sl10',
          'texto': 'Comentario sin fecha de origen',
          'creado_por': 'Duany',
          // La columna local es NOT NULL: el hueco real
          // llega como cadena vacía/ilegible del espejo.
          'creado_en': '',
          'sync_estado': 'pending',
        });
        await d.insert('incidencias_historial', {
          'id': 'his-sl10',
          'incidencia_id': 'inc-sl10',
          'campo': 'estado',
          'valor_anterior': 'pendiente',
          'valor_nuevo': 'en_proceso',
          'cambiado_por': 'Duany',
          'cambiado_en': '2026-11-11T09:30:00',
        });
      });
      await tester.pumpWidget(const MaterialApp(
        home: DetalleIncidenciaScreen(incidenciaId: 'inc-sl10'),
      ));
      await _asentar(tester);

      // G13-3: estado y prioridad como en la lista, no claves.
      expect(find.text('En proceso'), findsWidgets);
      expect(find.text('Alta'), findsWidgets);
      expect(find.text('en_proceso'), findsNothing);
      // G13-3: el historial traduce campo y valores.
      expect(find.text('Estado: Pendiente → En proceso'), findsOneWidget);
      expect(find.text('estado: pendiente → en_proceso'), findsNothing);

      // BG-10b: el comentario sin fecha dice «sin fecha» y
      // NO la fecha de hoy (que el código viejo inventaba).
      expect(find.textContaining('sin fecha'), findsWidgets);
      final hoy = ahoraHabana();
      final hoyTexto = '${hoy.day}/${hoy.month}';
      expect(find.textContaining(hoyTexto), findsNothing);
    });
  });
}
