/// Ajustes de Argón a la 1.28 (veredicto APTO CON
/// AJUSTES) — tests de regresión por hallazgo, por el
/// camino real:
///
/// - H1 (MEDIA-ALTA): la transacción de aprobación de un
///   vale (op + espejo + marca) y el watermark de los
///   pulls corren contra núcleos con ejecutor explícito
///   (queueOpEn / updateMirrorPagadoHastaEn / setMetaEn /
///   setWatermarkTablaEn) que no conocen el getter db:
///   la transacción completa sin interbloqueo de
///   sqflite (un toque a la conexión principal la
///   colgaría y el timeout del test saltaría).
/// - H2 (MEDIA): conLatidoSyncLock blinda su Timer —
///   bandera de cancelación activada en el finally y
///   comprobada por el tick: tras terminar la operación
///   ningún latido zombi vuelve a tocar la BD.
/// - H4 (MEDIA): gastos por autor en teléfono
///   compartido — como entrenador B no se ven ni el
///   espejo ni las ops pendientes de A; como dueño, todo.
/// - H5 (BAJA): limpiarOptimista sobrevive a una fila
///   con id de tipo dinámico inesperado (el cast va
///   dentro del try) y sigue limpiando las filas sanas.
/// - H6 (BAJA): un 5xx de pasarela (502/503/504) cuenta
///   como fallo de transporte del manifiesto y el
///   cortacircuitos salta a los 3 seguidos; un 4xx no.
///
/// (El hallazgo #3 — nota de cierre en snapshots — no
/// se sostiene en el código vivo: confirmarCierre no
/// recibe ni produce nota alguna; ver el informe
/// ajustes_argon_128.md. Sin test porque no hay
/// comportamiento que corregir.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

String _jwtFalso(String email, String sub) {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"$sub",'
          '"email":"$email","aud":"authenticated"}')}'
      '.firma';
}

/// flutter_test instala un HttpClient simulado que
/// responde 400 a todo: para hablar con el servidor
/// falso local hace falta el cliente real (patrón de
/// ajustes_127_test).
class _HttpReal extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return HttpClient(context: context);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

/// Usuarios del servidor falso: correo → (sub, telegram).
const _usuariosFalsos = <String, (String, int)>{
  'jctr0602@ironbody.gym': ('uuid-dueno', 735772141),
  'duany@ironbody.gym': ('uuid-entrenador-a', 111111),
  'gabriel@ironbody.gym': ('uuid-entrenador-b', 222222),
};

