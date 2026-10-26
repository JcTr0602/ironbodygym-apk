/// Correcciones del panel 1.10 (Luna NO APRUEBA / Kimi APRUEBA CON
/// AJUSTES MENORES): revocar una tarifa que solo vive en el espejo
/// y que la fusión no revierta una revocación offline.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tarifa_especial.dart';
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

Future<void> _insertarEspejo(
  Database db, {
  required String id,
  required int clienteId,
  required int activa,
  String? actualizadaTs,
}) async {
  await db.execute(
      'CREATE TABLE IF NOT EXISTS espejo_tarifas_especiales '
      '(id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
  await db.insert('espejo_tarifas_especiales', {
    'id': id,
    'data': jsonEncode({
      'cliente_id': clienteId,
      'nombre': 'Espejo',
      'periodo': 'mensual',
      'monto_efectivo': 1000,
      'monto_transferencia': null,
      'vigente_desde': '2026-10-24',
      'vigente_hasta': null,
      'motivo': 'otorgada en otro teléfono',
      'otorgado_por': null,
      'activa': activa,
      'historial': '[]',
      'creada_ts': '2026-10-24T10:00:00-04:00',
      'actualizada_ts': actualizadaTs ?? '',
    }),
    'sync_seq': 1,
  });
}

void main() {
  group('fusión con cambio local más reciente (panel 1.10)', () {
    test('local más reciente gana sobre el espejo viejo', () {
      final out = fusionarTarifasEspeciales(
        [
          {
            'id': 'x',
            'cliente_id': 10,
            'periodo': 'mensual',
            'activa': 0,
            'actualizada_ts': '2026-10-25T12:00:00-04:00',
          },
        ],
        [
          {
            'id': 'x',
            'cliente_id': 10,
            'periodo': 'mensual',
            'activa': 1,
            'historial': [],
            'actualizada_ts': '',
          },
        ],
      );
      expect(out.length, 1);
      expect(out.first['activa'], 0);
    });

    test('espejo más reciente sigue ganando (caso del panel 1.9)', () {
      final out = fusionarTarifasEspeciales(
        [
          {
            'id': 'x',
            'cliente_id': 10,
            'periodo': 'mensual',
            'activa': 1,
            'actualizada_ts': '2026-10-20',
          },
        ],
        [
          {
            'id': 'x',
            'cliente_id': 10,
            'periodo': 'mensual',
            'activa': 0,
            'historial': [
              {'evento': 'revocada'}
            ],
            'actualizada_ts': '2026-10-24',
          },
        ],
      );
      expect(out.first['activa'], 0);
    });
  });

  group('revocar tarifa que solo vive en el espejo (panel 1.10)', () {
    test('encola la revocación y deja copia local inactiva', () async {
      final db = await _abrirDbVacia();
      await _insertarEspejo(db,
          id: 'solo-espejo', clienteId: 900010, activa: 1);
      expect(
          (await tarifaActivaPara(900010, 'mensual'))?['id'],
          'solo-espejo');

      await revocarTarifaEspecial(
          id: 'solo-espejo', motivo: 'terminó el pacto');

      expect(await tarifaActivaPara(900010, 'mensual'), isNull);
      final locales = await db.query('tarifa_especial',
          where: 'id=?', whereArgs: ['solo-espejo']);
      expect(locales.length, 1);
      expect(locales.first['activa'], 0);
      final ops = await db.query('ops_queue',
          where: "tipo = 'revoke_tarifa_especial'");
      expect(ops.length, 1);
    });

    test('revocar un id inexistente no encola nada', () async {
      await _abrirDbVacia();
      await revocarTarifaEspecial(id: 'no-existe', motivo: 'x');
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: "tipo = 'revoke_tarifa_especial'");
      expect(ops, isEmpty);
    });
  });

  group('otorgar inactiva la previa que solo vive en el espejo', () {
    test('la pantalla ya no muestra dos activas', () async {
      final db = await _abrirDbVacia();
      await _insertarEspejo(db,
          id: 'vieja-espejo', clienteId: 900011, activa: 1);
      expect(
          (await tarifaActivaPara(900011, 'mensual'))?['id'],
          'vieja-espejo');

      final nueva = await otorgarTarifaEspecial(
          clienteId: 900011,
          nombre: 'Nueva',
          montoEfectivo: 1200,
          motivo: 'reemplazo');

      expect(
          (await tarifaActivaPara(900011, 'mensual'))?['id'], nueva);
      final activas = await tarifasActivas();
      expect(
          activas
              .where((f) => f['cliente_id'] == 900011)
              .length,
          1);
      // La vieja queda inactiva en local (el servidor la inactiva
      // al aplicar el upsert; aquí no se encola revoke extra).
      final vieja = await db.query('tarifa_especial',
          where: 'id=?', whereArgs: ['vieja-espejo']);
      expect(vieja.first['activa'], 0);
    });
  });
}
