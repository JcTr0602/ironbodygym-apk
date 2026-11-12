/// Compuertas 1.32 — fila X-3 (defecto de CAMPO 2026-11-12,
/// reportado por Jc con captura; en producción 1.31 e
/// idéntico en el candidato): el dueño NO podía marcar su
/// consumo propio a la Casa operando desde el pomo de un
/// entrenador. La guarda de `_payloadVentaServicio` miraba
/// `vendedorEsDueno` (el vendedor ATRIBUIDO, titular del
/// pomo) en vez del ACTOR (la sesión). La corrección
/// enhebra `actorEsDueno` hasta la guarda y solo hasta
/// ella: saldo y comisión siguen gobernados por el
/// vendedor atribuido.
///
/// Siembra patrón ventas_115b: pomo 10 de Duany
/// (titular_telegram_id 969869611) con 40 dosis.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _espejo(String tabla, int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {'id': id, 'data': jsonEncode(data), 'sync_seq': 1});
}

/// Pomo 10: de Duany, 40 dosis asignadas, activo.
Future<void> _siembraPomoDuany() async {
  await _espejo('servicio_pomos', 10, {
    'suplemento_id': 1,
    'titular_telegram_id': 969869611,
    'es_principal': 0,
    'dosis_asignadas': 40,
    'dosis_repartidas': 0,
    'activo': 1,
  });
  await LocalDb.instance
      .setMeta('ajustes', jsonEncode({'servicio_comision_dosis': 50}));
}

Future<Map<String, dynamic>> _payloadDe(String opUuid) async {
  final op = await LocalDb.instance.opEnCola(opUuid);
  return jsonDecode(op!['payload'] as String) as Map<String, dynamic>;
}

