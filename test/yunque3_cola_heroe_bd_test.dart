/// Yunque 3 (K7-1/K7-2) — La Cola: los conteos del héroe y de
/// la tarjeta del entrenador salen de la BD, no de la lista
/// visible truncada a 30 de recentOps.
///
/// K7-1: una op rechazada/enviada empujada fuera de la ventana
/// por 30+ ops más recientes dejaba de contar y el héroe decía
/// «Todo subió». K7-2: el entrenador con 35 pendientes propias
/// entre aplicadas ajenas veía «30» en su total y su desglose.
///
/// El filtro de autor es el MISMO `esOpMia` que filtra la lista
/// visible (la firma vive en el payload: no es SQL); los
/// métodos nuevos de LocalDb lo reciben como predicado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
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

Future<void> _op({
  required String uuid,
  required String estado,
  String tipo = 'pago_mensual',
  String ts = '2026-10-26T09:00:00.000-04:00',
  Map<String, dynamic> payload = const {'cliente_id': 7},
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': ts,
  });
}

String _tsMinuto(int minuto) =>
    '2026-10-26T10:${minuto.toString().padLeft(2, '0')}:00.000-04:00';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'K7-1 héroe (dueño): la rechazada y la enviada antiguas, '
      'fuera de la ventana de 30, SÍ cuentan', () async {
    await _bdVacia();
    // Las dos ops viejas que el héroe debe contar.
    await _op(
        uuid: 'vieja-rechazada',
        estado: 'rechazada',
        ts: '2026-10-26T07:00:00.000-04:00');
    await _op(
        uuid: 'vieja-enviada',
        estado: 'enviada',
        ts: '2026-10-26T07:01:00.000-04:00');
    // Una en error y una bloqueada, recientes.
    await _op(uuid: 'reciente-error', estado: 'error', ts: _tsMinuto(58));
    await _op(
        uuid: 'reciente-revision',
        estado: 'necesita_revision',
        ts: _tsMinuto(59));
    // 31 aplicadas más recientes que las viejas: las empujan
    // fuera de recentOps() (limit 30).
    for (var i = 0; i < 31; i++) {
      await _op(uuid: 'aplicada-$i', estado: 'aplicada', ts: _tsMinuto(i));
    }
    // Prueba de la ventana (el «antes»): la lista visible NO
    // trae ni la rechazada ni la enviada viejas.
    final visibles = await LocalDb.instance.recentOps();
    expect(visibles, hasLength(30));
    expect(
        visibles.any((o) => o['op_uuid'] == 'vieja-rechazada'), isFalse);
    expect(visibles.any((o) => o['op_uuid'] == 'vieja-enviada'), isFalse);

    final hero = await LocalDb.instance.conteosHeroeCola();
    // error = rechazada + error + necesita_revision.
    expect(hero.error, 3);
    expect(hero.enviada, 1);
  });

  test(
      'K7-1 héroe (entrenador): solo cuentan SUS ops en error '
      'y enviadas, aunque sean antiguas', () async {
    await _bdVacia();
    const mio = 111;
    const otro = 222;
    Map<String, dynamic> de(int tid) => {'registrado_por': tid};
    await _op(uuid: 'mia-error', estado: 'error', payload: de(mio));
    await _op(uuid: 'mia-revision', estado: 'necesita_revision',
        payload: de(mio));
    await _op(uuid: 'mia-enviada', estado: 'enviada', payload: de(mio));
    await _op(uuid: 'ajena-error', estado: 'error', payload: de(otro));
    await _op(uuid: 'ajena-revision', estado: 'necesita_revision',
        payload: de(otro));
    await _op(uuid: 'ajena-enviada', estado: 'enviada', payload: de(otro));
    await _op(uuid: 'ajena-rechazada', estado: 'rechazada',
        payload: de(otro));

    final hero = await LocalDb.instance.conteosHeroeCola(
      esMia: (o) => esOpMia(o, miTelegramId: mio),
    );
    expect(hero.error, 2, reason: 'mi error + mi necesita_revision');
    expect(hero.enviada, 1);
    // Sin filtro (dueño): todo cuenta.
    final global = await LocalDb.instance.conteosHeroeCola();
    expect(global.error, 5);
    expect(global.enviada, 2);
  });

  test(
      'K7-2 entrenador: 35 pendientes propias entre aplicadas '
      'y pendientes ajenas — total y desglose suman 35',
      () async {
    await _bdVacia();
    const mio = 111;
    const otro = 222;
    Map<String, dynamic> de(int tid) => {'registrado_por': tid};
    // 35 propias pendientes: 20 pagos + 15 inscripciones.
    for (var i = 0; i < 20; i++) {
      await _op(
          uuid: 'mia-pago-$i',
          estado: 'pendiente',
          tipo: 'pago_mensual',
          payload: de(mio),
          ts: _tsMinuto(i % 60));
    }
    for (var i = 0; i < 15; i++) {
      await _op(
          uuid: 'mia-insc-$i',
          estado: 'pendiente',
          tipo: 'inscribir',
          payload: de(mio),
          ts: _tsMinuto(i % 60));
    }
    // Ruido: aplicadas ajenas y pendientes ajenas recientes.
    for (var i = 0; i < 10; i++) {
      await _op(
          uuid: 'ajena-aplicada-$i',
          estado: 'aplicada',
          payload: de(otro),
          ts: _tsMinuto(59));
    }
    for (var i = 0; i < 5; i++) {
      await _op(
          uuid: 'ajena-pendiente-$i',
          estado: 'pendiente',
          payload: de(otro),
          ts: _tsMinuto(59));
    }
    // Mi enviada NO entra en esta tarjeta (solo 'pendiente',
    // el conjunto histórico de la rama entrenador).
    await _op(uuid: 'mia-enviada', estado: 'enviada', payload: de(mio));

    final r = await LocalDb.instance.conteoPendientesPropias(
      esMia: (o) => esOpMia(o, miTelegramId: mio),
    );
    expect(r.total, 35);
    expect(r.porTipo, {'pago_mensual': 20, 'inscribir': 15});
    expect(r.porTipo.values.fold<int>(0, (a, b) => a + b), 35);
  });
}
