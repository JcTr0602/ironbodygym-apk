/// Gestión 1.29 · Oleada 4 · Adopción del directorio de
/// gastos recortado por el servidor (cabo de la pieza
/// «gastos propias», 2026-11-07).
///
/// El servidor ya recorta: la policy h08_propias de
/// sync_gastos + la vista sync_estado entregan a cada
/// entrenador SOLO su propia entrada del directorio. Pero la
/// app, desde H-08 (1.23), solo guardaba `usuarios_apk` si
/// la sesión era admin y al no-admin se lo BORRABA en cada
/// pull: en el teléfono del entrenador el directorio nunca
/// existía, `nombresCanonEntrenadores()` no resolvía su
/// nombre y D-A1 quedaba fail-closed (sus gastos
/// sincronizados, invisibles).
///
/// Contrato que se fija:
/// 1. Entrenador: el pull de estado guarda su única entrada
///    TAL COMO LLEGA (la app no re-filtra) →
///    nombresCanonEntrenadores() resuelve su nombre y sus
///    gastos del espejo (autor en texto, FORMA REAL) se ven;
///    los de otro entrenador, no.
/// 2. Admin: el directorio completo y la actividad se
///    guardan como siempre.
/// 3. Entrenador: la actividad global con montos NUNCA se
///    persiste en su teléfono (ni aunque la fila la trajera)
///    y una meta de actividad heredada de una sesión admin
///    anterior se limpia — pero el directorio NO se borra.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/entrenador_identidad.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
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
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion({
  required String email,
  required int telegramId,
}) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
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
  await db.delete('meta');
}

/// Espejo de gastos con la FORMA REAL (autor = nombre en
/// texto), igual que el test de D-A1.
Future<void> _sembrarGastos() async {
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
  await espejo(4, 'Espejo duany minuscula', 150, 'duany');
}

Set<String> _conceptos(List<Map<String, dynamic>> gastos) =>
    gastos.map((g) => '${g['concepto']}').toSet();

const _dirDuanySolo = [
  {'telegram_id': 111111, 'nombre': 'Duany', 'username': 'duany'},
];

const _dirCompleto = [
  {'telegram_id': 111111, 'nombre': 'Duany', 'username': 'duany'},
  {'telegram_id': 222222, 'nombre': 'Gabriel', 'username': 'gabriel'},
  {'telegram_id': 735772141, 'nombre': 'Jc', 'username': 'jctr0602'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('Oleada 4 · adopción del directorio (gastos propias)', () {
    test(
        'entrenador: el pull guarda su única entrada y sus '
        'gastos sincronizados se ven; los ajenos, no', () async {
      await _bdVacia();
      await _sembrarGastos();
      await _fijarSesion(
          email: 'duany@ironbody.gym', telegramId: 111111);

      // Sin directorio (el estado ANTES de la adopción):
      // fail-closed — el espejo no muestra nada de nadie.
      final antes = await gastosTodos();
      expect(_conceptos(antes), isNot(contains('Espejo Duany')),
          reason: 'sin directorio, D-A1 sigue fail-closed');

      // El pull de estado con lo que el servidor recortado
      // entrega a un entrenador: SOLO su entrada. La fila
      // trae además una actividad que NO debe persistir.
      await SyncEngine.instance.aplicarEstadoServidor({
        'ajustes': <String, dynamic>{},
        'usuarios': _dirDuanySolo,
        'actividad': [
          {'tipo': 'pago', 'monto': 9999},
        ],
      });

      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      expect(raw, isNotNull,
          reason: 'el directorio del entrenador se guarda');
      final guardado = jsonDecode(raw!) as List;
      expect(guardado.length, 1,
          reason: 'tal como llega: ni re-filtrado ni ampliado');
      final canon = await nombresCanonEntrenadores();
      expect(canon[111111], 'Duany');
      expect(canon.containsKey(222222), isFalse);

      final despues = await gastosTodos();
      final conceptos = _conceptos(despues);
      expect(conceptos, contains('Espejo Duany'));
      expect(conceptos, contains('Espejo duany minuscula'));
      expect(conceptos, isNot(contains('Espejo Gabriel')));

      // La actividad global jamás se persiste al no-admin.
      expect(
          await LocalDb.instance.getMeta('sync_estado_actividad'),
          isNull);
      expect(
          await LocalDb.instance
              .getMeta('sync_estado_actividad_serie'),
          isNull);
    });

    test(
        'admin: directorio completo y actividad, como siempre',
        () async {
      await _bdVacia();
      await _fijarSesion(
          email: 'jctr0602@ironbody.gym', telegramId: 735772141);
      await SyncEngine.instance.aplicarEstadoServidor({
        'ajustes': <String, dynamic>{},
        'usuarios': _dirCompleto,
        'actividad': [
          {'tipo': 'pago', 'monto': 500},
        ],
      });
      final guardado =
          jsonDecode((await LocalDb.instance.getMeta('usuarios_apk'))!)
              as List;
      expect(guardado.length, 3);
      final canon = await nombresCanonEntrenadores();
      expect(canon.length, 3);
      expect(canon[222222], 'Gabriel');
      expect(
          await LocalDb.instance.getMeta('sync_estado_actividad'),
          isNotNull);
    });

    test(
        'entrenador en teléfono compartido: la actividad '
        'heredada se limpia y el directorio se REEMPLAZA por '
        'el recortado, no se borra', () async {
      await _bdVacia();
      // Restos de una sesión admin anterior en el mismo
      // teléfono: directorio completo + actividad guardada.
      await LocalDb.instance
          .setMeta('usuarios_apk', jsonEncode(_dirCompleto));
      await LocalDb.instance.setMeta(
          'sync_estado_actividad', jsonEncode([{'monto': 1}]));
      await _fijarSesion(
          email: 'duany@ironbody.gym', telegramId: 111111);
      await SyncEngine.instance.aplicarEstadoServidor({
        'ajustes': <String, dynamic>{},
        'usuarios': _dirDuanySolo,
        'actividad': <dynamic>[],
      });
      final guardado =
          jsonDecode((await LocalDb.instance.getMeta('usuarios_apk'))!)
              as List;
      expect(guardado.length, 1,
          reason: 'queda el directorio RECORTADO, no el heredado');
      expect(
          await LocalDb.instance.getMeta('sync_estado_actividad'),
          isNull,
          reason: 'la actividad heredada se limpia');
    });
  });
}
