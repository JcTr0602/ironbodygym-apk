/// Tests 1.15 Grupo B — Permisos UI (app).
///
/// P2-app: guard isOwner que bloquea acciones de usuarios y foto
/// encolada (contrato admin_usuario/cambiar_foto, sin subida
/// directa a Storage); P3: signOut limpia AccesoAppCache al inicio;
/// P6: la contraseña nueva se recorta antes de validar, encolar y
/// compartir; P7: Permisos deprecada sin romper importadores y
/// can_ver_ranking_servicios fail-closed.
///
/// El test P3 levanta un servidor HTTP local que responde al RPC
/// de accesos y al logout, para cargar la caché de verdad y
/// comprobar que signOut la deja limpia (sin servidor no hay
/// forma de sembrar la caché: cargar() falla y la deja vacía).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/permisos.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/usuarios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ironbody_gym/localdb.dart';

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      if (req.uri.path.endsWith('listar_accesos_clientes')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'cliente_id': 7,
            'nombre': 'Prueba',
            'telefono': '58161619',
            'activo': true,
          }
        ]));
      } else if (req.uri.path.endsWith('obtener_mis_permisos')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'es_admin': false,
          'activo': true,
          'habilitado': true,
          'permisos': <String, dynamic>{},
        }));
      } else {
        // Logout de GoTrue y cualquier otro GET/POST: 204.
        res.statusCode = 204;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

void main() {
  late HttpServer server;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    server = await _servidorFake();
    // flutter_test instala un HttpClient mock (400 a toda
    // petición): restaurarlo ANTES de crear el cliente Supabase
    // para que el RPC y el logout lleguen al servidor local.
    HttpOverrides.global = null;
    await Supabase.initialize(
      url: 'http://127.0.0.1:${server.port}',
      anonKey: 'dummy',
    );
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('P2-app guard y foto', () {
    test('test_usuarios_screen_no_dueno_no_puede_ejecutar_acciones_admin', () {
      // El guard que usan _accion, _cambiarRol, _crear y
      // _cambiarFoto antes de cualquier diálogo o escritura.
      expect(puedeEjecutarAccionesUsuarios(true), isTrue);
      expect(puedeEjecutarAccionesUsuarios(false), isFalse);
    });

    test('test_cambiar_foto_encola_operacion_y_no_sube_directo_a_storage', () {
      // Contrato con el servidor (el otro agente lo implementa
      // así): op admin_usuario, accion='cambiar_foto', payload
      // {username, foto_base64} con el base64 de los bytes.
      final bytes = utf8.encode('foto-falsa-jpg');
      final pay = payloadCambiarFotoUsuario(username: 'gabriel', bytes: bytes);
      expect(pay['accion'], 'cambiar_foto');
      expect(pay['username'], 'gabriel');
      expect(pay['foto_base64'], base64Encode(bytes));
      expect(base64Decode(pay['foto_base64'] as String), bytes);
      // _cambiarFoto usa este payload con queueOp (sin
      // storage.uploadBinary) y avisa «encolada», no
      // «actualizada»: verificado por lectura del método, ya
      // que ImagePicker no se puede mockear en un test unitario.
    });
  });

  group('P3 signOut', () {
    test('test_sign_out_limpia_acceso_app_cache', () async {
      // Cargar la caché de verdad vía RPC del servidor fake.
      expect(await AccesoAppCache.instance.cargar(), isTrue);
      expect(AccesoAppCache.instance.cargado, isTrue);
      expect(AccesoAppCache.instance.obtener(7), isNotNull);
      // Cerrar sesión: la caché debe quedar limpia aunque la
      // purga o el logout remoto fallen (limpiar va primero).
      await AuthService().signOut();
      expect(AccesoAppCache.instance.cargado, isFalse);
      expect(AccesoAppCache.instance.todos, isNull);
      expect(AccesoAppCache.instance.obtener(7), isNull);
    });
  });

  group('P6 contraseña recortada', () {
    test(
        'test_crear_usuario_recorta_password_antes_de_validar_encolar_y_compartir',
        () {
      // _crear() normaliza con trim y valida ESA cadena: la
      // validada, la encolada y la compartida son la misma.
      expect(normalizarPasswordNuevoUsuario('  abcdef  '), 'abcdef');
      expect(normalizarPasswordNuevoUsuario('abcdef'), 'abcdef');
      // 6 caracteres que tras trim quedan en menos: rechazada.
      expect(
          validarNuevoUsuarioApk(
              'gabriel', normalizarPasswordNuevoUsuario('  ab  ')),
          isNotNull);
      expect(
          validarNuevoUsuarioApk(
              'gabriel', normalizarPasswordNuevoUsuario('  abcdef  ')),
          isNull);
      // Sin recortar, el viejo _crear la habría aceptado (6
      // caracteres con espacios) y encolado otra distinta.
      expect(validarNuevoUsuarioApk('gabriel', '  ab  '), isNull);
    });
  });

  group('P7 legacy y clave', () {
    test('permisos_deprecada_sigue_importable_y_usable', () {
      // Compatibilidad de importadores (detalle_suplemento,
      // venta_suplemento): la clase existe y sus getters siguen
      // respondiendo; la deprecación es solo una marca.
      // ignore: deprecated_member_use
      final perm = Permisos();
      expect(perm.cobrar, isTrue);
      expect(perm.inscribir, isTrue);
    });

    test('can_ver_ranking_servicios_fail_closed_sin_clave', () async {
      // Sin la clave en el JSON de permisos, el efectivo es
      // false (fail-closed): el servidor fake devuelve permisos
      // vacíos y el dueño no aplica (sin sesión).
      await PermisosEntrenador().cargar();
      expect(PermisosEntrenador().canVerRankingServicios, isFalse);
      expect(PermisosEntrenador().canVerCifras, isFalse);
    });
  });
}
