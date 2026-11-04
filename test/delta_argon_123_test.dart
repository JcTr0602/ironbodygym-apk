/// Tests del Delta Argón 1.23 (pasadas 3ª/4ª/5ª verificadas
/// contra el código vivo): defectos de dinero y de estado.
///
/// - 3ª#2: la renovación desde la papelera refleja el nuevo
///   pagado_hasta en el espejo dentro de la misma transacción.
/// - 3ª#3: auditoriaInsert no colisiona en la PK en lote y la
///   cadena de hashes queda íntegra.
/// - 3ª#4: editar_pago se refleja en el espejo (JSON + columnas)
///   y respeta la marca de anulado viva.
/// - 3ª#1: reconciliarTurnoIdLocal fusiona en colisión
///   conservando el estado más avanzado y los datos de cierre.
/// - 3ª#5: conteoPagosDia cuenta transferencias de la cola y
///   los fiados como registros (regla de Jc).
/// - 3ª#6: las guardas de fiado de inscripcion_venta_suplemento
///   en montoEfectivoOp y montoCobradoCupOp.
/// - 5ª#6: cobradoHoyPorMetodo suma la cola sin duplicar lo ya
///   espejado (descarte por op_uuid).
/// - 5ª#2/4ª#2: la bandeja de avisos incluye el recibo de un
///   pago aún en cola, con las reglas de privacidad de siempre.
/// - 3ª-O4: la caché de ajustes se invalida si una escritura
///   con executor se revierte.
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
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_delta_argon_123_test.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

int _seq = 7700;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data,
    {Map<String, Object?>? cols}) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
    if (cols != null) ...cols,
  });
}

Future<void> _op(Database db,
    {required String uuid,
    required String tipo,
    required Map<String, dynamic> payload,
    int? telegramId,
    String estado = 'pendiente'}) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': isoHabana(ahoraHabana()),
    'telegram_id': telegramId,
  });
}

