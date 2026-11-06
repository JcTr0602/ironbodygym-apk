/// Gestión 1.25 · T02 — La marca «avisado» vale solo para
/// el vencimiento actual.
///
/// Antes: marcarAvisado guardaba solo un timestamp y la
/// marca era eterna — el cliente avisado por su
/// vencimiento de octubre salía «avisado» también en el
/// de noviembre. Ahora la marca guarda el pagado_hasta
/// avisado y idsAvisadosVigentes() solo la honra mientras
/// ese siga siendo el pagado_hasta del cliente.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _cliente(Database db,
    {required int id, required String? pagadoHasta}) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': 'Cliente $id',
      'estado': 'activo',
      'pagado_hasta': pagadoHasta,
    }),
    'sync_seq': 100 + id,
  });
}

Future<void> _renovar(Database db,
    {required int id, required String pagadoHasta}) async {
  final rows = await db.query('clientes', where: 'id=?', whereArgs: [id]);
  final data = jsonDecode(rows.single['data'] as String) as Map;
  data['pagado_hasta'] = pagadoHasta;
  await db.update('clientes', {'data': jsonEncode(data)},
      where: 'id=?', whereArgs: [id]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    // Sin borrado manual del archivo compartido (lección
    // T01): resetParaTest limpia el de este proceso.
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('avisado de ESTE vencimiento: la marca vale', () async {
    final db = await LocalDb.instance.db;
    await _cliente(db, id: 1, pagadoHasta: '2026-11-10');
    await LocalDb.instance
        .marcarAvisado(1, pagadoHasta: '2026-11-10');
    expect(await LocalDb.instance.idsAvisadosVigentes(), {1});
  });

  test('tras renovar, la marca vieja ya no esconde al cliente',
      () async {
    final db = await LocalDb.instance.db;
    await _cliente(db, id: 1, pagadoHasta: '2026-11-10');
    await LocalDb.instance
        .marcarAvisado(1, pagadoHasta: '2026-11-10');
    await _renovar(db, id: 1, pagadoHasta: '2026-12-10');
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty,
        reason: 'su vencimiento actual (diciembre) nunca se avisó');
  });

  test('marca vieja sin vencimiento guardado: caducada', () async {
    final db = await LocalDb.instance.db;
    await _cliente(db, id: 2, pagadoHasta: '2026-11-10');
    // Formato anterior a la 1.25: solo el timestamp.
    await LocalDb.instance
        .setMeta('avisado_2', '2026-10-05T09:00:00.000');
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty,
        reason: 'no se puede probar a qué vencimiento se avisó');
    // El conjunto crudo sí la sigue viendo (compatibilidad).
    expect(await LocalDb.instance.idsAvisados(), {2});
  });

  test('cliente que ya no existe: su marca no cuenta', () async {
    await LocalDb.instance
        .marcarAvisado(99, pagadoHasta: '2026-11-10');
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty);
  });

  // 1.25 T116 (F1-26): la variante con fecha — misma
  // vigencia, y la fecha es la del timestamp de la marca.
  test('avisadosVigentesConFecha: fecha de la marca vigente',
      () async {
    final db = await LocalDb.instance.db;
    await _cliente(db, id: 1, pagadoHasta: '2026-11-10');
    await _cliente(db, id: 2, pagadoHasta: '2026-11-10');
    await LocalDb.instance
        .marcarAvisado(1, pagadoHasta: '2026-11-10');
    await LocalDb.instance
        .marcarAvisado(2, pagadoHasta: '2026-10-10');
    final mapa = await LocalDb.instance.avisadosVigentesConFecha();
    expect(mapa.keys, {1},
        reason: 'la marca de 2 avisa de un vencimiento que ya no es el suyo');
    // La fecha cae en el día en que se marcó (hoy del test).
    final hoy = DateTime.now();
    expect(mapa[1]!.year, hoy.year);
    expect(mapa[1]!.month, hoy.month);
    expect(mapa[1]!.day, hoy.day);
  });

  test('sin pagado_hasta (nunca pagó): marca ligada a ese estado',
      () async {
    final db = await LocalDb.instance.db;
    await _cliente(db, id: 3, pagadoHasta: null);
    await LocalDb.instance.marcarAvisado(3, pagadoHasta: null);
    expect(await LocalDb.instance.idsAvisadosVigentes(), {3});
    // Al pagar por primera vez, el estado cambia y la
    // marca caduca sola.
    await _renovar(db, id: 3, pagadoHasta: '2026-12-01');
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty);
  });
}
