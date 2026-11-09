/// 1.30 (Oleada 4, §5.3/§5.4): eliminar_suplemento en cascada,
/// lado app. La pieza de servidor (S-130-3: handler en cascada +
/// migración de reservas) vive en la ventana §10; aquí se prueba
/// lo que la app hace: la guarda de ventas, las cuentas de la
/// confirmación, la purga local en la misma transacción y la
/// restauración de espejos si el servidor rechaza la op.
///
/// La sesión de dueño no es fingible en tests (isOwner sale del
/// JWT, como declara suplementos_rediseno_test): el camino
/// ⋮ → _eliminarSuplemento no se monta; se prueban las funciones
/// públicas que ese camino consume (cuentas, texto, guarda) y la
/// composición real en un DialogoApp.confirmar.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tablas = [
  'ops_queue',
  'suplementos',
  'ventas_suplementos',
  'servicio_pomos',
  'servicio_botes',
  'servicio_lotes',
  'servicio_ventas',
  'servicio_salidas',
  'servicio_compras',
  'reservas',
];

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  for (final t in _tablas) {
    await db.delete(t);
  }
  await db.delete('meta', where: "k LIKE 'forzar_redescarga_%'");
}

/// Grafo completo del suplemento 5 (objetivo) + suplemento 9
/// (control intocable). Saldos derivados: pomo 51 = 30 − 2
/// (ventas) − 1 (salidas) = 27; pomo 52 = 10 − 3 = 7; Σ = 34.
Future<void> _sembrarGrafo() async {
  final db = LocalDb.instance;
  await db.upsertMirror('suplementos', 5, {
    'id': 5,
    'nombre': 'Proteína Cascada',
    'precio_oficial': 5000,
    'moneda': 'CUP',
    'stock': 3,
    'activo': 1,
  }, 101);
  await db.upsertMirror('suplementos', 9, {
    'id': 9,
    'nombre': 'Creatina Control',
    'precio_oficial': 3500,
    'moneda': 'CUP',
    'stock': 8,
    'activo': 1,
  }, 102);
  await db.upsertMirror('servicio_pomos', 51, {
    'id': 51,
    'suplemento_id': 5,
    'dosis_asignadas': 30,
    'dosis_repartidas': 0,
    'activo': 1,
    'es_principal': 1,
  }, 103);
  await db.upsertMirror('servicio_pomos', 52, {
    'id': 52,
    'suplemento_id': 5,
    'dosis_asignadas': 10,
    'dosis_repartidas': 0,
    'activo': 1,
    'es_principal': 0,
  }, 104);
  await db.upsertMirror('servicio_pomos', 91, {
    'id': 91,
    'suplemento_id': 9,
    'dosis_asignadas': 7,
    'dosis_repartidas': 0,
    'activo': 1,
    'es_principal': 1,
  }, 105);
  await db.upsertMirror('servicio_botes', 61, {
    'id': 61,
    'suplemento_id': 5,
    'estado': 'abierto',
  }, 106);
  await db.upsertMirror('servicio_botes', 62, {
    'id': 62,
    'suplemento_id': 5,
    'estado': 'cerrado',
  }, 107);
  await db.upsertMirror('servicio_botes', 91, {
    'id': 91,
    'suplemento_id': 9,
    'estado': 'abierto',
  }, 108);
  await db.upsertMirror(
      'servicio_lotes', 71, {'id': 71, 'bote_id': 61}, 109);
  await db.upsertMirror(
      'servicio_lotes', 72, {'id': 72, 'bote_id': 62}, 110);
  await db.upsertMirror(
      'servicio_lotes', 93, {'id': 93, 'bote_id': 91}, 111);
  await db.upsertMirror('servicio_ventas', 81, {
    'id': 81,
    'pomo_id': 51,
    'lote_id': 71,
    'cantidad': 2,
    'precio_unitario': 600,
    'metodo': 'efectivo',
  }, 112);
  await db.upsertMirror('servicio_ventas', 82, {
    'id': 82,
    'pomo_id': 52,
    'lote_id': 72,
    'cantidad': 3,
    'precio_unitario': 600,
    'metodo': 'efectivo',
  }, 113);
  await db.upsertMirror('servicio_ventas', 83, {
    'id': 83,
    'pomo_id': 91,
    'lote_id': 93,
    'cantidad': 1,
    'precio_unitario': 600,
    'metodo': 'efectivo',
  }, 114);
  await db.upsertMirror('servicio_salidas', 85, {
    'id': 85,
    'pomo_id': 51,
    'lote_id': 71,
    'dosis': 1,
  }, 115);
  await db.upsertMirror('servicio_salidas', 86, {
    'id': 86,
    'pomo_id': 91,
    'lote_id': 93,
    'dosis': 2,
  }, 116);
  await db.upsertMirror('servicio_compras', 87, {
    'id': 87,
    'suplemento_id': 5,
    'cantidad_botes': 2,
  }, 117);
  await db.upsertMirror('servicio_compras', 88, {
    'id': 88,
    'suplemento_id': 9,
    'cantidad_botes': 1,
  }, 118);
  // Reservas vivas del 5: se borran con la cascada.
  await db.upsertMirror('reservas', 120, {
    'id': 120,
    'suplemento_id': 5,
    'estado': 'solicitada',
    'cliente_id': 1,
  }, 119);
  await db.upsertMirror('reservas', 121, {
    'id': 121,
    'suplemento_id': 5,
    'estado': 'reservada',
    'cliente_id': 2,
  }, 120);
  // Las históricas: SIETE rechazadas (el patrón real de
  // producción: 7 rechazadas en 6 suplementos, las que hoy
  // rebotan el borrado por FK) + pagada + expirada. Ninguna se
  // borra: se desvinculan y sobreviven.
  for (var i = 0; i < 7; i++) {
    await db.upsertMirror('reservas', 101 + i, {
      'id': 101 + i,
      'suplemento_id': 5,
      'estado': 'rechazada',
      'cliente_id': 10 + i,
    }, 121 + i);
  }
  await db.upsertMirror('reservas', 108, {
    'id': 108,
    'suplemento_id': 5,
    'estado': 'pagada',
    'cliente_id': 20,
  }, 128);
  await db.upsertMirror('reservas', 109, {
    'id': 109,
    'suplemento_id': 5,
    'estado': 'expirada',
    'cliente_id': 21,
  }, 129);
  // Control: histórica de otro suplemento, intocable.
  await db.upsertMirror('reservas', 130, {
    'id': 130,
    'suplemento_id': 9,
    'estado': 'rechazada',
    'cliente_id': 30,
  }, 130);
}

