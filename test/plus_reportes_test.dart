/// Bandeja «Reportes A++» G2 (v1.7.0) — CONTRATO DEFINITIVO del
/// servidor (B2):
///
/// - Confirmar: op `plus_confirmar_reporte`
///   {reporte_id: int, monto_cup, invitado_id?} — SIN `decision`.
/// - Rechazar: op SEPARADA `plus_rechazar_reporte`
///   {reporte_id: int, motivo} — motivo obligatorio.
/// - Listado: RPC `plus_reportes_listar(p_estado, p_limite,
///   p_desde)`; cada fila puede traer
///   `alerta_referencia_rechazada`.
///
/// Sin red: el servicio se prueba con RPC inyectada y las
/// decisiones contra la cola local real.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plus_reportes.dart';
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

ReportePlus _reporte(String id) => ReportePlus(
      id: id,
      invitadoId: 'inv-$id',
      nombre: 'Invitado $id',
      telefono: '58190000',
      monto: 1000,
      referencia: 'REF$id',
      banco: '',
      movilOrigen: '',
      creadoEn: null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('contrato: constantes centralizadas', () {
    expect(kTipoOpConfirmarPlus, 'plus_confirmar_reporte');
    expect(kTipoOpRechazarPlus, 'plus_rechazar_reporte');
    expect(kRpcListarReportesPlus, 'plus_reportes_listar');
    expect(kEstadoReportesPendientes, 'pendiente');
  });

  test('payloadConfirmarPlus: exacto, sin campo decision', () {
    expect(
      payloadConfirmarPlus(
          reporteId: 5, montoCup: 1000, invitadoId: 'inv-1'),
      {'reporte_id': 5, 'monto_cup': 1000, 'invitado_id': 'inv-1'},
    );
    expect(
      payloadConfirmarPlus(reporteId: 5, montoCup: 1000),
      {'reporte_id': 5, 'monto_cup': 1000},
      reason: 'invitado_id es opcional: sin valor no viaja',
    );
    expect(
      payloadConfirmarPlus(reporteId: 5, montoCup: 1500.5),
      {'reporte_id': 5, 'monto_cup': 1500.5},
      reason: 'monto con decimales se conserva como número',
    );
    expect(
      payloadConfirmarPlus(reporteId: 5, montoCup: 1000)
          .containsKey('decision'),
      isFalse,
    );
  });

  test('payloadRechazarPlus: exacto, motivo recortado', () {
    expect(
      payloadRechazarPlus(
          reporteId: 7, motivo: '  no se ve el pago  '),
      {'reporte_id': 7, 'motivo': 'no se ve el pago'},
    );
  });

  test('gate: solo el dueño decide (fail-closed)', () {
    expect(puedeDecidirReportesPlus(esDueno: true), isTrue);
    expect(puedeDecidirReportesPlus(esDueno: false), isFalse);
  });

  test('parsearReportesPlus: formas, tolerancia y alerta', () {
    final filaOk = {
      'id': 11,
      'invitado_id': 'i1',
      'nombre': 'Ana',
      'telefono': '58191111',
      'monto': 1000,
      'referencia': 'ABC123',
      'banco': 'BANDEC',
      'movil_origen': '58191111',
      'creado_en': '2026-10-23T10:00:00Z',
      'alerta_referencia_rechazada': true,
    };
    // Lista directa; el id numérico del servidor se conserva y
    // se expone como entero para los payloads.
    var lista = parsearReportesPlus([filaOk]);
    expect(lista.length, 1);
    expect(lista.single.id, '11');
    expect(lista.single.reporteIdInt, 11);
    expect(lista.single.nombre, 'Ana');
    expect(lista.single.monto, 1000.0);
    expect(lista.single.creadoEn, isNotNull);
    expect(lista.single.alertaReferenciaRechazada, isTrue,
        reason: 'la bandera del servidor llega al modelo');
    // Sin la bandera: false (no alerta fantasma).
    lista = parsearReportesPlus([
      {'id': 'r2', 'invitado_id': 'i2'}
    ]);
    expect(lista.single.alertaReferenciaRechazada, isFalse);
    expect(lista.single.nombre, 'Invitado');
    // Mapa con 'reportes' y con 'pendientes'.
    expect(parsearReportesPlus({'reportes': [filaOk]}).length, 1);
    expect(parsearReportesPlus({'pendientes': [filaOk]}).length, 1);
    // Monto por la clave alterna precio_cup.
    lista = parsearReportesPlus([
      {'reporte_id': 'r9', 'invitado_id': 'i9', 'precio_cup': '1000'}
    ]);
    expect(lista.single.id, 'r9');
    expect(lista.single.monto, 1000.0);
    // Filas sin id o sin invitado se descartan; basura no rompe.
    expect(
        parsearReportesPlus([
          {'invitado_id': 'i1'},
          {'id': 'r1'},
          'basura',
          42,
        ]).length,
        0);
    expect(parsearReportesPlus(null).length, 0);
    expect(parsearReportesPlus({'otra': []}).length, 0);
  });

  test('servicio: llama plus_reportes_listar con sus parámetros '
      'y ordena FIFO', () async {
    String? nombreVisto;
    Map<String, dynamic>? paramsVistos;
    final svc = PlusReportesService(rpc: (nombre, params) async {
      nombreVisto = nombre;
      paramsVistos = params;
      return [
        {
          'id': 2,
          'invitado_id': 'i2',
          'creado_en': '2026-10-23T12:00:00Z'
        },
        {
          'id': 1,
          'invitado_id': 'i1',
          'creado_en': '2026-10-23T08:00:00Z'
        },
      ];
    });
    final lista = await svc.pendientes();
    expect(nombreVisto, 'plus_reportes_listar');
    expect(paramsVistos?['p_estado'], 'pendiente');
    expect(paramsVistos?['p_limite'], kLimiteReportesPlus);
    expect(paramsVistos?['p_desde'], 0);
    expect(lista.map((r) => r.id).toList(), ['1', '2']);
  });

  test('reportesPlusConOpPendiente: ambos tipos de op bloquean',
      () {
    final ops = <Map<String, dynamic>>[
      {
        'tipo': kTipoOpConfirmarPlus,
        'payload': '{"reporte_id":1,"monto_cup":1000}',
      },
      {
        'tipo': kTipoOpRechazarPlus,
        'payload': {'reporte_id': 2, 'motivo': 'x'},
      },
      {
        'tipo': 'pago_mensual',
        'payload': '{"reporte_id":9}',
      },
      {'tipo': kTipoOpConfirmarPlus, 'payload': 'no-es-json'},
      {'tipo': kTipoOpRechazarPlus, 'payload': ''},
    ];
    expect(reportesPlusConOpPendiente(ops), {'1', '2'});
  });

  test('encolarDecisionPlus: confirmar y rechazar son ops '
      'distintas con su payload exacto', () async {
    final db = await _abrirDbVacia();
    await encolarDecisionPlus(
      LocalDb.instance,
      reporte: _reporte('7'),
      confirmar: true,
      opUuid: 'op-plus-conf',
    );
    await encolarDecisionPlus(
      LocalDb.instance,
      reporte: _reporte('8'),
      confirmar: false,
      motivo: 'referencia no encontrada',
      opUuid: 'op-plus-rech',
    );
    final ops = await LocalDb.instance.pendingOps();
    final conf =
        ops.singleWhere((o) => o['op_uuid'] == 'op-plus-conf');
    expect(conf['tipo'], 'plus_confirmar_reporte');
    expect(
      jsonDecode(conf['payload'] as String),
      {'reporte_id': 7, 'monto_cup': 1000, 'invitado_id': 'inv-7'},
    );
    final rech =
        ops.singleWhere((o) => o['op_uuid'] == 'op-plus-rech');
    expect(rech['tipo'], 'plus_rechazar_reporte');
    expect(
      jsonDecode(rech['payload'] as String),
      {'reporte_id': 8, 'motivo': 'referencia no encontrada'},
    );
    // Ambas tarjetas quedan bloqueadas en la bandeja.
    expect(reportesPlusConOpPendiente(ops), {'7', '8'});
    await db.close();
  });

  test('encolarDecisionPlus: monto ajustado por el dueño', () async {
    final db = await _abrirDbVacia();
    await encolarDecisionPlus(
      LocalDb.instance,
      reporte: _reporte('9'),
      confirmar: true,
      montoCup: 900,
      opUuid: 'op-plus-ajuste',
    );
    final ops = await LocalDb.instance.pendingOps();
    final op = ops.singleWhere((o) => o['op_uuid'] == 'op-plus-ajuste');
    expect((jsonDecode(op['payload'] as String)
        as Map)['monto_cup'], 900);
    await db.close();
  });

  test('montoConfirmacionPlusValido: finito y mayor que 0', () {
    expect(montoConfirmacionPlusValido(1000), isTrue);
    expect(montoConfirmacionPlusValido(0.5), isTrue);
    expect(montoConfirmacionPlusValido(null), isFalse);
    expect(montoConfirmacionPlusValido(0), isFalse);
    expect(montoConfirmacionPlusValido(-250), isFalse);
    // tryParse acepta estos textos y un «<= 0» no los frenaría:
    expect(montoConfirmacionPlusValido(double.nan), isFalse);
    expect(montoConfirmacionPlusValido(double.infinity), isFalse);
    expect(
        montoConfirmacionPlusValido(double.negativeInfinity), isFalse);
  });
}
