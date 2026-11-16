/// Lote 1.35 · SL-1 · A-17 (g06 nº17, BLOQUEANTE): doble toque
/// en «Convertir» de la lista OFFLINE duplicaba la conversión.
///
/// En la base (ead3d63), `_convirtiendoId` solo se activaba
/// DESPUÉS del diálogo de confirmación y de la lectura de
/// caché de la rama offline de `_convertirDesdeLista`: dos
/// toques rápidos pasaban la guarda (aún null), abrían dos
/// diálogos y nacían dos flujos de conversión (dos
/// InscribirScreen apiladas). La corrección activa la guarda
/// en la PRIMERA línea del handler y la libera en finally.
///
/// Camino real: lista pintada desde la caché (modo offline),
/// chip de candidato visible por visitas locales, detalle del
/// invitado en caché. Se toca el chip dos veces seguidas y se
/// confirma el diálogo: debe abrirse UN solo diálogo y UNA
/// sola inscripción.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/invitados.dart' as ui_inv;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> _invJson(String id, String nombre) => {
      'id': id,
      'nombre': nombre,
      'telefono': '58112233',
      'estado': 'activo',
      'creado_en': '2026-11-01T10:00:00',
      'caduca_en': '2027-01-01T10:00:00',
      'dias_restantes': 40,
    };

Map<String, dynamic> _detalleJson(String id, String nombre) => {
      'invitado': {
        'id': id,
        'nombre': nombre,
        'telefono': '58112233',
        'estado': 'activo',
        'creado_en': '2026-11-01T10:00:00',
        'caduca_en': '2027-01-01T10:00:00',
      },
    };

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('sl1_a17_docs');
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
    ui_inv.servicioInvitadosParaTest = null;
    ui_inv.conteoReportesPlusParaTest = () async => 0;
  });

  tearDown(() {
    ui_inv.servicioInvitadosParaTest = null;
    ui_inv.conteoReportesPlusParaTest = null;
  });

  testWidgets(
      'A-17: dos toques en «Convertir» (lista offline) abren '
      'UNA sola conversión', (tester) async {
    // Semillas locales: umbral de candidato en 2 y dos visitas
    // del invitado; detalle en caché para la conversión offline.
    await tester.runAsync(() async {
      await LocalDb.instance.setMeta('w7_umbral_visitas', '2');
      final ahora = DateTime.now().toUtc().toIso8601String();
      for (var i = 0; i < 2; i++) {
        await LocalDb.instance.registrarVisitaInvitado(
          clave: 'tel:58112233',
          invitadoId: 'inv-1',
          nombre: 'Invitado Uno',
          tsIso: ahora,
        );
      }
      await LocalDb.instance.guardarDetalleCacheInvitado(
          'inv-1', jsonEncode(_detalleJson('inv-1', 'Invitado Uno')));
    });

    // Primera carga CON red (pinta la lista fresca y carga las
    // visitas → chip de candidato). Después la red cae: la
    // recarga conserva la caché en modo offline.
    var enLinea = true;
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) async {
        if (!enLinea) throw Exception('sin red (test)');
        if (nombre == 'invitados_listar') {
          return {
            'invitados': [_invJson('inv-1', 'Invitado Uno')],
          };
        }
        if (nombre == 'invitados_resumen') return {'total': 1};
        throw Exception('RPC no simulada: $nombre');
      },
    );

    await tester.pumpWidget(
        const MaterialApp(home: ui_inv.InvitadosScreen()));
    await _drenar(tester);
    expect(find.text('⭐ Candidato a cliente · Convertir'),
        findsOneWidget,
        reason: 'el chip de candidato debe verse con red');

    // Cae la red y se recarga: la lista queda en modo offline
    // (caché) con el chip aún visible.
    enLinea = false;
    await tester.tap(find.byTooltip('Actualizar'));
    await _drenar(tester);
    expect(find.textContaining('Sin conexión'), findsWidgets,
        reason: 'la lista debe quedar en modo offline');
    final chip = find.text('⭐ Candidato a cliente · Convertir');
    expect(chip, findsOneWidget);

    // Ventana determinista del doble toque: se retiene la BD
    // con una transacción abierta (sqflite serializa las
    // operaciones: la lectura de caché de AMBOS handlers
    // queda aparcada detrás). Dos toques seguidos entran así
    // en el handler antes de que el primero pueda avanzar —
    // la ventana real del doble toque rápido en el gym.
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      unawaited(db.transaction((txn) async {
        await Future<void>.delayed(
            const Duration(milliseconds: 1500));
      }));
      // La transacción ya ocupa el ejecutor.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.tap(chip);
    await tester.tap(chip);
    // Se suelta la transacción (1,5 s) y ambos handlers avanzan.
    await _drenar(tester, vueltas: 16, ms: 200);

    // Debe haber UN solo diálogo de confirmación offline
    // (skipOffstage: false — con dos diálogos apilados, el de
    // abajo queda fuera de escena y el finder normal no lo ve).
    expect(
        find.text('Convertir sin conexión', skipOffstage: false),
        findsOneWidget,
        reason: 'dos toques no deben abrir dos diálogos: el '
            'segundo flujo es la conversión duplicada');

    // Se cancela el diálogo y no queda ningún otro detrás.
    await tester.tap(find.widgetWithText(TextButton, 'Ahora no'));
    await _drenar(tester, vueltas: 6);
    expect(
        find.text('Convertir sin conexión', skipOffstage: false),
        findsNothing,
        reason: 'no debe quedar un segundo diálogo del '
            'segundo toque');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  });
}
