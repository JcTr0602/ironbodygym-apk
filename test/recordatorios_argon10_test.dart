/// Argón #10 (recordatorios): regresiones de los defectos
/// verificados contra el código real y corregidos. Solo cubre
/// servicio (debidosHoy, disparar, cambiarActiva) + el helper puro;
/// los fixes de UI pura (bandeja, cumpleaños, cumpleaños del mes)
/// van por analyze + prueba de campo. En tests no hay sesión: el
/// teléfono es no-dueño, así que el camino de dueño (puedoDisparar
/// en masivos) se razona, no se ejecuta.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/recordatorios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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

/// Carnet 6 dígitos con el cumpleaños de hoy (año 00).
String _carnetHoy() {
  final hoy = hoyHabanaIso();
  return '00${hoy.substring(5, 7)}${hoy.substring(8, 10)}';
}

Future<void> _seedConfig({
  String id = 'cfg-cumple',
  String alcance = 'todos',
  int? creadoPor = 999,
  String? disparadoHoy,
  String actualizadaTs = '2026-01-01T00:00:00',
}) async {
  await LocalDb.instance.guardarRecordatorio({
    'id': id,
    'titulo': 'Cumple',
    'tipo': 'cumpleanos',
    'alcance': alcance,
    'target_key': 'todos',
    'dias_anticipacion': 3,
    'fecha_fija': null,
    'activa': 1,
    'creado_por': creadoPor,
    'disparado_en_fecha_habana': disparadoHoy,
    'creada_ts': '2026-01-01T00:00:00',
    'actualizada_ts': actualizadaTs,
  });
}

Future<void> _seedCliente(int id,
    {int protegido = 0, int eliminado = 0}) async {
  await LocalDb.instance.upsertMirror('clientes', id, {
    'nombre': 'Cliente $id',
    'carnet': _carnetHoy(),
    'protegido': protegido,
    'eliminado': eliminado,
  }, 0);
}

