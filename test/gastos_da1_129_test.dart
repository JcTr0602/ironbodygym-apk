/// Gestión 1.29 · Oleada 2 · D-A1 (fijo): la vista de
/// gastos del entrenador.
///
/// El defecto: el ajuste H4 de la 1.28 filtraba el espejo
/// de gastos comparando `registrado_por` como si fuera un
/// telegram_id, pero el servidor lo publica como NOMBRE
/// (sync.py resuelve el autor desde sync_devices y el
/// puente baja el nombre). La comparación daba siempre
/// «no es mío» y al entrenador se le ocultaban TODOS sus
/// gastos ya sincronizados. El test de H4 sembraba el
/// autor como ENTERO: un falso verde que aquí no se
/// repite — estos tests siembran la FORMA REAL de
/// producción (autor en texto).
///
/// Contrato que se fija:
/// 1. Como entrenador veo mis gastos del espejo (autor
///    como nombre) y mis pendientes; los de otro, no.
/// 2. La grafía no importa: «duany» en minúsculas y
///    «Gabriel (APK)» se atribuyen a su dueño.
/// 3. Suplantación imposible: una sesión de Duany con el
///    nombre de exhibición cambiado a «Gabriel» sigue
///    viendo SOLO lo de Duany (el nombre canónico sale
///    del directorio por telegram_id, nunca del
///    displayName editable).
/// 4. Arranque en frío (H-04): sin directorio en el
///    teléfono, el espejo devuelve CERO filas y mis
///    pendientes se siguen viendo por su sello entero.
/// 5. El cruce de multiplicidad es por nombre: la fila
///    espejo de otro no consume mi op gemela, y mi fila
///    espejo SÍ consume la mía (sin duplicar).
/// 6. Como dueño se ve todo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId,
    {String? nombreVisible}) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
    if (nombreVisible != null)
      'user_metadata': {'nombre': nombreVisible},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion({
  required String email,
  required int telegramId,
  String? nombreVisible,
}) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId,
        nombreVisible: nombreVisible),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': {
        if (nombreVisible != null) 'nombre': nombreVisible,
      },
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('gastos');
  await db.delete('ops_queue');
  await db.delete('meta', where: 'k = ?', whereArgs: ['usuarios_apk']);
}

/// Siembra con la FORMA REAL de producción: el autor del
/// espejo es el NOMBRE en texto (así lo publica el
/// servidor), y la op de la cola lleva su sello entero.
Future<void> _sembrar({bool conDirectorio = true}) async {
  final db = await LocalDb.instance.db;
  Future<void> espejo(
          int id, String concepto, double monto, String autor) =>
      db.insert('gastos', {
        'id': id,
        'data': jsonEncode({
          'id': id,
          'fecha': '2026-11-06',
          'concepto': concepto,
          'monto': monto,
          'registrado_por': autor,
        }),
        'sync_seq': id,
      });
  await espejo(1, 'Espejo Duany', 100, 'Duany');
  await espejo(2, 'Espejo Gabriel', 200, 'Gabriel');
  await espejo(3, 'Espejo Gabriel APK', 250, 'Gabriel (APK)');
  await espejo(4, 'Espejo duany minuscula', 150, 'duany');
  Future<void> op(String uuid, String concepto, double monto, int tid) =>
      db.insert('ops_queue', {
        'op_uuid': uuid,
        'tipo': 'gasto',
        'payload': jsonEncode({
          'fecha': '2026-11-07',
          'concepto': concepto,
          'monto': monto,
        }),
        'estado': 'pendiente',
        'creada_ts': '2026-11-07T08:00:00.000-05:00',
        'telegram_id': tid,
      });
  await op('op-gasto-duany', 'Pendiente Duany', 300, 111111);
  await op('op-gasto-gabriel', 'Pendiente Gabriel', 400, 222222);
  if (conDirectorio) {
    await LocalDb.instance.setMeta(
      'usuarios_apk',
      jsonEncode([
        {'telegram_id': 111111, 'nombre': 'Duany', 'username': 'duany'},
        {
          'telegram_id': 222222,
          'nombre': 'Gabriel',
          'username': 'gabriel'
        },
        {'telegram_id': 735772141, 'nombre': 'Jc', 'username': 'jctr0602'},
      ]),
    );
  }
}

