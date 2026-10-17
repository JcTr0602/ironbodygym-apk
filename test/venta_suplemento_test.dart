/// Tests del núcleo de venta unificado de suplementos (v1.3.4, B1/C1/C2/C3).
///
/// Cubre `registrarVentaSuplemento` (lib/negocio.dart):
/// - venta exitosa: descuenta stock en el JSON y encola la op en UNA
///   transacción atómica;
/// - falla con stock insuficiente (cantidad > stock): no escribe nada;
/// - falla con cantidad <= 0 y precio <= 0 (validación pre-transacción);
/// - el payload lleva centavos enteros correctos y `moneda: 'USD'`;
/// - `precioDifiereEnCentavos`: 35.00 vs 30.00 difiere, 35.00 vs 35.00 no.
///
/// Patrón de BD: igual que pagos_indexados_test.dart (sqflite_common_ffi +
/// LocalDb.instance contra ironbody.db fresca por test).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _sembrarSuplemento() =>
    LocalDb.instance.upsertMirror('suplementos', 1, {
      'id': 1,
      'nombre': 'Creatina Monohidrato',
      'precio_oficial': 35.00,
      'stock': 10,
      'categoria': 'Creatinas',
    }, 1);

Future<int> _stockActual() async {
  final d = await LocalDb.instance.db;
  final rows = await d.query('suplementos',
      columns: ['data'], where: 'id = ?', whereArgs: [1], limit: 1);
  final data =
      jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
  return (data['stock'] as num).toInt();
}

Future<List<Map<String, dynamic>>> _opsVenta() async {
  final d = await LocalDb.instance.db;
  return d.query('ops_queue',
      where: "tipo = 'venta_suplemento'", orderBy: 'creada_ts');
}