void main() {
  LocalDb.nombreArchivoDbForzado = 'test_delta_argon_123_test.db';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  test('3ª#2 papelera: updateMirrorPagadoHasta con txn refleja '
      'el nuevo vencimiento al salir de la transacción', () async {
    final db = await _abrirDbVacia();
    await _espejo(db, 'clientes', 7, {
      'id': 7,
      'nombre': 'Recuperado',
      'estado': 'eliminado',
      'pagado_hasta': '2026-10-01',
    });
    // Réplica del flujo de _recuperarYRenovar: cambiar_estado +
    // pago_mensual + reflejo del vencimiento, todo en UN txn.
    await db.transaction((txn) async {
      await LocalDb.instance.queueOp(
        opUuid: 'op-cambio-7',
        tipo: 'cambiar_estado',
        payload: {'cliente_id': 7, 'estado': 'activo'},
        txn: txn,
      );
      await LocalDb.instance.queueOp(
        opUuid: 'op-pago-7',
        tipo: 'pago_mensual',
        payload: {
          'cliente_id': 7,
          'monto': 2000,
          'pagado_hasta': '2026-12-03',
        },
        txn: txn,
      );
      await LocalDb.instance
          .updateMirrorPagadoHasta(7, '2026-12-03', txn: txn);
    });
    final filas = await LocalDb.instance.mirrorPorIds('clientes', [7]);
    expect(filas, hasLength(1));
    expect(filas.first['pagado_hasta'], '2026-12-03');
    final cruda = await db.query('clientes', where: 'id=7');
    final data =
        jsonDecode(cruda.first['data'] as String) as Map<String, dynamic>;
    expect(data['pagado_hasta'], '2026-12-03');
  });

  test('3ª#4 editar_pago: reflejo en JSON y columnas del espejo; '
      'la marca de anulado viva se conserva', () async {
    final db = await _abrirDbVacia();
    // Columnas dedicadas reales de pagos (columnasPagos):
    // fecha, cliente_id, telegram_user_id, metodo. Sin columna
    // de monto: vive solo en el JSON.
    await _espejo(db, 'pagos', 50, {
      'id': 50,
      'cliente_id': 7,
      'fecha': '2026-11-01',
      'monto': 2000,
      'metodo': 'efectivo',
    }, cols: {
      'fecha': '2026-11-01',
      'metodo': 'efectivo',
      'cliente_id': 7,
    });
    await _espejo(db, 'pagos', 51, {
      'id': 51,
      'cliente_id': 7,
      'fecha': '2026-11-01',
      'monto': 2000,
      'metodo': 'efectivo',
      'anulado': 1,
    }, cols: {
      'fecha': '2026-11-01',
      'metodo': 'efectivo',
      'cliente_id': 7,
    });
    await LocalDb.instance.queueOp(
      opUuid: 'op-edit-50',
      tipo: 'editar_pago',
      payload: {
        'pago_id': 50,
        'monto': 2500,
        'fecha': '2026-11-03',
        'metodo': 'transferencia',
        'motivo': 'error de dedo',
      },
    );
    await LocalDb.instance.queueOp(
      opUuid: 'op-edit-51',
      tipo: 'editar_pago',
      payload: {
        'pago_id': 51,
        'monto': 1500,
        'fecha': '2026-11-02',
        'metodo': 'efectivo',
        'motivo': 'corrección',
      },
    );
    // mirrorPorIds devuelve el JSON ya decodificado y fusionado
    // con las columnas; la fila cruda verifica el 'data' en sí.
    final filas = await LocalDb.instance.mirrorPorIds('pagos', [50, 51]);
    final p50 = filas.firstWhere((f) => f['id'] == 50);
    expect(p50['monto'], 2500);
    expect(p50['metodo'], 'transferencia');
    expect(p50['fecha'], '2026-11-03');
    final crudas = await db.query('pagos', where: 'id IN (50, 51)');
    final c50 = crudas.firstWhere((f) => f['id'] == 50);
    final d50 = jsonDecode(c50['data'] as String) as Map<String, dynamic>;
    expect(d50['monto'], 2500);
    expect(d50['metodo'], 'transferencia');
    expect(c50['metodo'], 'transferencia'); // columna dedicada
    expect(c50['fecha'], '2026-11-03'); // columna dedicada
    final p51 = filas.firstWhere((f) => f['id'] == 51);
    final c51 = crudas.firstWhere((f) => f['id'] == 51);
    final d51 = jsonDecode(c51['data'] as String) as Map<String, dynamic>;
    // El pago con anulación viva NO resucita: la marca sigue.
    expect(d51['anulado'], 1);
    expect(esPagoAnulado(p51, const {}), isTrue);
    expect(d51['monto'], 1500);
  });

  test('3ª#4b reflejo de editar_pago: un timestamp ISO completo '
      'se normaliza a fecha de negocio en JSON y columna '
      '(delta Argón H2)', () async {
    final db = await _abrirDbVacia();
    await _espejo(db, 'pagos', 52, {
      'id': 52,
      'cliente_id': 7,
      'fecha': '2026-10-30',
      'monto': 2000,
      'metodo': 'efectivo',
    }, cols: {
      'fecha': '2026-10-30',
      'metodo': 'efectivo',
      'cliente_id': 7,
    });
    // 2026-11-01T02:30Z es 2026-10-31 en La Habana (UTC-4):
    // el JSON no puede quedar con el string largo ni con el
    // día UTC — manda la fecha de negocio, como en la columna.
    await LocalDb.instance.reflejarEditarPagoEnEspejo(52,
        fecha: '2026-11-01T02:30:00Z');
    final crudas = await db.query('pagos', where: 'id=52');
    final c52 = crudas.single;
    final d52 = jsonDecode(c52['data'] as String) as Map<String, dynamic>;
    expect(d52['fecha'], '2026-10-31');
    expect(c52['fecha'], '2026-10-31');
  });

  test('3ª#3 auditoriaInsert: 50 eventos en lote sin colisión '
      'y cadena de hashes íntegra', () async {
    final db = await _abrirDbVacia();
    final ids = <String>{};
    for (var i = 0; i < 50; i++) {
      ids.add(await LocalDb.instance.auditoriaInsert(
        actorId: 'u1',
        actorNombre: 'Dueño',
        accion: 'misma_accion',
        objetoTipo: 'cliente',
        objetoId: '$i',
        dispositivoId: 'dev-test',
      ));
    }
    expect(ids, hasLength(50));
    final filas = await db.query('auditoria_local', orderBy: 'rowid ASC');
    expect(filas, hasLength(50));
    expect(filas.first['hash_previo'], isNull);
    for (var i = 1; i < filas.length; i++) {
      expect(filas[i]['hash_previo'], filas[i - 1]['hash_propio'],
          reason: 'eslabón $i');
    }
    final hashes = filas.map((f) => f['hash_propio']).toSet();
    expect(hashes, hasLength(50));
  });

  test('3ª#1 reconciliación: colisión fusiona conservando el '
      'estado más avanzado y rescatando el cierre', () async {
    final db = await _abrirDbVacia();
    Future<void> turno(String id, String estado,
        {String franja = 'manana',
        String? horaCierre,
        String? cierreOp,
        int inc = 0}) async {
      await db.insert('turnos', {
        'turno_id': id,
        'fecha_turno': '2026-11-04',
        'turno': franja,
        'hora_apertura': '2026-11-04T06:00:00-05:00',
        'hora_cierre': horaCierre,
        'telegram_id': 111,
        'estado': estado,
        'cierre_op_uuid': cierreOp,
        'tiene_incidencias': inc,
        'turno_id_reconciliado': 0,
      });
    }

    // La colisión real es de PK turno_id: la fila canónica ya
    // existe con OTRA clave natural (el índice único
    // (fecha, turno, telegram_id) impide dos filas con la
    // misma): nació como 'tarde' por el desfase de franjas y
    // trae el cierre y las incidencias; la vieja está cerrada
    // local (estado más avanzado).
    await turno('uuid-viejo', 'cerrado_local');
    await turno('uuid-canon', 'abierto_local',
        franja: 'tarde',
        horaCierre: '2026-11-04T12:00:00-05:00',
        cierreOp: 'op-cierre-1',
        inc: 1);
    final ok = await LocalDb.instance
        .reconciliarTurnoIdLocal('uuid-viejo', 'uuid-canon');
    expect(ok, isTrue);
    final filas = await db.query('turnos');
    expect(filas, hasLength(1));
    final f = filas.first;
    expect(f['turno_id'], 'uuid-canon');
    expect(f['estado'], 'cerrado_local'); // rango 4 > 1
    expect(f['hora_cierre'], '2026-11-04T12:00:00-05:00');
    expect(f['cierre_op_uuid'], 'op-cierre-1');
    expect(f['tiene_incidencias'], 1);
    expect(f['turno_id_reconciliado'], 1);
  });

  test('3ª#1 reconciliación sin colisión: renombra y marca',
      () async {
    final db = await _abrirDbVacia();
    await db.insert('turnos', {
      'turno_id': 'uuid-solo',
      'fecha_turno': '2026-11-04',
      'turno': 'tarde',
      'hora_apertura': '2026-11-04T14:00:00-05:00',
      'telegram_id': 111,
      'estado': 'abierto_local',
      'tiene_incidencias': 0,
      'turno_id_reconciliado': 0,
    });
    final ok = await LocalDb.instance
        .reconciliarTurnoIdLocal('uuid-solo', 'uuid-nuevo');
    expect(ok, isTrue);
    final filas = await db.query('turnos');
    expect(filas, hasLength(1));
    expect(filas.first['turno_id'], 'uuid-nuevo');
    expect(filas.first['turno_id_reconciliado'], 1);
  });

  test('3ª#5 conteoPagosDia: la cola cuenta transferencias y '
      'fiados como registros; lo de ayer no entra', () async {
    final db = await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    await _op(db,
        uuid: 'op-fiado',
        tipo: 'venta_suplemento',
        telegramId: 111,
        payload: {
          'cliente_id': 7,
          'cantidad': 1,
          'precio': 600,
          'moneda': 'CUP',
          'es_fiado': 1,
          'fecha': hoy,
        });
    await _op(db,
        uuid: 'op-transf',
        tipo: 'pago_mensual',
        telegramId: 111,
        payload: {
          'cliente_id': 7,
          'monto': 2500,
          'metodo': 'transferencia',
          'fecha': hoy,
        });
    await _op(db,
        uuid: 'op-ayer',
        tipo: 'pago_mensual',
        telegramId: 111,
        payload: {
          'cliente_id': 7,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': '2020-01-01',
        });
    await _op(db,
        uuid: 'op-otro',
        tipo: 'pago_mensual',
        telegramId: 222,
        payload: {
          'cliente_id': 8,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': hoy,
        });
    expect(await conteoPagosDia(111, fecha: hoy), 2);
  });

  test('3ª#6 fiado dentro de inscripción: la venta no suma ni '
      'en cobrado ni en efectivo; la mensualidad sí', () async {
    Map<String, dynamic> opCon(bool fiado) => {
          'tipo': 'inscripcion_venta_suplemento',
          'payload': jsonEncode({
            'cliente': {'periodo': 'mensual', 'meses': 1, 'monto': 2000},
            'metodo_pago': 'efectivo',
            'venta': {
              'cantidad': 2,
              'precio': 500,
              'moneda': 'CUP',
              if (fiado) 'es_fiado': 1,
            },
          }),
        };
    const pr = {
      'mensual': 2000.0,
      'transfer': 2500.0,
      'semanal': 600.0,
      'quincenal': 1200.0,
      'diario': 200.0,
      'menores': 1500.0,
    };
    await _abrirDbVacia();
    expect(await montoCobradoCupOp(opCon(true)), 2000);
    expect(montoEfectivoOp(opCon(true), pr), 2000);
    expect(await montoCobradoCupOp(opCon(false)), 3000);
    expect(montoEfectivoOp(opCon(false), pr), 3000);
  });

  test('5ª#6 cobradoHoyPorMetodo: la cola suma por su método '
      'y no duplica lo ya espejado (mismo op_uuid)', () async {
    final db = await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    await _espejo(db, 'pagos', 60, {
      'id': 60,
      'cliente_id': 7,
      'fecha': hoy,
      'monto': 2500,
      'metodo': 'transferencia',
      'op_uuid': 'uuid-esp',
    }, cols: {
      'fecha': hoy,
      'metodo': 'transferencia',
      'cliente_id': 7,
    });
    // La MISMA op en cola (ventana push→pull): no duplica.
    await _op(db,
        uuid: 'uuid-esp',
        tipo: 'pago_mensual',
        payload: {
          'cliente_id': 7,
          'monto': 2500,
          'metodo': 'transferencia',
          'fecha': hoy,
        });
    // Una inscripción en efectivo aún sin espejar: sí suma.
    await _op(db,
        uuid: 'uuid-cola',
        tipo: 'inscribir',
        payload: {
          'cliente_id': 8,
          'monto': 2000,
          'metodo_pago': 'efectivo',
          'fecha': hoy,
        });
    final r = await cobradoHoyPorMetodo();
    expect(r['transferencia'], 2500);
    expect(r['efectivo'], 2000);
  });

  test('5ª#2 bandeja: el recibo de un pago en cola aparece; '
      'sin espejo (no-dueño) u op ajena, no', () async {
    final db = await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    final futuro = DateTime.parse(hoy)
        .add(const Duration(days: 10))
        .toIso8601String()
        .substring(0, 10);
    await _espejo(db, 'clientes', 31, {
      'id': 31,
      'nombre': 'Cola Recibo',
      'telefono': '58190031',
      'estado': 'activo',
      'pagado_hasta': futuro,
    });
    // Pago de hoy aún en cola (sin telegram: sesión de test).
    await _op(db,
        uuid: 'op-recibo-31',
        tipo: 'pago_mensual',
        payload: {
          'cliente_id': 31,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': hoy,
        });
    // NOTA: el filtro «solo mis recibos» del no-dueño exige el
    // telegram_id de la sesión (tid); sin sesión (tid null) el
    // paso del ESPEJO tampoco filtra (paridad deliberada del
    // código: `(!esDueno && tid != null)` en ambos pasos), así
    // que una op «ajena» no es representable en este entorno:
    // queda verificado por paridad de código, no por test.
    // Cliente SIN espejo: para un no-dueño el recibo se omite.
    await _op(db,
        uuid: 'op-recibo-32',
        tipo: 'pago_mensual',
        payload: {
          'cliente_id': 32,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': hoy,
        });
    final avisos = await avisosWhatsappHoy();
    final recibos31 = avisos
        .where((a) => a['tipo'] == 'recibo' && a['cliente_id'] == 31)
        .toList();
    expect(recibos31, hasLength(1));
    expect(
        avisos.where(
            (a) => a['tipo'] == 'recibo' && a['cliente_id'] == 32),
        isEmpty);
  });

  test('3ª-O4 caché de ajustes: una escritura con executor '
      'revertida no contamina la caché', () async {
    final db = await _abrirDbVacia();
    await LocalDb.instance.setAjustes({'a': 1});
    expect(await LocalDb.instance.getAjustes(), {'a': 1});
    // Mutar el mapa devuelto no contamina la caché (copias).
    final leido = await LocalDb.instance.getAjustes();
    leido['a'] = 99;
    expect((await LocalDb.instance.getAjustes())['a'], 1);
    // Escritura dentro de una transacción que se revierte:
    // la caché se invalida y la lectura vuelve al valor firme.
    try {
      await db.transaction((txn) async {
        await LocalDb.instance
            .setAjustes({'a': 2}, executor: txn);
        throw StateError('revertir');
      });
    } catch (_) {}
    expect((await LocalDb.instance.getAjustes())['a'], 1);
  });
}
