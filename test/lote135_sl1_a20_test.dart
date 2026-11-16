/// Lote 1.35 · SL-1 · A-20 (g06 nº20): el guardado de
/// información pública era clave a clave por RPC inmediata,
/// sin durabilidad: un corte a mitad dejaba claves mezcladas
/// en silencio. El guardado en bloque marca TODAS las claves
/// como pendientes ANTES de publicar y devuelve las que no se
/// aplicaron: o todo aplicado, o un pendiente visible.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
  });

  group('A-20 · guardarInfoPublicaEnBloque', () {
    setUp(() async => _bdVacia());

    test(
        'la red cae tras la primera clave: lo aplicado queda '
        'aplicado y lo demás queda PENDIENTE visible, nunca '
        'mezcla silenciosa', () async {
      final aplicadas = <String>[];
      final svc = InvitadosService(
        rpc: (nombre, params) async {
          if (nombre == 'info_publica_guardar') {
            final clave = '${params?['p_clave']}';
            if (clave == 'direccion') {
              throw Exception('la red cae aquí (test)');
            }
            aplicadas.add(clave);
            return {'ok': true};
          }
          throw Exception('RPC no simulada: $nombre');
        },
      );
      final quedan = await svc.guardarInfoPublicaEnBloque({
        'whatsapp_dueno': '58191577',
        'direccion': 'Calle Boca',
      });
      expect(aplicadas, ['whatsapp_dueno'],
          reason: 'la primera clave sí se aplicó');
      expect(quedan, {'direccion': 'Calle Boca'},
          reason: 'la no aplicada queda pendiente y VISIBLE '
              'en el resultado, no perdida en silencio');
      // Y la marca durable coincide: es lo que la pantalla
      // enseña como pendiente y lo que la sync reintentará.
      final pendientes =
          await LocalDb.instance.infoPublicaPendientes();
      expect(pendientes, {'direccion': 'Calle Boca'});
    });

    test(
        'con red sana, el bloque aplica todo y no deja '
        'pendientes', () async {
      final svc = InvitadosService(
        rpc: (nombre, params) async => {'ok': true},
      );
      final quedan = await svc.guardarInfoPublicaEnBloque({
        'whatsapp_dueno': '58191577',
        'direccion': 'Calle Boca',
      });
      expect(quedan, isEmpty);
      expect(await LocalDb.instance.infoPublicaPendientes(),
          isEmpty);
    });
  });
}
