/// 1.32 · Escalón 1 — H-MUERTE-3: la muerte por bump de una
/// mutación sobre cliente existente pide el pull protegido AT-04.
///
/// El defecto (Y-ERRORES Gestión): `_aplicarEstadoServidor`
/// marcaba `_pullProtegidoPendiente` para las mutaciones sobre
/// cliente existente (AT-04), pero `_bumpConReversion` —la muerte
/// local por agotamiento/auth, que jamás pasa por el estado del
/// servidor— no marcaba nada: la edición optimista falsa quedaba
/// pintada hasta que la fila del cliente cambiara en el servidor
/// por otro motivo.
///
/// Se ejerce por la costura H2 (`bumpConReversionParaTest`) y se
/// observa la bandera por la costura nueva
/// (`pullProtegidoPendienteParaTest`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<void> _sembrarOp(
  Database db, {
  required String uuid,
  required String tipo,
  Map<String, dynamic> payload = const {},
}) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': 'enviada',
    'creada_ts': '2026-11-11T10:00:00-04:00',
  });
}

Future<String?> _estadoOp(Database db, String uuid) async {
  final filas = await db.query('ops_queue',
      columns: ['estado'], where: 'op_uuid=?', whereArgs: [uuid]);
  return filas.single['estado'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('H-MUERTE-3 · bump de mutación sobre cliente existente', () {
    late Database db;

    setUp(() async {
      db = await _abrirDbVacia();
      SyncEngine.instance.limpiarPullProtegidoParaTest();
    });

    for (final tipo in [
      'editar_cliente',
      'cambiar_estado',
      'update_cliente_sensible',
      'regalar_mes_cumpleanos',
    ]) {
      test('bump a revisión de $tipo enciende el pull protegido AT-04',
          () async {
        await _sembrarOp(db,
            uuid: 'op-e1-m3-$tipo',
            tipo: tipo,
            payload: {'cliente_id': 42});
        await SyncEngine.instance.bumpConReversionParaTest(
          {
            'op_uuid': 'op-e1-m3-$tipo',
            'tipo': tipo,
            'payload': jsonEncode({'cliente_id': 42}),
          },
          'HTTP 422',
          httpStatus: 422,
        );
        expect(await _estadoOp(db, 'op-e1-m3-$tipo'), 'necesita_revision');
        expect(SyncEngine.instance.pullProtegidoPendienteParaTest, isTrue,
            reason: 'la muerte por bump de $tipo debe pedir el mismo '
                'pull protegido que la rama de rechazo del servidor '
                '(AT-04); sin la bandera, el cambio optimista queda '
                'pintado en el espejo');
      });
    }

    test('bump a revisión de un tipo fuera del conjunto AT-04 no '
        'enciende la bandera', () async {
      await _sembrarOp(db,
          uuid: 'op-e1-m3-fuera', tipo: 'crear_cliente', payload: {});
      await SyncEngine.instance.bumpConReversionParaTest(
        {
          'op_uuid': 'op-e1-m3-fuera',
          'tipo': 'crear_cliente',
          'payload': jsonEncode({}),
        },
        'HTTP 422',
        httpStatus: 422,
      );
      expect(await _estadoOp(db, 'op-e1-m3-fuera'), 'necesita_revision');
      expect(SyncEngine.instance.pullProtegidoPendienteParaTest, isFalse,
          reason: 'crear_cliente no muta un cliente existente: su '
              'reflejo optimista se limpia borrando la fila temporal, '
              'sin pull protegido');
    });
  });
}
