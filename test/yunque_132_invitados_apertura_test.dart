/// 1.32 · Pieza 6 (H-B5-1 + H-B5-2, Corte A): Invitados abre
/// SIN esperar a la red. La lista y el detalle pintan su
/// caché local en el primer frame (en solo lectura) y la RPC
/// sustituye al llegar; el cierre de conversiones —
/// verificarConversiones, cuya confirmación es una escritura
/// SIN timeout a propósito — va en segundo plano y ya no
/// puede dejar el spinner eterno en el camino de pintado.
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

/// Drenaje realista (patrón de la oleada 3): los futuros de
/// sqflite_ffi no completan solo con pumps de la zona falsa.
Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _vaciarTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Map<String, dynamic> _invJson(String id, String nombre) => {
      'id': id,
      'nombre': nombre,
      'telefono': '58112233',
      'estado': 'activo',
      'creado_en': '2026-11-01T10:00:00',
      'caduca_en': '2026-12-01T10:00:00',
      'dias_restantes': 24,
    };

Map<String, dynamic> _detalleJson(String id, String nombre) => {
      'invitado': {
        'id': id,
        'nombre': nombre,
        'telefono': '58112233',
        'estado': 'activo',
        'creado_en': '2026-11-01T10:00:00',
        'caduca_en': '2026-12-01T10:00:00',
      },
    };

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('hb5_docs');
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
      'H-B5-1 lista: la caché pinta con la RPC colgada; al '
      'responder, la lista fresca la sustituye', (tester) async {
    // Caché sembrada con el servicio real (solo escribe en BD).
    await tester.runAsync(() async {
      await InvitadosService().guardarCacheInvitados(
        resumen: null,
        listaTodos: [
          InvitadoResumen.fromJson(_invJson('inv-c', 'Invitado Caché')),
        ],
      );
    });
    final colgada = Completer<dynamic>();
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) {
        if (nombre == 'invitados_listar') return colgada.future;
        if (nombre == 'invitados_resumen') return Future.value(null);
        throw Exception('RPC no simulada: $nombre');
      },
    );
    await tester.pumpWidget(
        const MaterialApp(home: ui_inv.InvitadosScreen()));
    await _drenar(tester);
    // La RPC sigue colgada y la caché YA está pintada.
    expect(find.text('Invitado Caché'), findsOneWidget,
        reason: 'la caché local pinta sin esperar a la red');
    // La red responde: la foto fresca sustituye a la caché.
    colgada.complete({
      'invitados': [_invJson('inv-f', 'Invitado Fresco')],
    });
    await _drenar(tester, vueltas: 6);
    expect(find.text('Invitado Fresco'), findsOneWidget);
    expect(find.text('Invitado Caché'), findsNothing);
    await _vaciarTimers(tester);
  });

  testWidgets(
      'H-B5-2: la confirmación de conversión colgada (escritura '
      'sin timeout) no bloquea la pintura de la lista',
      (tester) async {
    // Conversión opEncolada con su op ya aplicada: al abrir,
    // verificarConversiones intentará confirmar en el
    // servidor y esa escritura quedará colgada para siempre.
    await tester.runAsync(() async {
      await LocalDb.instance.queueOp(
        opUuid: 'op-conv-1',
        tipo: 'inscribir',
        payload: {
          'invitado_id': 'inv-1',
          'conversion_uuid': 'conv-1',
          'nombre': 'Invitado Uno',
        },
      );
      final d = await LocalDb.instance.db;
      await d.rawUpdate(
          "UPDATE ops_queue SET estado = 'aplicada', "
          'resultado_servidor = ? WHERE op_uuid = ?',
          ['{"cliente_id": 321}', 'op-conv-1']);
    });
    final confirmacionColgada = Completer<dynamic>();
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) {
        if (nombre == 'invitado_confirmar_conversion') {
          return confirmacionColgada.future; // nunca responde
        }
        if (nombre == 'invitados_listar') {
          return Future.value({
            'invitados': [_invJson('inv-1', 'Invitado Uno')],
          });
        }
        if (nombre == 'invitados_resumen') return Future.value(null);
        throw Exception('RPC no simulada: $nombre');
      },
    );
    await tester.pumpWidget(
        const MaterialApp(home: ui_inv.InvitadosScreen()));
    await _drenar(tester);
    // Con la escritura de confirmación colgada, la lista pinta
    // igual: la verificación va en segundo plano.
    expect(find.text('Invitado Uno'), findsOneWidget,
        reason: 'la escritura colgada no está en el camino de '
            'pintado');
    await _vaciarTimers(tester);
  });

  testWidgets(
      'H-B5-1 detalle: la caché pinta con la RPC colgada; al '
      'responder, el detalle fresco lo sustituye', (tester) async {
    await tester.runAsync(() async {
      await LocalDb.instance.guardarDetalleCacheInvitado(
          'inv-9',
          jsonEncode(_detalleJson('inv-9', 'Detalle Caché')));
    });
    final colgada = Completer<dynamic>();
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) {
        if (nombre == 'invitado_detalle') return colgada.future;
        throw Exception('RPC no simulada: $nombre');
      },
    );
    await tester.pumpWidget(const MaterialApp(
        home: ui_inv.InvitadoDetalleScreen(invitadoId: 'inv-9')));
    await _drenar(tester);
    expect(find.textContaining('Detalle Caché'), findsWidgets,
        reason: 'el detalle cacheado pinta sin esperar a la red');
    colgada.complete(_detalleJson('inv-9', 'Detalle Fresco'));
    await _drenar(tester, vueltas: 6);
    expect(find.textContaining('Detalle Fresco'), findsWidgets);
    expect(find.textContaining('Detalle Caché'), findsNothing);
    await _vaciarTimers(tester);
  });
}
