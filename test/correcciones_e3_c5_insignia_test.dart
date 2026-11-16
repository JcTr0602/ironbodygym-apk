/// 1.35 (corrección E3, C5-02 del Yunque de Cambios): la
/// insignia de Vencimientos del pilar solo se recontaba
/// al nacer y cuando la sync quedaba en reposo. Marcar
/// avisado es una escritura LOCAL y cobrar desde la ficha
/// tampoco recuenta: la insignia seguía prometiendo el
/// trabajo ya hecho.
///
/// Corrección: el pilar recuenta al cambiar de segmento
/// y al aplicar un destino, y ListasScreen avisa con
/// `alCambiarDatos` tras marcar/desmarcar, cobrar y
/// volver de la ficha; el pilar embebido lo pasa.
///
/// Discriminante: sobre la base de074a6, tras marcar al
/// atrasado en la BD y dar una vuelta por otro segmento,
/// la insignia sigue en 3 (rojo). El test B no compila
/// en la base (el parámetro no existe) — se anota como
/// tal; el A es el discriminante conductual.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/listas.dart';
import 'package:ironbody_gym/ui/pilar_clientes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// La misma siembra de UI-08: la insignia nace en 3
/// (vence hoy + atrasado sin avisar + atrasado viejo;
/// el avisado y el al día no cuentan).
Future<void> _sembrar(WidgetTester tester) async {
  const canalEventos = EventChannel('com.llfbandit.app_links/events');
  const canalMensajes = MethodChannel('com.llfbandit.app_links/messages');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          canalEventos, MockStreamHandler.inline(onListen: (_, __) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(canalMensajes, (_) async => null);
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    final hoy = ahoraHabana();
    Future<void> cli(int id, String nombre, DateTime hasta) =>
        LocalDb.instance.upsertMirror('clientes', id, {
          'id': id,
          'nombre': nombre,
          'telefono': '5819000$id',
          'pagado_hasta': _iso(hasta),
          'estado': 'activo',
          'activo': 1,
        }, 1);
    await cli(1, 'Vence Hoy', hoy);
    await cli(2, 'Atrasado Sin Avisar',
        hoy.subtract(const Duration(days: 10)));
    await cli(3, 'Atrasado Avisado',
        hoy.subtract(const Duration(days: 10)));
    await cli(4, 'Al Dia', hoy.add(const Duration(days: 10)));
    await cli(5, 'Atrasado Viejo',
        hoy.subtract(const Duration(days: 40)));
    await LocalDb.instance.marcarAvisado(3,
        pagadoHasta: _iso(hoy.subtract(const Duration(days: 10))));
  });
}

Finder _enInsignia(String texto) => find.descendant(
    of: find.byType(Badge), matching: find.text(texto));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E3 · C5-02 (A): marcar avisado y dar la '
      'vuelta por otro segmento recuenta la insignia',
      (tester) async {
    await _sembrar(tester);
    // El pilar vive dentro de un Scaffold en la app (sus
    // chips y hojas exigen el Material ancestro).
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: PilarClientes(esDueno: true))));
    await tester.pumpAndSettle();
    expect(_enInsignia('3'), findsOneWidget,
        reason: 'precondición: la insignia nace en 3');

    // El trabajo se hace FUERA del pilar (la marca es
    // local: ni la sync ni el pilar se enteran solos).
    final hoy = ahoraHabana();
    await tester.runAsync(() async {
      await LocalDb.instance.marcarAvisado(2,
          pagadoHasta:
              _iso(hoy.subtract(const Duration(days: 10))));
    });

    // La vuelta por otro segmento y de regreso.
    await tester.tap(find.text('Invitados/Plus'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vencimientos'));
    await tester.pumpAndSettle();

    expect(_enInsignia('2'), findsOneWidget,
        reason: 'al volver, la insignia ya no promete el '
            'aviso que se acaba de marcar');
    expect(_enInsignia('3'), findsNothing);
  });

  testWidgets('E3 · C5-02 (B): ListasScreen avisa con '
      'alCambiarDatos al marcar un avisado por la vía real',
      (tester) async {
    await _sembrar(tester);
    var avisos = 0;
    await tester.pumpWidget(MaterialApp(
      home: ListasScreen(
        embebida: true,
        inicial: 2, // Atrasados <30d
        alCambiarDatos: () => avisos++,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Atrasado Sin Avisar'), findsWidgets);
    // El botón de avisar de la fila sin avisar (el otro
    // atrasado ya está avisado: su tooltip es el de quitar).
    await tester.tap(find.byTooltip('Marcar como avisado'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Solo marcar como avisado'));
    await tester.pumpAndSettle();
    expect(avisos, greaterThanOrEqualTo(1),
        reason: 'marcar en local avisa al contenedor en el '
            'acto, sin esperar a la sync');
  });
}
