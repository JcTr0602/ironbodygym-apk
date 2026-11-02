/// 1.21 — Candado de acceso: evaluación pura por alcance y
/// precedencia (CD/R5), caducidad juzgada con la hora del
/// servidor pasada por el llamador (CD-02), reconocimiento de
/// la pausa en el resultado del servidor, retención sin quemar
/// intentos y despertar al desbloquear (CD-01), y la capa que
/// absorbe los toques (CD-03).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_bloqueo.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/capa_candado.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Map<String, dynamic> _fila({
  String alcance = 'global',
  String app = 'ambas',
  String? objetivo,
  String? mensaje,
  Object? activo = 1,
  String? expiraTs,
}) {
  return {
    'alcance': alcance,
    'app': app,
    if (objetivo != null) 'objetivo': objetivo,
    if (mensaje != null) 'mensaje': mensaje,
    'activo': activo,
    if (expiraTs != null) 'expira_ts': expiraTs,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => Directory.systemTemp.path);
  });

  final ahora = DateTime.utc(2026, 11, 2, 12);

  group('evaluarBloqueoLocal', () {
    test('global activo bloquea a cualquier entrenador', () {
      final b = evaluarBloqueoLocal(
        [_fila(mensaje: 'Cerrado por inventario')],
        telegramId: 111,
        ahoraServidor: ahora,
      );
      expect(b, isNotNull);
      expect(b!.mensaje, 'Cerrado por inventario');
    });

    test('sin mensaje del dueño se usa el texto por defecto', () {
      final b = evaluarBloqueoLocal([_fila()],
          telegramId: 111, ahoraServidor: ahora);
      expect(b!.mensaje, kMensajeCandadoDefecto);
    });

    test('app=clientes no bloquea Gestión; app=gestion sí', () {
      expect(
        evaluarBloqueoLocal([_fila(alcance: 'app', app: 'clientes')],
            telegramId: 111, ahoraServidor: ahora),
        isNull,
      );
      expect(
        evaluarBloqueoLocal([_fila(alcance: 'app', app: 'gestion')],
            telegramId: 111, ahoraServidor: ahora),
        isNotNull,
      );
    });

    test('rol entrenador bloquea; rol cliente no aplica a Gestión',
        () {
      expect(
        evaluarBloqueoLocal(
            [_fila(alcance: 'rol', objetivo: 'entrenador')],
            telegramId: 111,
            ahoraServidor: ahora),
        isNotNull,
      );
      expect(
        evaluarBloqueoLocal([_fila(alcance: 'rol', objetivo: 'cliente')],
            telegramId: 111, ahoraServidor: ahora),
        isNull,
      );
    });

    test('persona solo bloquea al objetivo', () {
      final filas = [_fila(alcance: 'persona', objetivo: '222')];
      expect(
          evaluarBloqueoLocal(filas,
              telegramId: 111, ahoraServidor: ahora),
          isNull);
      expect(
          evaluarBloqueoLocal(filas,
              telegramId: 222, ahoraServidor: ahora),
          isNotNull);
    });

    test('precedencia: el mensaje mostrado es el de persona', () {
      final b = evaluarBloqueoLocal(
        [
          _fila(mensaje: 'mensaje global'),
          _fila(
              alcance: 'persona',
              objetivo: '111',
              mensaje: 'mensaje personal'),
        ],
        telegramId: 111,
        ahoraServidor: ahora,
      );
      expect(b!.alcance, 'persona');
      expect(b.mensaje, 'mensaje personal');
    });

    test('caducidad pasada para el servidor no bloquea', () {
      final filas = [_fila(expiraTs: '2026-11-02T11:00:00.000Z')];
      expect(
          evaluarBloqueoLocal(filas,
              telegramId: 111, ahoraServidor: ahora),
          isNull);
      // Con la hora del servidor ANTES de la caducidad, sí.
      expect(
          evaluarBloqueoLocal(filas,
              telegramId: 111,
              ahoraServidor: DateTime.utc(2026, 11, 2, 10)),
          isNotNull);
    });

    test('inactiva no bloquea; activo booleano también vale', () {
      expect(
          evaluarBloqueoLocal([_fila(activo: 0)],
              telegramId: 111, ahoraServidor: ahora),
          isNull);
      expect(
          evaluarBloqueoLocal([_fila(activo: true)],
              telegramId: 111, ahoraServidor: ahora),
          isNotNull);
    });
  });

  group('pausa del servidor en el resultado', () {
    test('esAccesoPausado reconoce el código y el error', () {
      expect(
          esAccesoPausado({
            'ok': false,
            'codigo': 'ACCESO_PAUSADO',
            'error': 'ACCESO_PAUSADO: acceso pausado por el dueño',
          }),
          isTrue);
      expect(
          esAccesoPausado({'ok': false, 'error': 'CLIENTE_PROTEGIDO'}),
          isFalse);
      expect(esAccesoPausado(null), isFalse);
      expect(esAccesoPausado('ACCESO_PAUSADO'), isFalse);
    });

    test('la fila pausada del RPC se normaliza como pendiente',
        () {
      final rec = normalizarFilaResultado({
        'op_uuid': 'u1',
        'aplicada': false,
        'resultado': {
          'ok': false,
          'codigo': 'ACCESO_PAUSADO',
          'reintentable': true,
        },
      });
      expect(rec.estado, 'pendiente');
      expect(esAccesoPausado(rec.resultado), isTrue);
    });
  });

  group('retención y despertar en ops_queue', () {
    test('retenerOpPausada no toca intentos ni marca error',
        () async {
      await _preparar();
      final db = LocalDb.instance;
      await db.queueOp(
          opUuid: 'op-pausa-1',
          tipo: 'pago_mensual',
          payload: {'cliente_id': 1});
      await db.retenerOpPausada(
          'op-pausa-1', '2026-11-02T18:00:00.000-05:00');
      final d = await db.db;
      final filas = await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-pausa-1']);
      expect(filas, hasLength(1));
      expect(filas.first['estado'], 'pendiente');
      expect(filas.first['intentos'], 0);
      expect(filas.first['error'], isNull);
      expect(filas.first['proximo_reintento'],
          '2026-11-02T18:00:00.000-05:00');
    });

    test('despertarOpsPausadas solo despierta las pausadas',
        () async {
      await _preparar();
      final db = LocalDb.instance;
      await db.queueOp(
          opUuid: 'op-pausa-2', tipo: 'pago_mensual', payload: {});
      await db.queueOp(
          opUuid: 'op-normal-2', tipo: 'pago_mensual', payload: {});
      final d = await db.db;
      await d.rawUpdate(
          'UPDATE ops_queue SET proximo_reintento = ?, '
          'resultado_servidor = ? WHERE op_uuid = ?',
          [
            '2026-11-02T18:00:00.000-05:00',
            jsonEncode({'ok': false, 'codigo': 'ACCESO_PAUSADO'}),
            'op-pausa-2',
          ]);
      await d.rawUpdate(
          'UPDATE ops_queue SET proximo_reintento = ? '
          'WHERE op_uuid = ?',
          ['2026-11-02T18:00:00.000-05:00', 'op-normal-2']);
      final n = await db.despertarOpsPausadas();
      expect(n, 1);
      final filas = await d.query('ops_queue',
          columns: ['op_uuid', 'proximo_reintento'],
          orderBy: 'op_uuid ASC');
      // op-normal-2 conserva su backoff; op-pausa-2 quedó libre.
      expect(filas[0]['proximo_reintento'], isNotNull);
      expect(filas[1]['proximo_reintento'], isNull);
    });
  });

  testWidgets('la capa muestra el candado y absorbe los toques',
      (tester) async {
    var toques = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Center(
              child: ElevatedButton(
                onPressed: () => toques++,
                child: const Text('debajo'),
              ),
            ),
            const Positioned.fill(
              child: CapaCandado(
                bloqueo: BloqueoVigente(
                  alcance: 'global',
                  objetivo: null,
                  mensaje: 'Cerrado por inventario',
                  expiraEn: null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    expect(find.text('Cerrado por inventario'), findsOneWidget);
    await tester.tap(find.text('debajo'), warnIfMissed: false);
    await tester.pump();
    expect(toques, 0);
  });
}
