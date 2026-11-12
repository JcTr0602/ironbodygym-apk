/// Corte B 1.32 · H-CB-1 (Argón, MEDIA): la emisión de la
/// huella M5 tras el cierre de una corrida estaba atada a
/// que la corrida ocupara plaza en el Diario
/// (quedoEnDiario). cerrarCorrida devuelve false en los
/// chequeos automáticos vacíos — el ciclo de cada 2 min —,
/// así que en un teléfono en reposo el latido de presencia
/// de 30 min jamás disparaba, un estado 'fallida' ya
/// recuperado no se refrescaba en el servidor y el reporte
/// pendiente (M5-T) no se reintentaba hasta una corrida
/// con movimiento.
///
/// Sin harness de sesión (como el resto del banco) no hay
/// userId y HuellaSync.registrarCierre no llega a emitir;
/// la señal observable de que el cierre SÍ invocó la
/// huella es que _huellaTrasCierre resuelve el device_tag
/// del teléfono, que se materializa en la meta
/// 'device_tag_id'.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diario_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_corteb132_hcb1.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_corteb132_hcb1.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
  // Watermarks sembrados: sin esto la apertura deriva el
  // origen a 'instalacion' (cursor global en 0) y la
  // corrida ocuparía plaza por su origen, fuera del
  // escenario del hallazgo.
  for (final t in LocalDb.tablasConWatermark) {
    await LocalDb.instance.setWatermarkTabla(t, 500);
  }
}

void main() {
  test('H-CB-1: el chequeo automático vacío (sin plaza en '
      'el Diario) también intenta emitir la huella M5',
      () async {
    await _init();
    final db = LocalDb.instance;
    expect(await db.getMeta('device_tag_id'), isNull,
        reason: 'precondición: nadie resolvió el tag aún');

    await SyncEngine.instance.cicloDiarioParaTest(
      tipo: 'solo_pull',
      origen: OrigenCorrida.automatica,
      estado: EstadoCorrida.completa,
    );

    // El escenario es exactamente el del hallazgo: la
    // corrida NO ocupó plaza — el contador de chequeos
    // vacíos avanzó y el historial quedó vacío.
    expect(await DiarioSync.instance.historial(), isEmpty);
    expect(
        await db.getMeta('chequeos_vacios_desde_ultima_corrida'),
        '1');

    // …y aun así la huella se intentó: el device_tag se
    // materializó. La emisión va unawaited: se espera a
    // que el futuro en segundo plano lo escriba.
    String? tag;
    for (var i = 0; i < 100 && tag == null; i++) {
      tag = await db.getMeta('device_tag_id');
      if (tag == null) {
        await Future<void>.delayed(
            const Duration(milliseconds: 50));
      }
    }
    expect(tag, isNotNull,
        reason: 'sin plaza no había intento de huella: el '
            'cierre debe invocarla en toda corrida que '
            'existió y dejar la decisión al freno de '
            'HuellaSync.registrarCierre');
  });
}
