/// Yunque de App 1.31 — B-3a del lector de incidencias:
/// `TiposIncidenciaScreen` pintaba el fallo de carga como
/// lista vacía (familia B-15: error disfrazado de vacío).
/// Sin sesión (no-dueño) la pantalla sí pinta su guarda; la
/// rama de error del dueño exige sesión y queda cubierta por
/// el patrón estructural de las 3 superficies hermanas
/// (`_errorCarga` + `EstadoError` con Reintentar), verificado
/// aquí contra la fuente.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/incidencias/tipos_incidencia.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // Sin sesión: todo corre como NO dueño (como el banco).
    // ignore: deprecated_member_use
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  testWidgets('tipos: sin sesión pinta la guarda de dueño, '
      'no una lista vacía muda', (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: TiposIncidenciaScreen()));
    await tester.pump();
    expect(find.text('Solo el dueño ve esta pantalla.'),
        findsOneWidget);
    expect(find.byType(ReorderableListView), findsNothing);
  });

  test('B-3a estructural: la pantalla de tipos declara '
      'error visible con reintento (patrón B-15)', () {
    final src = _fuente('lib/ui/incidencias/tipos_incidencia.dart');
    expect(src, contains('String? _errorCarga'));
    expect(src, contains('EstadoError('));
    expect(src, contains('onReintentar: _cargar'));
    expect(src, contains("_errorCarga = '\$e'"));
  });

  test('A-3/B-3b estructural: las mutaciones y cargas de '
      'incidencias ya no fallan en silencio', () {
    final detalle =
        _fuente('lib/ui/incidencias/detalle_incidencia.dart');
    expect(detalle, contains("AppLog.error('incidencias', "
        "'comentario_fallo'"));
    expect(detalle, contains("AppLog.error('incidencias', "
        "'cambiar_estado_fallo'"));
    final lista =
        _fuente('lib/ui/incidencias/lista_incidencias.dart');
    expect(lista,
        contains("AppLog.error('incidencias', 'lote_fallo'"));
    final tipos =
        _fuente('lib/ui/incidencias/tipos_incidencia.dart');
    expect(tipos, contains("AppLog.error('tipos_incidencia', "
        "'cambiar_activo_fallo'"));
    expect(tipos, contains("AppLog.error('tipos_incidencia', "
        "'guardar_tipo_fallo'"));
    final editor =
        _fuente('lib/ui/incidencias/editar_incidencia.dart');
    expect(editor, contains("AppLog.error('incidencias', "
        "'cargar_tipos_fallo'"));
  });
}
