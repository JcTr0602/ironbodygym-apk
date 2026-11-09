/// Gestión 1.28 — Oleada M1-A (Bloque A del estudio M1:
/// Sync y datos). Tests por paquete:
///
/// - A1: markOp/bumpOp no regresan una op 'aplicada'
///   (candado anti ciclo-zombi en la propia escritura).
/// - A2: banderaRedescargaSeConsume consume la bandera si la
///   re-descarga se aplicó aunque la purga no valide;
///   seqsFilasMirror por lote; manifiesto con vuelo único.
/// - A3: conteo legible de espejo (W1 ante JSON corrupto),
///   lectores con red por fila, getAjustes degradado, FTS
///   dentro de la transacción y sonda de contenido.
/// - A4: confirmarOpAplicada atómica (rollback incluido),
///   busy_timeout fijado, pareja W5 en una escritura.
/// - A5: rescate de fotos de incidencias con lease
///   (reclamada_en): el reclamo vivo no se pisa.
/// - A6: la op 'auditoria' viaja con los hashes de SU fila.
/// - A8: orden de envío por instante (hora repetida del
///   fall-back) y tope del salto de watermark.
/// - A9: enteroTolerante.
/// - A10: fechas de tiempo.dart sin días inventados.
/// - A11: ultimoSync — sin hora de servidor no se afirman
///   edades; la fusión con usuarios_apk salta el elemento
///   sucio sin perder al resto.
/// - A12: conLatidoSyncLock renueva y detecta la pérdida.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diagnostico_espejo.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ultimo_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

Future<void> _insertarOp(String uuid, String estado,
    {String creadaTs = '2026-10-23T09:38:00.000-04:00',
    int intentos = 0}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'pago_mensual',
    'payload': '{}',
    'estado': estado,
    'creada_ts': creadaTs,
    'intentos': intentos,
  });
}

Future<String?> _estadoOp(String uuid) async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('ops_queue',
      columns: ['estado'], where: 'op_uuid=?', whereArgs: [uuid]);
  return rows.isEmpty ? null : rows.first['estado'] as String?;
}

