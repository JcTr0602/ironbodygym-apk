/// Diario de sincronizaciones M1 (1.32, Oleada 2 Fase 2):
/// reglas de plaza y poda (puras) y comportamiento del
/// almacén contra la BD real (apertura, cierre condicional,
/// huérfana cortada, acumulación ON CONFLICT, chequeo vacío
/// sin plaza y retención con blindaje forense).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diario_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_diario_sync_test.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_diario_sync_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

void main() {
  group('corridaSinPlaza (M1-R3, pura)', () {
    test('automática completa y vacía: sin plaza', () {
      expect(
          corridaSinPlaza(
              origen: 'automatica',
              estado: 'completa',
              subidos: 0,
              bajados: 0,
              fotosSubidas: 0,
              fotosFallidas: 0),
          isTrue);
    });
    test('automática con bajados: con plaza', () {
      expect(
          corridaSinPlaza(
              origen: 'automatica',
              estado: 'completa',
              subidos: 0,
              bajados: 3,
              fotosSubidas: 0,
              fotosFallidas: 0),
          isFalse);
    });
    test('manual vacía: con plaza (la pidió una persona)', () {
      expect(
          corridaSinPlaza(
              origen: 'manual',
              estado: 'completa',
              subidos: 0,
              bajados: 0,
              fotosSubidas: 0,
              fotosFallidas: 0),
          isFalse);
    });
    test('automática fallida vacía: con plaza (forense)', () {
      expect(
          corridaSinPlaza(
              origen: 'automatica',
              estado: 'fallida',
              subidos: 0,
              bajados: 0,
              fotosSubidas: 0,
              fotosFallidas: 0),
          isFalse);
    });
    test('automática completa con una foto fallida: con plaza', () {
      expect(
          corridaSinPlaza(
              origen: 'automatica',
              estado: 'completa',
              subidos: 0,
              bajados: 0,
              fotosSubidas: 0,
              fotosFallidas: 1),
          isFalse);
    });
  });

  group('seleccionarPodaDiario (pura)', () {
    ({String id, String tipo, String origen, String estado, int inicioEpoch})
        fila(String id, int inicio,
                {String tipo = 'solo_pull',
                String origen = 'automatica',
                String estado = 'completa'}) =>
            (
              id: id,
              tipo: tipo,
              origen: origen,
              estado: estado,
              inicioEpoch: inicio
            );

    test('lo viejo de 30 días se poda aunque esté blindado', () {
      const ahora = 40 * 24 * 3600;
      final poda = seleccionarPodaDiario(
        [fila('vieja', 100, tipo: 'bajada_completa')],
        ahoraEpoch: ahora,
      );
      expect(poda, ['vieja']);
    });

    test('por cantidad: se conservan 50 y el exceso se poda',
        () {
      const ahora = 100 * 24 * 3600;
      final filas = [
        for (var i = 0; i < 55; i++)
          fila('c$i', ahora - i * 60),
      ];
      final poda = seleccionarPodaDiario(filas, ahoraEpoch: ahora);
      expect(poda.length, 5);
      expect(poda, containsAll(['c50', 'c51', 'c52', 'c53', 'c54']));
    });

    test('blindaje: la bajada completa vieja y las 5 últimas '
        'fallidas sobreviven a la poda por cantidad', () {
      const ahora = 100 * 24 * 3600;
      final filas = <({String id, String tipo, String origen, String estado, int inicioEpoch})>[
        // La bajada completa es la MÁS antigua de las vivas.
        fila('bajada', ahora - 90 * 60, tipo: 'bajada_completa'),
        // 6 fallidas repartidas al final de la cola.
        for (var i = 0; i < 6; i++)
          fila('f$i', ahora - (80 - i) * 60, estado: 'fallida'),
        for (var i = 0; i < 50; i++) fila('c$i', ahora - i * 60),
      ];
      final poda = seleccionarPodaDiario(filas, ahoraEpoch: ahora);
      expect(poda, isNot(contains('bajada')),
          reason: 'la última bajada completa es forense: no '
              'se poda por cantidad');
      // De las 6 fallidas, las 5 más recientes se blindan; la
      // más antigua de las seis sí puede podarse.
      final fallidasPodadas =
          poda.where((id) => id.startsWith('f')).toList();
      expect(fallidasPodadas.length, lessThanOrEqualTo(1));
    });
  });

  group('resumenOpDiario (pura)', () {
    test('pago con monto: etiqueta y monto', () {
      final r = resumenOpDiario('pago_mensual', {'monto': 2000});
      expect(r, contains('2000 CUP'));
    });
    test('sin monto: solo la etiqueta', () {
      final r = resumenOpDiario('pago_mensual', const {});
      expect(r, isNot(contains('CUP')));
      expect(r, isNotEmpty);
    });
    test('el nombre del cliente NO entra en la foto', () {
      final r = resumenOpDiario('pago_mensual',
          {'monto': 2000, 'nombre': 'Erlys Lagunilla'});
      expect(r, isNot(contains('Erlys')));
    });
  });

  group('almacén DiarioSync (BD real)', () {
    test('abrir y cerrar una corrida manual: queda en el '
        'historial con su veredicto', () async {
      await _init();
      final d = DiarioSync.instance;
      final id = await d.abrirCorrida(
          tipo: 'completa', origen: 'manual', ahoraEpoch: 1000);
      final enCurso = await d.corridaEnCurso();
      expect(enCurso?.id, id);
      final quedo = await d.cerrarCorrida(id,
          estado: 'completa',
          duracionMs: 1234,
          subidos: 2,
          bajados: 5,
          serverSeq: 900,
          watermarkMin: 900,
          ahoraEpoch: 1001);
      expect(quedo, isTrue);
      final h = await d.historial();
      expect(h, hasLength(1));
      expect(h.first.estado, 'completa');
      expect(h.first.subidos, 2);
      expect(h.first.bajados, 5);
      expect(h.first.duracionMs, 1234);
      expect(await d.corridaEnCurso(), isNull);
    });

    test('chequeo automático vacío: no ocupa plaza y deja '
        'sellos en meta', () async {
      await _init();
      final d = DiarioSync.instance;
      final id = await d.abrirCorrida(
          tipo: 'solo_pull', origen: 'automatica', ahoraEpoch: 2000);
      final quedo = await d.cerrarCorrida(id,
          estado: 'completa', duracionMs: 50, ahoraEpoch: 2001);
      expect(quedo, isFalse,
          reason: 'el chequeo vacío no crea fila (M1-R3)');
      expect(await d.historial(), isEmpty);
      expect(
          await LocalDb.instance
              .getMeta('chequeos_vacios_desde_ultima_corrida'),
          '1');
      expect(
          await LocalDb.instance.getMeta('ultimo_chequeo_vacio_ts'),
          '2001');
      // La siguiente corrida CON datos reinicia el contador.
      final id2 = await d.abrirCorrida(
          tipo: 'solo_pull', origen: 'automatica', ahoraEpoch: 3000);
      await d.cerrarCorrida(id2,
          estado: 'completa',
          duracionMs: 80,
          bajados: 4,
          ahoraEpoch: 3001);
      expect(
          await LocalDb.instance
              .getMeta('chequeos_vacios_desde_ultima_corrida'),
          '0');
      expect(await d.historial(), hasLength(1));
    });

    test('huérfana: la siguiente corrida la cierra cortada '
        'con la foto congelada y el zombi no la resucita',
        () async {
      await _init();
      final d = DiarioSync.instance;
      final idVieja = await d.abrirCorrida(
          tipo: 'completa', origen: 'instalacion', ahoraEpoch: 5000);
      await d.anotarProgreso(idVieja, tabla: 'pagos', pagina: 3);
      await d.volcarTablas(idVieja, {
        'clientes': AcumTablaDiario()
          ..fusionarIntento(
              aplicadas: 100, paginas: 1, wmAntes: 0, wmDespues: 50,
              estado: 'ok'),
      });
      // La nueva corrida cierra la huérfana al adquirir el
      // candado (M1-A4).
      final cerradas =
          await d.cerrarHuerfanasComoCortadas(ahoraEpoch: 5900);
      expect(cerradas, 1);
      final h = await d.historial();
      final cortada = h.firstWhere((c) => c.id == idVieja);
      expect(cortada.estado, 'cortada');
      expect(cortada.tablaActual, 'pagos');
      expect(cortada.paginaActual, 3);
      final tablas = await d.tablasDe(idVieja);
      expect(tablas, hasLength(1));
      expect(tablas.first.aplicadas, 100);
      // El zombi intenta cerrar la suya: no debe mutarla.
      await d.cerrarCorrida(idVieja,
          estado: 'completa',
          duracionMs: 1,
          bajados: 999,
          ahoraEpoch: 5950);
      final tras = (await d.historial())
          .firstWhere((c) => c.id == idVieja);
      expect(tras.estado, 'cortada',
          reason: 'la foto congelada manda: el cierre tardío '
              'del zombi no resucita la corrida');
      expect(tras.bajados, 0);
    });

    test('volcarTablas acumula entre intentos conservando '
        'el wm_antes original (M1-A3)', () async {
      await _init();
      final d = DiarioSync.instance;
      final id = await d.abrirCorrida(
          tipo: 'completa', origen: 'manual', ahoraEpoch: 7000);
      await d.volcarTablas(id, {
        'pagos': AcumTablaDiario()
          ..fusionarIntento(
              recibidas: 10, aplicadas: 9, sinCambio: 1, paginas: 1,
              wmAntes: 40, wmDespues: 80, estado: 'fallida',
              error: 'HTTP 500'),
      });
      await d.volcarTablas(id, {
        'pagos': AcumTablaDiario()
          ..fusionarIntento(
              recibidas: 5, aplicadas: 5, paginas: 1, wmAntes: 80,
              wmDespues: 120, estado: 'ok'),
      });
      final tablas = await d.tablasDe(id);
      expect(tablas, hasLength(1));
      final t = tablas.first;
      expect(t.recibidas, 15);
      expect(t.aplicadas, 14);
      expect(t.paginas, 2);
      expect(t.wmAntes, 40,
          reason: 'el wm_antes es el del primer intento');
      expect(t.wmDespues, 120);
      expect(t.estado, 'ok',
          reason: 'el estado final es el del último intento');
      expect(t.error, isNull);
    });

    test('volcarOps guarda la foto y ultimaCorridaConOps la '
        'encuentra', () async {
      await _init();
      final d = DiarioSync.instance;
      final id = await d.abrirCorrida(
          tipo: 'solo_push', origen: 'manual', ahoraEpoch: 8000);
      await d.volcarOps(id, const [
        CorridaOpSync(
            opUuid: 'uuid-1',
            tipo: 'pago_mensual',
            resumen: 'Pago mensual · 2000 CUP',
            resultado: 'aplicada'),
        CorridaOpSync(
            opUuid: 'uuid-2',
            tipo: 'inscribir_cliente',
            resumen: 'Inscripción',
            resultado: 'rechazada',
            motivo: 'El carnet ya existe'),
      ]);
      await d.cerrarCorrida(id,
          estado: 'parcial', duracionMs: 10, subidos: 1,
          ahoraEpoch: 8001);
      final conOps = await d.ultimaCorridaConOps();
      expect(conOps?.id, id);
      final ops = await d.opsDe(id);
      expect(ops, hasLength(2));
      expect(ops[1].resultado, 'rechazada');
      expect(ops[1].motivo, contains('carnet'));
    });
  });
}
