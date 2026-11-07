/// Correcciones de la auditoría 3 (concurrencia) de la
/// ronda 2 de la 1.28:
///
/// - D1 (media-baja): la conciliación en lote no tenía
///   guarda de vuelo y el anti-duplicado de
///   ConciliacionService.marcar era check-then-act no
///   atómico: dos marcadas concurrentes encolaban dos
///   ops para el mismo pago (incidencia fantasma).
/// - D2 (baja): «Deshacer» liquidación en cola sin
///   guarda: el segundo toque enseñaba el falso «ya
///   sincronizó» tras un deshacer correcto.
/// - D3 (baja): la pastilla de vales del hub de Premios
///   sin guarda de generación: un conteo viejo podía
///   pisar al nuevo.
/// - X1 (duda, cerrada): AccesoAppCache.limpiar()
///   durante un cargar() en vuelo: el vuelo zombi
///   restauraba la foto persistida DESPUÉS de limpiar
///   y la dejaba como dato de la sesión nueva.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/conciliacion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('fuente: las guardas de UI están puestas', () {
    test('D1: _marcarLote tiene guarda síncrona y el botón '
        'se deshabilita con cargando', () {
      final src =
          File('lib/ui/conciliacion.dart').readAsStringSync();
      expect(src.contains('bool _marcandoLote = false'), isTrue);
      expect(src.contains('if (_marcandoLote) return;'), isTrue);
      expect(src.contains('cargando: _marcandoLote'), isTrue);
      expect(src.contains('onPressed: _marcandoLote ? null : _marcarLote'),
          isTrue);
    });

    test('D2: _deshacerEnCola tiene guarda síncrona y el '
        'botón se deshabilita', () {
      final src = File('lib/ui/arqueo.dart').readAsStringSync();
      expect(src.contains('bool _deshaciendo = false'), isTrue);
      expect(src.contains('if (_deshaciendo) return;'), isTrue);
      expect(src.contains('_deshaciendo\n'), isTrue);
      expect(src.contains(': _deshacerEnCola'), isTrue);
    });

    test('D3: el hub usa el contador de generación del '
        'patrón de admin.dart', () {
      final src =
          File('lib/ui/panel_premios_hub.dart').readAsStringSync();
      expect(src.contains('int _conteoGen = 0'), isTrue);
      expect(src.contains('final gen = ++_conteoGen;'), isTrue);
      expect(src.contains('gen != _conteoGen'), isTrue);
    });
  });

  group('BD real', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_correccion_a3.db';
      await LocalDb.resetParaTest();
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', anonKey: 'dummy');
      } catch (_) {}
    });

    // La BD con nombre forzado NO se borra entre corridas:
    // cada test arranca con la cola vacía para no heredar
    // las ops de una corrida anterior (en la suite
    // completa, la primera corrida dejó la op del pago 42
    // y ambos marcar() rebotaban contra ella).
    setUp(() async {
      await (await LocalDb.instance.db).delete('ops_queue');
    });

    Future<int> opsConciliacion() async {
      final ops = await LocalDb.instance.pendingOpsLectura();
      return ops.where((o) => o['tipo'] == 'marcar_conciliacion').length;
    }

    test('D1: dos marcar() concurrentes del mismo pago '
        'encolan UNA sola op', () async {
      var errores = 0;
      Future<void> intento() async {
        try {
          await ConciliacionService.instance.marcar(
            pagoId: 42,
            estado: 'comprobada',
            estadoEsperado: 'pendiente',
          );
        } on StateError {
          errores++;
        }
      }

      await Future.wait([intento(), intento()]);
      expect(errores, 1,
          reason: 'la segunda marcación debe rebotar en el '
              'anti-duplicado, dentro de la transacción');
      expect(await opsConciliacion(), 1);
    });

    test('D1: dos lotes concurrentes sobre las mismas '
        'filas no duplican ninguna op', () async {
      final filas = <Map<String, dynamic>>[
        {'id': 51},
        {'id': 52},
        {'id': 53},
      ];
      final rs = await Future.wait([
        ConciliacionService.instance.marcarLoteComprobadas(filas),
        ConciliacionService.instance.marcarLoteComprobadas(filas),
      ]);
      expect(rs[0].marcadas + rs[1].marcadas, 3);
      expect(rs[0].omitidas + rs[1].omitidas, 3);
      expect(await opsConciliacion(), 3);
    });

    group('X1 · AccesoAppCache', () {
      Future<void> sembrarFotoPersistida() async {
        await LocalDb.instance.setMeta(
          'acceso_app_cache_v1',
          jsonEncode({
            'verificado_en': isoHabana(ahoraHabana()),
            'filas': [
              {'cliente_id': 5, 'nombre': 'Ana', 'activo': true},
            ],
          }),
        );
      }

      test('limpiar() durante un cargar() en vuelo: la foto '
          'persistida NO repuebla la caché', () async {
        final cache = AccesoAppCache.instance;
        cache.limpiar();
        // El borrado de la foto aterriza antes de sembrar.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await sembrarFotoPersistida();
        final vuelo = cache.cargar();
        cache.limpiar();
        final ok = await vuelo;
        expect(ok, isFalse);
        expect(cache.cargado, isFalse,
            reason: 'el vuelo zombi restauró la foto DESPUÉS '
                'de limpiar: eso era la duda X1');
        expect(cache.todos, isNull);
      });

      test('sin limpiar de por medio, la foto persistida '
          'sigue pintando en frío aunque la RPC falle',
          () async {
        final cache = AccesoAppCache.instance;
        cache.limpiar();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await sembrarFotoPersistida();
        final ok = await cache.cargar();
        expect(ok, isFalse); // la RPC dummy no responde
        expect(cache.cargado, isTrue);
        expect(cache.esPersistido, isTrue);
        expect(cache.obtener(5)?.nombre, 'Ana');
        cache.limpiar();
      });
    });
  });
}
