/// Corrección ARG136-11 (adjudicación Argón 1.36): la rama
/// `fecha:` de `LocalDb.pagosPorFiltro` era la única de la
/// familia que no hablaba en fecha de negocio Habana: su
/// SQL era igualdad exacta sobre la columna y su predicado
/// Dart del fallback comparaba el texto crudo del JSON.
/// Las ramas hermanas de la misma función (fechaPrefijo,
/// fechaDesde) y las funciones hermanas
/// (servicioVentasPorFiltro, ventasSuplementosPorFiltro)
/// usan fechaNegocioHabana. Deuda latente (ningún llamador
/// vivo usa `fecha:`), pero la rama queda alineada: SQL con
/// ventana ±1 día + filtro fino fechaNegocioHabana, la
/// pauta de pagosDelDia y mirrorPorFecha.
///
/// Esta fila REFORMULA la excepción nombrada de 136-925
/// sobre pagosPorFiltro; no la revoca: la excepción queda
/// cerrada solo para la rama `fecha:`.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _pagoSinColumnas(int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert('pagos', {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': 1,
    // fecha y demás columnas indexadas quedan NULL (fila
    // vieja sin backfill): manda el fallback en Dart.
  });
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('fecha: una fila sin columna con timestamp UTC de '
      'madrugada se encuentra por su día de negocio', () async {
    // 2026-11-01T02:30Z = 2026-10-31 en La Habana.
    await _pagoSinColumnas(1, {
      'id': 1,
      'fecha': '2026-11-01T02:30:00Z',
      'monto': 2500,
      'metodo': 'transferencia',
    });
    final deOctubre =
        await LocalDb.instance.pagosPorFiltro(fecha: '2026-10-31');
    expect(deOctubre.map((p) => p['id']), contains(1),
        reason: 'el fallback compara con fechaNegocioHabana, '
            'no con el texto crudo');
    final deNoviembre =
        await LocalDb.instance.pagosPorFiltro(fecha: '2026-11-01');
    expect(deNoviembre.map((p) => p['id']), isNot(contains(1)),
        reason: 'y no cae en el día UTC');
  });

  test('fecha: la fila normal con columna se encuentra '
      'igual que antes (control)', () async {
    await LocalDb.instance.upsertMirror('pagos', 2, {
      'id': 2,
      'fecha': '2026-11-10',
      'monto': 2000,
      'metodo': 'efectivo',
    }, 1);
    await LocalDb.instance.upsertMirror('pagos', 3, {
      'id': 3,
      'fecha': '2026-11-11',
      'monto': 2000,
      'metodo': 'efectivo',
    }, 2);
    final r =
        await LocalDb.instance.pagosPorFiltro(fecha: '2026-11-10');
    expect(r.map((p) => p['id']), [2],
        reason: 'la ventana ±1 del precorte no deja pasar '
            'el día vecino: el filtro fino manda');
  });

  test('fecha: combinada con método, ambas condiciones '
      'mandan', () async {
    await LocalDb.instance.upsertMirror('pagos', 4, {
      'id': 4,
      'fecha': '2026-11-10',
      'monto': 2000,
      'metodo': 'efectivo',
    }, 1);
    await LocalDb.instance.upsertMirror('pagos', 5, {
      'id': 5,
      'fecha': '2026-11-10',
      'monto': 2500,
      'metodo': 'transferencia',
    }, 2);
    final r = await LocalDb.instance
        .pagosPorFiltro(fecha: '2026-11-10', metodo: 'efectivo');
    expect(r.map((p) => p['id']), [4]);
  });
}
