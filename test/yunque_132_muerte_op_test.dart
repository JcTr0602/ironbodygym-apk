/// Tests 1.32 — Escalón 2 (Corte A de Argón):
/// - H-MUERTE-1: el descarte manual (`cancelOp`) resuelve los
///   efectos locales de la op por el embudo
///   `resolverEfectosOpMuerta`, en la misma transacción que el
///   DELETE. Antes era un DELETE desnudo y cada efecto quedaba
///   pegado para siempre.
/// - H-MUERTE-2: la reversión del optimismo de `reponer_lote`
///   es idempotente por identidad de op (morir → reintentar →
///   morir ya no descuenta las dosis dos veces).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _limpiar() async {
  final d = await LocalDb.instance.db;
  for (final t in [
    'ops_queue',
    'clientes',
    'pagos',
    'servicio_lotes',
    'ventas_suplementos',
    'categorias_suplemento',
    'entregas_efectivo',
    'incidencias_local',
    'meta',
  ]) {
    try {
      await d.delete(t);
    } catch (_) {}
  }
}

Future<void> _espejo(
    String tabla, int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {'id': id, 'data': jsonEncode(data), 'sync_seq': 1});
}

Future<void> _op(String uuid, String tipo, Map<String, dynamic> payload,
    String estado) async {
  final d = await LocalDb.instance.db;
  await d.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': '2026-11-11T08:00:00-05:00',
  });
}

Future<Map<String, dynamic>?> _cliente(int id) async {
  final filas = await LocalDb.instance.mirrorPorIds('clientes', [id]);
  return filas.isEmpty ? null : filas.first;
}

Future<int?> _dosisRepuestas(int loteId) async {
  final lotes = await LocalDb.instance.allMirror('servicio_lotes');
  for (final l in lotes) {
    if (l['id'] == loteId) return (l['dosis_repuestas'] as num?)?.toInt();
  }
  return null;
}