Set<String> _conceptos(List<Map<String, dynamic>> gastos) =>
    gastos.map((g) => '${g['concepto']}').toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('D-A1 · gastos por nombre canónico', () {
    test('como Duany: espejo por NOMBRE + mis pendientes; '
        'nada de Gabriel', () async {
      await _bdVacia();
      await _sembrar();
      await _fijarSesion(
          email: 'duany@ironbody.gym', telegramId: 111111);
      final todos = await gastosTodos();
      expect(
        _conceptos(todos),
        {'Espejo Duany', 'Espejo duany minuscula', 'Pendiente Duany'},
        reason: 'el autor del espejo viaja como nombre: la '
            'vista debe resolverlo contra el directorio por '
            'telegram_id, no compararlo como id',
      );
    });

    test('como Gabriel: incluye su fila «Gabriel (APK)»',
        () async {
      await _bdVacia();
      await _sembrar();
      await _fijarSesion(
          email: 'gabriel@ironbody.gym', telegramId: 222222);
      final todos = await gastosTodos();
      expect(
        _conceptos(todos),
        {'Espejo Gabriel', 'Espejo Gabriel APK', 'Pendiente Gabriel'},
      );
    });

    test('suplantación: Duany con displayName «Gabriel» '
        'sigue viendo solo lo suyo', () async {
      await _bdVacia();
      await _sembrar();
      // El nombre de exhibición (user_metadata, editable
      // por el propio usuario) dice «Gabriel»: si el
      // filtro cayera a él, vería los gastos de Gabriel.
      await _fijarSesion(
          email: 'duany@ironbody.gym',
          telegramId: 111111,
          nombreVisible: 'Gabriel');
      final todos = await gastosTodos();
      expect(
        _conceptos(todos),
        {'Espejo Duany', 'Espejo duany minuscula', 'Pendiente Duany'},
        reason: 'el nombre canónico sale del directorio '
            'por telegram_id (app_metadata), jamás del '
            'displayName editable',
      );
    });

    test('arranque en frío sin directorio: cero del espejo, '
        'mis pendientes por su sello', () async {
      await _bdVacia();
      await _sembrar(conDirectorio: false);
      await _fijarSesion(
          email: 'duany@ironbody.gym', telegramId: 111111);
      final todos = await gastosTodos();
      expect(
        _conceptos(todos),
        {'Pendiente Duany'},
        reason: 'fail-closed de H-04: sin nombre resuelto '
            'no se atribuye ningún gasto del espejo; los '
            'pendientes se ven por su sello entero',
      );
    });

    test('como dueño se ve todo', () async {
      await _bdVacia();
      await _sembrar();
      await _fijarSesion(
          email: 'jctr0602@ironbody.gym', telegramId: 735772141);
      final todos = await gastosTodos();
      expect(
        _conceptos(todos),
        {
          'Espejo Duany',
          'Espejo Gabriel',
          'Espejo Gabriel APK',
          'Espejo duany minuscula',
          'Pendiente Duany',
          'Pendiente Gabriel',
        },
      );
    });
  });

  group('D-A1 · cruce de multiplicidad por nombre', () {
    Future<void> sembrarGemelos({required String autorEspejo}) async {
      final db = await LocalDb.instance.db;
      await db.insert('gastos', {
        'id': 9,
        'data': jsonEncode({
          'id': 9,
          'fecha': '2026-11-07',
          'concepto': 'Pomos',
          'monto': 500,
          'registrado_por': autorEspejo,
        }),
        'sync_seq': 9,
      });
      await db.insert('ops_queue', {
        'op_uuid': 'op-gemela-duany',
        'tipo': 'gasto',
        'payload': jsonEncode(
            {'fecha': '2026-11-07', 'concepto': 'Pomos', 'monto': 500}),
        'estado': 'pendiente',
        'creada_ts': '2026-11-07T09:00:00.000-05:00',
        'telegram_id': 111111,
      });
      await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {'telegram_id': 111111, 'nombre': 'Duany', 'username': 'duany'},
          {
            'telegram_id': 222222,
            'nombre': 'Gabriel',
            'username': 'gabriel'
          },
        ]),
      );
    }

    test('la fila espejo de OTRO no consume mi op gemela',
        () async {
      await _bdVacia();
      await sembrarGemelos(autorEspejo: 'Gabriel');
      await _fijarSesion(
          email: 'duany@ironbody.gym', telegramId: 111111);
      final todos = await gastosTodos();
      final pomos =
          todos.where((g) => g['concepto'] == 'Pomos').toList();
      expect(pomos, hasLength(1),
          reason: 'la espejo de Gabriel no se ve y tampoco '
              'puede tragarse mi pendiente');
      expect(pomos.single['pendiente_sync'], 1,
          reason: 'mi op sigue pendiente: no la consumió '
              'la fila de otro');
    });

    test('mi fila espejo SÍ consume mi op gemela (sin '
        'duplicar)', () async {
      await _bdVacia();
      await sembrarGemelos(autorEspejo: 'Duany');
      await _fijarSesion(
          email: 'duany@ironbody.gym', telegramId: 111111);
      final todos = await gastosTodos();
      final pomos =
          todos.where((g) => g['concepto'] == 'Pomos').toList();
      expect(pomos, hasLength(1));
      // La fila que sobrevive es la del ESPEJO: las filas
      // espejo no llevan marca (solo las de cola llevan
      // pendiente_sync = 1), así que «sin marca» aquí =
      // ya sincronizado, no pendiente.
      expect(pomos.single['pendiente_sync'], isNull,
          reason: 'la ocurrencia del espejo con MI nombre '
              'consume mi op: el gasto sale una sola vez, '
              'ya como sincronizado');
    });
  });

  group('D-A1 · normalización del nombre de autor', () {
    test('sufijo (APK), espacios y mayúsculas no importan',
        () {
      expect(normalizarNombreAutorGasto(' Gabriel (APK) '), 'gabriel');
      expect(normalizarNombreAutorGasto('DUANY'), 'duany');
      expect(normalizarNombreAutorGasto('Ana (apk)'), 'ana');
      expect(normalizarNombreAutorGasto('  Gabriel  '), 'gabriel');
    });
  });
}
