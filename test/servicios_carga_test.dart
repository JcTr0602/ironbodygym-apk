/// Carga de Servicios sin escanear espejos completos (10/25):
/// ventas del día vía mirrorPorFecha, desglose por pomo vía
/// mirrorPorCampo y nombres de entrenadores vía el índice de
/// telegram_user_id en `pagos`.
///
/// Patrón de BD: igual que cuadre_reverso_test.dart
/// (sqflite_common_ffi + LocalDb.instance contra ironbody.db fresca).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const duany = 969869611;
const gabriel = 1403501391;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db; // dispara onCreate
  });

  test('mirrorPorFecha en servicio_ventas trae solo el día', () async {
    Future<void> venta(int id, String fecha, int pomo) =>
        LocalDb.instance.upsertMirror('servicio_ventas', id, {
          'id': id,
          'fecha': fecha,
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 600,
          'pomo_id': pomo,
        }, 1);
    await venta(1, '2026-10-30', 2);
    await venta(2, '2026-10-30 09:15:00', 2);
    await venta(3, '2026-10-29', 2);
    await venta(4, '2026-10-31', 3);

    final hoy = await LocalDb.instance
        .mirrorPorFecha('servicio_ventas', 'fecha', '2026-10-30',
            '2026-10-30');
    expect(hoy.map((v) => v['id']).toList()..sort(), [1, 2]);
  });

  test('mirrorPorCampo trae solo las filas del pomo', () async {
    Future<void> venta(int id, int? pomo) =>
        LocalDb.instance.upsertMirror('servicio_ventas', id, {
          'id': id,
          'fecha': '2026-10-30',
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 600,
          'pomo_id': pomo,
        }, 1);
    await venta(1, 2);
    await venta(2, 3);
    await venta(3, 2);
    await venta(4, null); // época de lotes: sin pomo

    final pomo2 = await LocalDb.instance
        .mirrorPorCampo('servicio_ventas', 'pomo_id', 2);
    expect(pomo2.map((v) => v['id']).toList()..sort(), [1, 3]);
  });

  test('nombresPorTelegramIds resuelve solo los tids pedidos',
      () async {
    Future<void> pago(int id, int tid, String nombre) =>
        LocalDb.instance.upsertMirror('pagos', id, {
          'id': id,
          'telegram_user_id': tid,
          'registrado_por': nombre,
          'fecha': '2026-10-30',
          'cliente_id': 1,
          'monto': 2000,
        }, 1);
    await pago(1, duany, 'Duany');
    await pago(2, gabriel, 'Gabriel');

    final nombres = await LocalDb.instance
        .nombresPorTelegramIds({duany});
    expect(nombres, {duany: 'Duany'});
    expect(nombres.containsKey(gabriel), isFalse);
  });
}
