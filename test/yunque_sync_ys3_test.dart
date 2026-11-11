/// Yunque de Sincronización · YS-3 — el rechazo de una op de
/// incidencia resuelve su fila local (IMP-5, residuo A).
///
/// El defecto: `_aplicarEstadoServidor` extraía el id de la
/// incidencia SOLO en la rama aplicada. Si el servidor
/// rechazaba la op (o la dejaba en revisión), la fila local
/// quedaba en `sync_estado='pending'` para siempre — y
/// `_pullIncidencias` congela el avance de su cursor ante
/// cualquier fila 'pending': la fila eterna fabricaba la
/// re-descarga perpetua de la ventana (b).
///
/// Se prueba por la costura del barrido (verificador
/// inyectado), el mismo camino real que confirma las ops.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

Future<void> _siembra(
  Database db, {
  required String uuid,
  required String tipo,
  required Map<String, dynamic> payload,
  String incidenciaId = 'inc-ys3',
}) async {
  await db.insert('incidencias_local', {
    'id': incidenciaId,
    'tipo': 'sync',
    'descripcion': 'Incidencia de prueba YS-3',
    'creada_por': 'test',
    'creada_en': '2026-11-10T10:00:00-04:00',
    'sync_estado': 'pending',
    'sincronizada': 0,
  });
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': 'enviada',
    'creada_ts': '2026-11-10T10:00:00-04:00',
  });
}

Future<Map<String, dynamic>> _filaIncidencia(
    Database db, String id) async {
  final filas = await db.query('incidencias_local',
      where: 'id=?', whereArgs: [id]);
  return filas.single;
}

Future<String?> _estadoOp(Database db, String uuid) async {
  final filas = await db.query('ops_queue',
      columns: ['estado'], where: 'op_uuid=?', whereArgs: [uuid]);
  return filas.single['estado'] as String?;
}

