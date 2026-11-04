/// 1.23 Bloque 6 — W1: diagnóstico ante un espejo vacío.
///
/// - La regla de disparo es pura: espejo en 0 HOY con testigo
///   positivo (clientes tras la última bajada buena).
/// - El testigo SOLO se escribe con conteos positivos: una
///   bajada que llega vacía no borra la evidencia.
/// - La evaluación lee el estado real (espejo + metas + cola)
///   y arma la causa probable según las señales.
/// - La tarjeta pinta el diagnóstico cuando aplica y no pinta
///   nada en el estado normal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diagnostico_espejo.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/diagnostico_espejo_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('W1 regla pura', () {
    test('dispara solo con espejo en 0 y testigo positivo', () {
      expect(
          esEspejoVacioSospechoso(conteoActual: 0, clientesPrevios: 214),
          isTrue);
      expect(
          esEspejoVacioSospechoso(conteoActual: 0, clientesPrevios: 0),
          isFalse,
          reason: 'instalación nueva: 0 sin historia es normal');
      expect(
          esEspejoVacioSospechoso(conteoActual: 5, clientesPrevios: 214),
          isFalse);
    });

    test('causa probable según las señales', () {
      expect(causaProbableEspejoVacio(haySyncOk: false, opsPendientes: 0),
          contains('no registra ninguna sincronización'));
      expect(causaProbableEspejoVacio(haySyncOk: true, opsPendientes: 3),
          contains('aún no ha subido'));
      expect(causaProbableEspejoVacio(haySyncOk: true, opsPendientes: 0),
          contains('llegó sin ningún cliente'));
    });
  });

  group('W1 contra la BD', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      // La tarjeta lee AuthService().isOwner al pintar: sin
      // Supabase inicializado revienta (patrón de la suite).
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    setUp(() async {
      await LocalDb.resetParaTest();
    });

    Future<void> sembrarClientes(int n) async {
      final d = await LocalDb.instance.db;
      for (var i = 1; i <= n; i++) {
        await d.insert(
            'clientes', {'id': i, 'data': '{}', 'sync_seq': i});
      }
    }

    test('sin testigo no hay diagnóstico aunque el espejo '
        'esté vacío', () async {
      expect(await evaluarEspejoVacio(), isNull);
    });

    test('con clientes en el espejo no hay diagnóstico',
        () async {
      await sembrarClientes(3);
      await registrarTestigoClientes(3);
      expect(await evaluarEspejoVacio(), isNull);
    });

    test('espejo vaciado con testigo: diagnóstico completo',
        () async {
      await sembrarClientes(214);
      await registrarTestigoClientes(214);
      await LocalDb.instance.setMeta('last_pull_ok',
          DateTime.utc(2026, 11, 3, 12).toIso8601String());
      final d0 = await LocalDb.instance.db;
      await d0.delete('clientes');
      final diag = await evaluarEspejoVacio();
      expect(diag, isNotNull);
      expect(diag!.clientesPrevios, 214);
      expect(diag.ultimaSyncOk, isNotNull);
      expect(diag.opsPendientes, 0);
      expect(diag.causaProbable, contains('llegó sin ningún cliente'));
    });

    test('el testigo no se pisa con una bajada vacía', () async {
      await registrarTestigoClientes(120);
      await registrarTestigoClientes(0);
      final meta =
          await LocalDb.instance.getMeta('clientes_previos_buenos');
      expect(meta, '120',
          reason: 'una bajada vacía no borra la evidencia');
      await registrarTestigoClientes(121);
      expect(await LocalDb.instance.getMeta('clientes_previos_buenos'),
          '121');
    });

    testWidgets('la tarjeta pinta el diagnóstico y se oculta '
        'sin testigo', (t) async {
      // La BD es IO real: dentro de testWidgets se siembra y se
      // deja aterrizar el futuro de la tarjeta con runAsync
      // (el patrón del banco); los pumps de tiempo falso no
      // hacen avanzar el IO.
      await t.runAsync(() async {
        await sembrarClientes(7);
        await registrarTestigoClientes(7);
        final d0 = await LocalDb.instance.db;
        await d0.delete('clientes');
      });
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: TarjetaDiagnosticoEspejo()),
      ));
      // La evaluación de la tarjeta es IO real (la BD se recrea
      // tras el reset): se espera en bucle acotado a que pinte.
      for (var i = 0;
          i < 50 &&
              find
                  .text('Los clientes aparecen en cero')
                  .evaluate()
                  .isEmpty;
          i++) {
        await t.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.pump();
      }
      expect(find.text('Los clientes aparecen en cero'),
          findsOneWidget);
      expect(find.text('Sincronizar ahora'), findsOneWidget);

      // Sin testigo (vacío legítimo marcado), la tarjeta no
      // pinta nada.
      await t.runAsync(() async {
        await LocalDb.instance
            .setMeta('clientes_previos_buenos', '0');
      });
      // Con la misma posición y tipo, Flutter reutilizaría el
      // State (y su diagnóstico ya cargado): la segunda tarjeta
      // lleva key propia para nacer de cero, como al reabrir
      // la pantalla en la app.
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: TarjetaDiagnosticoEspejo(key: ValueKey('sin-testigo'))),
      ));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await t.pump();
      expect(find.text('Los clientes aparecen en cero'),
          findsNothing);
    });
  });
}
