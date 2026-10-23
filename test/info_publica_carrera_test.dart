/// Carrera de la republicación de info pública (v1.7.0, panel;
/// representación v37): el gancho de fin de sync republicando un
/// valor NO puede barrer la marca de un guardado más nuevo,
/// venga del isolate que venga.
///
/// Tres defensas, todas probadas aquí:
///  1. SERIALIZACIÓN: guardar y republicar corren en una cadena
///     compartida del servicio; nunca hay dos RPC de publicación
///     solapadas en el mismo isolate.
///  2. MARCAS POR FILAS (v37): marcar es un INSERT OR REPLACE y
///     limpiar un DELETE condicional por (clave, valor) sobre la
///     tabla `info_publica_pendiente` — sentencias únicas que
///     SQLite serializa entre conexiones. Si el valor cambió
///     mientras la RPC estaba en vuelo, el DELETE afecta 0
///     filas y la marca nueva sobrevive. (La representación
///     anterior, un JSON en meta leído-modificado-escrito, es
///     la que el panel tumbó dos veces.)
///  3. ENTRE ISOLATES: el escenario exacto de la última delta —
///     republicación del 1200 en vuelo mientras OTRA conexión a
///     la misma BD (como el isolate de fondo) marca y publica
///     el 1600 — a nivel de BD, no de meta.
///
/// Sin red real: RPC inyectada y controlable (puerta manual) y
/// la tabla contra la BD local real (FFI), patrón de la casa.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _rutaDb() async {
  final dir = await getDatabasesPath();
  return p.join(dir, 'ironbody.db');
}

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dbPath = await _rutaDb();
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<Map<String, String>> _pendientes() =>
    LocalDb.instance.infoPublicaPendientes();

Future<void> _marcarPendiente(String clave, String valor) =>
    LocalDb.instance.marcarInfoPublicaPendiente(clave, valor);

/// Red falsa controlable: cada RPC de publicación puede quedar
/// retenida en una puerta (Completer) hasta que el test la
/// abre, y los valores listados en [valoresQueFallan] lanzan
/// como si no hubiera red. Registra el orden de INICIO de las
/// RPC y el máximo de RPC simultáneas observadas.
class _RedControlable {
  Completer<void>? puerta;
  final Set<String> valoresQueFallan = {};
  final List<String> inicios = [];
  final Map<String, String> publicadas = {};
  int _enCurso = 0;
  int maxSimultaneas = 0;
  final Completer<void> _primeraRpc = Completer<void>();

  Future<void> get primeraRpcEnVuelo => _primeraRpc.future;