/// Servidor falso mínimo: solo auth. Devuelve el
/// usuario que corresponde al correo del login, con su
/// telegram_id en app_metadata (la fuente real de
/// AuthService.telegramId).
Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
        final cuerpo = await utf8.decoder.bind(req).join();
        final datos = jsonDecode(cuerpo) as Map<String, dynamic>;
        final email = '${datos['email'] ?? ''}';
        final (sub, telegram) =
            _usuariosFalsos[email] ?? ('uuid-x', 0);
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'access_token': _jwtFalso(email, sub),
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-falso',
          'user': {
            'id': sub,
            'email': email,
            'aud': 'authenticated',
            'app_metadata': {'telegram_id': telegram},
            'user_metadata': {},
          },
        }));
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
      } else {
        res.statusCode = 201;
        res.write('[]');
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

Future<void> _entrarComo(String email) async {
  await Supabase.instance.client.auth
      .signInWithPassword(email: email, password: 'da-igual');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    HttpOverrides.global = _HttpReal();
    server = await _servidorFake();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://${server.address.host}:${server.port}',
      anonKey: 'anon-falsa',
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('H1 · núcleos con ejecutor explícito', () {
    test(
        'la transacción de aprobación (op + espejo + '
        'marca) y el watermark corren enteros contra txn',
        () async {
      await _bdVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      await db.upsertMirror('clientes', 7, {
        'nombre': 'Ana',
        'pagado_hasta': '2026-11-01',
        'estado': 'activo',
      }, 10);
      // La misma forma que _aprobarReal/_anularReal y
      // que los pulls de incidencias: todo contra txn.
      // Si algún núcleo tocara el getter db, sqflite se
      // interbloquea y el timeout hace fallar el test.
      await d.transaction((txn) async {
        await db.queueOpEn(
          txn,
          opUuid: 'uuid-h1',
          tipo: 'regalar_dias_premio',
          payload: {
            'cliente_id': 7,
            'vale_id': 5,
            'fecha': '2026-11-07',
          },
        );
        await db.updateMirrorPagadoHastaEn(txn, 7, '2026-11-16');
        await db.setMetaEn(txn, 'premio_vale_resuelto_5', 'uuid-h1');
        await db.setWatermarkTablaEn(txn, 'incidencias', 321);
      }).timeout(const Duration(seconds: 15));
      final ops = await d.query('ops_queue',
          where: 'op_uuid=?', whereArgs: ['uuid-h1']);
      expect(ops, hasLength(1));
      expect(ops.single['tipo'], 'regalar_dias_premio');
      expect(await db.getMeta('premio_vale_resuelto_5'), 'uuid-h1');
      expect(await db.getWatermarkTabla('incidencias'), 321);
      final cli = await db.mirrorPorIds('clientes', [7]);
      expect(cli.single['pagado_hasta'], '2026-11-16');
    });
  });

  group('H2 · latido del sync lock blindado', () {
    test(
        'renueva durante la operación y ningún tick toca '
        'la BD tras el finally', () async {
      await _bdVacia();
      final db = LocalDb.instance;
      final owner = await db.adquirirSyncLock();
      expect(owner, isNotNull);
      final r = await db.conLatidoSyncLock<int>(owner!, () async {
        await Future<void>.delayed(
            const Duration(milliseconds: 220));
        return 7;
      }, intervalo: const Duration(milliseconds: 40));
      expect(r, 7);
      // Se deja asentar un posible tick en vuelo y se
      // comprueba que el valor del lock queda CONGELADO:
      // un latido zombi lo reescribiría con un timestamp
      // nuevo en cada tick (40 ms).
      await Future<void>.delayed(
          const Duration(milliseconds: 60));
      final v1 = await db.getMeta('sync_lock');
      await Future<void>.delayed(
          const Duration(milliseconds: 160));
      final v2 = await db.getMeta('sync_lock');
      expect(v2, v1,
          reason: 'tras el finally el latido no puede '
              'volver a escribir el lock');
      expect(await db.renovarSyncLock(owner), isTrue,
          reason: 'seguimos siendo los dueños del lock');
    });

    test('el blindaje vive en el código (bandera antes '
        'de cancelar, tick que la comprueba)', () {
      final src = File('lib/localdb.dart').readAsStringSync();
      final i = src.indexOf('conLatidoSyncLock');
      expect(i, greaterThan(0));
      final cuerpo = src.substring(i, i + 2600);
      expect(cuerpo.contains('var cancelado = false;'), isTrue);
      final iBandera = cuerpo.indexOf('cancelado = true;');
      final iCancel = cuerpo.indexOf('latido.cancel();');
      expect(iBandera, greaterThan(0));
      expect(iCancel, greaterThan(iBandera),
          reason: 'la bandera se activa ANTES de cancelar '
              'el timer');
      expect(
          cuerpo.contains('if (cancelado || perdido) return;'),
          isTrue);
    });
  });

  group('H4 · gastos por autor (teléfono compartido)', () {
    Future<void> sembrarGastos() async {
      final d = await LocalDb.instance.db;
      // Espejo: un gasto de A y uno de B.
      // 1.29 (Oleada 2, D-A1): la siembra original traía
      // el autor como ENTERO (telegram_id) y el test
      // pasaba — un FALSO VERDE: en producción el
      // servidor publica el autor como NOMBRE y con esa
      // forma la vista del entrenador ocultaba todos sus
      // gastos. La siembra usa ahora la forma real
      // (nombre en texto) + el directorio del pull.
      await d.insert('gastos', {
        'id': 1,
        'data': jsonEncode({
          'id': 1,
          'fecha': '2026-11-06',
          'concepto': 'Espejo A',
          'monto': 100,
          'registrado_por': 'Duany',
        }),
        'sync_seq': 1,
      });
      await d.insert('gastos', {
        'id': 2,
        'data': jsonEncode({
          'id': 2,
          'fecha': '2026-11-06',
          'concepto': 'Espejo B',
          'monto': 200,
          'registrado_por': 'Gabriel',
        }),
        'sync_seq': 2,
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
          {
            'telegram_id': 735772141,
            'nombre': 'Jc',
            'username': 'jctr0602'
          },
        ]),
      );
      // Cola: una op pendiente de cada uno, sellada con
      // el telegram_id de su autor (como hace queueOp).
      await d.insert('ops_queue', {
        'op_uuid': 'op-gasto-a',
        'tipo': 'gasto',
        'payload': jsonEncode(
            {'fecha': '2026-11-07', 'concepto': 'Pendiente A', 'monto': 300}),
        'estado': 'pendiente',
        'creada_ts': '2026-11-07T08:00:00.000-05:00',
        'telegram_id': 111111,
      });
      await d.insert('ops_queue', {
        'op_uuid': 'op-gasto-b',
        'tipo': 'gasto',
        'payload': jsonEncode(
            {'fecha': '2026-11-07', 'concepto': 'Pendiente B', 'monto': 400}),
        'estado': 'pendiente',
        'creada_ts': '2026-11-07T08:05:00.000-05:00',
        'telegram_id': 222222,
      });
    }

    Set<String> conceptosDe(List<Map<String, dynamic>> gastos) =>
        gastos.map((g) => '${g['concepto']}').toSet();

    test('como B no se ven los gastos de A (ni espejo ni '
        'pendientes) y sí los propios', () async {
      await _bdVacia();
      await sembrarGastos();
      await _entrarComo('gabriel@ironbody.gym');
      expect(AuthService().isOwner, isFalse);
      expect(AuthService().telegramId, 222222);
      final todos = await gastosTodos();
      expect(conceptosDe(todos), {'Espejo B', 'Pendiente B'},
          reason: 'el gasto propio pendiente de subir '
              'debe seguir viéndose para su autor');
    });

    test('como A se ven solo los de A', () async {
      await _bdVacia();
      await sembrarGastos();
      await _entrarComo('duany@ironbody.gym');
      expect(AuthService().telegramId, 111111);
      final todos = await gastosTodos();
      expect(conceptosDe(todos), {'Espejo A', 'Pendiente A'});
    });

    test('como dueño se ven todos', () async {
      await _bdVacia();
      await sembrarGastos();
      await _entrarComo('jctr0602@ironbody.gym');
      expect(AuthService().isOwner, isTrue);
      final todos = await gastosTodos();
      expect(
          conceptosDe(todos),
          {'Espejo A', 'Espejo B', 'Pendiente A', 'Pendiente B'});
    });
  });

  group('H5 · limpiarOptimista con id de tipo inesperado', () {
    test(
        'una fila con id REAL no tumba la limpieza y la '
        'fila sana sí se borra', () async {
      await _bdVacia();
      final d = await LocalDb.instance.db;
      // Tabla genérica con id sin tipo (la reutilización
      // que Argón señala): SQLite guarda el -1.5 como
      // REAL y el query id < 0 lo devuelve tal cual.
      await d.execute(
          'CREATE TABLE tmp_limpieza_argon (id, data TEXT)');
      await d.insert('tmp_limpieza_argon', {
        'id': -1.5,
        'data': jsonEncode({'op_uuid': 'uuid-rara'}),
      });
      await d.insert('tmp_limpieza_argon', {
        'id': -7,
        'data': jsonEncode({'op_uuid': 'uuid-rara'}),
      });
      // Con el cast fuera del try esto lanzaba TypeError.
      await LocalDb.instance
          .limpiarOptimista('tmp_limpieza_argon', 'uuid-rara');
      final quedan = await d.query('tmp_limpieza_argon');
      expect(quedan, hasLength(1));
      expect(quedan.single['id'], -1.5,
          reason: 'la fila rara se salta; la sana (id -7, '
              'con el op_uuid) se borró');
    });
  });

  group('H6 · 5xx de pasarela = fallo de transporte', () {
    test('la clasificación: <500 responde, 5xx no', () {
      expect(huboRespuestaManifiesto(200), isTrue);
      expect(huboRespuestaManifiesto(400), isTrue);
      expect(huboRespuestaManifiesto(404), isTrue);
      expect(huboRespuestaManifiesto(429), isTrue);
      expect(huboRespuestaManifiesto(502), isFalse);
      expect(huboRespuestaManifiesto(503), isFalse);
      expect(huboRespuestaManifiesto(504), isFalse);
    });

    test('tres 5xx seguidos saltan el cortacircuitos', () {
      var t = Duration.zero;
      final c = CorteManifiesto(reloj: () => t);
      c.registrarTransporte(huboRespuestaManifiesto(503));
      c.registrarTransporte(huboRespuestaManifiesto(502));
      expect(c.agotado, isFalse);
      c.registrarTransporte(huboRespuestaManifiesto(504));
      expect(c.agotado, isTrue,
          reason: 'con la pasarela caída la pasada debe '
              'cortar a las 3 tablas, no quemar los 150 s');
    });

    test('la verificación del manifiesto usa la '
        'clasificación en la rama de error HTTP', () {
      final src = File('lib/sync.dart').readAsStringSync();
      final i = src.indexOf('_verificarTablaManifiesto');
      expect(i, greaterThan(0));
      // Yunque 1.34: la ventana crece de 4200 a 6500 — el
      // sello de completa (C3-2) y el predicado
      // manifiestoSellaCompleta añadieron ~330 caracteres
      // documentados en esta misma región y la llamada
      // quedó a 4351. La aserción no cambia: el cableado
      // clasificación→huboRespuesta debe existir en la
      // función; solo se recolocó su ventana.
      final cuerpo = src.substring(i, i + 6500);
      expect(
          cuerpo.contains(
              'huboRespuesta: huboRespuestaManifiesto(r.statusCode)'),
          isTrue);
    });
  });
}
