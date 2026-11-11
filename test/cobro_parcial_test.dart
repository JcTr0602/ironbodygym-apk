/// 1.26.1 — Cobrar Parcial (veredicto de Argón con
/// restricciones de aritmética). Tres capas:
///
/// 1. El compositor puro (lib/cobro_parcial.dart): los
///    escenarios exactos del veredicto — el arrastre va
///    en la cabeza de la cola FIFO; si el monto no lo
///    supera, op_ids va vacío; si lo supera, el prefijo
///    mínimo de pagos lo cubre; ningún pago se parte.
/// 2. La foto (negocio.dart): filas FIFO desde los
///    espejos + arrastre vivo, y el cruce dueño/arqueo
///    (Punto C): foto.total == pendienteArqueo().cup en
///    el mundo limpio de las guardas.
/// 3. La hoja (widget): teclear valida contra el total,
///    los atajos fijan el monto y «Quedan pendientes»
///    cuadra en vivo; confirmar devuelve el monto.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cobro_parcial.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/hoja_cobrar_parcial.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

FilaCobro _f(String tabla, int id, double monto, int dia) =>
    FilaCobro(
        tabla: tabla,
        id: id,
        monto: monto,
        fecha: DateTime(2026, 11, dia));

void main() {
  group('compositor puro (aritmética de Argón)', () {
    final filas = [
      _f('pagos', 1, 2000, 4),
      _f('pagos', 2, 2000, 5),
      _f('pagos_diarios', 3, 200, 5),
    ];

    test('parcial #1: X=3000 sobre 4800 cubre el prefijo '
        '2000+2000 y deja 1000 de arrastre', () {
      final c = componerCobroParcial(
          filasFifo: filas, arrastre: 0, monto: 3000)!;
      expect(c.opIds['pagos'], [1, 2]);
      expect(c.opIds['pagos_diarios'], isEmpty);
      expect(c.montoEsperado, 4000);
      expect(c.montoEntregado, 3000);
      expect(c.nuevoArrastre, 1000);
      expect(c.cubiertas.map((f) => f.id), [1, 2]);
    });

    test('parcial #2 con X <= arrastre: op_ids vacío, '
        'no se toca ningún pago', () {
      final c = componerCobroParcial(
          filasFifo: [_f('pagos_diarios', 3, 200, 5)],
          arrastre: 1000,
          monto: 500)!;
      expect(c.cubiertas, isEmpty);
      expect(c.opIds.values.every((l) => l.isEmpty), isTrue);
      expect(c.montoEsperado, 1000);
      expect(c.nuevoArrastre, 500);
    });

    test('parcial #2 con X > arrastre: el arrastre va '
        'primero y el prefijo completa', () {
      final c = componerCobroParcial(
          filasFifo: [_f('pagos_diarios', 3, 200, 5)],
          arrastre: 1000,
          monto: 1100)!;
      expect(c.cubiertas.map((f) => f.id), [3]);
      expect(c.montoEsperado, 1200);
      expect(c.nuevoArrastre, 100);
    });

    test('X = total exacto: cubre todo, arrastre 0', () {
      final c = componerCobroParcial(
          filasFifo: filas, arrastre: 0, monto: 4200)!;
      expect(c.cubiertas.length, 3);
      expect(c.montoEsperado, 4200);
      expect(c.nuevoArrastre, 0);
    });

    test('X en el borde del arrastre: no consume filas',
        () {
      final c = componerCobroParcial(
          filasFifo: filas, arrastre: 1000, monto: 1000)!;
      expect(c.cubiertas, isEmpty);
      expect(c.nuevoArrastre, 0);
    });

    test('montos inválidos: cero, negativo, NaN y '
        'mayor que el total devuelven null', () {
      expect(
          componerCobroParcial(
              filasFifo: filas, arrastre: 0, monto: 0),
          isNull);
      expect(
          componerCobroParcial(
              filasFifo: filas, arrastre: 0, monto: -5),
          isNull);
      expect(
          componerCobroParcial(
              filasFifo: filas, arrastre: 0, monto: double.nan),
          isNull);
      expect(
          componerCobroParcial(
              filasFifo: filas, arrastre: 0, monto: 4201),
          isNull);
    });

    test('un reverso de servicio negativo netea dentro '
        'del prefijo', () {
      final conReverso = [
        _f('pagos', 1, 2000, 4),
        _f('servicio_ventas', 9, -300, 5),
        _f('pagos', 2, 500, 5),
      ];
      final c = componerCobroParcial(
          filasFifo: conReverso, arrastre: 0, monto: 2100)!;
      expect(c.cubiertas.map((f) => f.id), [1, 9, 2]);
      expect(c.montoEsperado, 2200);
      expect(c.nuevoArrastre, 100);
      expect(c.opIds['servicio_ventas'], [9]);
    });

    test('atajos: redondos, mitad y todo, sin duplicar',
        () {
      final a4800 = atajosCobroParcial(4800);
      expect(a4800.map((a) => a.valor), [1000, 2000, 2400, 4800]);
      expect(a4800.map((a) => a.etiqueta),
          ['1000', '2000', 'Mitad', 'Todo']);
      expect(atajosCobroParcial(2000).map((a) => a.valor),
          [1000, 2000]);
      expect(atajosCobroParcial(800).map((a) => a.valor),
          [400, 800]);
      expect(atajosCobroParcial(300).map((a) => a.etiqueta),
          ['Mitad', 'Todo']);
    });
  });

  group('foto desde espejos (negocio)', () {
    Future<Database> abrirDbVacia() async {
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

    var seq = 9700;
    Future<void> espejo(
        Database db, String tabla, int id, Map<String, dynamic> data,
        {Map<String, Object?>? cols}) async {
      await db.insert(tabla, {
        'id': id,
        'data': jsonEncode(data),
        'sync_seq': seq++,
        if (cols != null) ...cols,
      });
    }

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    test('filas FIFO por fecha + arrastre vivo, y la '
        'foto cuadra con pendienteArqueo (Punto C)',
        () async {
      final db = await abrirDbVacia();
      const tid = 777;
      // Sembrados desordenados a propósito: el FIFO
      // ordena por fecha (y luego id), no por inserción.
      await espejo(db, 'pagos', 12, {
        'id': 12,
        'fecha': '2026-11-05',
        'monto': 2000,
        'metodo': 'efectivo',
        'telegram_user_id': tid,
        'entregado': 0,
      }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
      await espejo(db, 'pagos', 11, {
        'id': 11,
        'fecha': '2026-11-04',
        'monto': 2000,
        'metodo': 'efectivo',
        'telegram_user_id': tid,
        'entregado': 0,
      }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
      await espejo(db, 'pagos_diarios', 21, {
        'id': 21,
        'registrado_por': tid,
        'total': 200,
        'fecha': '2026-11-05',
        'entregado': 0,
      });
      // Una liquidación parcial previa: arrastre 1000.
      await espejo(db, 'liquidaciones_caja', 40, {
        'id': 40,
        'entrenador_telegram_id': tid,
        'estado': 'parcial',
        'saldo_arrastre': 1000,
        'moneda': 'CUP',
        'op_ids': <String, dynamic>{},
      });
      // Ruido que NO debe entrar: otro entrenador y un
      // pago por transferencia.
      await espejo(db, 'pagos', 13, {
        'id': 13,
        'fecha': '2026-11-03',
        'monto': 9999,
        'metodo': 'efectivo',
        'telegram_user_id': 888,
        'entregado': 0,
      }, cols: {'metodo': 'efectivo', 'telegram_user_id': 888});
      await espejo(db, 'pagos', 14, {
        'id': 14,
        'fecha': '2026-11-03',
        'monto': 8888,
        'metodo': 'transferencia',
        'telegram_user_id': tid,
        'entregado': 0,
      }, cols: {'metodo': 'transferencia', 'telegram_user_id': tid});

      expect(await arrastreVivoCup(tid), 1000);
      final foto = await fotoCobroParcial(tid);
      expect(foto.filas.map((f) => f.id), [11, 12, 21]);
      expect(foto.filas.map((f) => f.tabla),
          ['pagos', 'pagos', 'pagos_diarios']);
      expect(foto.total, 5200);
      // Punto C de Argón: la foto del compositor y la
      // cifra de la liquidación (arqueo) coinciden.
      expect((await pendienteArqueo(tid)).cup, foto.total);
      await db.close();
    });

    test('arrastresVivosCup: suma parciales CUP por '
        'entrenador e ignora USD y liquidadas', () async {
      final db = await abrirDbVacia();
      await espejo(db, 'liquidaciones_caja', 50, {
        'id': 50,
        'entrenador_telegram_id': 555,
        'entrenador_nombre': 'Solo Arrastre',
        'estado': 'parcial',
        'saldo_arrastre': 1500,
        'moneda': 'CUP',
        'op_ids': <String, dynamic>{},
      });
      await espejo(db, 'liquidaciones_caja', 51, {
        'id': 51,
        'entrenador_telegram_id': 555,
        'entrenador_nombre': 'Solo Arrastre',
        'estado': 'parcial',
        'saldo_arrastre': 500,
        'moneda': 'CUP',
        'op_ids': <String, dynamic>{},
      });
      await espejo(db, 'liquidaciones_caja', 52, {
        'id': 52,
        'entrenador_telegram_id': 555,
        'estado': 'parcial',
        'saldo_arrastre': 50,
        'moneda': 'USD',
        'op_ids': <String, dynamic>{},
      });
      await espejo(db, 'liquidaciones_caja', 53, {
        'id': 53,
        'entrenador_telegram_id': 555,
        'estado': 'liquidado',
        'saldo_arrastre': 999,
        'moneda': 'CUP',
        'op_ids': <String, dynamic>{},
      });
      final todos = await arrastresVivosCup();
      expect(todos.keys, [555]);
      expect(todos[555]!.total, 2000);
      expect(todos[555]!.nombre, 'Solo Arrastre');
      expect(await arrastreVivoCup(555), 2000);
      await db.close();
    });
  });

  group('hoja de cobro parcial (widget)', () {
    testWidgets('el pad empotrado valida y «quedan pendientes» '
        'cuadra; el atajo Todo confirma el total',
        (tester) async {
      double? resultado;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  resultado = await showModalBottomSheet<double>(
                    context: ctx,
                    isScrollControlled: true,
                    builder: (_) => const HojaCobrarParcial(
                        nombre: 'Duany', total: 4800, arrastre: 0),
                  );
                },
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Cobrar parcial — Duany'), findsOneWidget);
      expect(find.text('Pendiente total: 4800 CUP'),
          findsOneWidget);
      // 1.32 (O2F2): la hoja compone con el PAD empotrado;
      // teclear = tocar las teclas del pad.
      Future<void> tecla(String t) async {
        await tester.tap(find.byKey(ValueKey('pad-$t')));
        await tester.pump();
      }

      await tecla('3');
      await tecla('0');
      await tecla('0');
      await tecla('0');
      expect(find.textContaining('Quedan pendientes 1800 CUP'),
          findsOneWidget);
      // Por encima del total: inválido y no confirma
      // (el botón está deshabilitado: la hoja sigue).
      await tecla('C');
      await tecla('9');
      await tecla('9');
      await tecla('9');
      await tecla('9');
      expect(find.text('Supera el pendiente total.'),
          findsOneWidget);
      await tester.tap(find.text('Confirmar cobro'));
      await tester.pumpAndSettle();
      expect(resultado, isNull);
      expect(find.text('Cobrar parcial — Duany'), findsOneWidget);
      // Atajo Todo: fija el total y confirmar lo devuelve.
      await tester.tap(find.text('Todo'));
      await tester.pump();
      await tester.tap(find.text('Confirmar cobro'));
      await tester.pumpAndSettle();
      expect(resultado, 4800);
    });
  });
}