Map<String, dynamic>? _porId(List<Map<String, dynamic>> filas, int id) {
  for (final f in filas) {
    if ((f['id'] as num?)?.toInt() == id) return f;
  }
  return null;
}

Future<String?> _estadoOpUnica() async {
  final db = await LocalDb.instance.db;
  final ops = await db.query('ops_queue',
      where: 'tipo = ?', whereArgs: ['eliminar_suplemento']);
  if (ops.length != 1) return null;
  return ops.first['estado'] as String?;
}

Future<Map<String, ResultadoOpServidor>> Function(List<String>)
    _fetcher(String estado, {Map<String, dynamic>? resultado}) {
  return (uuids) async => {
        for (final u in uuids)
          u: (
            estado: estado,
            resultado: resultado,
            error: estado == 'rechazada'
                ? 'FOREIGN KEY constraint failed'
                : null,
          ),
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // app_links (deep links de Supabase Auth): sin mock, la
    // activación de su canal lanza MissingPluginException de
    // forma intermitente (patrón de suplementos_rediseno_test).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('cuentas de la confirmación (§5.3 punto 2)', () {
    test('cuenta pomos con Σ de saldos derivados, botes y vivas',
        () async {
      await _limpiar();
      await _sembrarGrafo();
      final c = await cuentasCascadaSuplemento(5);
      expect(c.pomos, 2);
      expect(c.dosis, 34, reason: '27 del pomo 51 + 7 del pomo 52');
      expect(c.botes, 2);
      expect(c.botesAbiertos, 1);
      expect(c.reservasVivas, 2,
          reason: 'las 9 no vivas no cuentan como pérdida');
      final control = await cuentasCascadaSuplemento(9);
      expect(control.pomos, 1);
      expect(control.dosis, 4, reason: '7 − 1 venta − 2 salidas');
      expect(control.reservasVivas, 0);
    });

    test('texto y mensaje: la frase del plan, o vacía sin cuentas',
        () {
      const c = (
        pomos: 2,
        dosis: 34,
        botes: 2,
        botesAbiertos: 1,
        reservasVivas: 2,
      );
      expect(
          textoCuentasCascada(c),
          'Se eliminan 2 pomo(s) con 34 dosis en total, 2 bote(s) y '
          '2 reserva(s) pendiente(s). '
          'El historial de dosis vendidas se conserva.');
      const cero = (
        pomos: 0,
        dosis: 0,
        botes: 0,
        botesAbiertos: 0,
        reservasVivas: 0,
      );
      expect(textoCuentasCascada(cero), '');
      final m = mensajeConfirmacionCascada('Proteína Cascada', c);
      expect(m, contains('¿Eliminar "Proteína Cascada" del catálogo?'));
      expect(m, contains('Se eliminan 2 pomo(s)'));
      expect(mensajeConfirmacionCascada('X', cero),
          isNot(contains('Se eliminan')));
    });

    testWidgets('widget: el diálogo enseña las cuentas del espejo',
        (tester) async {
      late CuentasCascada cuentas;
      await tester.runAsync(() async {
        await _limpiar();
        await _sembrarGrafo();
        cuentas = await cuentasCascadaSuplemento(5);
      });
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => DialogoApp.confirmar(
                  ctx,
                  titulo: 'Eliminar suplemento',
                  mensaje: mensajeConfirmacionCascada(
                      'Proteína Cascada', cuentas),
                  aceptar: 'Eliminar',
                ),
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining(
              'Se eliminan 2 pomo(s) con 34 dosis en total'),
          findsOneWidget);
      expect(
          find.textContaining(
              'El historial de dosis vendidas se conserva.'),
          findsOneWidget);
    });
  });

  group('guarda de ventas (§5.3 punto 1)', () {
    test('sin ventas en el espejo, 0; con venta del 5, 1; del 9, 0',
        () async {
      await _limpiar();
      await _sembrarGrafo();
      expect(await ventasEspejoDeSuplemento(5), 0);
      await LocalDb.instance.upsertMirror('ventas_suplementos', 201, {
        'id': 201,
        'suplemento_id': 5,
        'cantidad': 1,
      }, 201);
      expect(await ventasEspejoDeSuplemento(5), 1);
      expect(await ventasEspejoDeSuplemento(9), 0);
    });
  });

  group('purga local en cascada (§5.3 punto 3)', () {
    test(
        'borra lo vivo, desvincula la historia, encola una sola op '
        'y no toca el control', () async {
      await _limpiar();
      await _sembrarGrafo();
      await LocalDb.instance.eliminarSuplementoLocal(5);
      final db = LocalDb.instance;

      expect(_porId(await db.allMirror('suplementos'), 5), isNull);
      expect(_porId(await db.allMirror('suplementos'), 9), isNotNull);
      expect(_porId(await db.allMirror('servicio_pomos'), 51), isNull);
      expect(_porId(await db.allMirror('servicio_pomos'), 52), isNull);
      expect(
          _porId(await db.allMirror('servicio_pomos'), 91), isNotNull);
      expect(_porId(await db.allMirror('servicio_botes'), 61), isNull);
      expect(_porId(await db.allMirror('servicio_botes'), 62), isNull);
      expect(
          _porId(await db.allMirror('servicio_botes'), 91), isNotNull);
      expect(_porId(await db.allMirror('servicio_lotes'), 71), isNull);
      expect(_porId(await db.allMirror('servicio_lotes'), 72), isNull);
      expect(
          _porId(await db.allMirror('servicio_lotes'), 93), isNotNull);

      // Historia de dosis: sobrevive desvinculada, montos intactos.
      final ventas = await db.allMirror('servicio_ventas');
      final v81 = _porId(ventas, 81)!;
      expect(v81['lote_id'], isNull);
      expect(v81['pomo_id'], isNull);
      expect(v81['cantidad'], 2);
      final v82 = _porId(ventas, 82)!;
      expect(v82['lote_id'], isNull);
      expect(v82['pomo_id'], isNull);
      expect(v82['cantidad'], 3);
      final v83 = _porId(ventas, 83)!;
      expect(v83['pomo_id'], 91);
      expect(v83['lote_id'], 93);
      final salidas = await db.allMirror('servicio_salidas');
      final s85 = _porId(salidas, 85)!;
      expect(s85['lote_id'], isNull);
      expect(s85['pomo_id'], isNull);
      expect(s85['dosis'], 1);
      expect(_porId(salidas, 86)!['pomo_id'], 91);

      // Compras: historia de gasto desvinculada.
      final compras = await db.allMirror('servicio_compras');
      expect(_porId(compras, 87)!['suplemento_id'], isNull);
      expect(_porId(compras, 88)!['suplemento_id'], 9);

      // Reservas: vivas fuera; históricas JAMÁS borradas.
      final reservas = await db.allMirror('reservas');
      expect(_porId(reservas, 120), isNull, reason: 'viva solicitada');
      expect(_porId(reservas, 121), isNull, reason: 'viva reservada');
      for (var i = 0; i < 7; i++) {
        final r = _porId(reservas, 101 + i);
        expect(r, isNotNull,
            reason: 'la histórica rechazada ${101 + i} no se borra');
        expect(r!['suplemento_id'], isNull);
        expect(r['estado'], 'rechazada');
      }
      expect(_porId(reservas, 108)!['suplemento_id'], isNull);
      expect(_porId(reservas, 109)!['suplemento_id'], isNull);
      expect(_porId(reservas, 130)!['suplemento_id'], 9,
          reason: 'la histórica del control queda intacta');

      // Una sola op, con el payload de siempre.
      final raw = await LocalDb.instance.db;
      final ops = await raw.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['eliminar_suplemento']);
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.first['payload'] as String) as Map<String, dynamic>;
      expect(payload['suplemento_id'], 5);
    });

    test(
        '1.31 (Yunque A): el blob desvinculado no lleva la llave '
        '`id` dentro del JSON', () async {
      await _limpiar();
      await _sembrarGrafo();
      await LocalDb.instance.eliminarSuplementoLocal(5);
      final raw = await LocalDb.instance.db;
      // La reserva histórica 108 se desvincula (suplemento_id a
      // NULL reescribiendo solo `data`): el blob resultante no
      // puede arrastrar `id` — es la columna, no un campo.
      final filas = await raw.query('reservas',
          columns: ['data'], where: 'id = ?', whereArgs: [108]);
      expect(filas.length, 1);
      final blob = jsonDecode(filas.first['data'] as String)
          as Map<String, dynamic>;
      expect(blob.containsKey('id'), isFalse);
      expect(blob['suplemento_id'], isNull);
    });
  });

  group('restauración si el servidor no aplica (§5.3 punto 4)', () {
    Future<void> purgarYBarrer(
        String estado, Map<String, dynamic>? resultado) async {
      await _limpiar();
      await _sembrarGrafo();
      await LocalDb.instance.eliminarSuplementoLocal(5);
      await SyncEngine.instance
          .barridoConfirmacion(verificar: _fetcher(estado, resultado: resultado));
    }

    Future<void> esperarBanderas(String? valor) async {
      for (final t in const [
        'suplementos',
        'servicio_pomos',
        'servicio_botes',
        'servicio_lotes',
        'reservas',
      ]) {
        expect(await LocalDb.instance.getMeta('forzar_redescarga_$t'),
            valor,
            reason: 'bandera de $t');
      }
    }

    test('rechazo (el rebote FK de hoy) → las 5 banderas', () async {
      await purgarYBarrer('rechazada',
          {'ok': false, 'error': 'FOREIGN KEY constraint failed'});
      expect(await _estadoOpUnica(), 'rechazada');
      await esperarBanderas('1');
    });

    test('necesita_revision → las 5 banderas también', () async {
      await purgarYBarrer('necesita_revision', null);
      expect(await _estadoOpUnica(), 'necesita_revision');
      await esperarBanderas('1');
    });

    test('aplicada → ninguna bandera (la purga era la verdad)',
        () async {
      await purgarYBarrer('aplicada', {'ok': true});
      expect(await _estadoOpUnica(), 'aplicada');
      await esperarBanderas(null);
    });
  });
}
