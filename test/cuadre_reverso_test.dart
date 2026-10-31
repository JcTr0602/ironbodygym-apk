/// Corrección del -1500 fantasma (2026-10-30): el dueño revierte dos
/// ventas entregadas y el cuadre del día le cargaba -1500, porque el
/// fallback `responsable ?? registrado_por` inventaba atribución para
/// un reverso cuyo responsable el servidor deja en null a propósito
/// (el pendiente del entrenador no se toca).
///
/// Patrón de BD: igual que venta_suplemento_test.dart
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
      'comision_monto': 0,
      'metodo': 'efectivo',
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

  group('cuadreServiciosDia con reversos', () {
    test('el reverso del dueño de ventas entregadas no le cae en efectivo',
        () async {
      // Caso real del 2026-10-30: originales del 28/10 ya entregadas,
      // reversos del 30/10 registrados por el dueño con responsable
      // en null deliberado (filas 13 y 14 de gym.db).
      await _sembrar(_fila(
          id: 10,
          fecha: '2026-10-28',
          tipo: 'agua_suelta',
          cantidad: 2,
          precio: 300,
          vendedor: duany,
          responsable: dueno,
          registrado: duany));
      await _sembrar(_fila(
          id: 11,
          fecha: '2026-10-28',
          tipo: 'dosis_con_agua',
          cantidad: 1,
          precio: 900,
          vendedor: gabriel,
          responsable: gabriel,
          comisionero: gabriel,
          registrado: gabriel));
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

      final cuadreDueno = await cuadreServiciosDia(dueno, '2026-10-30');
      expect(cuadreDueno['efectivo'], 0.0);
      expect(cuadreDueno['dosis_con_agua'], 0);
      expect(cuadreDueno['agua_suelta'], 0);
      // El reverso netea en su propio día por convención del servidor:
      // Gabriel ve -1 dosis ese día, pero su efectivo no se mueve.
      final cuadreGabriel = await cuadreServiciosDia(gabriel, '2026-10-30');
      expect(cuadreGabriel['efectivo'], 0.0);
      expect(cuadreGabriel['dosis_con_agua'], -1);
    });

    test('el reverso de una venta sin entregar sigue neteando', () async {
      // El servidor copia los roles del original: el reverso resta
      // del mismo vendedor y responsable, sin necesitar fallback.
      await _sembrar(_fila(
          id: 20,
          fecha: '2026-10-30',
          tipo: 'dosis_sin_agua',
          cantidad: 1,
          precio: 600,
          vendedor: gabriel,
          responsable: gabriel,
          registrado: gabriel));
      await _sembrar(_fila(
          id: 21,
          fecha: '2026-10-30',
          tipo: 'dosis_sin_agua',
          cantidad: -1,
          precio: 600,
          vendedor: gabriel,
          responsable: gabriel,
          registrado: gabriel,
          reversoDe: 20));

      final cuadre = await cuadreServiciosDia(gabriel, '2026-10-30');
      expect(cuadre['efectivo'], 0.0);
      expect(cuadre['dosis_sin_agua'], 0);
    });

    test('la fila vieja sin roles sigue recayendo en quien registró',
        () async {
      // Sin columnas de roles (previa al ítem 8) y sin ser reverso,
      // el fallback a registrado_por se conserva.
      await _sembrar(_fila(
          id: 30,
          fecha: '2026-10-30',
          tipo: 'dosis_sin_agua',
          cantidad: 1,
          precio: 600,
          vendedor: null,
          responsable: null,
          registrado: gabriel));

      final cuadre = await cuadreServiciosDia(gabriel, '2026-10-30');
      expect(cuadre['efectivo'], 600.0);
      expect(cuadre['dosis_sin_agua'], 1);
    });
  });
}
