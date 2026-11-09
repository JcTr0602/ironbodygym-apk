// Yunque B · lente SERVICIOS — regresión de SER-05, SER-06 y
// SER-07 (Gestión 1.31).
//
// SER-05: la guarda de borrado de suplemento cuenta también
// las ops de dosis por pomo, los rellenos y las de reserva.
// SER-06: el contador de solicitadas visibles aplica el
// filtro de protegidos de la bandeja.
// SER-07: la solicitud vencida se detecta como la reservada.
//
// (SER-02 —la hoja de relleno ya no pinta el saldo— y SER-03
// —tope ciego en la venta simple— son de UI sin costura pura;
// SER-04 es el listener de sesión de AccesoAppCache, espejo
// del de PermisosEntrenador: verificados por lectura y
// analyze en el informe de la oleada.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:ironbody_gym/ui/reservas.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

int _seq = 7300;

Future<void> _pomo(Database db, int id, int suplementoId) async {
  await db.insert('servicio_pomos', {
    'id': id,
    'data': jsonEncode(
        {'id': id, 'suplemento_id': suplementoId, 'activo': 1}),
    'sync_seq': _seq++,
  });
}

Future<void> _reserva(
    Database db, int id, int suplementoId, String estado) async {
  await db.insert('reservas', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'suplemento_id': suplementoId,
      'cliente_id': 1,
      'estado': estado,
    }),
    'sync_seq': _seq++,
  });
}

int _opN = 0;
Future<void> _op(String tipo, Map<String, dynamic> payload) =>
    LocalDb.instance.queueOp(
        opUuid: 'yb-ser-${_opN++}', tipo: tipo, payload: payload);

void main() {
  group('YB-SER-05 opsVivasQueReferencianSuplemento', () {
    setUp(() async {
      final db = await _abrirDbVacia();
      // Suplemento 7 con pomos 70/71 y reserva viva 700;
      // suplemento 8 con pomo 80 y reserva 800.
      await _pomo(db, 70, 7);
      await _pomo(db, 71, 7);
      await _pomo(db, 80, 8);
      await _reserva(db, 700, 7, 'solicitada');
      await _reserva(db, 800, 8, 'reservada');
      // Reserva terminal del 7: sus ops ya no cuentan.
      await _reserva(db, 701, 7, 'cancelada');
    });

    test('sin ops: cero', () async {
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 7), 0);
    });

    test('venta de dosis por pomo del suplemento: cuenta', () async {
      await _op('venta_servicio', {'pomo_id': 71, 'cantidad': 1});
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 7), 1);
      // Y no cuenta para el otro suplemento.
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 8), 0);
    });

    test('salida y reversión por pomo también cuentan', () async {
      await _op('salida_servicio', {'pomo_id': 70});
      await _op('revertir_venta_servicio', {'pomo_id': 70});
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 7), 2);
    });

    test('relleno (reponer_pomo) con suplemento_id: cuenta', () async {
      await _op('reponer_pomo',
          {'pomo_destino_id': 71, 'dosis': 5, 'suplemento_id': 7});
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 7), 1);
    });

    test('op de reserva viva: cuenta; de reserva terminal: no',
        () async {
      await _op('confirmar_reserva', {'reserva_id': 700});
      await _op('cancelar_reserva', {'reserva_id': 701});
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 7), 1);
    });

    test('los tipos históricos siguen contando', () async {
      await _op('venta_suplemento', {'suplemento_id': 7});
      await _op('inscripcion_venta_suplemento', {
        'venta': {'suplemento_id': 7}
      });
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 7), 2);
    });

    test('una op aplicada ya no bloquea', () async {
      await _op('venta_servicio', {'pomo_id': 70});
      final db = await LocalDb.instance.db;
      await db.rawUpdate(
          "UPDATE ops_queue SET estado = 'aplicada'");
      expect(await opsVivasQueReferencianSuplemento(
          LocalDb.instance, 7), 0);
    });
  });

  group('YB-SER-06 contarSolicitadasVisibles', () {
    final clientes = <Map<String, dynamic>>[
      {'id': 1, 'nombre': 'Normal'},
      {'id': 2, 'nombre': 'Protegido', 'protegido': 1},
    ];
    final reservas = <Map<String, dynamic>>[
      {'id': 1, 'cliente_id': 1, 'estado': 'solicitada'},
      {'id': 2, 'cliente_id': 2, 'estado': 'solicitada'},
      {'id': 3, 'cliente_id': 1, 'estado': 'reservada'},
    ];

    test('el dueño cuenta todas las solicitadas', () {
      expect(
          contarSolicitadasVisibles(reservas, clientes,
              esDueno: true),
          2);
    });

    test('el entrenador NO cuenta la del protegido', () {
      expect(
          contarSolicitadasVisibles(reservas, clientes,
              esDueno: false),
          1);
    });
  });

  group('YB-SER-07 solicitudVencida', () {
    ReservaVista vista(String estado, String? expira) => ReservaVista(
          id: 1,
          clienteId: 1,
          clienteNombre: 'Ana',
          suplementoId: 7,
          suplementoNombre: 'Proteína',
          cantidad: 1,
          precioUnitario: 100,
          precioVigente: 100,
          estado: estado,
          creadaTs: '2026-11-01T00:00:00',
          expiraEn: expira,
          notaResolucion: null,
        );
    final ahora = DateTime(2026, 11, 9, 12, 0);

    test('solicitada con expira_en pasado: vencida', () {
      expect(
          vista('solicitada', '2026-11-08T12:00:00')
              .solicitudVencida(ahora),
          isTrue);
    });

    test('solicitada vigente o sin fecha: no vencida', () {
      expect(
          vista('solicitada', '2026-11-10T12:00:00')
              .solicitudVencida(ahora),
          isFalse);
      expect(vista('solicitada', null).solicitudVencida(ahora),
          isFalse);
    });

    test('la reservada vencida sigue siendo de apartadoVencido',
        () {
      final v = vista('reservada', '2026-11-08T12:00:00');
      expect(v.solicitudVencida(ahora), isFalse);
      expect(v.apartadoVencido(ahora), isTrue);
    });
  });
}