Future<void> _insertarClienteCrudo(int id, String data, int seq) async {
  final db = await LocalDb.instance.db;
  await db.rawInsert(
      'INSERT OR REPLACE INTO clientes (id, data, sync_seq) '
      'VALUES (?, ?, ?)',
      [id, data, seq]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A10 · tiempo.dart sin días inventados', () {
    test('fechaNegocioHabana rechaza fechas que no existen', () {
      expect(fechaNegocioHabana('2026-02-31'), '');
      expect(fechaNegocioHabana('2026-02-31T00:00:00Z'), '');
      expect(fechaNegocioHabana('2026-02-29'), '');
      expect(fechaNegocioHabana('2024-02-29'), '2024-02-29');
      expect(fechaNegocioHabana('2026-02-28'), '2026-02-28');
      // Con zona: el instante se convierte a La Habana.
      expect(fechaNegocioHabana('2026-11-01T02:30:00Z'), '2026-10-31');
      // Sin zona: manda la fecha escrita.
      expect(fechaNegocioHabana('2026-10-31T23:30:00'), '2026-10-31');
    });

    test('mesHabanaDe no devuelve meses imposibles', () {
      expect(mesHabanaDe('2026-13-15'), isNull);
      expect(mesHabanaDe('2026-00-15'), isNull);
      expect(mesHabanaDe('2026-12-15'), '2026-12');
      expect(mesHabanaDe('basura'), isNull);
    });

    test('mesSiguiente valida sin lanzar ni inventar', () {
      expect(mesSiguiente('2026-12'), '2027-01');
      expect(mesSiguiente('2026-01'), '2026-02');
      expect(mesSiguiente('2026-13'), '2026-13');
      expect(mesSiguiente('basura'), 'basura');
    });

    test('esFechaCalendarioReal hace round-trip', () {
      expect(esFechaCalendarioReal(2026, 2, 29), isFalse);
      expect(esFechaCalendarioReal(2024, 2, 29), isTrue);
      expect(esFechaCalendarioReal(2026, 4, 31), isFalse);
      expect(esFechaCalendarioReal(2026, 13, 1), isFalse);
    });
  });

  group('A11 · ultimo_sync veraz', () {
    test('sin hora del servidor, con registro = sinVerificar', () {
      expect(
        clasificarSyncTelefono(
          ultimoSyncAt: '2026-11-01T00:00:00Z',
          ahoraServidorUtc: null,
          enTurno: true,
        ),
        EstadoSyncTelefono.sinVerificar,
      );
      // Sin registro sigue siendo sinRegistro aunque no haya
      // hora del servidor (no depende de relojes).
      expect(
        clasificarSyncTelefono(
          ultimoSyncAt: null,
          ahoraServidorUtc: null,
          enTurno: true,
        ),
        EstadoSyncTelefono.sinRegistro,
      );
      // Con hora del servidor la clasificación es la de siempre.
      expect(
        clasificarSyncTelefono(
          ultimoSyncAt: '2026-11-01T00:00:00Z',
          ahoraServidorUtc: DateTime.utc(2026, 11, 1, 10),
          enTurno: true,
        ),
        EstadoSyncTelefono.atrasado,
      );
    });

    test('un elemento sucio de usuarios_apk no borra al resto',
        () async {
      await _bdVacia();
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            // nombre que NO es String: el elemento sucio.
            {'telegram_id': 111, 'nombre': 12345},
            {'telegram_id': 222, 'nombre': 'Gabriel'},
            // sin telegram_id válido: se salta solo.
            {'nombre': 'SinId'},
          ]));
      final filas = await ultimoSyncPorTelefono();
      final ids = filas.map((f) => f['telegram_user_id']).toSet();
      expect(ids, contains(222),
          reason: 'el entrenador válido debe sobrevivir a la '
              'fusión aunque un hermano venga sucio');
      expect(ids, contains(111),
          reason: 'el nombre no-String se tolera como texto');
    });
  });

  group('A9 · enteroTolerante', () {
    test('num, texto numérico y basura', () {
      expect(SyncEngine.enteroTolerante(5), 5);
      expect(SyncEngine.enteroTolerante(5.9), 5);
      expect(SyncEngine.enteroTolerante('42'), 42);
      expect(SyncEngine.enteroTolerante(' 7 '), 7);
      expect(SyncEngine.enteroTolerante('x'), isNull);
      expect(SyncEngine.enteroTolerante(null), isNull);
      expect(SyncEngine.enteroTolerante(true), isNull);
    });
  });

  group('A8 · tope del salto de watermark', () {
    test('con fin de tabla salta a serverSeq; sin él, al máximo '
        'realmente descargado; nunca retrocede', () {
      expect(
          topeSaltoWatermark(
              finTabla: true, serverSeq: 500, tablaMax: 120, wmActual: 100),
          500);
      expect(
          topeSaltoWatermark(
              finTabla: false, serverSeq: 500, tablaMax: 120, wmActual: 100),
          120);
      expect(
          topeSaltoWatermark(
              finTabla: false, serverSeq: 500, tablaMax: 90, wmActual: 100),
          100);
    });
  });

  group('A2 · bandera de re-descarga y manifiesto', () {
    test('la bandera se consume si la re-descarga se aplicó, '
        'aunque la purga no haya validado', () {
      // El caso pinzado: server_seq se movió durante la
      // pasada → purga no validada, pero la tabla SÍ se
      // re-descargó completa.
      expect(
          SyncEngine.banderaRedescargaSeConsume(
              esPurgable: true,
              fueReseteada: true,
              entroEnPurga: true,
              purgaValidada: false,
              redescargaCompleta: true),
          isTrue);
      // Sin re-descarga completa manda la regla histórica.
      expect(
          SyncEngine.banderaRedescargaSeConsume(
              esPurgable: true,
              fueReseteada: true,
              entroEnPurga: true,
              purgaValidada: false),
          isFalse);
      expect(
          SyncEngine.banderaRedescargaSeConsume(
              esPurgable: true,
              fueReseteada: false,
              entroEnPurga: true,
              purgaValidada: true,
              redescargaCompleta: true),
          isFalse);
      expect(
          SyncEngine.banderaRedescargaSeConsume(
              esPurgable: false,
              fueReseteada: true,
              entroEnPurga: false,
              purgaValidada: false),
          isTrue);
    });

    test('seqsFilasMirror responde por lote', () async {
      await _bdVacia();
      await LocalDb.instance
          .upsertMirror('clientes', 1, {'nombre': 'Ana'}, 10);
      await LocalDb.instance
          .upsertMirror('clientes', 2, {'nombre': 'Beto'}, 20);
      final r = await LocalDb.instance
          .seqsFilasMirror('clientes', ['1', '2', '3']);
      expect(r, {'1': 10, '2': 20});
    });

    test('manifiestoDiarioSiToca vuela una sola vez en '
        'paralelo (vuelo único)', () async {
      await _bdVacia();
      var llamadas = 0;
      Future<int> fake() async {
        llamadas++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return 0;
      }

      final e = SyncEngine.instance;
      await Future.wait([
        e.manifiestoDiarioSiToca(verificar: fake),
        e.manifiestoDiarioSiToca(verificar: fake),
      ]);
      expect(llamadas, 1,
          reason: 'dos disparos solapados comparten la corrida');
      // Y sellado el día, un tercer disparo tampoco corre.
      await e.manifiestoDiarioSiToca(verificar: fake);
      expect(llamadas, 1);
    });
  });

  group('A1 · la cola no regresa desde aplicada', () {
    test('markOp no regresa aplicada → enviada/rechazada', () async {
      await _bdVacia();
      await _insertarOp('op-a1', 'aplicada');
      await LocalDb.instance.markOp('op-a1', 'enviada');
      expect(await _estadoOp('op-a1'), 'aplicada');
      await LocalDb.instance.markOp('op-a1', 'rechazada');
      expect(await _estadoOp('op-a1'), 'aplicada');
      // El camino normal sigue funcionando.
      await _insertarOp('op-a2', 'pendiente');
      await LocalDb.instance.markOp('op-a2', 'enviada');
      expect(await _estadoOp('op-a2'), 'enviada');
    });

    test('una anulación aplicada no desmarca el pago si llega '
        'un rechazada tardío', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await db.rawInsert(
          'INSERT INTO pagos (id, data, sync_seq) VALUES (?, ?, ?)',
          [50, '{"monto":2000,"anulado":true}', 3]);
      await db.insert('ops_queue', {
        'op_uuid': 'op-anul-1',
        'tipo': 'anular_pago',
        'payload': '{"pago_id":50}',
        'estado': 'aplicada',
        'creada_ts': '2026-10-23T09:38:00.000-04:00',
      });
      await LocalDb.instance.markOp('op-anul-1', 'rechazada');
      expect(await _estadoOp('op-anul-1'), 'aplicada');
      final rows = await db.query('pagos',
          columns: ['data'], where: 'id=?', whereArgs: [50]);
      expect(rows.first['data'], contains('"anulado":true'),
          reason: 'la anulación SÍ se aplicó en el servidor: '
              'el pago no puede resucitar localmente');
    });

    test('bumpOp no toca una op ya aplicada', () async {
      await _bdVacia();
      await _insertarOp('op-b1', 'aplicada', intentos: 2);
      await LocalDb.instance.bumpOp('op-b1', Exception('red'));
      expect(await _estadoOp('op-b1'), 'aplicada');
      final db = await LocalDb.instance.db;
      final rows = await db.query('ops_queue',
          columns: ['intentos'], where: 'op_uuid=?', whereArgs: ['op-b1']);
      expect(rows.first['intentos'], 2);
      // Y sobre una viva sí registra el fallo.
      await _insertarOp('op-b2', 'enviada');
      await LocalDb.instance.bumpOp('op-b2', Exception('red'));
      expect(await _estadoOp('op-b2'), 'error');
    });
  });

  group('A8 · orden de envío por instante', () {
    test('la hora repetida del fall-back no invierte el orden',
        () async {
      await _bdVacia();
      // 01:30 con -05:00 = 06:30 UTC (DESPUÉS).
      await _insertarOp('op-tarde', 'pendiente',
          creadaTs: '2026-11-01T01:30:00.000-05:00');
      // 01:59 con -04:00 = 05:59 UTC (ANTES).
      await _insertarOp('op-temprano', 'pendiente',
          creadaTs: '2026-11-01T01:59:00.000-04:00');
      final lista = await LocalDb.instance.pendientesParaEnvio(null);
      expect(lista.map((r) => r['op_uuid']).toList(),
          ['op-temprano', 'op-tarde']);
    });
  });

  group('A3 · espejo con JSON dañado', () {
    // Nota: la fila "dañada" de estos tests es un JSON de nivel
    // superior que NO es objeto ('[1,2,3]'). Un JSON truncado
    // no puede ni insertarse en `clientes`: el índice
    // idx_clientes_estado lo evalúa con json_extract y SQLite
    // lo rechaza; la corrupción que sobrevive en disco (p. ej.
    // tras restaurar un archivo) es la que los lectores deben
    // tolerar sin tumbarse.
    test('conteo legible distingue corruptas y el W1 dispara',
        () async {
      await _bdVacia();
      await _insertarClienteCrudo(1, '{"nombre":"Ana"}', 5);
      await _insertarClienteCrudo(2, '[1,2,3]', 6);
      await _insertarClienteCrudo(3, '[1,2,3]', 7);
      final c = await LocalDb.instance.conteoMirrorLegible('clientes');
      expect(c.total, 3);
      expect(c.legibles, 1);
      expect(c.corruptas, 2);
      // W1: testigo positivo y CERO legibles → diagnóstico.
      // (Con el conteo crudo viejo: 3 filas → no disparaba.)
      await _insertarClienteCrudo(1, '[1,2,3]', 8);
      await LocalDb.instance.setMeta('clientes_previos_buenos', '5');
      final diag = await evaluarEspejoVacio();
      expect(diag, isNotNull);
      expect(diag!.clientesPrevios, 5);
    });

    test('allMirror deja señal persistente de corruptas', () async {
      await _bdVacia();
      await _insertarClienteCrudo(1, '[1,2,3]', 5);
      final filas = await LocalDb.instance.allMirror('clientes');
      expect(filas, isEmpty);
      // La señal va en un unawaited: dar tiempo al flush.
      String? meta;
      for (var i = 0; i < 20 && meta == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        meta = await LocalDb.instance.getMeta('mirror_corruptas_clientes');
      }
      expect(meta, '1');
    });

    test('mirrorPorIds omite la fila dañada sin tumbar las demás',
        () async {
      await _bdVacia();
      await _insertarClienteCrudo(1, '{"nombre":"Ana"}', 5);
      await _insertarClienteCrudo(2, '[1,2,3]', 6);
      final r = await LocalDb.instance.mirrorPorIds('clientes', [1, 2]);
      expect(r.length, 1);
      expect(r.first['nombre'], 'Ana');
    });

    test('updateMirror* omite la fila dañada sin lanzar', () async {
      await _bdVacia();
      await _insertarClienteCrudo(9, '[1,2,3]', 5);
      await LocalDb.instance.updateMirrorEstado(9, 'activo');
      final db = await LocalDb.instance.db;
      final rows = await db.query('clientes',
          columns: ['data'], where: 'id=?', whereArgs: [9]);
      expect(rows.first['data'], '[1,2,3]',
          reason: 'la fila queda intacta: el pull la reescribirá');
    });

    test('getAjustes con el JSON dañado devuelve {}', () async {
      await _bdVacia();
      await LocalDb.instance.setMeta('ajustes', '{"roto": ');
      expect(await LocalDb.instance.getAjustes(), isEmpty);
    });

    test('actualizarFtsCliente dentro de una transacción '
        'escribe el índice con la fila', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await db.transaction((txn) async {
        await LocalDb.instance.actualizarFtsCliente(
            5, '{"nombre":"Pedro Nuevo","telefono":"58191577"}', null,
            txn: txn);
      });
      final r = await db.rawQuery(
          'SELECT nombre_norm, telefonos FROM clientes_fts WHERE id = 5');
      expect(r.length, 1);
      expect(r.first['nombre_norm'], contains('pedro'));
    });

    test('la sonda FTS detecta contenido viejo y reconstruye',
        () async {
      await _bdVacia();
      await LocalDb.instance
          .upsertMirror('clientes', 5, {'nombre': 'Pedro Nuevo'}, 10);
      final db = await LocalDb.instance.db;
      // El espejo cambia SIN pasar por el índice (la ventana
      // vieja: commit sí, FTS no) y el índice queda viejo.
      await db.rawUpdate('UPDATE clientes SET data = ? WHERE id = 5',
          ['{"nombre":"Pedro Cambiado"}']);
      // Reabrir: la reparación de arranque re-corre la sonda.
      await LocalDb.resetParaTest(borrarArchivo: false);
      final db2 = await LocalDb.instance.db;
      final r = await db2.rawQuery(
          'SELECT nombre_norm FROM clientes_fts WHERE id = 5');
      expect(r.length, 1);
      expect(r.first['nombre_norm'], contains('cambiado'),
          reason: 'la sonda de contenido debió reconstruir el '
              'índice con el nombre del espejo');
    });
  });

  group('A4 · atomicidad y calibración', () {
    test('confirmarOpAplicada aplica todo en una transacción',
        () async {
      await _bdVacia();
      await _insertarOp('op-c1', 'enviada');
      final db = await LocalDb.instance.db;
      await db.rawInsert(
          'INSERT INTO ventas_suplementos (id, data, sync_seq) '
          'VALUES (?, ?, ?)',
          [-7, '{"op_uuid":"op-c1","monto":100}', 0]);
      await LocalDb.instance.confirmarOpAplicada('op-c1',
          resultadoJson: '{"ok":true}', tablaOptimista: 'ventas_suplementos');
      expect(await _estadoOp('op-c1'), 'aplicada');
      final ops = await db.query('ops_queue',
          columns: ['resultado_servidor'],
          where: 'op_uuid=?',
          whereArgs: ['op-c1']);
      expect(ops.first['resultado_servidor'], '{"ok":true}');
      final ventas = await db.query('ventas_suplementos');
      expect(ventas, isEmpty,
          reason: 'la fila optimista desaparece en la misma '
              'transacción que confirma la op');
    });

    test('confirmarOpAplicada con un paso roto no deja nada a '
        'medias (rollback)', () async {
      await _bdVacia();
      await _insertarOp('op-c2', 'enviada');
      await expectLater(
        LocalDb.instance.confirmarOpAplicada('op-c2',
            resultadoJson: '{"ok":true}',
            tablaOptimista: 'tabla_que_no_existe'),
        throwsA(anything),
      );
      expect(await _estadoOp('op-c2'), 'enviada',
          reason: 'ni el estado ni el resultado quedaron '
              'escritos: la confirmación es atómica');
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          columns: ['resultado_servidor'],
          where: 'op_uuid=?',
          whereArgs: ['op-c2']);
      expect(ops.first['resultado_servidor'], isNull);
    });

    test('busy_timeout queda fijado en la conexión', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      final r = await db.rawQuery('PRAGMA busy_timeout');
      expect((r.first.values.first as num).toInt(), 5000);
    });

    test('la pareja W5 se guarda junta', () async {
      await _bdVacia();
      await LocalDb.instance.guardarCalibracionServidor(
          '2026-11-06T20:00:00.000Z', '2026-11-06T20:00:01.000Z');
      expect(await LocalDb.instance.getMeta('server_timestamp_ultimo_sync'),
          '2026-11-06T20:00:00.000Z');
      expect(await LocalDb.instance.getMeta('server_timestamp_recibido_en'),
          '2026-11-06T20:00:01.000Z');
    });
  });

  group('A5 · fotos de incidencias con lease', () {
    Future<void> foto(String id, String estado, String? reclamada) async {
      final db = await LocalDb.instance.db;
      await db.insert('incidencias_fotos', {
        'id': id,
        'incidencia_id': 'inc-1',
        'local_path': '/tmp/$id.jpg',
        'tipo': 'evidencia',
        'sync_estado': estado,
        'reclamada_en': reclamada,
        'creado_en': '2026-11-06T10:00:00-04:00',
      });
    }

    test('el rescate respeta reclamos vivos y recoge huérfanas',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await db.insert('incidencias_local', {
        'id': 'inc-1',
        'tipo': 'sync',
        'descripcion': 'prueba',
        'creada_por': 'yo',
        'creada_en': '2026-11-06T09:00:00-04:00',
      });
      final ahora = ahoraHabana();
      await foto('f-viva', 'uploading', isoHabana(ahora));
      await foto('f-vieja', 'uploading',
          isoHabana(ahora.subtract(const Duration(hours: 1))));
      await foto('f-legado', 'uploading', null);
      final rescatadas = await LocalDb.instance
          .rescatarFotosIncidenciasAtascadas(
              ahoraEpochSeg: ahora.millisecondsSinceEpoch ~/ 1000);
      expect(rescatadas, 2);
      final rows = await db.query('incidencias_fotos',
          columns: ['id', 'sync_estado', 'reclamada_en']);
      final porId = {for (final r in rows) '${r['id']}': r};
      expect(porId['f-viva']!['sync_estado'], 'uploading',
          reason: 'un reclamo vivo de otro isolate no se pisa');
      expect(porId['f-vieja']!['sync_estado'], 'retry');
      expect(porId['f-vieja']!['reclamada_en'], isNull);
      expect(porId['f-legado']!['sync_estado'], 'retry');
    });

    test('la migración v65 crea la columna reclamada_en', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      final cols = await db.rawQuery('PRAGMA table_info(incidencias_fotos)');
      expect(cols.map((c) => c['name']), contains('reclamada_en'));
      // 1.28 (M5-B3): la versión vigente subió a 66
      // (pausada_hasta); 1.28 (corrección A5-D1): a 67
      // (reset del watermark de recordatorios); 1.29
      // (Oleada 6, D-A3): a 68 (sello de autor en
      // fotos_cola); 1.30 (cierre §17): a 69 (paso de
      // migración del espejo avisos_vistos). La columna de
      // v65 sigue naciendo en el esquema limpio, que es lo
      // que aquí se fija.
      expect(LocalDb.versionActual, 69);
    });
  });

  group('A6 · auditoría con sus propios hashes', () {
    test('auditoriaPorId devuelve la fila pedida, no la más '
        'vieja pendiente', () async {
      await _bdVacia();
      final id1 = await LocalDb.instance.auditoriaInsert(
          actorId: 'a1',
          actorNombre: 'Uno',
          accion: 'primera',
          objetoTipo: 'pago',
          objetoId: '1',
          dispositivoId: 'dev');
      final id2 = await LocalDb.instance.auditoriaInsert(
          actorId: 'a1',
          actorNombre: 'Uno',
          accion: 'segunda',
          objetoTipo: 'pago',
          objetoId: '2',
          dispositivoId: 'dev');
      final fila2 = await LocalDb.instance.auditoriaPorId(id2);
      final fila1 = await LocalDb.instance.auditoriaPorId(id1);
      expect(fila2, isNotNull);
      expect(fila2!['hash_previo'], fila1!['hash_propio'],
          reason: 'la cadena enlaza: el previo de la segunda '
              'es el propio de la primera');
      expect(fila2['hash_propio'], isNot(fila1['hash_propio']));
    });

    test('registrarAuditoria encola la op con los hashes de '
        'SU fila (no los de la pendiente más vieja)', () async {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
      await _bdVacia();
      // Señuelo: una auditoría pendiente MÁS VIEJA. Con el
      // defecto, la op nueva viajaba con SUS hashes.
      final idSenuelo = await LocalDb.instance.auditoriaInsert(
          actorId: 'a0',
          actorNombre: 'Señuelo',
          accion: 'senuelo',
          objetoTipo: 'pago',
          objetoId: '0',
          dispositivoId: 'dev');
      final senuelo = await LocalDb.instance.auditoriaPorId(idSenuelo);
      final idNueva = await SyncEngine.instance.registrarAuditoria(
          accion: 'cobro_real', objetoTipo: 'pago', objetoId: '99');
      final propia = await LocalDb.instance.auditoriaPorId(idNueva);
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          columns: ['payload'],
          where: "tipo='auditoria'",
          orderBy: 'rowid DESC',
          limit: 1);
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.first['payload'] as String) as Map<String, dynamic>;
      expect(payload['id'], idNueva);
      expect(payload['hash_propio'], propia!['hash_propio']);
      expect(payload['hash_previo'], propia['hash_previo']);
      expect(payload['hash_propio'], isNot(senuelo!['hash_propio']));
    });
  });

  group('A12 · latido fuera del motor', () {
    test('conLatidoSyncLock mantiene el lock y detecta su '
        'pérdida', () async {
      await _bdVacia();
      final owner = await LocalDb.instance.adquirirSyncLock();
      expect(owner, isNotNull);
      final r = await LocalDb.instance
          .conLatidoSyncLock(owner!, () async => 42);
      expect(r, 42);
      expect(await LocalDb.instance.renovarSyncLock(owner), isTrue,
          reason: 'tras la operación seguimos siendo los dueños');
      // Robo del lock: la siguiente operación con latido debe
      // negarse a entregar su resultado.
      final db = await LocalDb.instance.db;
      await db.rawUpdate(
          "UPDATE meta SET v = '9999999999999:otro' WHERE k = 'sync_lock'");
      await expectLater(
        LocalDb.instance.conLatidoSyncLock(owner, () async => 43),
        throwsStateError,
      );
    });
  });
}
