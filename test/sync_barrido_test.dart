/// Tests v1.8.0 (Frente 5, punto E) — barrido de confirmación.
///
/// Caso de campo que se reproduce (2026-10-23): la op
/// confirmar_entrega salió del teléfono, el puente la APLICÓ en
/// el servidor (11:42) y el teléfono la siguió mostrando
/// «pendiente» a las 12:34 porque ningún ciclo llegó a confirmar
/// su estado local. El barrido verifica contra el servidor TODAS
/// las ops locales no terminales (incluidas las 'enviada' con la
/// confirmación perdida) y aplica localmente el estado que el
/// servidor ya decidió. La verificación se inyecta (seam, mismo
/// patrón que manifiestoDiarioSiToca): sin red real en tests.
///
/// TRIESTADO (veredicto de Argón): si la verificación falla o el
/// servidor aún dice «pendiente», no se marca NADA.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _insertarOp({
  required String uuid,
  required String tipo,
  required String estado,
  String? userId,
  String? enviadaTs,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode({'cliente_id': 7}),
    'estado': estado,
    'user_id': userId,
    'enviada_ts': enviadaTs,
    'creada_ts': '2026-10-23T09:38:00.000-04:00',
  });
}

Future<String?> _estadoDe(String uuid) async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('ops_queue',
      columns: ['estado'], where: 'op_uuid = ?', whereArgs: [uuid]);
  return rows.isEmpty ? null : rows.first['estado'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('(iii) op enviada con la confirmación perdida converge: '
      'el servidor la aplicó y el barrido la marca aplicada',
      () async {
    await _bdVacia();
    // Réplica del caso de campo: confirmar_entrega quedó en
    // 'enviada' (salió y el servidor la aplicó), sin confirmación
    // local durante ~1 hora.
    await _insertarOp(
      uuid: 'op-campo-1',
      tipo: 'confirmar_entrega',
      estado: 'enviada',
      enviadaTs: '2026-10-23T11:38:00.000-04:00',
    );
    expect(await LocalDb.instance.countPendingOps(), 1);

    List<String>? consultados;
    final res = await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async {
        consultados = uuids;
        return {
          'op-campo-1': (
            estado: 'aplicada',
            resultado: {
              'ok': true,
              'resultado': {'items': 5, 'total': 7200.0},
            },
            error: null,
          ),
        };
      },
    );

    // El barrido consultó por la op atascada (no solo por las
    // «por enviar») y la confirmó.
    expect(consultados, contains('op-campo-1'));
    expect(res.confirmadas, 1);
    expect(res.uuids, contains('op-campo-1'));
    expect(await _estadoDe('op-campo-1'), 'aplicada');
    expect(await LocalDb.instance.countPendingOps(), 0);
    // El resultado del servidor quedó en la caché local.
    final db = await LocalDb.instance.db;
    final rows = await db.query('ops_queue',
        columns: ['resultado_servidor'],
        where: 'op_uuid = ?',
        whereArgs: ['op-campo-1']);
    expect(rows.first['resultado_servidor'], isNotNull);
  });

  test('triestado: si el servidor aún dice «pendiente», no se '
      'marca nada', () async {
    await _bdVacia();
    await _insertarOp(
      uuid: 'op-vuelo-1',
      tipo: 'pago_mensual',
      estado: 'enviada',
      enviadaTs: '2026-10-23T11:38:00.000-04:00',
    );
    final res = await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async => {
        'op-vuelo-1': (estado: 'pendiente', resultado: null, error: null),
      },
    );
    expect(res.confirmadas, 0);
    expect(await _estadoDe('op-vuelo-1'), 'enviada');
    expect(await LocalDb.instance.countPendingOps(), 1);
  });

  test('triestado: si la verificación falla (red), no se marca '
      'nada y no se propaga', () async {
    await _bdVacia();
    await _insertarOp(
      uuid: 'op-sinred-1',
      tipo: 'pago_mensual',
      estado: 'pendiente',
    );
    final res = await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async => throw Exception('sin red (fake)'),
    );
    expect(res.confirmadas, 0);
    expect(await _estadoDe('op-sinred-1'), 'pendiente');
  });

  test('sin ops no terminales: el barrido no consulta al servidor',
      () async {
    await _bdVacia();
    var llamo = false;
    final res = await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async {
        llamo = true;
        return {};
      },
    );
    expect(res.confirmadas, 0);
    expect(llamo, isFalse);
  });

  group('conteoPendientesSync (categorías del resumen)', () {
    test('excluyentes y exhaustivas respecto a countPendingOps',
        () async {
      await _bdVacia();
      await _insertarOp(
          uuid: 'c-enviada',
          tipo: 'pago_mensual',
          estado: 'enviada',
          userId: 'u1');
      await _insertarOp(
          uuid: 'c-pendiente',
          tipo: 'pago_mensual',
          estado: 'pendiente',
          userId: 'u1');
      await _insertarOp(
          uuid: 'c-error',
          tipo: 'pago_mensual',
          estado: 'error',
          userId: 'u1');
      await _insertarOp(
          uuid: 'c-ajena',
          tipo: 'pago_mensual',
          estado: 'pendiente',
          userId: 'u2');
      await _insertarOp(
          uuid: 'c-aplicada',
          tipo: 'pago_mensual',
          estado: 'aplicada',
          userId: 'u1');
      final c = await LocalDb.instance.conteoPendientesSync('u1');
      expect(c.esperandoConfirmacion, 1);
      expect(c.porSubir, 1);
      expect(c.conError, 1);
      expect(c.deOtroUsuario, 1);
      final total = c.esperandoConfirmacion +
          c.porSubir +
          c.conError +
          c.deOtroUsuario;
      expect(total, await LocalDb.instance.countPendingOps());
    });
  });
}
