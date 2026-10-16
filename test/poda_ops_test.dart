/// Prueba de la poda segura de ops_queue (v1.3.4, item 3: veredicto
/// de Argon).
///
/// Verifica [LocalDb.purgarOpsAplicadas] y
/// [LocalDb.podaOpsDiariaSiToca]:
/// 1. Borra SOLO ops 'aplicada' con (enviada_ts ?? creada_ts) anterior
///    al corte (La Habana actual - 60 dias).
/// 2. Nunca toca otros estados (pendiente/enviada/error/rechazada/
///    necesita_revision), aunque tengan fecha vieja.
/// 3. Protege SIEMPRE las ultimas 200 ops por creada_ts (la subquery
///    NOT IN ... LIMIT 200 cubre TODA la tabla: con <=200 filas no se
///    borra nada), aunque sean viejas.
/// 4. La version diaria corre como maximo 1 vez al dia (meta
///    'ultima_poda_ops'): la segunda llamada el mismo dia no borra.
/// 5. Ante la tabla ausente no lanza (defensiva).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// ISO Habana de hace [dias] dias (mismo formato que guarda la app).
String _haceDias(int dias, {int minutosExtra = 0}) => isoHabana(
      ahoraHabana().subtract(Duration(days: dias, minutes: minutosExtra)),
    );

/// BD limpia (instalacion v26) y singleton reseteado.
Future<void> _abrirLimpia() async {
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
  required String estado,
  required String creadaTs,
  String? enviadaTs,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'pago_mensual',
    'payload': '{}',
    'estado': estado,
    'creada_ts': creadaTs,
    'enviada_ts': enviadaTs,
  });
}

/// Relleno de [n] aplicadas recientes: garantiza que la tabla tenga
/// mas de 200 filas para que la poda pueda actuar (la proteccion de
/// las ultimas 200 cubre toda la tabla si hay <= 200).
Future<void> _rellenoReciente(int n) async {
  for (var i = 0; i < n; i++) {
    final ts = _haceDias(10, minutosExtra: i);
    await _insertarOp(
        uuid: 'relleno-$i', estado: 'aplicada', creadaTs: ts, enviadaTs: ts);
  }
}

Future<int> _contar({String? where, List<Object?>? args}) async {
  final db = await LocalDb.instance.db;
  final r = await db.rawQuery(
      'SELECT COUNT(*) c FROM ops_queue${where == null ? '' : ' WHERE $where'}',
      args);
  return (r.first['c'] as int?) ?? 0;
}

