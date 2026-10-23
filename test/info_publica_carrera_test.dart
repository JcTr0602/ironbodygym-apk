/// Carrera de la republicación de info pública (v1.7.0, delta
/// del panel): el gancho de fin de sync republicando un valor
/// NO puede barrer la marca de un guardado más nuevo.
///
/// Dos defensas, ambas probadas aquí:
///  1. SERIALIZACIÓN: guardar y republicar corren en una cadena
///     compartida del servicio; nunca hay dos RPC de publicación
///     solapadas en el mismo isolate.
///  2. LIMPIEZA DEFENSIVA: tras publicar, la marca se recalcula
///     sobre la meta ACTUAL y solo se borra la clave cuyo valor
///     sigue siendo el recién publicado; si el valor cambió
///     mientras tanto, la marca nueva sobrevive.
///
/// Sin red real: RPC inyectada y controlable (puerta manual) y
/// la meta contra la BD local real (FFI), patrón de la casa.
library;

import 'dart:async';
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

Future<Map<String, String>> _pendientesEnMeta() async =>
    decodificarInfoPublicaPendiente(
        await LocalDb.instance.getMeta(kMetaInfoPublicaPendiente));

Future<void> _marcarPendiente(String clave, String valor) =>
    LocalDb.instance.setMeta(kMetaInfoPublicaPendiente,
        codificarInfoPublicaPendiente({clave: valor}));

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

  group('pendientesTrasRepublicar (limpieza defensiva, pura)', () {
    test('valor sin cambiar: la clave publicada se limpia', () {
      expect(
        pendientesTrasRepublicar(
          actuales: {'precio_app_plus': '1200'},
          publicadas: {'precio_app_plus': '1200'},
        ),
        isEmpty,
      );
    });

    test('valor cambiado mientras tanto: la marca NUEVA se '
        'conserva', () {
      expect(
        pendientesTrasRepublicar(
          actuales: {'precio_app_plus': '1500'},
          publicadas: {'precio_app_plus': '1200'},
        ),
        {'precio_app_plus': '1500'},
      );
    });

    test('las claves ajenas al intento quedan intactas', () {
      expect(
        pendientesTrasRepublicar(
          actuales: {'precio_app_plus': '1200', 'otra': 'x'},
          publicadas: {'precio_app_plus': '1200'},
        ),
        {'otra': 'x'},
      );
    });

    test('sin publicadas no se borra nada', () {
      expect(
        pendientesTrasRepublicar(
          actuales: {'precio_app_plus': '1200'},
          publicadas: const {},
        ),
        {'precio_app_plus': '1200'},
      );
    });
  });

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
      expect(await _pendientesEnMeta(), isEmpty);
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
      // La marca NO es '' ni {1200}: sigue pendiente el 1500.
      expect(await _pendientesEnMeta(), {'precio_app_plus': '1500'});

      // (b) Con la red sana, la siguiente republicación publica
      // el 1500 y limpia la marca.
      red.valoresQueFallan.clear();
      await gancho.republicarInfoPublicaPendiente();
      expect(red.publicadas, {'precio_app_plus': '1500'});
      expect(await _pendientesEnMeta(), isEmpty);
      await db.close();
    });
  });

  group('limpieza defensiva (marca movida fuera de la cadena)', () {
    test('(a) la meta cambia DURANTE la republicación en vuelo: '
        'la limpieza no barre la marca nueva', () async {
      final db = await _abrirDbVacia();
      await _marcarPendiente('precio_app_plus', '1200');
      final red = _RedControlable()..puerta = Completer<void>();
      final svc = InvitadosService(rpc: red.rpc);

      final fRep = svc.republicarInfoPublicaPendiente();
      await red.primeraRpcEnVuelo
          .timeout(const Duration(seconds: 10));

      // Un guardado más nuevo aterriza en la meta MIENTRAS la
      // RPC del 1200 sigue en vuelo (p. ej. escrito desde el
      // isolate de fondo, al que la cadena no alcanza).
      await _marcarPendiente('precio_app_plus', '1500');

      red.puerta!.complete();
      red.puerta = null;
      await fRep;

      // El 1200 SÍ se publicó...
      expect(red.publicadas, {'precio_app_plus': '1200'});
      // ...pero la marca del 1500 sobrevive intacta.
      expect(await _pendientesEnMeta(), {'precio_app_plus': '1500'});

      // (b) La republicación siguiente publica el 1500 y limpia.
      await svc.republicarInfoPublicaPendiente();
      expect(red.publicadas, {'precio_app_plus': '1500'});
      expect(await _pendientesEnMeta(), isEmpty);
      await db.close();
    });
  });
}
