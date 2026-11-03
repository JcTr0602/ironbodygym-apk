/// 1.22 Pieza 1B (campo 2026-11-02) — la confirmación de
/// entrega de Gabriel fue rechazada por el servidor porque la
/// app metió una venta de suplementos en USD (la #5) en la op
/// de entrega CUP: el servidor valida moneda='CUP' y rechazó
/// la op ENTERA.
///  a) idsPendientesEntrega excluye ventas que no sean CUP.
///  b) detallesDeOp de confirmar_entrega y liquidar_nomina ya
///     no salen vacíos (el dueño no veía qué confirmó).
library;

import 'dart:convert';
import 'dart:io';

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

int _seq = 7000;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
  });
}

void main() {
  group('1B-a: idsPendientesEntrega no mete ventas USD en la '
      'entrega CUP', () {
    test('CUP entra; USD/usd fuera; sin moneda = legado CUP',
        () async {
      final db = await _abrirDbVacia();
      const tid = 1403501391; // Gabriel, el caso real
      await _espejo(db, 'ventas_suplementos', 5, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'USD',
        'precio': 30,
      });
      await _espejo(db, 'ventas_suplementos', 6, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'CUP',
        'precio': 600,
      });
      await _espejo(db, 'ventas_suplementos', 7, {
        'registrado_por': tid,
        'entregado': 0,
        'precio': 600,
      });
      await _espejo(db, 'ventas_suplementos', 8, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'usd',
        'precio': 10,
      });
      final ids = await idsPendientesEntrega(trainerId: tid);
      expect(ids.suplementos, [6, 7]);
      await db.close();
    });
  });

  group('1B-b: detalle de la op en el historial', () {
    test('confirmar_entrega muestra entrenador e ítems', () async {
      final op = {
        'tipo': 'confirmar_entrega',
        'payload': jsonEncode({
          'trainer_nombre': 'Gabriel',
          'trainer_telegram_id': 1403501391,
          'pago_ids': [1, 2, 3],
          'pago_diario_ids': [4],
          'suplemento_ids': [5],
          'servicio_ids': <int>[],
        }),
      };
      final d = await detallesDeOp(op);
      expect(d.any((l) => l.contains('Gabriel')), isTrue);
      expect(d.any((l) => l.contains('3 mensualidades')), isTrue);
      expect(d.any((l) => l.contains('1 pagos diarios')), isTrue);
      expect(
          d.any((l) => l.contains('1 ventas de suplementos')),
          isTrue);
    });

    test('liquidar_nomina muestra entrenador, mes y neto',
        () async {
      final op = {
        'tipo': 'liquidar_nomina',
        'payload': jsonEncode({
          'entrenador_nombre': 'Duany',
          'mes': '2026-10',
          'neto': 12500,
        }),
      };
      final d = await detallesDeOp(op);
      expect(d.any((l) => l.contains('Duany')), isTrue);
      expect(d.any((l) => l.contains('2026-10')), isTrue);
      expect(d.any((l) => l.contains('12500')), isTrue);
    });
  });

  group('1B-d: moneda nula = CUP en los totales (auditoría #1)', () {
    test('totalVentaCup trata la venta legada sin moneda como CUP',
        () {
      expect(totalVentaCup({'total': 500}), 500);
      expect(totalVentaCup({'moneda': 'CUP', 'total': 500}), 500);
      expect(totalVentaCup({'moneda': 'USD', 'total': 500}), 0);
      expect(totalVentaCup({'precio': 100, 'cantidad': 3}), 300);
    });
  });

  group('1B-c: confirmarEntregaPorIds no mete ventas USD '
      '(«Cobrar todo»)', () {
    // Autoauditoría 1.22 #1 (2026-11-03): la guarda de la 1B
    // vivía en idsPendientesEntrega y en la pantalla por día,
    // pero «Cobrar todo» remezcla los días CUP+USD en un
    // pseudo-día y confirmarEntregaPorIds encolaba EXACTAMENTE
    // los ids recibidos: la op volvía a rebotar entera en el
    // servidor (el bug de la venta #5 por otra puerta). La
    // función que encola filtra las ventas que no sean CUP
    // contra el espejo, como idsPendientesEntrega.
    test('la op sale solo con la venta CUP y el espejo USD no '
        'se marca entregado', () async {
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', anonKey: 'dummy');
      } catch (_) {}
      final db = await _abrirDbVacia();
      const tid = 1403501391;
      await _espejo(db, 'ventas_suplementos', 5, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'USD',
        'precio': 30,
      });
      await _espejo(db, 'ventas_suplementos', 6, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'CUP',
        'precio': 600,
      });
      await confirmarEntregaPorIds(
        mensualIds: const [],
        diarioIds: const [],
        suplementoIds: const [5, 6],
        entrenadorNombre: 'Gabriel',
        trainerTelegramId: tid,
      );
      final ops = await db.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['confirmar_entrega']);
      expect(ops, hasLength(1));
      final payload =
          jsonDecode(ops.single['payload'] as String)
              as Map<String, dynamic>;
      expect(payload['suplemento_ids'], [6],
          reason: 'la venta USD no viaja en la op CUP');
      final espejo =
          await LocalDb.instance.allMirror('ventas_suplementos');
      final v5 = espejo.singleWhere((v) => v['id'] == 5);
      final v6 = espejo.singleWhere((v) => v['id'] == 6);
      expect(v5['entregado'], isNot(1),
          reason: 'el espejo USD no se marca entregado');
      expect(v6['entregado'], 1);
      await db.close();
    });
  });

  group('CAMPO dashboard: RPC de invitados colgada', () {
    test('contarPlusVigentes corta por timeout y degrada a null',
        () {
      fakeAsync((async) {
        final svc = InvitadosService(
            rpc: (nombre, params) =>
                Completer<dynamic>().future);
        int? resultado = -999;
        var termino = false;
        svc.contarPlusVigentes().then((v) {
          resultado = v;
          termino = true;
        });
        async.elapse(const Duration(seconds: 11));
        expect(termino, isFalse,
            reason: 'dentro del timeout aún espera');
        async.elapse(const Duration(seconds: 2));
        expect(termino, isTrue,
            reason: 'el timeout resolvió la espera');
        expect(resultado, isNull,
            reason: 'degrada a null: la UI omite el dato');
      });
    });

    // Autoauditoría 1.22 #1 (2026-11-03): la 1C dejó fuera dos
    // LECTURAS del mismo servicio — detalle() e infoPublica()
    // seguían con _rpc sin timeout. La ficha del invitado
    // espera detalle() antes de pintar: con la conexión
    // colgada quedaba en spinner eterno (la misma clase de
    // fallo que el Dashboard) y su catch nunca veía el error
    // RED que dispara el fallback a la caché offline (D5).
    test('detalle() corta por timeout con error RED', () {
      fakeAsync((async) {
        final svc = InvitadosService(
            rpc: (nombre, params) =>
                Completer<dynamic>().future);
        Object? error;
        var termino = false;
        svc.detalle('inv-1').then((_) {
          termino = true;
        }, onError: (Object e) {
          error = e;
          termino = true;
        });
        async.elapse(const Duration(seconds: 11));
        expect(termino, isFalse,
            reason: 'dentro del timeout aún espera');
        async.elapse(const Duration(seconds: 2));
        expect(termino, isTrue,
            reason: 'el timeout resolvió la espera');
        expect(error, isA<InvitadoError>());
        expect((error as InvitadoError).codigo, 'RED',
            reason: 'RED es lo que la ficha usa para caer a '
                'la caché offline');
      });
    });

    test('infoPublica() corta por timeout con error RED', () {
      fakeAsync((async) {
        final svc = InvitadosService(
            rpc: (nombre, params) =>
                Completer<dynamic>().future);
        Object? error;
        var termino = false;
        svc.infoPublica().then((_) {
          termino = true;
        }, onError: (Object e) {
          error = e;
          termino = true;
        });
        async.elapse(const Duration(seconds: 13));
        expect(termino, isTrue,
            reason: 'el timeout resolvió la espera');
        expect(error, isA<InvitadoError>());
        expect((error as InvitadoError).codigo, 'RED');
      });
    });
  });
}