Future<int> _opsEnCola() async {
  final d = await LocalDb.instance.db;
  final filas = await d.query('ops_queue');
  return filas.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('X-3 · Casa para el dueño: la guarda mira al ACTOR', () {
    test(
        '(1) SIMPLE: dueño desde el pomo de Duany → se '
        'registra, descuenta de SU pomo, precio 0, sin comisión',
        () async {
      await _bdVacia();
      await _siembraPomoDuany();
      expect(await saldoPomoLocal(10), 40);
      final uuid = await registrarVentaServicio(
        tipo: 'dosis_sin_agua',
        pomoId: 10,
        cantidad: 1,
        casa: true,
        beneficiario: 'dueno',
        vendedorEsDueno: false, // vendedor atribuido: Duany
        actorEsDueno: true, // quien opera: el dueño
        vendedorId: 969869611,
      );
      expect(uuid, isNotEmpty);
      expect(await saldoPomoLocal(10), 39,
          reason: 'la dosis sale del pomo abierto en el '
              'mostrador (el de Duany), no del principal');
      final pay = await _payloadDe(uuid);
      expect(pay['casa'], isTrue);
      expect(pay['beneficiario'], 'dueno');
      expect(pay['pomo_id'], 10);
      expect(pay['vendedor_id'], 969869611);
      expect(pay['precio_unitario'], 0,
          reason: 'el consumo propio del dueño no se cobra');
      expect(pay['comision_unitaria'], 0,
          reason: 'nadie gana comisión por la Casa del dueño');
    });

    test(
        '(2) un ENTRENADOR intentando Casa para el dueño '
        'sigue bloqueado, con aviso comprensible', () async {
      await _bdVacia();
      await _siembraPomoDuany();
      await expectLater(
        registrarVentaServicio(
          tipo: 'dosis_sin_agua',
          pomoId: 10,
          cantidad: 1,
          casa: true,
          beneficiario: 'dueno',
          vendedorEsDueno: false,
          actorEsDueno: false, // quien opera: un entrenador
          vendedorId: 969869611,
        ),
        throwsA(isA<Exception>().having((e) => e.toString(), 'mensaje',
            contains('Solo el dueño puede marcar su propio consumo'))),
      );
      expect(await _opsEnCola(), 0,
          reason: 'el bloqueo no deja ninguna op encolada');
      expect(await saldoPomoLocal(10), 40);
    });

    test(
        '(3a) Casa con un cliente SIN cuenta_casa sigue '
        'bloqueada', () async {
      await _bdVacia();
      await _siembraPomoDuany();
      await _espejo('clientes', 77, {
        'nombre': 'Sin Casa',
        'estado': 'activo',
        'cuenta_casa': 0,
        'fecha_inscripcion': '2026-01-01',
      });
      await expectLater(
        registrarVentaServicio(
          tipo: 'dosis_sin_agua',
          pomoId: 10,
          cantidad: 1,
          clienteId: 77,
          casa: true,
          vendedorEsDueno: false,
          actorEsDueno: true,
          vendedorId: 969869611,
        ),
        throwsA(isA<Exception>().having((e) => e.toString(), 'mensaje',
            contains('La Cuenta a la Casa solo aplica'))),
      );
      expect(await _opsEnCola(), 0);
    });

    test(
        '(3b) Casa para el dueño CON cliente sigue bloqueada '
        '(el consumo propio no lleva cliente)', () async {
      await _bdVacia();
      await _siembraPomoDuany();
      await _espejo('clientes', 78, {
        'nombre': 'Con Casa',
        'estado': 'activo',
        'cuenta_casa': 1,
        'fecha_inscripcion': '2026-01-01',
      });
      await expectLater(
        registrarVentaServicio(
          tipo: 'dosis_sin_agua',
          pomoId: 10,
          cantidad: 1,
          clienteId: 78,
          casa: true,
          beneficiario: 'dueno',
          vendedorEsDueno: false,
          actorEsDueno: true,
          vendedorId: 969869611,
        ),
        throwsA(isA<Exception>().having((e) => e.toString(), 'mensaje',
            contains('no lleva cliente'))),
      );
      expect(await _opsEnCola(), 0);
    });

    test(
        '(4) MÚLTIPLE: dueño desde el pomo de Duany → grupo '
        'registrado, descuento del pomo ajeno, todo a 0',
        () async {
      await _bdVacia();
      await _siembraPomoDuany();
      final uuids = await registrarVentaMultipleServicio(
        pomoId: 10,
        dosisN: 3,
        pomosM: 0,
        casa: true,
        beneficiario: 'dueno',
        vendedorEsDueno: false,
        actorEsDueno: true,
        vendedorId: 969869611,
        topeDosis: 40,
        topePomos: 10,
      );
      expect(uuids, hasLength(1),
          reason: 'sin agua, el grupo es una sola op ×3');
      expect(await saldoPomoLocal(10), 37);
      final pay = await _payloadDe(uuids.single);
      expect(pay['cantidad'], 3);
      expect(pay['beneficiario'], 'dueno');
      expect(pay['precio_unitario'], 0);
      expect(pay['comision_unitaria'], 0);
      expect(pay['venta_grupo_id'], isNotNull);
    });

    test(
        '(5) REPETIR: la repetición de Mi Turno enhebra el '
        'mismo criterio — una Casa de CLIENTE repetida por el '
        'entrenador sigue pasando (su guarda no es la del '
        'dueño)', () async {
      await _bdVacia();
      await _siembraPomoDuany();
      await _espejo('clientes', 79, {
        'nombre': 'De La Casa',
        'estado': 'activo',
        'cuenta_casa': 1,
        'fecha_inscripcion': '2026-01-01',
      });
      final uuids = await repetirUltimaVentaServicio(
        {
          'forma': 'simple',
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'pomo_id': 10,
          'cliente_id': 79,
          'casa': true,
        },
        topePomosAgua: 10,
        actorEsDueno: false,
      );
      expect(uuids, hasLength(1));
      expect(await saldoPomoLocal(10), 39);
      final pay = await _payloadDe(uuids.single);
      expect(pay['casa'], isTrue);
      expect(pay['cliente_id'], 79);
      expect(pay['precio_unitario'], 0);
    });
  });
}
