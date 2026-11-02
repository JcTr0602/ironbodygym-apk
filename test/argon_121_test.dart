/// Argón 1.21: ajustes del veredicto externo (APTO CON AJUSTES).
///
/// - AR-01: detallePendiente excluye lo ya absorbido por una
///   liquidación de caja (mismo cruce que pendienteEntrega).
/// - AR-C04: la purga al cerrar sesión borra también los
///   archivos de fotos de incidencias privadas y las ops
///   encoladas que las referencian (tipos vivos de la familia).
/// - Pregunta 6: Incidencia.fromMap lee 'en_revision' del
///   servidor como 'en_proceso'.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/modelos/incidencia.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

const _tid = 1403501391;

void main() {
  test('AR-01: detallePendiente excluye pagos y servicios '
      'ya liquidados', () async {
    await _preparar();
    final db = LocalDb.instance;
    // Pago mensual en efectivo SIN entregar (pendiente).
    await db.upsertMirror('pagos', 10, {
      'id': 10,
      'cliente_id': 5,
      'metodo': 'efectivo',
      'entregado': 0,
      'monto': 2000,
      'telegram_user_id': _tid,
      'op_uuid': 'uuid-pago-10',
    }, 1);
    // Otro pago igual pero ya absorbido por la liquidación 40.
    await db.upsertMirror('pagos', 11, {
      'id': 11,
      'cliente_id': 6,
      'metodo': 'efectivo',
      'entregado': 0,
      'monto': 2000,
      'telegram_user_id': _tid,
      'op_uuid': 'uuid-pago-11',
    }, 2);
    // Venta de servicio pendiente, también liquidada.
    await db.upsertMirror('servicio_ventas', 20, {
      'id': 20,
      'registrado_por': _tid,
      'metodo': 'efectivo',
      'entregado': 0,
      'casa': 0,
      'cantidad': 1,
      'op_uuid': 'uuid-srv-20',
    }, 3);
    await db.upsertMirror('liquidaciones_caja', 40, {
      'id': 40,
      'entrenador_telegram_id': _tid,
      'estado': 'confirmada',
      'moneda': 'CUP',
      'op_ids': {
        'pagos': [11],
        'servicio_ventas': [20],
      },
    }, 4);

    final (mens, diarios, servicios) = await detallePendiente(_tid);
    expect(mens.map((e) => e['id']), [10],
        reason: 'el pago 11 ya liquidado no debe listarse');
    expect(diarios, isEmpty);
    expect(servicios, isEmpty,
        reason: 'la venta 20 ya liquidada no debe listarse');
  });

  test('AR-C04: la purga borra fotos y ops de incidencias '
      'privadas, y conserva lo compartido', () async {
    await _preparar();
    final db = LocalDb.instance;
    final d = await db.db;

    await d.insert('incidencias_local', {
      'id': 'inc-priv-1',
      'tipo': 'sync',
      'descripcion': 'Nota privada del dueño',
      'estado': 'pendiente',
      'creada_por': 'Jc',
      'creada_en': '2026-11-01T10:00:00-04:00',
      'visibilidad': 'privada',
    });
    await d.insert('incidencias_local', {
      'id': 'inc-pub-1',
      'tipo': 'sync',
      'descripcion': 'Nota compartida',
      'estado': 'pendiente',
      'creada_por': 'Gabriel',
      'creada_en': '2026-11-01T10:00:00-04:00',
      'visibilidad': 'compartida',
    });

    // Archivo físico real de la foto privada.
    final tmp = await Directory.systemTemp.createTemp('argon121');
    final foto = File(p.join(tmp.path, 'foto_privada.jpg'));
    await foto.writeAsBytes([1, 2, 3]);
    await d.insert('incidencias_fotos', {
      'id': 'foto-1',
      'incidencia_id': 'inc-priv-1',
      'local_path': foto.path,
      'storage_path': 'incidencias/inc-priv-1/foto-1.jpg',
      'creado_en': '2026-11-01T10:05:00-04:00',
      'sync_estado': 'synced',
      'tipo': 'evidencia',
    });

    // Ops encoladas: una privada (crear), una que referencia la
    // privada por id (cambiar_estado) y una compartida.
    await db.queueOp(opUuid: 'op-priv-crear', tipo: 'crear_incidencia',
        payload: {
          'id': 'inc-priv-1',
          'visibilidad': 'privada',
          'descripcion': 'Nota privada del dueño',
        });
    await db.queueOp(
        opUuid: 'op-priv-estado',
        tipo: 'cambiar_estado_incidencia',
        payload: {'id': 'inc-priv-1', 'estado': 'en_proceso'});
    await db.queueOp(opUuid: 'op-pub-crear', tipo: 'crear_incidencia',
        payload: {
          'id': 'inc-pub-1',
          'visibilidad': 'compartida',
          'descripcion': 'Nota compartida',
        });

    await db.purgarDatosSensibles();

    expect(await foto.exists(), isFalse,
        reason: 'el archivo de la foto privada debe borrarse');
    final fotos = await d.query('incidencias_fotos');
    expect(fotos, isEmpty,
        reason: 'la fila de la foto privada debe borrarse');
    final locales = await d.query('incidencias_local');
    expect(locales.map((e) => e['id']), ['inc-pub-1']);
    final ops = await d.query('ops_queue');
    expect(ops.map((e) => e['op_uuid']), ['op-pub-crear'],
        reason: 'solo sobrevive la op de la incidencia compartida');
    await tmp.delete(recursive: true);
  });

  test('SB-01/SB-02: la purga resetea el watermark de gastos y '
      'liquidaciones_caja no hereda el global congelado', () async {
    await _preparar();
    final db = LocalDb.instance;
    await db.setWatermark(9000); // global avanzado
    await db.setWatermarkTabla('gastos', 500);
    await db.setWatermarkTabla('liquidaciones_caja', 700);
    await db.purgarDatosSensibles();
    // SB-01: wm_gastos reseteado a 0 en la purga (aunque el
    // global heredado sea enorme) → vuelve a bajar todo.
    expect(await db.getWatermarkTabla('gastos'), 0);
    expect(await db.getMeta('wm_gastos'), '0');
    // SB-02: su wm se borra en la purga y NO hereda el global.
    expect(await db.getWatermarkTabla('liquidaciones_caja'), 0);
  });

  test('Q6: fromMap normaliza en_revision a en_proceso',
      () async {
    final inc = Incidencia.fromMap({
      'id': 'inc-9',
      'estado': 'en_revision',
      'descripcion': 'Revisando',
      'creada_por': 'Gabriel',
      'creada_en': '2026-11-01T10:00:00-04:00',
    });
    expect(inc.estado, 'en_proceso');
    final inc2 = Incidencia.fromMap({
      'id': 'inc-10',
      'estado': 'pendiente',
      'descripcion': 'Otra',
      'creada_por': 'Gabriel',
      'creada_en': '2026-11-01T10:00:00-04:00',
    });
    expect(inc2.estado, 'pendiente');
  });
}