Future<void> _barrer(String estado, dynamic resultado) async {
  await SyncEngine.instance.barridoConfirmacion(
    verificar: (uuids) async => {
      for (final u in uuids)
        u: (estado: estado, resultado: resultado, error: null),
    },
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  test('YS-3: op de incidencia RECHAZADA resuelve su fila local '
      'con el motivo', () async {
    final db = await _abrirDbVacia();
    await _siembra(db,
        uuid: 'op-ys3-rechazo',
        tipo: 'crear_incidencia',
        payload: {'id': 'inc-ys3', 'descripcion': 'x'});
    await _barrer('rechazada', {'ok': false, 'error': 'duplicada'});

    expect(await _estadoOp(db, 'op-ys3-rechazo'), 'rechazada');
    final fila = await _filaIncidencia(db, 'inc-ys3');
    expect(fila['sync_estado'], 'error',
        reason: 'la fila siguió pending: el pull de '
            'incidencias quedaría congelado para siempre');
    expect(fila['sync_error'], contains('duplicada'));
    expect(fila['sincronizada'], 0);
    await db.close();
  });

  test('YS-3: op en REVISIÓN también resuelve su fila', () async {
    final db = await _abrirDbVacia();
    await _siembra(db,
        uuid: 'op-ys3-revision',
        tipo: 'editar_incidencia',
        payload: {'incidencia_id': 'inc-ys3', 'descripcion': 'y'});
    await _barrer('necesita_revision', {'error': 'a revisar'});

    expect(await _estadoOp(db, 'op-ys3-revision'),
        'necesita_revision');
    final fila = await _filaIncidencia(db, 'inc-ys3');
    expect(fila['sync_estado'], 'error');
    expect(fila['sync_error'], contains('a revisar'));
    await db.close();
  });

  test('YS-3: regresión — la rama APLICADA sigue marcando '
      'synced (confirmarOpAplicada intacta)', () async {
    final db = await _abrirDbVacia();
    await _siembra(db,
        uuid: 'op-ys3-aplicada',
        tipo: 'cambiar_estado_incidencia',
        payload: {'id': 'inc-ys3', 'estado': 'resuelta'});
    await _barrer('aplicada', {'ok': true});

    expect(await _estadoOp(db, 'op-ys3-aplicada'), 'aplicada');
    final fila = await _filaIncidencia(db, 'inc-ys3');
    expect(fila['sync_estado'], 'synced');
    expect(fila['sincronizada'], 1);
    await db.close();
  });

  test('YS-3: una op que NO es de incidencia no toca filas de '
      'incidencias al rechazarse', () async {
    final db = await _abrirDbVacia();
    await _siembra(db,
        uuid: 'op-ys3-ajena',
        tipo: 'pago_mensual',
        payload: {'cliente_id': 1, 'id': 'inc-ys3'});
    await _barrer('rechazada', {'ok': false, 'error': 'sin fondos'});

    expect(await _estadoOp(db, 'op-ys3-ajena'), 'rechazada');
    final fila = await _filaIncidencia(db, 'inc-ys3');
    expect(fila['sync_estado'], 'pending',
        reason: 'se resolvió una incidencia desde una op que '
            'no era suya: la extracción debe mirar el TIPO');
    await db.close();
  });

  test('YS-3/H2: la resolución local de una muerte por 4xx de '
      'PostgREST resuelve la fila y marca la op rechazada',
      () async {
    final db = await _abrirDbVacia();
    await _siembra(db,
        uuid: 'op-ys3-muerte-4xx',
        tipo: 'crear_incidencia',
        payload: {'id': 'inc-ys3', 'descripcion': 'x'});
    // El camino (a) de _uploadUnaPorUna no se puede ejercer
    // sin red real: se prueba el helper que su rama de
    // rechazada invoca (el cableado queda fijado por el pin
    // estructural de abajo).
    final resuelta = await SyncEngine.instance
        .resolverIncidenciaSiOpMuereLocalParaTest(
      {
        'op_uuid': 'op-ys3-muerte-4xx',
        'tipo': 'crear_incidencia',
        'payload': jsonEncode({'id': 'inc-ys3'}),
      },
      revision: false,
      motivo: 'El servidor la rechazó (HTTP 422). detalle',
    );
    expect(resuelta, isTrue);
    expect(await _estadoOp(db, 'op-ys3-muerte-4xx'), 'rechazada');
    final fila = await _filaIncidencia(db, 'inc-ys3');
    expect(fila['sync_estado'], 'error',
        reason: 'la fila siguió pending: el pull de '
            'incidencias quedaría congelado para siempre');
    expect(fila['sync_error'], contains('HTTP 422'));
    await db.close();
  });

  test('YS-3/H2: una op de incidencia que cae en '
      'necesita_revision por el bump resuelve su fila', () async {
    final db = await _abrirDbVacia();
    await _siembra(db,
        uuid: 'op-ys3-muerte-bump',
        tipo: 'editar_incidencia',
        payload: {'incidencia_id': 'inc-ys3', 'descripcion': 'y'});
    // HTTP 422 clasifica como validación: el bump la manda a
    // revisión al primer intento y _bumpConReversion debe
    // resolver la fila (la op jamás llega al servidor).
    await SyncEngine.instance.bumpConReversionParaTest(
      {
        'op_uuid': 'op-ys3-muerte-bump',
        'tipo': 'editar_incidencia',
        'payload': jsonEncode({'incidencia_id': 'inc-ys3'}),
      },
      'HTTP 422',
      httpStatus: 422,
    );
    expect(await _estadoOp(db, 'op-ys3-muerte-bump'),
        'necesita_revision');
    final fila = await _filaIncidencia(db, 'inc-ys3');
    expect(fila['sync_estado'], 'error',
        reason: 'la muerte local por bump no resolvió la '
            'fila: el pull de incidencias quedaría congelado');
    expect(fila['sync_error'], contains('revisión'));
    await db.close();
  });

  test('YS-3/H2: pin — las dos muertes locales invocan el '
      'helper de resolución de incidencias', () {
    final sync = File('lib/sync.dart').readAsStringSync();
    final iBump = sync.indexOf('Future<void> _bumpConReversion(');
    final iUp = sync.indexOf('Future<int> _uploadUnaPorUna(');
    final iRes = sync.indexOf(
        'Future<Map<String, ResultadoOpServidor>> '
        '_resultadosOpsBatch(');
    expect(iBump, isNonNegative);
    expect(iUp, greaterThan(iBump));
    expect(iRes, greaterThan(iUp));
    expect(
        sync
            .substring(iBump, iUp)
            .contains('_resolverIncidenciaSiOpMuereLocal(op,'),
        isTrue,
        reason: 'la rama necesita_revision de _bumpConReversion '
            'dejó de resolver la fila de la incidencia');
    expect(
        sync
            .substring(iUp, iRes)
            .contains('_resolverIncidenciaSiOpMuereLocal(op,'),
        isTrue,
        reason: 'la rama rechazada de _uploadUnaPorUna dejó de '
            'resolver la fila de la incidencia');
  });

  test('YS-3: el pull solo congela ante pending (pin del '
      'contrato que la resolución desbloquea)', () {
    final sync = File('lib/sync.dart').readAsStringSync();
    final i = sync.indexOf('Future<int> _pullIncidencias()');
    expect(i, isNonNegative);
    final cuerpo = sync.substring(i, i + 6000);
    expect(
        cuerpo.contains("local.first['sync_estado'] ==\n"
            "                  'pending'"),
        isTrue,
        reason: 'el pull cambió su condición de conflicto: '
            'revisar que una fila resuelta (error) no congele');
  });
}
