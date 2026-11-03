/// 1.23 — Correcciones de la auditoría total de Argón
/// (AT-01..AT-15; RESUMEN_VERIFICADO §11). Este archivo fija:
///
/// - AT-03: medicionesClienteLocal emite `creado_en` real en
///   AMBAS ramas (espejo con created_at y op pendiente con
///   creada_ts): la ventana de edición de 24 h ya no se
///   reconstruye desde la fecha plana.
/// - AT-06 (verificado NO vivo, fijado por comportamiento):
///   los dos caminos de escritura del espejo suplementos
///   preservan la columna ultimo_precio (UPSERT que no la
///   toca); el del batch del pull ejecuta en el test la
///   sentencia real de producción (constante compartida).
/// - AT-07: fechaNegocioHabana convierte los timestamps CON
///   zona a la fecha de La Habana; columnasPagos la usa para
///   la columna indexada (un pago de madrugada UTC cae en el
///   día/mes habanero, no en el UTC).
/// - AT-10: bumpOp borra el resultado_servidor viejo al
///   fallar un intento: una op que falló de verdad ya no
///   despierta como «pausada» al caer el candado.
/// - AT-11 (pin de fuente delimitado al callback): los
///   bloques de onUpgrade corren en orden ascendente estricto.
/// - AT-12: resumenIngresosDia no cuenta cortesía ni promo
///   como movimientos del día.
/// - AT-13 (panel): la promoción tardía de un turno exige la
///   evidencia de SU op concreta en 'aplicada': la carrera
///   preparar→confirmar (op encolada tras la selección del
///   run en segundo plano) no promueve el turno.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/turno_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _limpiarDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  for (final t in [
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
    'ops_queue',
    'cliente_mediciones',
    'suplementos',
    'turnos',
  ]) {
    await db.delete(t);
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('AT-07 fechaNegocioHabana', () {
    test('fecha plana se respeta tal cual', () {
      expect(fechaNegocioHabana('2026-10-31'), '2026-10-31');
    });

    test('timestamp sin zona manda su fecha escrita', () {
      expect(fechaNegocioHabana('2026-10-16T14:20:00'), '2026-10-16');
    });

    test('timestamp UTC de madrugada cae en el día habanero', () {
      // 02:30 UTC del 1-nov = 22:30 del 31-oct en La Habana.
      expect(fechaNegocioHabana('2026-11-01T02:30:00Z'), '2026-10-31');
      // 04:30 UTC del 1-nov = 00:30 del 1-nov en La Habana.
      expect(fechaNegocioHabana('2026-11-01T04:30:00Z'), '2026-11-01');
    });

    test('timestamp con offset se convierte por el instante', () {
      expect(fechaNegocioHabana('2026-10-31T23:30:00-04:00'),
          '2026-10-31');
      // 23:30 -05:00 = 04:30 UTC del día siguiente = 00:30 habanero.
      expect(fechaNegocioHabana('2026-10-31T23:30:00-05:00'),
          '2026-11-01');
    });

    test('valores sin fecha válida devuelven vacío', () {
      expect(fechaNegocioHabana(null), '');
      expect(fechaNegocioHabana(''), '');
      expect(fechaNegocioHabana('ayer'), '');
      expect(fechaNegocioHabana('31/10/2026'), '');
    });

    test('columnasPagos indexa la fecha habanera (AT-07)', () {
      final cols = LocalDb.columnasPagos(
          {'fecha': '2026-11-01T02:30:00Z', 'metodo': 'efectivo'});
      expect(cols['fecha'], '2026-10-31');
      final plana = LocalDb.columnasPagos({'fecha': '2026-11-01'});
      expect(plana['fecha'], '2026-11-01');
      final mala = LocalDb.columnasPagos({'fecha': 'sin-fecha'});
      expect(mala['fecha'], isNull);
    });
  });

  group('AT-03 creado_en de mediciones', () {
    setUp(_limpiarDb);

    test('espejo emite created_at y la op pendiente su creada_ts',
        () async {
      await LocalDb.instance.upsertMirror('cliente_mediciones', 77, {
        'cliente_id': 5,
        'fecha_medicion': '2026-11-02',
        'peso_kg': 90.5,
        'created_at': '2026-11-03T01:15:00Z',
      }, 1);
      await LocalDb.instance.queueOp(
        opUuid: 'op-med-at03',
        tipo: 'registrar_medicion_cliente',
        payload: {
          'medicion_id': 'med-pendiente-1',
          'cliente_id': 5,
          'fecha_medicion': '2026-11-03',
          'medidas': {'peso_kg': 91.0},
        },
      );
      // creada_ts la fija queueOp con el instante de encolado:
      // la fila debe traer creado_en NO vacío en la rama de op.
      final lista = await medicionesClienteLocal(5);
      expect(lista, hasLength(2));
      final espejo =
          lista.firstWhere((m) => m['espejado'] == true);
      expect(espejo['creado_en'], '2026-11-03T01:15:00Z');
      final pendiente =
          lista.firstWhere((m) => m['espejado'] == false);
      expect(pendiente['creado_en'], isNotEmpty);
      expect(pendiente['creado_en'], isNot('2026-11-03'));
    });
  });

  group('AT-06 ultimo_precio sobrevive al espejo (pin)', () {
    setUp(_limpiarDb);

    test('upsertMirror no pisa la columna ultimo_precio', () async {
      final db = await LocalDb.instance.db;
      await LocalDb.instance.upsertMirror('suplementos', 3, {
        'nombre': 'Proteína',
        'precio_oficial': 5000,
        'moneda': 'CUP',
      }, 1);
      await db.rawUpdate(
          'UPDATE suplementos SET ultimo_precio = 4500 WHERE id = 3');
      // Segundo pull con datos nuevos: la columna se conserva.
      await LocalDb.instance.upsertMirror('suplementos', 3, {
        'nombre': 'Proteína',
        'precio_oficial': 5200,
        'moneda': 'CUP',
      }, 2);
      final filas = await db
          .rawQuery('SELECT ultimo_precio FROM suplementos WHERE id = 3');
      expect(filas.single['ultimo_precio'], 4500);
    });

    test('el batch del pull preserva ultimo_precio (comportamiento)',
        () async {
      final db = await LocalDb.instance.db;
      await LocalDb.instance.upsertMirror('suplementos', 3, {
        'nombre': 'Proteína',
        'precio_oficial': 5000,
        'moneda': 'CUP',
      }, 1);
      await db.rawUpdate(
          'UPDATE suplementos SET ultimo_precio = 4500 WHERE id = 3');
      // La MISMA sentencia que ejecuta el commit por página del
      // pull (constante de producción), con datos remotos nuevos.
      final batch = db.batch();
      batch.rawInsert(LocalDb.sqlUpsertSuplementoPull, [
        3,
        jsonEncode({
          'nombre': 'Proteína',
          'precio_oficial': 5200,
          'moneda': 'USD',
        }),
        2,
        'USD',
      ]);
      await batch.commit(noResult: true);
      final filas = await db.rawQuery(
          'SELECT data, moneda, ultimo_precio FROM suplementos '
          'WHERE id = 3');
      // La fila remota se actualizó…
      expect(filas.single['moneda'], 'USD');
      expect(
          jsonDecode(filas.single['data'] as String)['precio_oficial'],
          5200);
      // …y la columna local sobrevivió.
      expect(filas.single['ultimo_precio'], 4500);
    });

    test('sync.dart usa la constante ejercida (no una copia)', () {
      final src = File('lib/sync.dart').readAsStringSync();
      expect(src, contains('LocalDb.sqlUpsertSuplementoPull'));
      expect(src,
          isNot(contains('ON CONFLICT(id) DO UPDATE SET data=excluded')));
    });
  });

  group('AT-10 bumpOp limpia el resultado viejo', () {
    setUp(_limpiarDb);

    test('una op que falla de verdad ya no despierta como pausada',
        () async {
      final db = await LocalDb.instance.db;
      await LocalDb.instance.queueOp(
        opUuid: 'op-at10',
        tipo: 'pago_mensual',
        payload: {'cliente_id': 1, 'monto': 2000},
      );
      // Estado heredado de la pausa: resultado con el código.
      await db.rawUpdate(
          'UPDATE ops_queue SET resultado_servidor = ? '
          'WHERE op_uuid = ?',
          [
            jsonEncode({'estado': 'rechazada', 'codigo': 'ACCESO_PAUSADO'}),
            'op-at10',
          ]);
      await LocalDb.instance
          .bumpOp('op-at10', Exception('timeout de red'));
      final filas = await db.rawQuery(
          'SELECT estado, resultado_servidor FROM ops_queue '
          'WHERE op_uuid = ?',
          ['op-at10']);
      expect(filas.single['resultado_servidor'], isNull);
      expect(filas.single['estado'], isNot('pendiente'));
      // Y despertarOpsPausadas ya no la toca.
      expect(
          await LocalDb.instance.despertarOpsPausadas(), 0);
    });

    test('una op pausada intacta SÍ despierta (control)', () async {
      final db = await LocalDb.instance.db;
      await LocalDb.instance.queueOp(
        opUuid: 'op-at10-b',
        tipo: 'pago_mensual',
        payload: {'cliente_id': 1, 'monto': 2000},
      );
      await db.rawUpdate(
          'UPDATE ops_queue SET estado = ?, proximo_reintento = ?, '
          'resultado_servidor = ? WHERE op_uuid = ?',
          [
            'pendiente',
            '2027-01-01T00:00:00-05:00',
            jsonEncode({'estado': 'rechazada', 'codigo': 'ACCESO_PAUSADO'}),
            'op-at10-b',
          ]);
      expect(await LocalDb.instance.despertarOpsPausadas(), 1);
    });
  });

  group('AT-12 movimientos del día sin cortesía ni promo', () {
    setUp(_limpiarDb);

    test('resumenIngresosDia excluye cortesia/promo del conteo',
        () async {
      Future<void> pago(int id, String metodo, double monto) =>
          LocalDb.instance.upsertMirror('pagos', id, {
            'fecha': '2026-11-02',
            'metodo': metodo,
            'monto': monto,
            'cliente_id': 9,
          }, 1);
      await pago(1, 'efectivo', 2000);
      await pago(2, 'transferencia', 2500);
      await pago(3, 'cortesia', 0);
      await pago(4, 'promo', 0);
      final r = await resumenIngresosDia('2026-11-02');
      expect(r.movimientos, 2);
      expect(r.efectivo, 2000);
      expect(r.transferencia, 2500);
      expect(r.total, 4500);
    });
  });

  group('AT-11 orden de onUpgrade (pin de fuente)', () {
    test('los bloques if (oldV < N) corren en orden ascendente', () {
      final src = File('lib/localdb.dart').readAsStringSync();
      final desde = src.indexOf('onUpgrade: (db, oldV');
      expect(desde, greaterThan(0));
      // Delimitado al callback (panel AT-11): lo primero que
      // corre tras cerrar el openDatabase es la reparación del
      // FTS; nada posterior al callback entra en el pin.
      final hasta = src.indexOf('await _repararFtsSiHaceFalta', desde);
      expect(hasta, greaterThan(desde));
      final cuerpo = src.substring(desde, hasta);
      final versiones = RegExp(r'if \(oldV < (\d+)\)')
          .allMatches(cuerpo)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(versiones.length, greaterThan(40));
      for (var i = 1; i < versiones.length; i++) {
        expect(versiones[i], greaterThanOrEqualTo(versiones[i - 1]),
            reason: 'bloque v${versiones[i]} tras v${versiones[i - 1]}');
      }
    });
  });

  group('AT-13 promoción de turnos ligada a la op concreta', () {
    setUp(_limpiarDb);
    const tid = 4242;

    Future<void> sembrarTurno(
        String id, String fecha, String estado,
        {String franja = 'tarde'}) async {
      final db = await LocalDb.instance.db;
      await db.insert('turnos', {
        'turno_id': id,
        'fecha_turno': fecha,
        'turno': franja,
        'hora_apertura': '2026-11-03T14:00:00-05:00',
        'telegram_id': tid,
        'estado': estado,
      });
    }

    Future<String?> estadoTurno(String id) async {
      final db = await LocalDb.instance.db;
      final r = await db.query('turnos',
          columns: ['estado'], where: 'turno_id=?', whereArgs: [id]);
      return r.isEmpty ? null : '${r.first['estado']}';
    }

    test('cierre: sin op o con op pendiente NO promueve; aplicada SÍ',
        () async {
      await sembrarTurno('t-cierre-at13', '2026-11-03', 'cerrado_local');
      final svc = TurnoService.instance;
      // Sin op de cierre registrada: la ausencia no confirma.
      await svc.promoverTurnosConEvidencia(tid);
      expect(await estadoTurno('t-cierre-at13'), 'cerrado_local');
      // La carrera del panel: la op se encoló DESPUÉS de que el
      // run en segundo plano de prepararCierre seleccionó su
      // lote. Cuando ese run termina y promueve, la op sigue
      // 'pendiente': el turno NO se mueve.
      await LocalDb.instance.queueOp(
        opUuid: 'op-cierre-at13',
        tipo: 'cierre_turno',
        payload: {'turno_id': 't-cierre-at13'},
      );
      await svc.promoverTurnosConEvidencia(tid);
      expect(await estadoTurno('t-cierre-at13'), 'cerrado_local');
      // Con la op aplicada de verdad, la promoción procede.
      final db = await LocalDb.instance.db;
      await db.rawUpdate(
          "UPDATE ops_queue SET estado = 'aplicada' "
          'WHERE op_uuid = ?',
          ['op-cierre-at13']);
      await svc.promoverTurnosConEvidencia(tid);
      expect(await estadoTurno('t-cierre-at13'), 'cerrado_sincronizado');
    });

    test('la evidencia aplicada de OTRO turno no promueve (delta)',
        () async {
      // Control negativo pedido por el panel del delta: la
      // evidencia debe ser de la op concreta de ESTE turno.
      await sembrarTurno('t-a-at13', '2026-11-03', 'cerrado_local');
      await sembrarTurno('t-b-at13', '2026-11-03', 'cerrado_local',
          franja: 'manana');
      await LocalDb.instance.queueOp(
        opUuid: 'op-cierre-a-at13',
        tipo: 'cierre_turno',
        payload: {'turno_id': 't-a-at13'},
      );
      await LocalDb.instance.queueOp(
        opUuid: 'op-cierre-b-at13',
        tipo: 'cierre_turno',
        payload: {'turno_id': 't-b-at13'},
      );
      final db = await LocalDb.instance.db;
      await db.rawUpdate(
          "UPDATE ops_queue SET estado = 'aplicada' "
          'WHERE op_uuid = ?',
          ['op-cierre-b-at13']);
      await TurnoService.instance.promoverTurnosConEvidencia(tid);
      // Solo B promueve; A sigue esperando SU evidencia.
      expect(await estadoTurno('t-a-at13'), 'cerrado_local');
      expect(await estadoTurno('t-b-at13'), 'cerrado_sincronizado');
    });

    test('una apertura aplicada no promueve un cierre (delta)',
        () async {
      // Control cruzado de tipo: el turno está cerrado_local y
      // su cierre sigue pendiente; una apertura_turno aplicada
      // con el MISMO turno_id no es evidencia del cierre.
      await sembrarTurno('t-cruz-at13', '2026-11-01', 'cerrado_local');
      await LocalDb.instance.queueOp(
        opUuid: 'op-cierre-cruz-at13',
        tipo: 'cierre_turno',
        payload: {'turno_id': 't-cruz-at13'},
      );
      await LocalDb.instance.queueOp(
        opUuid: 'op-apertura-cruz-at13',
        tipo: 'apertura_turno',
        payload: {'turno_id': 't-cruz-at13'},
      );
      final db = await LocalDb.instance.db;
      await db.rawUpdate(
          "UPDATE ops_queue SET estado = 'aplicada' "
          'WHERE op_uuid = ?',
          ['op-apertura-cruz-at13']);
      await TurnoService.instance.promoverTurnosConEvidencia(tid);
      expect(await estadoTurno('t-cruz-at13'), 'cerrado_local');
    });

    test('apertura: pendiente NO promueve; aplicada SÍ', () async {
      await sembrarTurno('t-apertura-at13', '2026-11-02', 'abierto_local');
      final svc = TurnoService.instance;
      await LocalDb.instance.queueOp(
        opUuid: 'op-apertura-at13',
        tipo: 'apertura_turno',
        payload: {'turno_id': 't-apertura-at13'},
      );
      await svc.promoverTurnosConEvidencia(tid);
      expect(await estadoTurno('t-apertura-at13'), 'abierto_local');
      final db = await LocalDb.instance.db;
      await db.rawUpdate(
          "UPDATE ops_queue SET estado = 'aplicada' "
          'WHERE op_uuid = ?',
          ['op-apertura-at13']);
      await svc.promoverTurnosConEvidencia(tid);
      expect(
          await estadoTurno('t-apertura-at13'), 'abierto_sincronizado');
    });
  });
}
