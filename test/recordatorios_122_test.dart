/// 1.22 Pieza 6 (Recordatorios): R-1, R-2, R-3, R-4, R-6, R-7.
/// Harness como recordatorios_argon10_test (ffi + Supabase
/// dummy: sin sesión, teléfono no-dueño).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/notificaciones_recordatorios.dart';
import 'package:ironbody_gym/recordatorios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('ops_queue');
  await db.delete('clientes');
  await db.delete('recordatorio_config');
  await db.delete('recordatorio_disparos_log');
}

Future<void> _seedConfig({
  required String id,
  required String tipo,
  String alcance = 'todos',
  int dias = 3,
}) async {
  await LocalDb.instance.guardarRecordatorio({
    'id': id,
    'titulo': 'Cfg $id',
    'tipo': tipo,
    'alcance': alcance,
    'target_key': 'todos',
    'dias_anticipacion': dias,
    'fecha_fija': null,
    'frecuencia': 'ninguna',
    'activa': 1,
    'creado_por': null,
    'disparado_en_fecha_habana': null,
    'creada_ts': '2026-01-01T00:00:00',
    'actualizada_ts': '2026-01-01T00:00:00',
  });
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
  });

  setUp(_limpiar);
  tearDown(() => ganchoSincronizarAvisos = null);

  group('R-1 ahoraUtcReal', () {
    test('es UTC y es el instante real (no el wall-clock)', () {
      final r = ahoraUtcReal();
      expect(r.isUtc, isTrue);
      final diff = DateTime.now().toUtc().difference(r).inSeconds.abs();
      expect(diff, lessThan(5));
    });

    test('instanteAvisoDebido: pasadas las 08:00 Habana, +5 min',
        () {
      final ocho = instanteAvisoHabana('2026-11-02');
      final ahora = ocho.add(const Duration(hours: 2));
      final inst =
          instanteAvisoDebido(fecha: '2026-11-02', ahoraUtc: ahora);
      expect(inst, ahora.add(const Duration(minutes: 5)));
    });
  });

  group('R-3 personalizado mensual con tope (DateTime.utc)', () {
    final cfg = {
      'fecha_fija': '2026-01-31',
      'frecuencia': 'mensual',
    };
    test('el 31 cae al 28 en febrero y al 30 en abril', () {
      expect(recordatorioPersonalizadoTocaHoy(cfg, '2026-02-28'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(cfg, '2026-04-30'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(cfg, '2026-03-31'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(cfg, '2026-04-29'),
          isFalse);
      expect(recordatorioPersonalizadoTocaHoy(cfg, '2026-02-27'),
          isFalse);
    });
  });

  group('R-4 Casa fuera de vencimiento (cumpleaños sí)', () {
    test('debidosHoy: Casa no aparece en vencimiento', () async {
      await _seedConfig(id: 'cfg-venc', tipo: 'vencimiento');
      await _seedConfig(id: 'cfg-cumple', tipo: 'cumpleanos');
      // Casa: vence en ventana (12 ≤ 10+3) y cumple el 10-nov.
      await LocalDb.instance.upsertMirror('clientes', 201, {
        'nombre': 'Cliente Casa',
        'carnet': '00111012345',
        'pagado_hasta': '2026-11-12',
        'cuenta_casa': 1,
        'estado': 'activo',
      }, 0);
      // Normal: vence en ventana.
      await LocalDb.instance.upsertMirror('clientes', 202, {
        'nombre': 'Cliente Normal',
        'carnet': '00990112345',
        'pagado_hasta': '2026-11-12',
        'estado': 'activo',
      }, 0);
      final debidos = await RecordatoriosService.instance
          .debidosHoy(hoyHabana: '2026-11-10');
      final venc = debidos
          .where((d) => d.tipo == 'vencimiento')
          .map((d) => d.clienteId)
          .toList();
      expect(venc, [202],
          reason: 'la Casa no genera aviso de vencimiento');
      final cumple = debidos
          .where((d) => d.tipo == 'cumpleanos')
          .map((d) => d.clienteId)
          .toList();
      expect(cumple, contains(201),
          reason: 'el cumpleaños de la Casa sí avisa');
      // R-2: los debidos llevan su fecha sellada.
      expect(debidos.every((d) => d.fechaHabana == '2026-11-10'),
          isTrue);
    });
  });

  group('R-2 disparar asienta la fecha DEL DEBIDO', () {
    test('pantalla abierta cruzando medianoche', () async {
      await _seedConfig(id: 'cfg-r2', tipo: 'cumpleanos',
          alcance: 'solo_mio');
      const debido = RecordatorioDebido(
        recordatorioId: 'cfg-r2',
        titulo: 'Cfg cfg-r2',
        tipo: 'cumpleanos',
        alcance: 'solo_mio',
        targetKey: 'cliente:301',
        clienteId: 301,
        clienteNombre: 'Cliente 301',
        yaDisparado: false,
        puedoDisparar: true,
        fechaHabana: '2026-10-31',
      );
      final svc = RecordatoriosService.instance;
      expect(await svc.disparar(debido), isTrue);
      expect(
          await LocalDb.instance.yaDisparadoRecordatorio(
              recordatorioId: 'cfg-r2',
              fechaHabana: '2026-10-31',
              targetKey: 'cliente:301'),
          isTrue);
      expect(
          await LocalDb.instance.yaDisparadoRecordatorio(
              recordatorioId: 'cfg-r2',
              fechaHabana: hoyHabanaIso(),
              targetKey: 'cliente:301'),
          isFalse);
    });
  });

  group('R-6/R-7 eliminar atómico + gancho de avisos', () {
    test('eliminar borra y encola en una transacción; el '
        'gancho corre tras cambiarActiva y eliminar', () async {
      await _seedConfig(id: 'cfg-del', tipo: 'vencimiento',
          alcance: 'solo_mio');
      var llamadas = 0;
      ganchoSincronizarAvisos = () async {
        llamadas++;
      };
      final svc = RecordatoriosService.instance;
      await svc.cambiarActiva('cfg-del', false);
      expect(llamadas, 1, reason: 'R-7 tras cambiarActiva');
      await svc.eliminar('cfg-del');
      expect(llamadas, 2, reason: 'R-7 tras eliminar');
      final db = await LocalDb.instance.db;
      final cfg = await db.query('recordatorio_config',
          where: 'id = ?', whereArgs: ['cfg-del']);
      expect(cfg, isEmpty);
      final ops = await db.query('ops_queue',
          where: 'tipo = ?',
          whereArgs: ['delete_recordatorio_config']);
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.first['payload'] as String)
              as Map<String, dynamic>;
      expect(payload['recordatorio_id'], 'cfg-del');
    });
  });
}
