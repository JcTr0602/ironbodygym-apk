/// Corrección A5-D2 (auditoría 5 de la 1.28): el editor de
/// Configuración «Mensualidad menores» y el Diagnóstico
/// vivían en la clave fija legacy, pero el cobro lee la
/// FUENTE ÚNICA (el tipo 'menores' del blob `tipos_pago`,
/// vía precioMenoresDesdeAjustes): editar el campo no
/// cambiaba lo cobrado.
///
/// El test fija la escritura nueva de punta a punta:
/// - blobTiposConPrecioMenores (pura): el blob sale completo
///   con el monto nuevo y el resto intacto, y la lectura de
///   la fuente única devuelve el precio NUEVO aunque la
///   clave legacy diga otra cosa.
/// - aplicarCambiosMontos (BD real): encola la op
///   guardar_tipos_pago con el blob nuevo en la misma
///   transacción que la op ajuste de la clave espejo, y el
///   ajustes local queda con el blob actualizado.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:ironbody_gym/ui/config_precios_bancarios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('blobTiposConPrecioMenores (escritura de la fuente única)',
      () {
    test('blob con menores: solo cambia su monto', () {
      final aj = <String, dynamic>{
        'mensualidad_menores': 1500,
        'tipos_pago': [
          {'id': 'mensual', 'nombre': 'Mensualidad', 'monto': 2000, 'dias': 30},
          {
            'id': 'menores',
            'nombre': 'Mensualidad menores',
            'monto': 1500,
            'dias': 30,
            'solo_menores': true,
          },
          {'id': 'oferta_50', 'nombre': 'Oferta', 'monto': 1000, 'dias': 30},
        ],
      };
      final blob = blobTiposConPrecioMenores(aj, 1600);
      expect(blob.length, 3);
      expect(blob[0]['monto'], 2000, reason: 'mensual intacto');
      expect(blob[1]['monto'], 1600.0);
      expect(blob[2]['monto'], 1000, reason: 'oferta intacta');
      // Y la lectura de la fuente única cobra lo NUEVO aunque
      // la clave legacy siga diciendo 1500.
      final ajNuevo = {...aj, 'tipos_pago': blob};
      expect(precioMenoresDesdeAjustes(ajNuevo), 1600);
    });

    test('blob sin menores: se inserta tras mensual', () {
      final aj = <String, dynamic>{
        'tipos_pago': [
          {'id': 'mensual', 'nombre': 'Mensualidad', 'monto': 2000, 'dias': 30},
          {'id': 'semanal', 'nombre': 'Semana', 'monto': 600, 'dias': 7},
        ],
      };
      final blob = blobTiposConPrecioMenores(aj, 1700);
      expect(blob.map((t) => t['id']), ['mensual', 'menores', 'semanal']);
      expect(blob[1]['monto'], 1700.0);
      expect(blob[1]['solo_menores'], isTrue);
    });

    test('sin blob: materializa la lista por defecto completa', () {
      final aj = <String, dynamic>{
        'mensualidad': 2100,
        'pago_semanal': 650,
      };
      final blob = blobTiposConPrecioMenores(aj, 1550);
      expect(blob.map((t) => t['id']),
          ['mensual', 'menores', 'semanal', 'quincenal']);
      expect(blob[0]['monto'], 2100.0,
          reason: 'mensual sale de su clave fija');
      expect(blob[1]['monto'], 1550.0);
      expect(blob[2]['monto'], 650.0);
      expect(blob[3]['monto'], 1200.0,
          reason: 'quincenal cae a su default histórico');
    });
  });

  group('aplicarCambiosMontos escribe el blob (BD real)', () {
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_a5_menores_test.db';
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', anonKey: 'dummy');
      } catch (_) {}
      await LocalDb.resetParaTest();
      final db = await LocalDb.instance.db;
      await db.delete('ops_queue');
      await LocalDb.instance.setAjustes({});
    });

    test('guardar «Mensualidad menores» encola guardar_tipos_pago '
        'con el precio nuevo y la fuente única lo cobra', () async {
      await LocalDb.instance.setAjustes({
        'mensualidad_menores': 1500,
        'tipos_pago': [
          {'id': 'mensual', 'nombre': 'Mensualidad', 'monto': 2000, 'dias': 30},
          {
            'id': 'menores',
            'nombre': 'Mensualidad menores',
            'monto': 1500,
            'dias': 30,
            'solo_menores': true,
          },
        ],
      });

      await aplicarCambiosMontos({'mensualidad_menores': 1600});

      // El ajustes local ya cobra lo nuevo por la fuente única.
      final aj = await LocalDb.instance.getAjustes();
      expect(precioMenoresDesdeAjustes(aj), 1600,
          reason: 'tras guardar en Configuración, la fuente '
              'única debe devolver el precio editado');
      // La op del blob viaja al servidor…
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue');
      final deTipos = ops.where((o) => o['tipo'] == 'guardar_tipos_pago');
      expect(deTipos, hasLength(1));
      final payload =
          jsonDecode(deTipos.single['payload'] as String) as Map<String, dynamic>;
      final tipos = payload['tipos'] as List;
      final menores =
          tipos.cast<Map<String, dynamic>>().singleWhere((t) => t['id'] == 'menores');
      expect((menores['monto'] as num).toDouble(), 1600);
      // …y la clave legacy queda como espejo (respaldo).
      final deAjuste = ops.where((o) =>
          o['tipo'] == 'ajuste' &&
          (jsonDecode(o['payload'] as String) as Map)['clave'] ==
              'mensualidad_menores');
      expect(deAjuste, hasLength(1));
    });

    test('otros montos NO encolan guardar_tipos_pago', () async {
      await aplicarCambiosMontos({'pago_diario': 250});
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue');
      expect(ops.where((o) => o['tipo'] == 'guardar_tipos_pago'),
          isEmpty);
      expect(ops.where((o) => o['tipo'] == 'ajuste'), hasLength(1));
    });
  });
}
