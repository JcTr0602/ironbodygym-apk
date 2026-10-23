/// Republicación durable de información pública (v1.7.0, panel;
/// representación v37): una clave que vive en `info_publica` (el
/// precio del App Plus) se marca como pendiente ANTES de intentar
/// publicarla; si la red falla, la marca queda y el gancho de fin
/// de sync reintenta tras cada sincronización exitosa. La marca
/// SOLO se limpia cuando la republicación tiene éxito.
///
/// La marca es UNA FILA por clave en la tabla
/// `info_publica_pendiente` (v37): marcar = INSERT OR REPLACE y
/// limpiar = DELETE condicional por (clave, valor), sentencias
/// únicas y atómicas a nivel de BD. (La representación original
/// — un JSON en meta leído-modificado-escrito — dejaba una
/// ventana entre isolates.)
///
/// Sin red real: el servicio se prueba con RPC inyectada y la
/// tabla contra la BD local real (FFI), patrón de la casa.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
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

InvitadosService _sinRed() => InvitadosService(
      rpc: (nombre, params) async =>
          throw Exception('sin red (test)'),
    );

Future<Map<String, String>> _pendientes() =>
    LocalDb.instance.infoPublicaPendientes();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tabla de pendientes (LocalDb, v37)', () {
    test('marcar inserta y ACTUALIZA con un solo INSERT OR '
        'REPLACE', () async {
      final db = await _abrirDbVacia();
      await LocalDb.instance
          .marcarInfoPublicaPendiente('precio_app_plus', '1200');
      await LocalDb.instance
          .marcarInfoPublicaPendiente('precio_app_plus', '1500');
      await LocalDb.instance
          .marcarInfoPublicaPendiente('otra', 'x');
      expect(await _pendientes(),
          {'precio_app_plus': '1500', 'otra': 'x'});
      await db.close();
    });

    test('limpiar con el valor exacto borra la fila (1 fila)',
        () async {
      final db = await _abrirDbVacia();
      await LocalDb.instance
          .marcarInfoPublicaPendiente('precio_app_plus', '1200');
      final borradas = await LocalDb.instance
          .limpiarInfoPublicaPendiente('precio_app_plus', '1200');
      expect(borradas, 1);
      expect(await _pendientes(), isEmpty);
      await db.close();
    });

    test('limpiar con un valor DISTINTO no borra nada (0 filas): '
        'la marca nueva sobrevive', () async {
      final db = await _abrirDbVacia();
      await LocalDb.instance
          .marcarInfoPublicaPendiente('precio_app_plus', '1500');
      final borradas = await LocalDb.instance
          .limpiarInfoPublicaPendiente('precio_app_plus', '1200');
      expect(borradas, 0);
      expect(await _pendientes(), {'precio_app_plus': '1500'});
      await db.close();
    });
  });

  group('republicarInfoPublicaPendientes (publicador inyectado)', () {
    test('todo publicado = no queda nada pendiente', () async {
      final quedan = await republicarInfoPublicaPendientes(
        {'a': '1', 'b': '2'},
        (clave, valor) async {},
      );
      expect(quedan, isEmpty);
    });

    test('un fallo deja pendiente SOLO esa clave', () async {
      final quedan = await republicarInfoPublicaPendientes(
        {'a': '1', 'b': '2'},
        (clave, valor) async {
          if (clave == 'b') throw Exception('sin red');
        },
      );
      expect(quedan, {'b': '2'});
    });

    test('fallo total = quedan todos', () async {
      final quedan = await republicarInfoPublicaPendientes(
        {'a': '1'},
        (clave, valor) async => throw Exception('sin red'),
      );
      expect(quedan, {'a': '1'});
    });
  });

  group('servicio: fila pendiente y reintento', () {
    test('guardar el precio sin red deja la fila puesta', () async {
      final db = await _abrirDbVacia();
      await _sinRed().guardarInfoPublicaConReintento(
          'precio_app_plus', '1200');
      expect(await _pendientes(), {'precio_app_plus': '1200'});
      await db.close();
    });

    test('guardar de nuevo sin red ACTUALIZA el valor de la fila',
        () async {
      final db = await _abrirDbVacia();
      final svc = _sinRed();
      await svc.guardarInfoPublicaConReintento('precio_app_plus', '1200');
      await svc.guardarInfoPublicaConReintento('precio_app_plus', '1500');
      expect(await _pendientes(), {'precio_app_plus': '1500'});
      await db.close();
    });

    test(
        'una republicación posterior con red publica el valor y '
        'limpia la fila', () async {
      final db = await _abrirDbVacia();
      await _sinRed().guardarInfoPublicaConReintento(
          'precio_app_plus', '1200');
      expect(await _pendientes(), isNotEmpty);

      final llamadas = <({String nombre, Map<String, dynamic>? params})>[];
      final conRed = InvitadosService(rpc: (nombre, params) async {
        llamadas.add((nombre: nombre, params: params));
        return <String, dynamic>{};
      });
      await conRed.republicarInfoPublicaPendiente();

      expect(llamadas, hasLength(1));
      expect(llamadas.single.nombre, 'info_publica_guardar');
      expect(llamadas.single.params,
          {'p_clave': 'precio_app_plus', 'p_valor': '1200'});
      expect(await _pendientes(), isEmpty);
      await db.close();
    });

    test('si la republicación vuelve a fallar, la fila persiste',
        () async {
      final db = await _abrirDbVacia();
      final svc = _sinRed();
      await svc.guardarInfoPublicaConReintento('precio_app_plus', '1200');
      await svc.republicarInfoPublicaPendiente();
      expect(await _pendientes(), {'precio_app_plus': '1200'});
      await db.close();
    });

    test('sin pendientes, el reintento no llama a la red', () async {
      final db = await _abrirDbVacia();
      var llamo = false;
      final svc = InvitadosService(rpc: (nombre, params) async {
        llamo = true;
        return null;
      });
      await svc.republicarInfoPublicaPendiente();
      expect(llamo, isFalse);
      await db.close();
    });
  });
}
