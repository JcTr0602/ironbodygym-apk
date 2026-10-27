/// Bug Gabriel (2026-10-27): dos diarios pendientes en el mismo
/// segundo colapsaban a uno en diariosDeHoy porque isoHabana()
/// trunca creado_en a segundos y la clave de dedup sumaba cada
/// pendiente al conjunto. Regresión: dos ops mismo segundo, mismo
/// turno/cantidad/entrenador → las 2 en la lista.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('ops_queue');
  await db.delete('pagos_diarios');
}

void main() {
  setUp(_limpiar);

  test('dos pendientes mismo segundo no colapsan', () async {
    final hoy = hoyHabanaIso();
    const creado = '2026-10-27T10:00:00';
    for (var i = 0; i < 2; i++) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'pago_diario',
        payload: {
          'fecha': hoy,
          'turno': 'mañana',
          'cantidad': 1,
          'registrado_por': 1403501391,
          'creado_en': creado,
        },
      );
    }
    final res = await diariosDeHoy();
    expect(res.length, 2);
    expect(res.where((d) => d['es_optimista'] == true).length, 2);
    final uuids = res.map((d) => d['op_uuid']).toSet();
    expect(uuids.length, 2);
  });

  test('un solo pendiente se muestra una vez', () async {
    final hoy = hoyHabanaIso();
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_diario',
      payload: {
        'fecha': hoy,
        'turno': 'mañana',
        'cantidad': 2,
        'registrado_por': 1403501391,
        'creado_en': '2026-10-27T10:00:00',
      },
    );
    final res = await diariosDeHoy();
    expect(res.length, 1);
    expect(res.first['total'], 400);
  });
}
