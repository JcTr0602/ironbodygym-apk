/// Pasos 3-4 de Argón (sync adaptativa, 2026-10-27).
///
/// Cubre lo que sí se puede probar en unidad:
/// - [EscaleraPaginas]: arranca en 100, sube con páginas rápidas
///   (≥ 8 KB en < 1,5 s) 100 → 250 → 500, no sube con páginas
///   lentas o pequeñas, y vuelve a 100 ante un fallo.
/// - [EstadoSubida.pausadaPorQos] existe (el switch de _subirUna
///   debe cubrirlo: si falta, no compila).
/// - [FotosColaService.pausarFilaPorQos]: devuelve la fila a
///   'pendiente' SIN tocar intentos ni backoff, solo si el worker
///   sigue siendo dueño.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('fotos_cola');
}

Future<int> _insertarFilaSubiendo() async {
  final db = await LocalDb.instance.db;
  return await db.insert('fotos_cola', {
    'op_uuid': 'test-op-1',
    'tipo': 'display',
    'ruta_local': '/tmp/x.jpg',
    'estado': 'subiendo',
    'intentos': 2,
    'worker_id': 'w1',
    'lease_hasta': '2026-10-27T12:00:00',
    'proximo_intento_en': '2026-10-27T11:00:00',
    'creado_en': '2026-10-27T10:00:00',
    'actualizado_en': '2026-10-27T10:00:00',
  });
}

void main() {
  setUp(_limpiar);

  test('escalera arranca en 100', () {
    expect(EscaleraPaginas().limite, 100);
  });

  test('página rápida sube 100 → 250 → 500 y se queda', () {
    final e = EscaleraPaginas();
    e.exito(9000, 1000);
    expect(e.limite, 250);
    e.exito(50000, 1200);
    expect(e.limite, 500);
    e.exito(50000, 100);
    expect(e.limite, 500);
  });

  test('página lenta o pequeña no sube ni baja', () {
    final e = EscaleraPaginas();
    e.exito(9000, 2000);
    expect(e.limite, 100);
    e.exito(100, 100);
    expect(e.limite, 100);
    e.exito(9000, 1000);
    expect(e.limite, 250);
    e.exito(9000, 5000);
    expect(e.limite, 250);
  });

  test('bordes: 8000 bytes y 1499 ms sube; 1500 ms o 7999 bytes no', () {
    final a = EscaleraPaginas();
    a.exito(8000, 1499);
    expect(a.limite, 250);
    final b = EscaleraPaginas();
    b.exito(8000, 1500);
    expect(b.limite, 100);
    final c = EscaleraPaginas();
    c.exito(7999, 100);
    expect(c.limite, 100);
  });

  test('fallo vuelve a 100', () {
    final e = EscaleraPaginas();
    e.exito(9000, 1000);
    e.exito(9000, 1000);
    expect(e.limite, 500);
    e.fallo();
    expect(e.limite, 100);
  });

  test('existe el estado pausadaPorQos', () {
    expect(EstadoSubida.values, contains(EstadoSubida.pausadaPorQos));
  });

  test('pausa QoS: a pendiente sin tocar intentos ni backoff', () async {
    final id = await _insertarFilaSubiendo();
    await FotosColaService.instance.pausarFilaPorQos(id, 'w1');
    final db = await LocalDb.instance.db;
    final rows =
        await db.query('fotos_cola', where: 'id = ?', whereArgs: [id]);
    expect(rows.length, 1);
    final f = rows.first;
    expect(f['estado'], 'pendiente');
    expect(f['intentos'], 2);
    expect(f['proximo_intento_en'], '2026-10-27T11:00:00');
    expect(f['worker_id'], null);
    expect(f['lease_hasta'], null);
  });

  test('pausa QoS: otro worker no toca la fila', () async {
    final id = await _insertarFilaSubiendo();
    await FotosColaService.instance.pausarFilaPorQos(id, 'w2');
    final db = await LocalDb.instance.db;
    final rows =
        await db.query('fotos_cola', where: 'id = ?', whereArgs: [id]);
    expect(rows.length, 1);
    final f = rows.first;
    expect(f['estado'], 'subiendo');
    expect(f['worker_id'], 'w1');
    expect(f['lease_hasta'], '2026-10-27T12:00:00');
  });
}