  Future<dynamic> rpc(String nombre, Map<String, dynamic>? params) async {
    final clave = '${params?['p_clave']}';
    final valor = '${params?['p_valor']}';
    _enCurso++;
    if (_enCurso > maxSimultaneas) maxSimultaneas = _enCurso;
    inicios.add('$clave=$valor');
    if (!_primeraRpc.isCompleted) _primeraRpc.complete();
    try {
      final p = puerta;
      if (p != null) await p.future;
      if (valoresQueFallan.contains(valor)) {
        throw Exception('sin red (test)');
      }
      publicadas[clave] = valor;
      return <String, dynamic>{};
    } finally {
      _enCurso--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('serialización (cadena del servicio)', () {
    test('(c) un guardado concurrente espera a la republicación '
        'en curso: nunca hay dos RPC solapadas', () async {
      final db = await _abrirDbVacia();
      await _marcarPendiente('precio_app_plus', '1200');
      final red = _RedControlable()..puerta = Completer<void>();
      // Dos instancias distintas, como en producción: el gancho
      // de sync (main.dart) y Ajustes (admin.dart) crean la suya.
      final gancho = InvitadosService(rpc: red.rpc);
      final ajustes = InvitadosService(rpc: red.rpc);

      final fGancho = gancho.republicarInfoPublicaPendiente();
      await red.primeraRpcEnVuelo
          .timeout(const Duration(seconds: 10));
      expect(red.inicios, ['precio_app_plus=1200']);

      final fAjustes =
          ajustes.guardarInfoPublicaConReintento('precio_app_plus', '1500');
      // El guardado queda EN COLA: ni siquiera inicia su RPC
      // mientras la republicación del 1200 sigue en vuelo.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(red.inicios, ['precio_app_plus=1200']);
      expect(red.maxSimultaneas, 1);

      red.puerta!.complete();
      red.puerta = null;
      await fGancho;
      await fAjustes;

      expect(red.inicios,
          ['precio_app_plus=1200', 'precio_app_plus=1500']);
      expect(red.maxSimultaneas, 1);
      expect(red.publicadas, {'precio_app_plus': '1500'});
      expect(await _pendientes(), isEmpty);
      await db.close();
    });

    test('(a) guardado en cola cuya publicación FALLA: la marca '
        'queda en el valor nuevo, no en el publicado ni vacía',
        () async {
      final db = await _abrirDbVacia();
      await _marcarPendiente('precio_app_plus', '1200');
      final red = _RedControlable()
        ..puerta = Completer<void>()
        ..valoresQueFallan.add('1500');
      final gancho = InvitadosService(rpc: red.rpc);
      final ajustes = InvitadosService(rpc: red.rpc);

      final fGancho = gancho.republicarInfoPublicaPendiente();
      await red.primeraRpcEnVuelo
          .timeout(const Duration(seconds: 10));
      final fAjustes =
          ajustes.guardarInfoPublicaConReintento('precio_app_plus', '1500');
      red.puerta!.complete();
      red.puerta = null;
      await fGancho;
      await fAjustes;

      // El 1200 se publicó; el 1500 se intentó y falló.
      expect(red.inicios,
          ['precio_app_plus=1200', 'precio_app_plus=1500']);
      expect(red.publicadas, {'precio_app_plus': '1200'});
      // La fila NO desaparece ni vuelve al 1200: sigue pendiente
      // el 1500.
      expect(await _pendientes(), {'precio_app_plus': '1500'});

      // (b) Con la red sana, la siguiente republicación publica
      // el 1500 y limpia la fila.
      red.valoresQueFallan.clear();
      await gancho.republicarInfoPublicaPendiente();
      expect(red.publicadas, {'precio_app_plus': '1500'});
      expect(await _pendientes(), isEmpty);
      await db.close();
    });
  });

  group('limpieza atómica (la fila cambia fuera de la cadena)', () {
    test('(a) la fila cambia DURANTE la republicación en vuelo: '
        'el DELETE condicional no barre la marca nueva', () async {
      final db = await _abrirDbVacia();
      await _marcarPendiente('precio_app_plus', '1200');
      final red = _RedControlable()..puerta = Completer<void>();
      final svc = InvitadosService(rpc: red.rpc);

      final fRep = svc.republicarInfoPublicaPendiente();
      await red.primeraRpcEnVuelo
          .timeout(const Duration(seconds: 10));

      // Un guardado más nuevo aterriza en la tabla MIENTRAS la
      // RPC del 1200 sigue en vuelo (un solo INSERT OR REPLACE,
      // como haría otro isolate, al que la cadena no alcanza).
      await _marcarPendiente('precio_app_plus', '1500');

      red.puerta!.complete();
      red.puerta = null;
      await fRep;

      // El 1200 SÍ se publicó...
      expect(red.publicadas, {'precio_app_plus': '1200'});
      // ...pero su DELETE (clave, 1200) afectó 0 filas: la fila
      // del 1500 sobrevive intacta.
      expect(await _pendientes(), {'precio_app_plus': '1500'});

      // (b) La republicación siguiente publica el 1500 y limpia.
      await svc.republicarInfoPublicaPendiente();
      expect(red.publicadas, {'precio_app_plus': '1500'});
      expect(await _pendientes(), isEmpty);
      await db.close();
    });
  });

  group('entre isolates (segunda conexión a la misma BD)', () {
    test('la republicación del 1200 en vuelo no borra la marca '
        'del 1600 escrita por OTRA conexión', () async {
      final db = await _abrirDbVacia();
      await _marcarPendiente('precio_app_plus', '1200');
      final red = _RedControlable()..puerta = Completer<void>();
      final svc = InvitadosService(rpc: red.rpc);

      // Este isolate (el de fondo) republica el 1200; su RPC
      // queda en vuelo, retenida en la puerta.
      final fRep = svc.republicarInfoPublicaPendiente();
      await red.primeraRpcEnVuelo
          .timeout(const Duration(seconds: 10));

      // OTRO isolate (el de la app, como el dispatcher de
      // fondo en producción): abre su PROPIA conexión a la
      // misma BD, marca el 1600 con un INSERT OR REPLACE y lo
      // publica. SQLite serializa las sentencias entre
      // conexiones: no hay foto compartida que pisar. (En el
      // mismo isolate, sqflite deduplica la conexión nativa
      // por ruta aunque cambie la factory: la segunda conexión
      // DEBE vivir en otro isolate, igual que en producción.)
      final ruta = await _rutaDb();
      await Isolate.run(() async {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        final otraConexion =
            await databaseFactoryFfi.openDatabase(ruta);
        try {
          await otraConexion.rawInsert(
              'INSERT OR REPLACE INTO info_publica_pendiente '
              '(clave, valor) VALUES (?, ?)',
              ['precio_app_plus', '1600']);
        } finally {
          await otraConexion.close();
        }
      });
      red.publicadas['precio_app_plus'] = '1600';
      // La conexión de LocalDb VE la fila escrita por la otra
      // conexión: mismo fichero, conexiones distintas.
      expect(await _pendientes(), {'precio_app_plus': '1600'});

      // La RPC del 1200 por fin completa.
      red.puerta!.complete();
      red.puerta = null;
      await fRep;

      // La limpieza del 1200 (DELETE por clave+valor) afectó 0
      // filas: NO queda marca del 1200 NI se borró la del 1600.
      expect(await _pendientes(), {'precio_app_plus': '1600'});

      // La siguiente republicación publica el 1600 y limpia.
      await svc.republicarInfoPublicaPendiente();
      expect(red.publicadas, {'precio_app_plus': '1600'});
      expect(await _pendientes(), isEmpty);
      await db.close();
    });
  });
}