Future<bool> _existe(String uuid) async =>
    (await _contar(where: 'op_uuid = ?', args: [uuid])) == 1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('purgarOpsAplicadas: borra solo aplicadas viejas, respeta estados',
      () async {
    await _abrirLimpia();
    await _rellenoReciente(200);

    // 3 aplicadas viejas con enviada_ts vieja -> se borran.
    for (var i = 0; i < 3; i++) {
      await _insertarOp(
          uuid: 'vieja-$i',
          estado: 'aplicada',
          creadaTs: _haceDias(90),
          enviadaTs: _haceDias(90));
    }
    // Aplicada vieja SIN enviada_ts (coalesce cae a creada_ts) -> se borra.
    await _insertarOp(
        uuid: 'vieja-sin-enviada', estado: 'aplicada', creadaTs: _haceDias(90));
    // Aplicada reciente -> se queda.
    await _insertarOp(
        uuid: 'aplicada-reciente',
        estado: 'aplicada',
        creadaTs: _haceDias(10),
        enviadaTs: _haceDias(10));
    // Aplicada con creada_ts vieja pero enviada_ts reciente -> se queda
    // (el coalesce usa enviada_ts).
    await _insertarOp(
        uuid: 'aplicada-enviada-reciente',
        estado: 'aplicada',
        creadaTs: _haceDias(90),
        enviadaTs: _haceDias(5));
    // Otros estados con fecha vieja -> TODOS se quedan (fuera de las
    // ultimas 200 por creada_ts, asi que solo el estado los protege).
    for (final e in [
      'pendiente',
      'enviada',
      'error',
      'rechazada',
      'necesita_revision'
    ]) {
      await _insertarOp(
          uuid: 'estado-$e',
          estado: e,
          creadaTs: _haceDias(90),
          enviadaTs: _haceDias(90));
    }

    final borradas = await LocalDb.instance.purgarOpsAplicadas();
    expect(borradas, 4, reason: 'deben borrarse las 4 aplicadas viejas');

    expect(await _contar(), 211 - 4,
        reason: 'solo las 4 aplicadas viejas deben faltar');
    expect(await _existe('aplicada-reciente'), isTrue);
    expect(await _existe('aplicada-enviada-reciente'), isTrue);
    for (final e in [
      'pendiente',
      'enviada',
      'error',
      'rechazada',
      'necesita_revision'
    ]) {
      expect(await _existe('estado-$e'), isTrue,
          reason: "estado '$e' jamas se toca");
    }
    expect(await _contar(where: "estado = 'aplicada'"), 202);
  });

  test('purgarOpsAplicadas: protege siempre las ultimas 200', () async {
    await _abrirLimpia();

    // 210 aplicadas, TODAS mas viejas que el corte (90 dias).
    // creada_ts distinta por minuto para un orden total determinista.
    for (var i = 0; i < 210; i++) {
      final ts = _haceDias(90, minutosExtra: i);
      await _insertarOp(
          uuid: 'prot-$i', estado: 'aplicada', creadaTs: ts, enviadaTs: ts);
    }

    final borradas = await LocalDb.instance.purgarOpsAplicadas();
    expect(borradas, 10,
        reason: 'solo las 10 mas viejas caen; 200 quedan protegidas');

    expect(await _contar(), 200);
    // Sobreviven las 200 con creada_ts mas reciente (i = 0..199).
    expect(await _existe('prot-0'), isTrue,
        reason: 'la mas reciente (i=0) debe sobrevivir');
    expect(await _existe('prot-199'), isTrue);
    // Caen las 10 mas viejas (i = 200..209).
    expect(await _existe('prot-200'), isFalse);
    expect(await _existe('prot-209'), isFalse,
        reason: 'la mas vieja (i=209) debe borrarse');
    // Nada mas que aplicadas en la tabla.
    expect(await _contar(where: "estado != 'aplicada'"), 0);
  });

  test('purgarOpsAplicadas: con <=200 filas no borra nada', () async {
    await _abrirLimpia();
    await _rellenoReciente(199);
    await _insertarOp(
        uuid: 'unica-vieja',
        estado: 'aplicada',
        creadaTs: _haceDias(90),
        enviadaTs: _haceDias(90));
    expect(await LocalDb.instance.purgarOpsAplicadas(), 0,
        reason: 'las 200 filas entran en la proteccion');
    expect(await _existe('unica-vieja'), isTrue);
  });

  test('podaOpsDiariaSiToca: corre 1 vez al dia (meta ultima_poda_ops)',
      () async {
    await _abrirLimpia();
    await _rellenoReciente(200);

    await _insertarOp(
        uuid: 'diaria-1',
        estado: 'aplicada',
        creadaTs: _haceDias(90),
        enviadaTs: _haceDias(90));
    await _insertarOp(
        uuid: 'diaria-2',
        estado: 'aplicada',
        creadaTs: _haceDias(90),
        enviadaTs: _haceDias(90));

    await LocalDb.instance.podaOpsDiariaSiToca();
    expect(await _contar(), 200);
    expect(await LocalDb.instance.getMeta('ultima_poda_ops'), hoyHabanaIso());

    // Nueva op vieja el MISMO dia: la segunda llamada debe saltarla.
    await _insertarOp(
        uuid: 'diaria-3',
        estado: 'aplicada',
        creadaTs: _haceDias(90),
        enviadaTs: _haceDias(90));
    await LocalDb.instance.podaOpsDiariaSiToca();
    expect(await _existe('diaria-3'), isTrue,
        reason: 'la guardia diaria debe saltar la segunda corrida');
  });

  test('purgarOpsAplicadas: sin tabla no lanza (defensiva)', () async {
    await _abrirLimpia();
    final db = await LocalDb.instance.db;
    await db.execute('DROP TABLE ops_queue');
    // No debe lanzar: loguea y devuelve 0.
    expect(await LocalDb.instance.purgarOpsAplicadas(), 0);
    // La version diaria tampoco lanza.
    await LocalDb.instance.podaOpsDiariaSiToca();
  });
}