void main() {
  setUpAll(_abrirDbVacia);
  setUp(_limpiar);

  group('H-MUERTE-1 · cancelOp resuelve efectos', () {
    test('pago_mensual en error: revierte el vencimiento y el sello',
        () async {
      await _espejo('clientes', 501, {
        'nombre': 'Cliente Pago',
        'pagado_hasta': '2026-12-10',
        'ultimo_pago_op_uuid': 'u-pago-1',
      });
      await _op('u-pago-1', 'pago_mensual', {
        'cliente_id': 501,
        'pagado_hasta': '2026-12-10',
        'pagado_hasta_anterior': '2026-11-10',
      }, 'error');
      expect(await LocalDb.instance.cancelOp('u-pago-1'), isTrue);
      final c = await _cliente(501);
      expect(c?['pagado_hasta'], '2026-11-10');
      expect(c?.containsKey('ultimo_pago_op_uuid'), isFalse);
      expect(await LocalDb.instance.opEnCola('u-pago-1'), isNull);
    });

    test('pago_mensual con procedencia AJENA: no revierte y pide '
        're-descarga completa', () async {
      await _espejo('clientes', 502, {
        'nombre': 'Cliente Ajeno',
        'pagado_hasta': '2026-12-10',
        'ultimo_pago_op_uuid': 'otra-op',
      });
      await _op('u-pago-2', 'pago_mensual', {
        'cliente_id': 502,
        'pagado_hasta': '2026-12-10',
        'pagado_hasta_anterior': '2026-11-10',
      }, 'error');
      expect(await LocalDb.instance.cancelOp('u-pago-2'), isTrue);
      final c = await _cliente(502);
      expect(c?['pagado_hasta'], '2026-12-10');
      expect(c?['ultimo_pago_op_uuid'], 'otra-op');
      expect(await LocalDb.instance.getMeta('forzar_redescarga_clientes'),
          '1');
    });

    test('anular_pago: desmarca el pago al cancelar la única viva',
        () async {
      await _espejo('pagos', 601, {'cliente_id': 501, 'anulado': true});
      await _op('u-anula-1', 'anular_pago', {'pago_id': 601}, 'pendiente');
      expect(await LocalDb.instance.cancelOp('u-anula-1'), isTrue);
      final d = await LocalDb.instance.db;
      final rows = await d.query('pagos', where: 'id=?', whereArgs: [601]);
      final data = jsonDecode(rows.first['data'] as String)
          as Map<String, dynamic>;
      expect(data.containsKey('anulado'), isFalse);
    });

    test('anular_pago doble: cancelar una NO desmarca (queda otra viva)',
        () async {
      await _espejo('pagos', 602, {'cliente_id': 501, 'anulado': true});
      await _op('u-anula-2a', 'anular_pago', {'pago_id': 602}, 'pendiente');
      await _op('u-anula-2b', 'anular_pago', {'pago_id': 602}, 'error');
      expect(await LocalDb.instance.cancelOp('u-anula-2a'), isTrue);
      final d = await LocalDb.instance.db;
      var rows = await d.query('pagos', where: 'id=?', whereArgs: [602]);
      var data =
          jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
      expect(data['anulado'], isTrue);
      expect(await LocalDb.instance.cancelOp('u-anula-2b'), isTrue);
      rows = await d.query('pagos', where: 'id=?', whereArgs: [602]);
      data = jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
      expect(data.containsKey('anulado'), isFalse);
    });

    test('liquidar_entrega_efectivo: borra la fila local de la entrega',
        () async {
      final d = await LocalDb.instance.db;
      await d.insert('entregas_efectivo', {
        'op_uuid': 'u-liq-1',
        'entrenador_telegram_id': 111,
        'monto_entregado': 500.0,
        'fecha_habana': '2026-11-11',
        'creada_ts': '2026-11-11T08:00:00-05:00',
      });
      await _op('u-liq-1', 'liquidar_entrega_efectivo', {}, 'error');
      expect(await LocalDb.instance.cancelOp('u-liq-1'), isTrue);
      final rows = await d.query('entregas_efectivo');
      expect(rows, isEmpty);
    });

    test('inscripcion_venta_suplemento: borra SOLO su fila optimista',
        () async {
      await _espejo('ventas_suplementos', -7, {
        'op_uuid': 'u-venta-1',
        'nombre': 'Venta optimista',
      });
      await _espejo('ventas_suplementos', -8, {
        'op_uuid': 'u-venta-otra',
        'nombre': 'Venta ajena',
      });
      // _espejo siembra sync_seq=1; la optimista real lleva id<0.
      await _op('u-venta-1', 'inscripcion_venta_suplemento', {}, 'pendiente');
      expect(await LocalDb.instance.cancelOp('u-venta-1'), isTrue);
      final ventas = await LocalDb.instance.allMirror('ventas_suplementos');
      expect(ventas.map((v) => v['id']), contains(-8));
      expect(ventas.map((v) => v['id']), isNot(contains(-7)));
    });

    test('crear_categoria: borra su fila optimista', () async {
      await _espejo('categorias_suplemento', -3, {
        'op_uuid': 'u-cat-1',
        'nombre': 'Categoría optimista',
      });
      await _op('u-cat-1', 'crear_categoria', {}, 'error');
      expect(await LocalDb.instance.cancelOp('u-cat-1'), isTrue);
      final cats =
          await LocalDb.instance.allMirror('categorias_suplemento');
      expect(cats, isEmpty);
    });

    test('reponer_lote pendiente (optimismo vivo): revierte las dosis',
        () async {
      await _espejo('servicio_lotes', 10, {
        'bote_id': 1,
        'dosis_iniciales': 40,
        'dosis_repuestas': 20,
        'estado': 'activo',
      });
      await _op('u-rep-1', 'reponer_lote', {'lote_id': 10, 'dosis': 20},
          'pendiente');
      expect(await LocalDb.instance.cancelOp('u-rep-1'), isTrue);
      expect(await _dosisRepuestas(10), 0);
    });

    test('reponer_lote ya revertido al morir: cancelar NO descuenta '
        'otra vez', () async {
      await _espejo('servicio_lotes', 11, {
        'bote_id': 1,
        'dosis_iniciales': 40,
        'dosis_repuestas': 20,
        'estado': 'activo',
      });
      await _op('u-rep-2', 'reponer_lote', {'lote_id': 11, 'dosis': 20},
          'necesita_revision');
      // La op muere (bump/revisión): primera reversión.
      await LocalDb.instance.revertirOptimismoReponerLote(
          {'lote_id': 11, 'dosis': 20},
          opUuid: 'u-rep-2');
      expect(await _dosisRepuestas(11), 0);
      // Descarte posterior desde Salud: sin segundo descuento.
      expect(await LocalDb.instance.cancelOp('u-rep-2'), isTrue);
      expect(await _dosisRepuestas(11), 0);
    });

    test('eliminar_suplemento: marca la restauración de los 5 espejos',
        () async {
      await _op('u-eli-1', 'eliminar_suplemento', {}, 'error');
      expect(await LocalDb.instance.cancelOp('u-eli-1'), isTrue);
      for (final t in [
        'suplementos',
        'servicio_pomos',
        'servicio_botes',
        'servicio_lotes',
        'reservas',
      ]) {
        expect(await LocalDb.instance.getMeta('forzar_redescarga_$t'), '1',
            reason: 'meta de $t');
      }
    });

    test('incidencia: su fila local sale a error con el motivo', () async {
      final d = await LocalDb.instance.db;
      await d.insert('incidencias_local', {
        'id': 'inc-1',
        'tipo': 'sync',
        'descripcion': 'Incidencia de prueba',
        'creada_por': 'dueno',
        'creada_en': '2026-11-11T08:00:00-05:00',
        'sincronizada': 0,
        'sync_estado': 'pending',
      });
      await _op('u-inc-1', 'crear_incidencia', {'id': 'inc-1'}, 'error');
      expect(await LocalDb.instance.cancelOp('u-inc-1'), isTrue);
      final rows = await d.query('incidencias_local',
          where: 'id=?', whereArgs: ['inc-1']);
      expect(rows.first['sync_estado'], 'error');
      expect('${rows.first['sync_error']}', contains('descartada'));
    });

    test('editar_cliente: pide la re-descarga completa de clientes',
        () async {
      await _op('u-edi-1', 'editar_cliente', {'cliente_id': 501}, 'error');
      expect(await LocalDb.instance.cancelOp('u-edi-1'), isTrue);
      expect(await LocalDb.instance.getMeta('forzar_redescarga_clientes'),
          '1');
    });

    test('guardas: aplicada/enviada/inexistente no se cancelan ni '
        'tocan efectos', () async {
      await _espejo('clientes', 503, {
        'nombre': 'Cliente Guarda',
        'pagado_hasta': '2026-12-10',
        'ultimo_pago_op_uuid': 'u-pago-3',
      });
      await _op('u-pago-3', 'pago_mensual', {
        'cliente_id': 503,
        'pagado_hasta': '2026-12-10',
        'pagado_hasta_anterior': '2026-11-10',
      }, 'aplicada');
      expect(await LocalDb.instance.cancelOp('u-pago-3'), isFalse);
      final d = await LocalDb.instance.db;
      await d.update('ops_queue', {'estado': 'enviada'},
          where: 'op_uuid=?', whereArgs: ['u-pago-3']);
      expect(await LocalDb.instance.cancelOp('u-pago-3'), isFalse);
      expect(await LocalDb.instance.cancelOp('u-no-existe'), isFalse);
      final c = await _cliente(503);
      expect(c?['pagado_hasta'], '2026-12-10');
      expect(c?['ultimo_pago_op_uuid'], 'u-pago-3');
    });
  });

  group('H-MUERTE-2 · reversión de reponer_lote idempotente', () {
    test('morir → reintentar → morir: una sola reversión neta', () async {
      await _espejo('servicio_lotes', 12, {
        'bote_id': 1,
        'dosis_iniciales': 40,
        'dosis_repuestas': 20,
        'estado': 'activo',
      });
      await _op('u-rep-3', 'reponer_lote', {'lote_id': 12, 'dosis': 20},
          'necesita_revision');
      // Primera muerte.
      await LocalDb.instance.revertirOptimismoReponerLote(
          {'lote_id': 12, 'dosis': 20},
          opUuid: 'u-rep-3');
      expect(await _dosisRepuestas(12), 0);
      // Reintento desde Salud: la op vuelve a 'pendiente' (la
      // vía real es el UPDATE de _reintentarBloqueada en
      // cola.dart, que cubre 'necesita_revision').
      final d = await LocalDb.instance.db;
      await d.update('ops_queue', {'estado': 'pendiente'},
          where: 'op_uuid=?', whereArgs: ['u-rep-3']);
      // Segunda muerte (4xx definitivo): NO descuenta otra vez.
      await LocalDb.instance.revertirOptimismoReponerLote(
          {'lote_id': 12, 'dosis': 20},
          opUuid: 'u-rep-3');
      expect(await _dosisRepuestas(12), 0);
    });

    test('sin opUuid (camino legado) la reversión sigue directa',
        () async {
      await _espejo('servicio_lotes', 13, {
        'bote_id': 1,
        'dosis_iniciales': 40,
        'dosis_repuestas': 5,
        'estado': 'activo',
      });
      await LocalDb.instance
          .revertirOptimismoReponerLote({'lote_id': 13, 'dosis': 5});
      expect(await _dosisRepuestas(13), 0);
    });
  });
}
