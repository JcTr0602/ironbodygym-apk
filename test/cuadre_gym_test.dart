/// Cuadre del dueño con totales del gym (9/25 del programa de
/// mejoras): la vista Gym suma todos los vendedores, pero el
/// efectivo excluye responsables null (un reverso de venta
/// entregada no mueve dinero). El camino personal no cambia.
///
/// Patrón de BD: igual que cuadre_reverso_test.dart
/// (sqflite_common_ffi + LocalDb.instance contra ironbody.db fresca).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const duany = 969869611;
const gabriel = 1403501391;
const dueno = 735772141;

Future<void> _sembrar(Map<String, dynamic> fila) =>
    LocalDb.instance.upsertMirror(
        'servicio_ventas', fila['id'] as int, fila, 1);

Map<String, dynamic> _fila({
  required int id,
  required String fecha,
  required String tipo,
  required int cantidad,
  required double precio,
  String metodo = 'efectivo',
  double comisionMonto = 0,
  int? vendedor,
  int? responsable,
  int? comisionero,
  required int registrado,
  int? reversoDe,
}) =>
    {
      'id': id,
      'fecha': fecha,
      'tipo': tipo,
      'cantidad': cantidad,
      'precio_unitario': precio,
      'comision_unitaria': 0,
      'comision_monto': comisionMonto,
      'metodo': metodo,
      'casa': 0,
      'vendedor_id': vendedor,
      'responsable_efectivo_id': responsable,
      'comision_entrenador_id': comisionero,
      'registrado_por': registrado,
      'reverso_de': reversoDe,
    };

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

  test('la vista Gym suma todos los vendedores del día', () async {
    await _sembrar(_fila(
        id: 1,
        fecha: '2026-10-30',
        tipo: 'dosis_sin_agua',
        cantidad: 1,
        precio: 600,
        vendedor: duany,
        responsable: duany,
        registrado: duany));
    await _sembrar(_fila(
        id: 2,
        fecha: '2026-10-30',
        tipo: 'dosis_con_agua',
        cantidad: 2,
        precio: 900,
        metodo: 'transferencia',
        comisionMonto: 100,
        vendedor: gabriel,
        responsable: gabriel,
        comisionero: gabriel,
        registrado: gabriel));

    final gym = await cuadreServiciosDiaGym('2026-10-30');
    expect(gym['dosis_sin_agua'], 1);
    expect(gym['dosis_con_agua'], 2);
    expect(gym['efectivo'], 600.0);
    expect(gym['transferencia'], 1800.0);
    expect(gym['comision'], 100.0);
    // El camino personal no cambió: Duany sigue viendo solo lo suyo.
    final duanyCuadre =
        await cuadreServiciosDia(duany, '2026-10-30');
    expect(duanyCuadre['dosis_con_agua'], 0);
    expect(duanyCuadre['transferencia'], 0.0);
    expect(duanyCuadre['efectivo'], 600.0);
  });

  test('el reverso del dueño no pinta un -1500 en el gym', () async {
    // Caso real del 2026-10-30 (filas 13 y 14): reversos de ventas
    // entregadas con responsable null deliberado. El gym netea las
    // dosis en el día pero su efectivo no se mueve (0, no -1500).
    await _sembrar(_fila(
        id: 13,
        fecha: '2026-10-30',
        tipo: 'agua_suelta',
        cantidad: -2,
        precio: 300,
        vendedor: duany,
        responsable: null,
        registrado: dueno,
        reversoDe: 10));
    await _sembrar(_fila(
        id: 14,
        fecha: '2026-10-30',
        tipo: 'dosis_con_agua',
        cantidad: -1,
        precio: 900,
        vendedor: gabriel,
        responsable: null,
        comisionero: gabriel,
        registrado: dueno,
        reversoDe: 11));

    final gym = await cuadreServiciosDiaGym('2026-10-30');
    expect(gym['agua_suelta'], -2);
    expect(gym['dosis_con_agua'], -1);
    expect(gym['efectivo'], 0.0);
  });

  test('la fila vieja sin roles cuenta para el gym', () async {
    await _sembrar(_fila(
        id: 30,
        fecha: '2026-10-30',
        tipo: 'dosis_sin_agua',
        cantidad: 1,
        precio: 600,
        vendedor: null,
        responsable: null,
        registrado: gabriel));

    final gym = await cuadreServiciosDiaGym('2026-10-30');
    expect(gym['dosis_sin_agua'], 1);
    // El fallback a registrado_por también pone responsable: el
    // efectivo sí cuenta (no es reverso, no hay null deliberado).
    expect(gym['efectivo'], 600.0);
  });
}
