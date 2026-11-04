/// 1.23 — Sync en segundo plano: la regla pura del
/// cortacircuitos del FGS y la marca del aviso de pendientes.
///
/// - Sin trabajo reclamable → el servicio se detiene por
///   terminado, haya o no habido progreso.
/// - Con progreso → sigue y el contador se reinicia.
/// - Sin progreso → cuenta; al tercer tick seguido se detiene
///   por cortacircuitos (no gira con WakeLock en una red muerta).
/// - La marca del aviso (meta) se deja y se limpia al cancelar.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/aviso_pendientes.dart';
import 'package:ironbody_gym/fotos_foreground.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('cortacircuitos del FGS (regla pura)', () {
    test('sin trabajo reclamable: detener por terminado', () {
      expect(
          decisionTickFgs(progreso: 0, quedan: false, ticksSinProgreso: 0),
          DecisionTickFgs.detenerTerminado);
      expect(
          decisionTickFgs(progreso: 5, quedan: false, ticksSinProgreso: 2),
          DecisionTickFgs.detenerTerminado);
    });

    test('con progreso y trabajo restante: seguir', () {
      expect(
          decisionTickFgs(progreso: 1, quedan: true, ticksSinProgreso: 2),
          DecisionTickFgs.seguir);
    });

    test('sin progreso: cuenta y al tercero corta', () {
      expect(
          decisionTickFgs(progreso: 0, quedan: true, ticksSinProgreso: 0),
          DecisionTickFgs.contarSinProgreso);
      expect(
          decisionTickFgs(progreso: 0, quedan: true, ticksSinProgreso: 1),
          DecisionTickFgs.contarSinProgreso);
      expect(
          decisionTickFgs(progreso: 0, quedan: true, ticksSinProgreso: 2),
          DecisionTickFgs.detenerCortacircuitos);
    });
  });

  group('aviso de pendientes (marca en meta)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    setUp(() async {
      await LocalDb.resetParaTest();
    });

    test('dejarMarca escribe ligada al usuario y cancelar '
        'limpia', () async {
      await AvisoPendientesSync.dejarMarca(4, userId: 'user-1');
      final marca =
          await LocalDb.instance.getMeta('aviso_sync_pendientes');
      expect(marca, isNotNull);
      expect(marca!.startsWith('user-1|4|'), isTrue);
      await AvisoPendientesSync.cancelar();
      final trasCancelar =
          await LocalDb.instance.getMeta('aviso_sync_pendientes');
      expect(trasCancelar ?? '', '');
    });

    test('delta panel: la marca de OTRA cuenta se limpia sin '
        'mostrar (sin sesión en el test = no es su dueño)',
        () async {
      await AvisoPendientesSync.dejarMarca(7, userId: 'user-9');
      await AvisoPendientesSync.mostrarSiPendiente();
      final marca =
          await LocalDb.instance.getMeta('aviso_sync_pendientes');
      expect(marca ?? '', '',
          reason: 'la marca ajena se consume en silencio');
    });

    test('mostrarSiPendiente sin marca no hace nada ni rompe',
        () async {
      await AvisoPendientesSync.mostrarSiPendiente();
      final marca =
          await LocalDb.instance.getMeta('aviso_sync_pendientes');
      expect(marca, isNull);
    });
  });

  group('barrera de mantenimiento (delta panel)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', anonKey: 'dummy');
      } catch (_) {}
    });

    test('iniciar/fin: el flag se crea y se borra; inactivo '
        'al principio', () async {
      expect(await LocalDb.instance.mantenimientoActivo(),
          isFalse);
      await LocalDb.instance.iniciarMantenimiento();
      expect(await LocalDb.instance.mantenimientoActivo(),
          isTrue);
      await LocalDb.instance.finMantenimiento();
      expect(await LocalDb.instance.mantenimientoActivo(),
          isFalse);
    });

    test('delta 2 del panel: dos bases en el mismo directorio '
        'tienen barreras INDEPENDIENTES', () async {
      // El flag deriva de la RUTA de la base: la barrera de
      // una base no bloquea ni se borra desde otra.
      LocalDb.nombreArchivoDbForzado = 'base_a_test.db';
      await LocalDb.instance.iniciarMantenimiento();
      expect(await LocalDb.instance.mantenimientoActivo(),
          isTrue);
      LocalDb.nombreArchivoDbForzado = 'base_b_test.db';
      expect(await LocalDb.instance.mantenimientoActivo(),
          isFalse,
          reason: 'la base B no hereda la barrera de la A');
      // Cerrar la barrera de B (inexistente) no toca la de A.
      await LocalDb.instance.finMantenimiento();
      LocalDb.nombreArchivoDbForzado = 'base_a_test.db';
      expect(await LocalDb.instance.mantenimientoActivo(),
          isTrue);
      await LocalDb.instance.finMantenimiento();
      expect(await LocalDb.instance.mantenimientoActivo(),
          isFalse);
      LocalDb.nombreArchivoDbForzado = null;
    });
  });
}
