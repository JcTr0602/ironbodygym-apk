/// Gestión 1.25 · T03 — La pestaña «Al día» no duplica a
/// los de «Hoy» y «Por vencer».
///
/// clientesAlDia() es el predicado de ACCESO (pagado_hasta
/// >= hoy; la Casa siempre) y NO cambia. La pestaña usa
/// clientesAlDiaPestana(): cada cliente en UNA sola
/// pestaña, y la unión de Hoy + Por vencer + Al día
/// (pestaña) = el predicado completo, sin solapes.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

List<int> _ids(List<Map<String, dynamic>> filas) =>
    [for (final f in filas) (f['id'] as num).toInt()]..sort();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  test('las tres pestañas son disjuntas y cubren el predicado',
      () async {
    // Sin borrado manual del archivo compartido (lección
    // T01): resetParaTest limpia el de este proceso.
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    final hoy = DateTime.parse(hoyHabanaIso());

    Future<void> cliente(int id,
        {bool casa = false, String? pagadoHasta}) async {
      await db.insert('clientes', {
        'id': id,
        'data': jsonEncode({
          'id': id,
          'nombre': 'Cliente $id',
          'estado': 'activo',
          'pagado_hasta': pagadoHasta,
          if (casa) 'cuenta_casa': 1,
        }),
        'sync_seq': 100 + id,
      });
    }

    await cliente(1, pagadoHasta: _iso(hoy)); // vence hoy
    await cliente(2,
        pagadoHasta: _iso(hoy.add(const Duration(days: 2))));
    await cliente(3,
        pagadoHasta: _iso(hoy.add(const Duration(days: 3))));
    await cliente(4,
        pagadoHasta: _iso(hoy.add(const Duration(days: 10))));
    await cliente(5, casa: true); // Casa, sin fecha
    await cliente(6,
        pagadoHasta: _iso(hoy.subtract(const Duration(days: 1))));

    final hoyIds = _ids(await vencenHoy());
    final pvIds = _ids(await porVencer(dias: 3));
    final pestana = _ids(await clientesAlDiaPestana());
    final predicado = _ids(await clientesAlDia());

    expect(hoyIds, [1]);
    expect(pvIds, [2, 3], reason: 'por vencer: hoy+1..hoy+3');
    expect(pestana, [4, 5],
        reason: 'al día de verdad + la Casa; nadie de hoy ni '
            'de por vencer');
    expect(predicado, [1, 2, 3, 4, 5],
        reason: 'el predicado de acceso NO cambia');

    // Disjuntas dos a dos y unión = predicado.
    expect(hoyIds.toSet().intersection(pvIds.toSet()), isEmpty);
    expect(hoyIds.toSet().intersection(pestana.toSet()), isEmpty);
    expect(pvIds.toSet().intersection(pestana.toSet()), isEmpty);
    expect({...hoyIds, ...pvIds, ...pestana}, predicado.toSet());
  });
}