void main() {
  // Patrón de control_acceso_cache_114_test: sin Supabase
  // inicializado, AuthService.isOwner/telegramId revientan con
  // assert. URL local que rechaza al instante: la sesión queda null
  // (no dueño) sin tocar red.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
  });

  setUp(_limpiar);

  group('Argón #10-1 estadoDebidoPorCliente (puro)', () {
    test('dueño + masivo + sin log: puede disparar', () {
      final e = estadoDebidoPorCliente(
          esDueno: true, alcance: 'todos', yaEnLog: false);
      expect(e.yaDisparado, isFalse);
      expect(e.puedoDisparar, isTrue);
    });

    test('dueño + masivo + ya en log: no puede repetir', () {
      final e = estadoDebidoPorCliente(
          esDueno: true, alcance: 'todos', yaEnLog: true);
      expect(e.yaDisparado, isTrue);
      expect(e.puedoDisparar, isFalse);
    });

    test('entrenador + masivo: nunca puede disparar', () {
      final e = estadoDebidoPorCliente(
          esDueno: false, alcance: 'todos', yaEnLog: false);
      expect(e.yaDisparado, isFalse);
      expect(e.puedoDisparar, isFalse);
    });

    test('solo_mio: decide solo el log', () {
      final libre = estadoDebidoPorCliente(
          esDueno: false, alcance: 'solo_mio', yaEnLog: false);
      expect(libre.yaDisparado, isFalse);
      expect(libre.puedoDisparar, isTrue);
      final ya = estadoDebidoPorCliente(
          esDueno: false, alcance: 'solo_mio', yaEnLog: true);
      expect(ya.yaDisparado, isTrue);
      expect(ya.puedoDisparar, isFalse);
    });
  });

  group('Argón #10-1/10-2 debidosHoy', () {
    test('marcador masivo de hoy NO bloquea por cliente', () async {
      // Estado que dejaba el código viejo tras disparar al primer
      // cliente: el flag de la config en hoy. Con el fix, cada
      // cliente se decide por su propio log (vacío aquí).
      await _seedConfig(disparadoHoy: hoyHabanaIso());
      await _seedCliente(101);
      await _seedCliente(102);
      final debidos =
          await RecordatoriosService.instance.debidosHoy();
      expect(debidos.length, 2);
      expect(debidos.every((d) => !d.yaDisparado), isTrue);
    });

    test('protegidos y eliminados no generan debidos', () async {
      await _seedConfig();
      await _seedCliente(101);
      await _seedCliente(102);
      await _seedCliente(103, protegido: 1);
      await _seedCliente(104, eliminado: 1);
      final debidos =
          await RecordatoriosService.instance.debidosHoy();
      expect(debidos.map((d) => d.clienteId).toSet(), {101, 102});
    });
  });

  group('Argón #10-3 interruptores de Mis avisos', () {
    test('cumpleaños apagado: sin debidos; encendido: aparecen',
        () async {
      await _seedConfig();
      await _seedCliente(101);
      await LocalDb.instance.setMeta('aviso_cumpleanos', '0');
      expect(await RecordatoriosService.instance.debidosHoy(),
          isEmpty);
      await LocalDb.instance.setMeta('aviso_cumpleanos', '1');
      final debidos =
          await RecordatoriosService.instance.debidosHoy();
      expect(debidos.length, 1);
    });
  });

  group('Argón #10-1 disparar por cliente', () {
    test('disparar es idempotente y no escribe el flag masivo',
        () async {
      await _seedConfig();
      await _seedCliente(101);
      const debido = RecordatorioDebido(
        recordatorioId: 'cfg-cumple',
        titulo: 'Cumple',
        tipo: 'cumpleanos',
        alcance: 'todos',
        targetKey: 'cliente:101',
        clienteId: 101,
        clienteNombre: 'Cliente 101',
        yaDisparado: false,
        puedoDisparar: true,
      );
      final svc = RecordatoriosService.instance;
      expect(await svc.disparar(debido), isTrue);
      expect(await svc.disparar(debido), isFalse);
      expect(
          await LocalDb.instance.yaDisparadoRecordatorio(
              recordatorioId: 'cfg-cumple',
              fechaHabana: hoyHabanaIso(),
              targetKey: 'cliente:101'),
          isTrue);
      final db = await LocalDb.instance.db;
      final cfg = await db.query('recordatorio_config',
          where: 'id = ?', whereArgs: ['cfg-cumple']);
      expect(cfg.first['disparado_en_fecha_habana'], isNull);
      // Y el segundo cliente sigue sin disparar.
      await _seedCliente(102);
      final debidos = await svc.debidosHoy();
      final segundo =
          debidos.where((d) => d.clienteId == 102).single;
      expect(segundo.yaDisparado, isFalse);
    });
  });

  group('Argón #10-6 cambiarActiva', () {
    test('pausar sella actualizada_ts', () async {
      await _seedConfig(
        id: 'cfg-solo',
        alcance: 'solo_mio',
        creadoPor: null,
        actualizadaTs: '2020-01-01T00:00:00',
      );
      await RecordatoriosService.instance
          .cambiarActiva('cfg-solo', false);
      final db = await LocalDb.instance.db;
      final rows = await db.query('recordatorio_config',
          where: 'id = ?', whereArgs: ['cfg-solo']);
      expect(rows.first['activa'], 0);
      expect(rows.first['actualizada_ts'],
          isNot('2020-01-01T00:00:00'));
    });

    test('pausar encola la op (panel Luna: una transacción)',
        () async {
      await _seedConfig(
        id: 'cfg-solo',
        alcance: 'solo_mio',
        creadoPor: null,
      );
      await RecordatoriosService.instance
          .cambiarActiva('cfg-solo', false);
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['upsert_recordatorio_config']);
      expect(ops.length, 1);
      final payload = jsonDecode(ops.first['payload'] as String)
          as Map<String, dynamic>;
      expect((payload['recordatorio'] as Map)['activa'], 0);
    });
  });
}
