/// SyncPill / estado del motor (v1.8.0, bug de campo): el stream
/// de estado es broadcast SIN replay y la píldora nacía con
/// initialData vacío (pending=0 → «Al día») al re-suscribirse,
/// conviviendo con el badge correcto de pendientes. El arreglo:
/// getter `currentStatus`, `reemitirEstado()` e initialData real.
/// Aquí se verifica el motor: tras sembrar ops pendientes en la
/// BD, la re-emisión deja `currentStatus.pending` con el dato de
/// la BD (que es lo que la píldora pinta al nacer y lo que recibe
/// un suscriptor nuevo).
library;

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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reemitirEstado: currentStatus refleja las ops pendientes '
      'de la BD y un suscriptor nuevo las recibe', () async {
    await _bdVacia();
    final engine = SyncEngine.instance;

    // Dos ops pendientes sembradas por el camino real de encolado.
    await LocalDb.instance.queueOp(
        opUuid: 'test-pill-1',
        tipo: 'editar_cliente',
        payload: {'cliente_id': 1});
    await LocalDb.instance.queueOp(
        opUuid: 'test-pill-2',
        tipo: 'editar_cliente',
        payload: {'cliente_id': 2});
    expect(await LocalDb.instance.countPendingOps(), 2);

    // Suscriptor NUEVO (como la píldora al volver a Home): sin
    // replay no recibiría nada; la re-emisión le entrega el estado.
    final futuro = engine.statusStream
        .firstWhere((s) => s.pending == 2)
        .timeout(const Duration(seconds: 30));
    await engine.reemitirEstado();
    final emitido = await futuro;
    expect(emitido.pending, 2);

    // Y el getter —el initialData de la píldora— ya trae el dato.
    expect(engine.currentStatus.pending, 2);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
