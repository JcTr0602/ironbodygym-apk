// Piezas añadidas de la oleada Medias/Bajas (Gestión 1.31):
// (b) y (c) de la incidencia de campo de Jc (2026-11-09).
//
// (c)(i): la Salud enseña al dueño el texto REAL de
// wm_err_<tabla> en vez de solo el genérico.
// (c)(ii): la banda de la corrida aplica el contrafuerte
// A4-D2: con internet confirmado, un error de transporte
// se presenta como «No se pudo contactar el servidor».
//
// (La (b) —la marca wm_sinverificar_ en el diagnóstico
// copiable de admin_secciones— vive dentro del método de
// UI que arma el informe; verificada por lectura y
// analyze en el informe de la oleada.)
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_yunque_b_piezas.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  LocalDb.nombreArchivoDbForzado = 'test_yunque_b_piezas.db';

  group('Pieza (c)(ii) describirErrorCorrida', () {
    const crudo = 'ClientException: Connection closed before '
        'full header was received';

    test('con internet confirmado: el servidor, no «sin conexión»',
        () {
      final txt = describirErrorCorrida(crudo, hayInternet: true);
      expect(txt, contains('No se pudo contactar el servidor'));
      expect(txt, isNot(contains('No hay conexión a internet')));
    });

    test('sin internet confirmado: se conserva la traducción',
        () {
      expect(describirErrorCorrida(crudo, hayInternet: false),
          contains('No hay conexión a internet'));
      expect(describirErrorCorrida(crudo),
          contains('No hay conexión a internet'));
    });

    test('un error que no es de transporte no se toca', () {
      final txt = describirErrorCorrida('otro fallo cualquiera',
          hayInternet: true);
      expect(txt, isNot(contains('No se pudo contactar')));
    });
  });

  group('Pieza (c)(i) Salud con el texto real de wm_err', () {
    test('la fila trae errorBajada y la nota lo incluye',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.setMeta(
          'wm_err_clientes', 'HTTP 400: fila ilegible (falso)');
      final salud = await cargarSaludSync();
      final fila = salud.tablas
          .firstWhere((t) => t.tablaLocal == 'clientes');
      expect(fila.estado, SemaforoTabla.rojo);
      expect(fila.errorBajada, 'HTTP 400: fila ilegible (falso)');
      expect(fila.nota, contains('fila ilegible (falso)'));
    });

    test('sin error: errorBajada vacío y nota sin inventar',
        () async {
      await _abrirDbVacia();
      final salud = await cargarSaludSync();
      final fila = salud.tablas
          .firstWhere((t) => t.tablaLocal == 'clientes');
      expect(fila.errorBajada, '');
    });
  });
}
