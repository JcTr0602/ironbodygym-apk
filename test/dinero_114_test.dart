/// Tests 1.14 (D17): montoCobradoCupOp valora la inscripción+venta
/// con el método real, no siempre a precio de efectivo.
///
/// Antes del fix, una inscripción+venta por transferencia se valoraba
/// en 2000 (efectivo) + venta; después, en 2500 (transferencia) + venta.
/// Requiere BD local (preciosVigentes lee ajustes; vacía usa los
/// valores por defecto 2000/2500).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
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

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload) => {
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

Map<String, dynamic> _payloadInscripcionVenta(String? metodo) => {
      if (metodo != null) 'metodo_pago': metodo,
      // La app real (payloadInscripcionVentaSuplemento) NO manda
      // monto en el mapa del cliente: el precio lo decide la tarifa
      // según el método. La fixture vieja llevaba 'monto': 2000 y
      // con la prioridad 1.15 del monto del payload habría tapado
      // el caso D17 (transferencia = 2500, no 2000).
      'cliente': {'periodo': 'mensual', 'meses': 1},
      'venta': {'moneda': 'CUP', 'cantidad': 2, 'precio': 500},
    };

void main() {
  setUpAll(_abrirDbVacia);

  group('montoCobradoCupOp inscripcion_venta_suplemento (1.14 D17)', () {
    test('efectivo: 2000 + venta 1000', () async {
      final v = await montoCobradoCupOp(
          _op('inscripcion_venta_suplemento', _payloadInscripcionVenta('efectivo')));
      expect(v, 3000);
    });

    test('sin método (op vieja) se asume efectivo', () async {
      final v = await montoCobradoCupOp(
          _op('inscripcion_venta_suplemento', _payloadInscripcionVenta(null)));
      expect(v, 3000);
    });

    test('transferencia: 2500 + venta 1000 (no 2000)', () async {
      final v = await montoCobradoCupOp(
          _op('inscripcion_venta_suplemento', _payloadInscripcionVenta('transferencia')));
      expect(v, 3500);
    });
  });

  group('montoCobradoCupOp pago_mensual con periodo tipo: (panel 1.14)', () {
    test('tipo:oferta50 en efectivo vale el monto real, no 2000', () async {
      final v = await montoCobradoCupOp(_op('pago_mensual', {
        'periodo': 'tipo:oferta50',
        'meses': 1,
        'monto': 1000,
        'metodo': 'efectivo',
      }));
      expect(v, 1000);
    });

    test('tipo:oferta50 por transferencia también vale el monto real',
        () async {
      final v = await montoCobradoCupOp(_op('pago_mensual', {
        'periodo': 'tipo:oferta50',
        'meses': 1,
        'monto': 1000,
        'metodo': 'transferencia',
      }));
      expect(v, 1000);
    });
  });
}
