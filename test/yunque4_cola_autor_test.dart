/// Yunque 4 (L7-3) — La Cola del entrenador: la antigüedad
/// de la más antigua y las retenidas también son del autor.
///
/// Y3 (K7-1/K7-2) corrigió el héroe, el total y el desglose,
/// pero `countOpsRetenidas` e `isoOpPendienteMasAntigua`
/// seguían GLOBALES: en el teléfono compartido el
/// entrenador veía la op vieja retenida del dueño como si
/// fuera suya (aviso de 6 h y «Subir ahora (N)» ajenos).
/// Los métodos por autor reciben el mismo `esOpMia` de la
/// UI, como `conteoPendientesPropias`.
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
  required int deTid,
  required String ts,
  String? proximoReintento,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'pago_mensual',
    'payload': jsonEncode({'cliente_id': 7, 'registrado_por': deTid}),
    'estado': estado,
    'creada_ts': ts,
    if (proximoReintento != null) 'proximo_reintento': proximoReintento,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'L7-3 · retenidas y más antigua del entrenador no '
      'incluyen la op vieja retenida del dueño', () async {
    await _bdVacia();
    const mio = 111;
    const dueno = 222;
    final futuro = DateTime.now()
        .add(const Duration(hours: 2))
        .toUtc()
        .toIso8601String();
    // La op del dueño: vieja (3 días) y retenida.
    await _op(
        uuid: 'dueno-vieja-retenida',
        estado: 'pendiente',
        deTid: dueno,
        ts: '2026-11-11T08:00:00.000-05:00',
        proximoReintento: futuro);
    // Las del entrenador: una reciente y una retenida propia.
    await _op(
        uuid: 'mia-reciente',
        estado: 'pendiente',
        deTid: mio,
        ts: '2026-11-14T07:30:00.000-05:00');
    await _op(
        uuid: 'mia-retenida',
        estado: 'pendiente',
        deTid: mio,
        ts: '2026-11-14T07:00:00.000-05:00',
        proximoReintento: futuro);

    bool esMia(Map<String, dynamic> o) =>
        esOpMia(o, miTelegramId: mio);

    // Global (dueño): las dos retenidas y la de hace 3 días.
    expect(await LocalDb.instance.countOpsRetenidas(), 2);
    expect(await LocalDb.instance.isoOpPendienteMasAntigua(),
        '2026-11-11T08:00:00.000-05:00');

    // Por autor (entrenador): solo lo suyo.
    expect(
        await LocalDb.instance.countOpsRetenidasDe(esMia: esMia),
        1,
        reason: 'solo su retenida, no la del dueño');
    expect(
        await LocalDb.instance
            .isoOpPendienteMasAntiguaDe(esMia: esMia),
        '2026-11-14T07:00:00.000-05:00',
        reason: 'su más antigua es la retenida de hoy, no la '
            'de hace 3 días del dueño');
  });
}