Map<String, dynamic> _payload(Map<String, dynamic> op) =>
    jsonDecode(op['payload'] as String) as Map<String, dynamic>;

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
    await LocalDb.instance.db; // dispara onCreate v26
    await _sembrarSuplemento();
  });

  group('registrarVentaSuplemento', () {
    test('venta exitosa descuenta stock y encola la op en una transacción',
        () async {
      final opUuid = await registrarVentaSuplemento(
        suplementoId: 1,
        cantidad: 3,
        precioOficial: 35.00,
        precioVenta: 35.00,
        compradorTipo: 'externo',
        compradorNombre: 'Cliente externo',
        nota: 'venta rápida',
      );

      expect(opUuid, isNotEmpty);
      // Stock descontado en el JSON.
      expect(await _stockActual(), 7);
      // Una sola op encolada, con el uuid devuelto.
      final ops = await _opsVenta();
      expect(ops, hasLength(1));
      expect(ops.first['op_uuid'], opUuid);
      expect(ops.first['estado'], 'pendiente');
      final pay = _payload(ops.first);
      expect(pay['suplemento_id'], 1);
      expect(pay['cantidad'], 3);
      expect(pay['precio'], 35.00);
      expect(pay['precio_oficial'], 35.00);
      expect(pay['precio_oficial_centavos'], 3500);
      expect(pay['precio_venta_centavos'], 3500);
      expect(pay['descuento_autorizado_centavos'], 0);
      expect(pay['moneda'], 'USD');
      expect(pay['usd_tasa'], 1.0);
      expect(pay['comprador_tipo'], 'externo');
      expect(pay.containsKey('cliente_id'), isFalse);
      expect(pay['comprador_nombre'], 'Cliente externo');
      expect(pay['fecha'], hoyHabanaIso());
      expect(pay['nota'], 'venta rápida');
      expect(pay['entregado'], 0);
      // NUNCA inserta en ventas_suplementos (espejo puro por pull).
      final d = await LocalDb.instance.db;
      final ventas = await d.query('ventas_suplementos');
      expect(ventas, isEmpty);
    });

    test('venta con txn explícito y precio distinto registra centavos',
        () async {
      final d = await LocalDb.instance.db;
      final opUuid = await d.transaction((txn) async {
        return registrarVentaSuplemento(
          suplementoId: 1,
          cantidad: 2,
          precioOficial: 35.00,
          precioVenta: 30.00,
          compradorTipo: 'cliente',
          clienteId: 42,
          compradorNombre: 'Juan Pérez',
          notaPrecio: 'Autorizado por Jc',
          txn: txn,
        );
      });

      expect(opUuid, isNotEmpty);
      expect(await _stockActual(), 8);
      final ops = await _opsVenta();
      expect(ops, hasLength(1));
      final pay = _payload(ops.first);
      expect(pay['precio_oficial_centavos'], 3500);
      expect(pay['precio_venta_centavos'], 3000);
      expect(pay['descuento_autorizado_centavos'], -500);
      expect(pay['comprador_tipo'], 'cliente');
      expect(pay['cliente_id'], 42);
      expect(pay['nota_precio'], 'Autorizado por Jc');
    });

    test('falla con stock insuficiente y no escribe nada', () async {
      await expectLater(
        registrarVentaSuplemento(
          suplementoId: 1,
          cantidad: 99, // stock = 10
          precioOficial: 35.00,
          precioVenta: 35.00,
          compradorTipo: 'externo',
          compradorNombre: 'Cliente externo',
        ),
        throwsA(isA<Exception>().having(
            (e) => '$e', 'mensaje', contains('Stock insuficiente'))),
      );
      // Nada escrito: ni stock tocado ni op encolada (atomicidad).
      expect(await _stockActual(), 10);
      expect(await _opsVenta(), isEmpty);
    });

    test('falla con cantidad <= 0 y precio <= 0 (pre-transacción)', () async {
      await expectLater(
        registrarVentaSuplemento(
          suplementoId: 1,
          cantidad: 0,
          precioOficial: 35.00,
          precioVenta: 35.00,
          compradorTipo: 'externo',
          compradorNombre: 'Cliente externo',
        ),
        throwsException,
      );
      await expectLater(
        registrarVentaSuplemento(
          suplementoId: 1,
          cantidad: -2,
          precioOficial: 35.00,
          precioVenta: 35.00,
          compradorTipo: 'externo',
          compradorNombre: 'Cliente externo',
        ),
        throwsException,
      );
      await expectLater(
        registrarVentaSuplemento(
          suplementoId: 1,
          cantidad: 1,
          precioOficial: 35.00,
          precioVenta: 0,
          compradorTipo: 'externo',
          compradorNombre: 'Cliente externo',
        ),
        throwsException,
      );
      expect(await _stockActual(), 10);
      expect(await _opsVenta(), isEmpty);
    });

    test('cliente sin clienteId falla', () async {
      await expectLater(
        registrarVentaSuplemento(
          suplementoId: 1,
          cantidad: 1,
          precioOficial: 35.00,
          precioVenta: 35.00,
          compradorTipo: 'cliente',
          compradorNombre: 'Juan Pérez',
        ),
        throwsException,
      );
      expect(await _opsVenta(), isEmpty);
    });

    test('usd_tasa inválida se normaliza a 1.0', () async {
      await registrarVentaSuplemento(
        suplementoId: 1,
        cantidad: 1,
        precioOficial: 35.00,
        precioVenta: 35.00,
        usdTasa: -5,
        compradorTipo: 'externo',
        compradorNombre: 'Cliente externo',
      );
      final pay = _payload((await _opsVenta()).first);
      expect(pay['usd_tasa'], 1.0);
    });
  });

  group('precioDifiereEnCentavos', () {
    test('35.00 vs 30.00 difiere; 35.00 vs 35.00 no', () {
      expect(precioDifiereEnCentavos(35.00, 30.00), isTrue);
      expect(precioDifiereEnCentavos(35.00, 35.00), isFalse);
    });

    test('no hay falsos por aritmética de double', () {
      // 19.99 * 100 = 1998.999999... en double; en centavos es igual.
      expect(precioDifiereEnCentavos(19.99, 19.99), isFalse);
      expect(precioDifiereEnCentavos(10.10, 10.1), isFalse);
      // Un centavo real sí difiere.
      expect(precioDifiereEnCentavos(35.00, 34.99), isTrue);
    });
  });
}
