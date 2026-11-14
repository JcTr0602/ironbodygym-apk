/// Yunque 4 (L7-2) — Estadísticas de Servicios: el «Corte
/// por vendedor» resuelve los nombres por tid del VENDEDOR.
///
/// El corte agrupa por `vendedor_id ?? registrado_por`
/// (C5), pero el mapa de nombres solo se construía desde
/// `registrado_por`: la venta «a nombre de» Duany
/// registrada por el dueño salía como «Entrenador»
/// genérico. La corrección resuelve los tid del corte con
/// `LocalDb.nombresPorTelegramIds` (la vía del directorio
/// que usan Servicios y el Historial) y la mezcla sobre el
/// mapa de respaldo. Este test fija la mitad BD de esa
/// resolución: el nombre de un entrenador se encuentra por
/// SU telegram_id aunque quien registró la venta de
/// servicio haya sido el dueño.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'L7-2 · nombresPorTelegramIds resuelve al entrenador '
      'por su tid (el directorio del corte por vendedor)',
      () async {
    await _bdVacia();
    final db = await LocalDb.instance.db;
    // El espejo de pagos trae pagos registrados por Duany:
    // su nombre vive bajo SU telegram_user_id.
    await db.insert('pagos', {
      'id': 501,
      'cliente_id': 7,
      'fecha': '2026-11-14',
      'telegram_user_id': 111,
      'sync_seq': 9001,
      'data': jsonEncode({
        'cliente_id': 7,
        'registrado_por': 'Duany',
        'monto': 2000,
        'metodo': 'efectivo',
      }),
    });
    await db.insert('pagos', {
      'id': 502,
      'cliente_id': 8,
      'fecha': '2026-11-14',
      'telegram_user_id': 222,
      'sync_seq': 9002,
      'data': jsonEncode({
        'cliente_id': 8,
        'registrado_por': 'Jc',
        'monto': 2000,
        'metodo': 'efectivo',
      }),
    });

    final nombres =
        await LocalDb.instance.nombresPorTelegramIds({111, 222, 999});
    expect(nombres[111], 'Duany',
        reason: 'el tid del vendedor del corte se nombra '
            'desde el directorio, no desde el registrado_por '
            'de la venta de servicio (el dueño)');
    expect(nombres[222], 'Jc');
    expect(nombres.containsKey(999), isFalse,
        reason: 'un tid sin rastro no inventa nombre: la UI '
            'cae a su respaldo');
  });
}
