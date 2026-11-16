/// Lote 1.35 · SL-1 · Fichas de servicio (sin pantalla):
/// - A-12 (g06 nº12): la reconciliación NO cancela una
///   preparación nacida offline.
/// - A-09 (g06 nº9): el ancla del candado no se sobre-adelanta
///   sin cota tras un reinicio con salto de reloj.
/// - BG-01: el parseo de reportes Plus tolera formas no-List.
/// (A-20 va en su propio archivo: lote135_sl1_a20_test.dart.)
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_bloqueo.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plus_reportes.dart';
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

InvitadoDetalle _detalleSinPreparada() => InvitadoDetalle.fromJson({
      'invitado': {
        'id': 'inv-1',
        'nombre': 'Invitado Uno',
        'telefono': '58112233',
        'estado': 'activo',
        'creado_en': '2026-11-01T10:00:00',
        'caduca_en': '2027-01-01T10:00:00',
      },
    });

ConversionInvitado _preparada({required bool nacidaOffline}) =>
    ConversionInvitado(
      invitadoId: 'inv-1',
      conversionUuid: 'uuid-local-1',
      estado: EstadoConversion.preparada,
      nacidaOffline: nacidaOffline,
      creadaEn: '2026-11-16T10:00:00-05:00',
      actualizadaEn: '2026-11-16T10:00:00-05:00',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
  });

  group('A-12 · reconciliarPreparadaObsoleta', () {
    setUp(() async => _bdVacia());

    test(
        'una preparada nacidaOffline vuelve INTACTA aunque el '
        'servidor no la conozca', () async {
      final svc = InvitadosService(rpc: (n, params) async => null);
      final local = _preparada(nacidaOffline: true);
      await ConversionInvitadoStore().guardar(local);
      final res = await svc.reconciliarPreparadaObsoleta(
          _detalleSinPreparada(), local);
      expect(res.estado, EstadoConversion.preparada,
          reason: 'la nacida offline no se cancela: el servidor '
              'aún no la conoce y eso es lo esperado');
      final guardada = await ConversionInvitadoStore().leer('inv-1');
      expect(guardada?.estado, EstadoConversion.preparada);
    });

    test(
        'el gemelo SIN la marca sigue cancelando (la '
        'reconciliación conserva su función)', () async {
      final svc = InvitadosService(rpc: (n, params) async => null);
      final local = _preparada(nacidaOffline: false);
      await ConversionInvitadoStore().guardar(local);
      final res = await svc.reconciliarPreparadaObsoleta(
          _detalleSinPreparada(), local);
      expect(res.estado, EstadoConversion.cancelada);
    });
  });

  group('BG-01 · parsearReportesPlus tolerante', () {
    test('una forma no-List en «reportes» da lista vacía, '
        'sin TypeError', () {
      expect(parsearReportesPlus({'reportes': {'no': 'lista'}}),
          isEmpty);
      expect(parsearReportesPlus({'reportes': 42}), isEmpty);
      expect(parsearReportesPlus({'pendientes': 'texto'}), isEmpty);
    });

    test('null y formas sin lista dan lista vacía', () {
      expect(parsearReportesPlus(null), isEmpty);
      expect(parsearReportesPlus(const {}), isEmpty);
    });

    test('la forma buena sigue parseando (gemelo sano)', () {
      final r = parsearReportesPlus({
        'reportes': [
          {
            'id': '7',
            'invitado_id': 'inv-1',
            'nombre': 'Ana',
            'telefono': '58112233',
            'monto_cup': 1000,
            'referencia': 'REF1',
          },
        ],
      });
      expect(r.length, 1);
      expect(r.first.nombre, 'Ana');
    });
  });

  group('A-09 · ancla del candado tras reinicio', () {
    test(
        'reloj de pared +30 días con la app cerrada minutos: '
        'la hora estimada NO se adelanta y la pausa sigue '
        'vigente', () async {
      await _bdVacia();
      // Ancla guardada hace 30 días y 5 minutos (pared y
      // servidor en el mismo instante): el salto de +30 días
      // del reloj NO es tiempo transcurrido real.
      final ahora = DateTime.now().toUtc();
      final ancla = ahora.subtract(const Duration(days: 30, minutes: 5));
      await LocalDb.instance.setMeta(
          'bloqueo_ancla_server', ancla.toIso8601String());
      await LocalDb.instance.setMeta(
          'bloqueo_ancla_pared', ancla.toIso8601String());

      final svc = AccesoBloqueoService.instance;
      svc.iniciar();
      // La carga del ancla persistida es asíncrona: se espera
      // a que la estimación se separe del «ahora» sin ancla.
      var estimada = svc.ahoraServidorEstimada();
      for (var i = 0; i < 40; i++) {
        estimada = svc.ahoraServidorEstimada();
        if (ahora.difference(estimada).inHours > 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // La estimación debe quedarse en el ancla (sin adelanto
      // usable ante un salto implausible): a menos de 1 día
      // del ancla, jamás +30 días.
      expect(estimada.difference(ancla).inDays, lessThan(1),
          reason: 'el salto de pared de +30 días no puede '
              'adelantar la hora del servidor estimada');
      // Y la pausa que vence 3 días después del ancla sigue
      // vigente con esa estimación.
      final bloqueo = evaluarBloqueoLocal(
        [
          {
            'activo': 1,
            'app': 'gestion',
            'alcance': 'global',
            'mensaje': 'Pausa de prueba',
            'expira_ts':
                ancla.add(const Duration(days: 3)).toIso8601String(),
          },
        ],
        telegramId: null,
        ahoraServidor: estimada,
      );
      expect(bloqueo, isNotNull,
          reason: 'la pausa temporal no se levanta antes de '
              'tiempo por un salto de reloj');
    });
  });

}
