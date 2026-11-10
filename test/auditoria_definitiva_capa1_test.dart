/// Auditoría Definitiva · Capa 1 (parcial) — correcciones de la
/// oleada sobre Gestión 1.31 (base ef074cd). Cada grupo caza la
/// entrada numerada del consolidado
/// (cola-123/auditoria_definitiva/consolidado_capa1_parcial.md §E).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    for (final nombre in ['ironbody.db', 'ironbody_$pid.db']) {
      try {
        await File(p.join(dir, nombre) + sufijo).delete();
      } catch (_) {}
    }
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Map<String, dynamic> _opPago({
  required int clienteId,
  required String? optimista,
  required String? anterior,
}) {
  return {
    'op_uuid': 'op-test',
    'tipo': 'pago_mensual',
    'payload': jsonEncode({
      'cliente_id': clienteId,
      if (optimista != null) 'pagado_hasta': optimista,
      'pagado_hasta_anterior': anterior,
    }),
  };
}

Future<String?> _pagadoHastaEspejo(int clienteId) async {
  final filas =
      await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
  if (filas.isEmpty) return null;
  final v = filas.first['pagado_hasta'];
  return v == null ? null : '$v';
}

void main() {
  group('A-3 · reversión del vencimiento con guarda de procedencia',
      () {
    test('revierte si el espejo aún lleva el valor de ESTA op',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          501,
          {'id': 501, 'nombre': 'A', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 501,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(501), '2026-11-10');
    });

    test('NO pisa el vencimiento de un pago posterior confirmado',
        () async {
      await _abrirDbVacia();
      // El espejo ya muestra el vencimiento del SEGUNDO pago
      // (confirmado); la op rechazada es la PRIMERA.
      await LocalDb.instance.upsertMirror(
          'clientes',
          502,
          {'id': 502, 'nombre': 'B', 'pagado_hasta': '2027-01-09'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 502,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(502), '2027-01-09',
          reason: 'la reversión tardía borró el pago válido');
    });

    test('anterior null limpia el vencimiento solo si es el suyo',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          503,
          {'id': 503, 'nombre': 'C', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 503, optimista: '2026-12-10', anterior: null));
      expect(await _pagadoHastaEspejo(503), isNull);
    });

    test('op sin vencimiento optimista en el payload: no toca nada',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          504,
          {'id': 504, 'nombre': 'D', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 504, optimista: null, anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(504), '2026-12-10');
    });
  });

  group('A-2 · el sello de éxito exige push limpio (estructural)',
      () {
    final sync = File('lib/sync.dart').readAsStringSync();

    test('los bumps del push ensucian el veredicto de la corrida',
        () {
      final i = sync.indexOf('Future<void> _bumpConReversion');
      expect(i, isNonNegative);
      final cuerpo = sync.substring(i, i + 400);
      expect(cuerpo, contains('_fallosUltimoPush++'),
          reason: 'un bump ya no cuenta como fallo del push: '
              'el ciclo volvería a sellar en verde con la '
              'subida rota');
      expect(sync, contains('pushOk = _ultimoPushLimpio;'),
          reason: 'run() volvió a dar el push por bueno solo '
              'porque _doPush no lanzó');
    });

    test('la rama de ciclo completo exige pushOk para sellar', () {
      expect(sync, contains('if (completo && pushOk)'),
          reason: 'la rama completo volvió a sellar sin mirar '
              'la subida');
      final j = sync.indexOf('} else if (completo) {');
      expect(j, isNonNegative,
          reason: 'falta la rama «bajada completa, subida '
              'sucia» que conserva el error');
      final rama = sync.substring(j, j + 700);
      expect(rama, contains("setMeta('last_sync_error', msgPushSucio)"));
      expect(rama, isNot(contains('_marcarOk()')),
          reason: 'la rama de subida sucia no puede sellar');
    });

    test('el gancho de éxito y la limpieza de error van '
        'condicionados', () {
      expect(
          sync,
          contains('if (errorCorrida == null) _avisarSyncExitoso();'),
          reason: 'run() volvió a avisar éxito con la corrida '
              'en error');
      expect(sync, contains('if (_ultimoPushLimpio) _avisarSyncExitoso();'),
          reason: 'push() volvió a avisar éxito sin push limpio');
      final k = sync.indexOf("if (_ultimoPushLimpio) {\n"
          "        await _db.setMeta('last_sync_error', '');");
      expect(k, isNonNegative,
          reason: 'push() volvió a limpiar last_sync_error '
              'incondicionalmente');
    });
  });

  group('A-4 · la bandera de comprobantes no queda pegada', () {
    test('tras la pausa QoS, el siguiente ciclo SÍ procesa',
        () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      // Comprobante pendiente con el archivo ausente: si un
      // ciclo llega a procesarlo, termina en 'error'
      // (archivo_ausente) sin tocar la red.
      await d.insert('comprobantes_pago', {
        'comprobante_uuid': 'comp-a4',
        'ruta_local': '/no/existe/comp-a4.jpg',
        'storage_path': 'comprobantes/comp-a4.jpg',
        'estado': 'pendiente',
        'creado_en': '2026-11-10T00:00:00-05:00',
        'intentos': 0,
        'proximo_intento_en': 0,
      });
      // Una op de cobro pendiente cierra la puerta QoS.
      await db.queueOp(
          opUuid: 'op-a4',
          tipo: 'pago_mensual',
          payload: {'cliente_id': 1});
      expect(await ComprobantesService.instance.procesar(), 0);
      var fila = await ComprobantesService.instance.filaDe('comp-a4');
      expect(fila?['estado'], 'pendiente',
          reason: 'la puerta QoS no debió tocar la fila');
      // La op se aplica y la puerta se abre. Con la bandera
      // pegada (el defecto), este procesar() devolvería 0 al
      // instante sin mirar la fila.
      await db.markOp('op-a4', 'aplicada');
      await ComprobantesService.instance.procesar();
      fila = await ComprobantesService.instance.filaDe('comp-a4');
      expect(fila?['estado'], 'error',
          reason: 'el ciclo tras la pausa QoS no corrió: '
              '_procesando quedó pegada');
    });
  });
}
