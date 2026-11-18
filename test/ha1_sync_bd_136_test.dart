/// H-A1 (1.36): pruebas de BD de las filas Hy4 sync/BD —
/// 136-930 (retención solo en estados vivos), 136-929
/// (reintento de necesita_revision + predicado de autor del
/// conteo de revisión) y 136-925 (día de negocio Habana en
/// TODAS las filas de pagos).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
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

Future<void> _opCruda(String uuid, String estado,
    {String? userId, String? error, String? codigoError}) async {
  final d = await LocalDb.instance.db;
  await d.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'pago_mensual',
    'payload': '{}',
    'estado': estado,
    'creada_ts': '2026-11-10T10:00:00.000',
    'intentos': 3,
    'user_id': userId,
    'error': error,
    'codigo_error': codigoError,
    'proximo_reintento': '2026-11-10T12:00:00.000',
  });
}

Future<Map<String, dynamic>> _op(String uuid) async {
  final d = await LocalDb.instance.db;
  final f = await d.query('ops_queue',
      where: 'op_uuid = ?', whereArgs: [uuid]);
  return f.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => Directory.systemTemp.path);
  });

  group('136-930: retenerOpPausada solo toca estados vivos', () {
    test('una op APLICADA no revive por una retención tardía',
        () async {
      await _preparar();
      await _opCruda('op-aplicada', 'aplicada');
      await LocalDb.instance.retenerOpPausada(
          'op-aplicada', '2026-11-10T18:00:00.000');
      final f = await _op('op-aplicada');
      expect(f['estado'], 'aplicada',
          reason: 'la retención tardía no resucita terminales');
      expect(f['proximo_reintento'], '2026-11-10T12:00:00.000',
          reason: 'ni siquiera le mueve el próximo intento');
    });

    test('una op en ERROR sí se retiene (vuelve a pendiente '
        'con su hora)', () async {
      await _preparar();
      await _opCruda('op-error', 'error');
      await LocalDb.instance
          .retenerOpPausada('op-error', '2026-11-10T18:00:00.000');
      final f = await _op('op-error');
      expect(f['estado'], 'pendiente');
      expect(f['proximo_reintento'], '2026-11-10T18:00:00.000');
    });

    test('necesita_revision no se convierte en pendiente por '
        'una retención', () async {
      await _preparar();
      await _opCruda('op-rev', 'necesita_revision');
      await LocalDb.instance
          .retenerOpPausada('op-rev', '2026-11-10T18:00:00.000');
      final f = await _op('op-rev');
      expect(f['estado'], 'necesita_revision');
    });
  });

  group('136-929: reintentarOp y conteo de revisión', () {
    test('reintentarOp reactiva necesita_revision limpiando '
        'su error guardado', () async {
      await _preparar();
      await _opCruda('op-rev2', 'necesita_revision',
          error: 'duplicado sospechoso', codigoError: 'REVISION');
      await LocalDb.instance.reintentarOp('op-rev2');
      final f = await _op('op-rev2');
      expect(f['estado'], 'pendiente');
      expect(f['error'], isNull);
      expect(f['codigo_error'], isNull);
      expect(f['proximo_reintento'], isNull);
      expect(f['intentos'], 0);
    });

    test('reintentarOp sigue sin resucitar una aplicada',
        () async {
      await _preparar();
      await _opCruda('op-ok', 'aplicada');
      await LocalDb.instance.reintentarOp('op-ok');
      final f = await _op('op-ok');
      expect(f['estado'], 'aplicada');
    });

    test('el conteo de revisión usa el predicado estricto de '
        'la lista: la revisión sin autor no se atribuye',
        () async {
      await _preparar();
      await _opCruda('rev-mia', 'necesita_revision', userId: 'u1');
      await _opCruda('rev-sin-autor', 'necesita_revision');
      await _opCruda('rev-ajena', 'necesita_revision',
          userId: 'u2');
      await _opCruda('err-sin-autor', 'error');
      final c = await LocalDb.instance.conteoPendientesSync('u1');
      // La lista opsNecesitanRevision(userId:'u1') trae SOLO
      // rev-mia: el conteo de «con problema» debe decir
      // 1 (rev-mia) + 1 (err-sin-autor, predicado laxo del
      // error, como siempre) = 2, no 3.
      expect(c.conError, 2,
          reason: 'la revisión sin autor no cuenta como mía; '
              'el error sin autor sí (predicado histórico)');
      final lista =
          await LocalDb.instance.opsNecesitanRevision(userId: 'u1');
      expect(lista.map((f) => f['op_uuid']), ['rev-mia']);
    });
  });

  group('136-925: el día de negocio Habana manda en TODAS '
      'las filas de pagos', () {
    // Fila LEGADA: la columna `fecha` guarda el día crudo del
    // texto (2026-11-01) pero el instante UTC del JSON es
    // 2026-10-31 en La Habana (02:30Z = 21:30 del 31-oct en
    // horario de verano, UTC-4 hasta el 1-nov 05:00Z... el
    // instante 02:30Z del 1-nov aún es UTC-4 → 22:30 del 31).
    Future<void> sembrarLegado() async {
      final d = await LocalDb.instance.db;
      await d.insert('pagos', {
        'id': 501,
        'data': jsonEncode({
          'id': 501,
          'fecha': '2026-11-01T02:30:00.000Z',
          'monto': 2000,
          'metodo': 'efectivo',
          'telegram_user_id': 111,
          'cliente_id': 7,
        }),
        'sync_seq': 1,
        'fecha': '2026-11-01', // columna cruda legada (mal)
        'cliente_id': 7,
        'telegram_user_id': 111,
        'metodo': 'efectivo',
      });
      await d.insert('pagos', {
        'id': 502,
        'data': jsonEncode({
          'id': 502,
          'fecha': '2026-10-31',
          'monto': 2000,
          'metodo': 'efectivo',
          'telegram_user_id': 111,
          'cliente_id': 7,
        }),
        'sync_seq': 2,
        'fecha': '2026-10-31',
        'cliente_id': 7,
        'telegram_user_id': 111,
        'metodo': 'efectivo',
      });
    }

    test('pagosDelDia: la legada cae en SU día de negocio '
        '(31-oct), no en el de su columna', () async {
      await _preparar();
      await sembrarLegado();
      final del31 =
          await LocalDb.instance.pagosDelDia('2026-10-31');
      expect(del31.map((e) => e['id']), containsAll([501, 502]),
          reason: 'ambas filas son del 31 en hora de negocio');
      final del1 =
          await LocalDb.instance.pagosDelDia('2026-11-01');
      expect(del1, isEmpty,
          reason: 'ninguna fila es del 1-nov en hora de negocio');
    });

    test('pagosPorDiaYEntrenador aplica el mismo filtro fino',
        () async {
      await _preparar();
      await sembrarLegado();
      final r = await LocalDb.instance
          .pagosPorDiaYEntrenador('2026-10-31', 111);
      expect(r.map((e) => e['id']), containsAll([501, 502]));
      final r1 = await LocalDb.instance
          .pagosPorDiaYEntrenador('2026-11-01', 111);
      expect(r1, isEmpty);
    });

    test('mirrorPorFecha (pagos) también filtra fino a todas',
        () async {
      await _preparar();
      await sembrarLegado();
      final r = await LocalDb.instance.mirrorPorFecha(
          'pagos', 'fecha', '2026-10-31', '2026-10-31');
      expect(r.map((e) => e['id']), containsAll([501, 502]));
    });
  });
}
