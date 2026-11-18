/// 1.36 (136-231): UN solo registro de «ya le avisé».
///
/// Antes: Listas marcaba en `meta.avisado_<id>` (ligado a
/// pagado_hasta, sin caducidad por días) y Bandeja/Buscar en
/// `avisos_wa_contactados` (por tipo y solo hoy): avisar en
/// Listas no apagaba la Bandeja (doble aviso el mismo día) y
/// contactar en la Bandeja no marcaba Listas.
///
/// Fuente única: el registro por cliente y vencimiento
/// (`avisado_<id>`); la tabla por día es su índice derivado
/// para los tipos de vencimiento. Estos tests fijan:
/// 1. Marcar en Listas se lee en la Bandeja el mismo día.
/// 2. Marcar en la Bandeja se lee en Listas (marca vigente).
/// 3. Desmarcar en una superficie desmarca en la otra.
/// 4. Al cambiar pagado_hasta, la marca caduca en AMBAS.
/// 5. La semántica de «hoy»: la marca de ayer no es contacto
///    de hoy, pero sigue vigente como aviso del vencimiento.
/// 6. Los tipos ajenos (cumple) no tocan el registro único.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

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
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('1 · Listas → Bandeja: marcarAvisado apaga el día', () async {
    final db = await LocalDb.instance.db;
    final hoy = hoyHabanaIso();
    final vencido = _iso(ahoraHabana().subtract(const Duration(days: 5)));
    await _cliente(db, id: 1, pagadoHasta: vencido);
    await LocalDb.instance.marcarAvisado(1, pagadoHasta: vencido);
    final hoySet = await LocalDb.instance.avisosWaContactados(hoy);
    expect(hoySet, contains('vencido_1'),
        reason: 'la marca de Listas es contacto de hoy en la Bandeja');
    expect(await LocalDb.instance.idsAvisadosVigentes(), {1});
  });

  test('2 · Bandeja → Listas: marcarAvisoWaContactado marca el registro',
      () async {
    final db = await LocalDb.instance.db;
    final hoy = hoyHabanaIso();
    final vencido = _iso(ahoraHabana().subtract(const Duration(days: 5)));
    await _cliente(db, id: 2, pagadoHasta: vencido);
    await LocalDb.instance.marcarAvisoWaContactado(2, 'vencido', hoy);
    expect(await LocalDb.instance.idsAvisadosVigentes(), {2},
        reason: 'contactar en la Bandeja marca Listas: sale del '
            'botón masivo y de la pastilla');
    final conFecha = await LocalDb.instance.avisadosVigentesConFecha();
    expect(conFecha.keys, contains(2));
    expect(
        '${conFecha[2]!.year}-${conFecha[2]!.month}-${conFecha[2]!.day}',
        '${ahoraHabana().year}-${ahoraHabana().month}-${ahoraHabana().day}');
  });

  test('3 · Desmarcar en una superficie desmarca en la otra', () async {
    final db = await LocalDb.instance.db;
    final hoy = hoyHabanaIso();
    final vencido = _iso(ahoraHabana().subtract(const Duration(days: 5)));
    await _cliente(db, id: 3, pagadoHasta: vencido);
    // Marca por la Bandeja, desmarca por Listas.
    await LocalDb.instance.marcarAvisoWaContactado(3, 'vencido', hoy);
    await LocalDb.instance.desmarcarAvisado(3);
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty);
    expect(await LocalDb.instance.avisosWaContactados(hoy),
        isNot(contains('vencido_3')));
    // Marca por Listas, desmarca por la Bandeja.
    await LocalDb.instance.marcarAvisado(3, pagadoHasta: vencido);
    await LocalDb.instance.desmarcarAvisoWaContactado(3, 'vencido', hoy);
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty);
    expect(await LocalDb.instance.avisosWaContactados(hoy),
        isNot(contains('vencido_3')));
  });

  test('4 · Al renovar (cambia pagado_hasta) caduca en ambas', () async {
    final db = await LocalDb.instance.db;
    final hoy = hoyHabanaIso();
    final vencido = _iso(ahoraHabana().subtract(const Duration(days: 5)));
    final nuevo = _iso(ahoraHabana().add(const Duration(days: 25)));
    await _cliente(db, id: 4, pagadoHasta: vencido);
    await LocalDb.instance.marcarAvisoWaContactado(4, 'vencido', hoy);
    expect(await LocalDb.instance.idsAvisadosVigentes(), {4});
    await _renovar(db, id: 4, pagadoHasta: nuevo);
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty,
        reason: 'Listas: la marca era del vencimiento anterior');
    expect(await LocalDb.instance.avisosWaContactados(hoy),
        isNot(contains('vencido_4')),
        reason: 'Bandeja: tampoco cuenta como contactado de hoy');
  });

  test('5 · «Hoy» es la fecha de la marca, igual en las dos', () async {
    final db = await LocalDb.instance.db;
    final hoy = hoyHabanaIso();
    final ayerDt = ahoraHabana().subtract(const Duration(days: 1));
    final ayer = _iso(ayerDt);
    final vencido = _iso(ahoraHabana().subtract(const Duration(days: 5)));
    await _cliente(db, id: 5, pagadoHasta: vencido);
    // El estado tal como amanece al día siguiente de avisar:
    // la marca del registro único con su timestamp de ayer.
    await LocalDb.instance
        .setMeta('avisado_5', '$vencido|${isoHabana(ayerDt)}');
    // «Contactado hoy»: no — en ninguna de las dos lecturas del
    // día (la fecha de la marca es ayer).
    expect(await LocalDb.instance.avisosWaContactados(hoy),
        isNot(contains('vencido_5')));
    expect(await LocalDb.instance.avisosWaContactados(ayer),
        contains('vencido_5'),
        reason: 'el día de la marca sí lo cuenta como contactado');
    // Y el hecho sigue vigente para el vencimiento: Listas (y
    // la Bandeja, que lee los vigentes) lo dan por avisado.
    expect(await LocalDb.instance.idsAvisadosVigentes(), {5});
  });

  test('6 · Un tipo ajeno (cumple) no toca el registro único', () async {
    final db = await LocalDb.instance.db;
    final hoy = hoyHabanaIso();
    await _cliente(db, id: 6, pagadoHasta: hoy);
    await LocalDb.instance.marcarAvisoWaContactado(6, 'cumple', hoy);
    expect(await LocalDb.instance.idsAvisadosVigentes(), isEmpty);
    expect(await LocalDb.instance.avisosWaContactados(hoy),
        contains('cumple_6'));
    await LocalDb.instance.desmarcarAvisoWaContactado(6, 'cumple', hoy);
    expect(await LocalDb.instance.avisosWaContactados(hoy), isEmpty);
  });
}
