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
      // Sonda F02-HD (z16_tests_sl1-2 r1): el estado de las
      // marcas EN EL MOMENTO del fallo inyectado, leído desde
      // dentro del propio callback que falla — no después de
      // que la función devuelva.
      Map<String, String>? pendientesAlFallar;
      final svc = InvitadosService(
        rpc: (nombre, params) async {
          if (nombre == 'info_publica_guardar') {
            final clave = '${params?['p_clave']}';
            if (clave == 'direccion') {
              pendientesAlFallar =
                  await LocalDb.instance.infoPublicaPendientes();
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
      // F02-HD (z16_tests_sl1-2 r1): el orden de A-20 se
      // aserta DENTRO del fallo, no solo en el estado final:
      // cuando la publicación de «direccion» cae, AMBAS
      // claves ya estaban marcadas como pendientes (marcar
      // precede a publicar; una variante que marcara solo la
      // clave caída al salir del bucle dejaría el mismo
      // estado final y este test no debe pasarla).
      expect(pendientesAlFallar, isNotNull,
          reason: 'la sonda debió capturar las marcas en el '
              'momento del fallo inyectado');
      expect(
          pendientesAlFallar,
          {
            'whatsapp_dueno': '58191577',
            'direccion': 'Calle Boca',
          },
          reason: 'A-20: al fallar la segunda clave, la '
              'primera ya estaba marcada como pendiente '
              'ANTES de publicarse: el marcado es previo a '
              'la publicación, no un resto del bucle');
    });

    test(
        'con red sana, el bloque aplica todo y no deja '
        'pendientes', () async {
      // F02-HD (z16_tests_sl1-1 r1): la falsa REGISTRA las
      // llamadas — «sin pendientes» también era el estado
      // inicial tras _bdVacia(), así que sin registro el
      // test pasaba aunque no se publicara nada.
      final llamadas = <({String nombre, Map<String, dynamic>? params})>[];
      final svc = InvitadosService(
        rpc: (nombre, params) async {
          llamadas.add((nombre: nombre, params: params));
          return {'ok': true};
        },
      );
      final quedan = await svc.guardarInfoPublicaEnBloque({
        'whatsapp_dueno': '58191577',
        'direccion': 'Calle Boca',
      });
      expect(quedan, isEmpty);
      expect(await LocalDb.instance.infoPublicaPendientes(),
          isEmpty);
      // La corrida SÍ publicó: una llamada a
      // info_publica_guardar por clave, con su valor.
      final publicaciones = llamadas
          .where((l) => l.nombre == 'info_publica_guardar')
          .toList();
      expect(publicaciones, hasLength(2),
          reason: 'A-20: con red sana se llama a '
              'info_publica_guardar una vez por clave del '
              'bloque; sin llamadas no hay publicación que '
              'pueda dejar el bloque aplicado');
      expect(
          <String, String>{
            for (final l in publicaciones)
              '${l.params?['p_clave']}': '${l.params?['p_valor']}',
          },
          {
            'whatsapp_dueno': '58191577',
            'direccion': 'Calle Boca',
          },
          reason: 'cada clave se publica con SU valor, no '
              'con el de otra ni vacío');
    });
  });
}
