/// Cableado de verificarManifiesto (v1.3.4, Item 6 Capa 1: veredicto
/// de Argon).
///
/// Verifica [SyncEngine.manifiestoDiarioSiToca] SIN red real (la
/// verificacion se inyecta como fake):
/// 1. Guardia diaria: corre como maximo 1 vez al dia (meta
///    'ultimo_manifiesto' = hoyHabanaIso()); la segunda llamada el
///    mismo dia no re-ejecuta; al dia siguiente si.
/// 2. No se ejecuta con ops pendientes (countPendingOps() > 0) y el
///    dia no queda registrado.
/// 3. Ante divergencia, la verificacion setea forzar_redescarga_<tabla>
///    (el fake replica el efecto real de verificarManifiesto) y la
///    corrida queda registrada.
/// 4. Defensiva: si la verificacion lanza, no se propaga y el dia no
///    se registra (se reintentara en el proximo sync).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake de verificacion: cuenta llamadas; opcionalmente diverge
/// (seteando la meta como hace el verificarManifiesto real) o lanza.
class _FakeVerificacion {
  int llamadas = 0;
  bool divergir = false;
  bool lanzar = false;

  Future<int> call() async {
    llamadas++;
    if (lanzar) throw Exception('red caida (fake)');
    if (divergir) {
      // Replica el efecto real de verificarManifiesto ante divergencia.
      await LocalDb.instance.setMeta('forzar_redescarga_clientes', '1');
      return 1;
    }
    return 0;
  }
}

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
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'pago_mensual',
    'payload': '{}',
    'estado': estado,
    'creada_ts': creadaTs,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('guardia diaria: 1 vez al dia, no 2 el mismo dia', () async {
    await _abrirLimpia();
    final fake = _FakeVerificacion();

    await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake.call);
    expect(fake.llamadas, 1);
    expect(
        await LocalDb.instance.getMeta('ultimo_manifiesto'), hoyHabanaIso());

    // Segunda llamada el mismo dia: se salta.
    await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake.call);
    expect(fake.llamadas, 1,
        reason: 'la guardia diaria debe saltar la segunda corrida');
  });

  test('guardia diaria: al dia siguiente vuelve a correr', () async {
    await _abrirLimpia();
    final fake = _FakeVerificacion();
    // Simula una corrida de ayer.
    final ayer = isoHabana(ahoraHabana().subtract(const Duration(days: 1)))
        .substring(0, 10);
    await LocalDb.instance.setMeta('ultimo_manifiesto', ayer);

    await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake.call);
    expect(fake.llamadas, 1);
    expect(
        await LocalDb.instance.getMeta('ultimo_manifiesto'), hoyHabanaIso());
  });

  test('no se ejecuta con ops pendientes', () async {
    await _abrirLimpia();
    final fake = _FakeVerificacion();
    await _insertarOp(
        uuid: 'pend-1',
        estado: 'pendiente',
        creadaTs: isoHabana(ahoraHabana()));

    await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake.call);
    expect(fake.llamadas, 0, reason: 'con la cola sucia no debe verificar');
    expect(await LocalDb.instance.getMeta('ultimo_manifiesto'), isNull,
        reason: 'el dia no se registra si no corrio');
  });

  test('ante divergencia setea forzar_redescarga_<tabla>', () async {
    await _abrirLimpia();
    final fake = _FakeVerificacion()..divergir = true;

    await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake.call);
    expect(fake.llamadas, 1);
    expect(await LocalDb.instance.getMeta('forzar_redescarga_clientes'), '1',
        reason: 'la divergencia debe marcar la tabla para re-descarga');
    expect(
        await LocalDb.instance.getMeta('ultimo_manifiesto'), hoyHabanaIso());
  });

  test('defensiva: si la verificacion lanza, no propaga', () async {
    await _abrirLimpia();
    final fake = _FakeVerificacion()..lanzar = true;

    // No debe lanzar.
    await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake.call);
    expect(fake.llamadas, 1);
    expect(await LocalDb.instance.getMeta('ultimo_manifiesto'), isNull,
        reason: 'el dia no se registra si fallo: se reintenta luego');
  });
}
