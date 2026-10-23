/// Republicación durable de información pública (v1.7.0, panel):
/// una clave que vive en `info_publica` (el precio del App Plus)
/// se marca como pendiente en meta ANTES de intentar publicarla;
/// si la red falla, la marca queda y el gancho de fin de sync
/// reintenta tras cada sincronización exitosa. La marca SOLO se
/// limpia cuando la republicación tiene éxito.
///
/// Sin red real: el servicio se prueba con RPC inyectada y la
/// meta contra la BD local real (FFI), patrón de la casa.
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

Future<Map<String, String>> _pendientesEnMeta() async =>
    decodificarInfoPublicaPendiente(
        await LocalDb.instance.getMeta(kMetaInfoPublicaPendiente));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('codec de pendientes (puro)', () {
    test('meta ausente, vacía o ilegible = sin pendientes', () {
      expect(decodificarInfoPublicaPendiente(null), isEmpty);
      expect(decodificarInfoPublicaPendiente(''), isEmpty);
      expect(decodificarInfoPublicaPendiente('no-es-json'), isEmpty);
      expect(decodificarInfoPublicaPendiente('[1,2]'), isEmpty);
    });

    test('ida y vuelta conserva las parejas', () {
      final mapa = {'precio_app_plus': '1200', 'otra': 'x'};
      expect(
          decodificarInfoPublicaPendiente(
              codificarInfoPublicaPendiente(mapa)),
          mapa);
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

  group('servicio: bandera en meta y reintento', () {
    test('guardar el precio sin red deja la bandera puesta',
        () async {
      final db = await _abrirDbVacia();
      await _sinRed().guardarInfoPublicaConReintento(
          'precio_app_plus', '1200');
      expect(await _pendientesEnMeta(), {'precio_app_plus': '1200'});
      await db.close();
    });

    test('guardar de nuevo sin red ACTUALIZA el valor marcado',
        () async {
      final db = await _abrirDbVacia();
      final svc = _sinRed();
      await svc.guardarInfoPublicaConReintento('precio_app_plus', '1200');
      await svc.guardarInfoPublicaConReintento('precio_app_plus', '1500');
      expect(await _pendientesEnMeta(), {'precio_app_plus': '1500'});
      await db.close();
    });

    test(
        'una republicación posterior con red publica el valor y '
        'limpia la bandera', () async {
      final db = await _abrirDbVacia();
      await _sinRed().guardarInfoPublicaConReintento(
          'precio_app_plus', '1200');
      expect(await _pendientesEnMeta(), isNotEmpty);

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
      expect(await _pendientesEnMeta(), isEmpty);
      await db.close();
    });

    test('si la republicación vuelve a fallar, la bandera persiste',
        () async {
      final db = await _abrirDbVacia();
      final svc = _sinRed();
      await svc.guardarInfoPublicaConReintento('precio_app_plus', '1200');
      await svc.republicarInfoPublicaPendiente();
      expect(await _pendientesEnMeta(), {'precio_app_plus': '1200'});
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
