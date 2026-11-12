/// Oleada 2 Fase 2 · Adjudicación de Argón (paquete
/// syncsello_) — contratos a nivel de BD local (sin red):
///
/// - F-11: los conteos que cierran las puertas filtran por
///   usuario activo (la 'enviada' ajena no es mi espera).
/// - F-12: queueOpEn hereda la autoría del respaldo en
///   meta cuando la sesión no responde (k/v reales).
/// - F-14: 'necesita_revision' cuenta como problema.
/// - F-16: confirmarOpAplicada escribe enviada_ts y la
///   poda por época no borra la confirmada de hoy.
/// - F-17: contrato — deleteOp solo vive en localdb y en
///   los dos diálogos que compensan a mano.
/// - F-19: borrarEspejosConfirmados resetea watermarks
///   DENTRO de su transacción y honra la exclusión F-19.
/// - F-21: upsertMirror/upsertMirrorTexto no dejan una
///   fila confirmada en sync_seq 0 y el «sin cambio»
///   repone el seq entrante mayor (anti-fantasmas).
/// - F-22: purgarMirrorAusentes aborta por umbral
///   relativo (>50 %) sin flag, y borra con flag de
///   conteo confirmado.
/// - F-23/F-24: la purga conserva la privada no
///   sincronizada o con op viva (fila, ops y fotos),
///   purga la sincronizada, rebobina wm_incidencias y
///   borra los sellos en meta.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_o2f2s_adj_c.db';
  try {
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_o2f2s_adj_c.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
}

Future<void> _limpiarOps() async {
  final d = await LocalDb.instance.db;
  await d.delete('ops_queue');
}

Future<void> _opCruda(String uuid,
    {required String estado,
    String? userId,
    String tipo = 'crear_categoria',
    String payload = '{"nombre":"X"}',
    String? creadaTs,
    String? enviadaTs}) async {
  final d = await LocalDb.instance.db;
  await d.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': payload,
    'estado': estado,
    'user_id': userId,
    'creada_ts': creadaTs ?? isoHabana(ahoraHabana()),
    'enviada_ts': enviadaTs,
    'intentos': 0,
  });
}

void main() {
  setUpAll(_init);
  setUp(_limpiarOps);

  group('F-11: conteos por usuario activo', () {
    test('la enviada ajena no cuenta como mi espera; la '
        'propia y la sin autor sí', () async {
      await _opCruda('op-ajena',
          estado: 'enviada', userId: 'otro-uuid');
      await _opCruda('op-propia',
          estado: 'enviada', userId: 'mi-uuid');
      await _opCruda('op-legado', estado: 'pendiente');
      final c =
          await LocalDb.instance.conteoPendientesSync('mi-uuid');
      expect(c.esperandoConfirmacion, 1,
          reason: 'solo la enviada propia espera confirmación');
      expect(c.porSubir, 1);
      expect(c.deOtroUsuario, 0,
          reason: 'la enviada ajena no es «pendiente de otro» '
              'en esta rama del conteo');
    });
  });

  group('F-14: necesita_revision cuenta como problema', () {
    test('con_error la incluye', () async {
      await _opCruda('op-rev',
          estado: 'necesita_revision', userId: 'mi-uuid');
      final c =
          await LocalDb.instance.conteoPendientesSync('mi-uuid');
      expect(c.conError, 1);
    });
  });

  group('F-12: respaldo de autoría en meta', () {
    test('sin sesión, queueOpEn hereda el respaldo '
        'persistido (y sin respaldo queda NULL)', () async {
      final db = LocalDb.instance;
      final d = await db.db;
      await db.setMeta('ultimo_user_id_activo', 'uuid-respaldo');
      await db.setMeta('ultimo_telegram_id_activo', '123456');
      await db.queueOpEn(d,
          opUuid: 'op-f12-a',
          tipo: 'crear_categoria',
          payload: {'nombre': 'Respaldo'});
      var rows = await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-f12-a']);
      expect(rows.single['user_id'], 'uuid-respaldo');
      expect(rows.single['telegram_id'], 123456);
      await db.setMeta('ultimo_user_id_activo', '');
      await db.setMeta('ultimo_telegram_id_activo', '');
      await db.queueOpEn(d,
          opUuid: 'op-f12-b',
          tipo: 'crear_categoria',
          payload: {'nombre': 'Sin respaldo'});
      rows = await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-f12-b']);
      expect(rows.single['user_id'], isNull);
    });
  });

  group('F-16: confirmarOpAplicada + poda por época', () {
    test('la confirmada de hoy con creada_ts vieja NO se '
        'poda; la vieja más allá de las 200 protegidas sí',
        () async {
      final db = LocalDb.instance;
      final vieja =
          isoHabana(ahoraHabana().subtract(const Duration(days: 100)));
      // 205 aplicadas viejas de verdad (enviada_ts vieja).
      final d = await db.db;
      await d.transaction((txn) async {
        for (var i = 0; i < 205; i++) {
          await txn.insert('ops_queue', {
            'op_uuid': 'vieja-$i',
            'tipo': 'crear_categoria',
            'payload': '{"nombre":"V"}',
            'estado': 'aplicada',
            'creada_ts': vieja,
            'enviada_ts': vieja,
            'intentos': 1,
          });
        }
      });
      // La protagonista: creada hace 100 días, confirmada HOY.
      await _opCruda('op-f16',
          estado: 'pendiente', creadaTs: vieja);
      await db.confirmarOpAplicada('op-f16');
      final fila = (await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-f16'])).single;
      expect(fila['estado'], 'aplicada');
      expect(fila['enviada_ts'], isNotNull,
          reason: 'F-16: la confirmación escribe enviada_ts');
      final borradas = await db.purgarOpsAplicadas();
      expect(borradas, 6,
          reason: '206 aplicadas; las 200 protegidas incluyen '
              'a la protagonista: 205 viejas − 199 = 6 podadas');
      final queda = await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-f16']);
      expect(queda, hasLength(1),
          reason: 'la confirmada de hoy sobrevive a la poda');
    });
  });

  group('F-17: deleteOp fijada por contrato', () {
    test('los únicos llamadores en lib/ son los dos '
        'diálogos que compensan pago_mensual a mano', () {
      final llamadores = <String>{};
      for (final e
          in Directory('lib').listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.dart')) {
          final txt = e.readAsStringSync();
          if (txt.contains('.deleteOp(') ||
              txt.contains(' deleteOp(')) {
            llamadores.add(e.path.replaceAll('\\', '/'));
          }
        }
      }
      expect(
          llamadores,
          {
            'lib/localdb.dart',
            'lib/ui/pago.dart',
            'lib/ui/confirmacion_cobro.dart',
          },
          reason: 'deleteOp es primitiva peligrosa: cualquier '
              'llamador nuevo debe pasar por el embudo de '
              'efectos o compensar como estos dos');
    });
  });

  group('F-19: borrarEspejosConfirmados se basta solo', () {
    test('borra confirmadas y resetea el watermark dentro '
        'de su transacción; la exclusión por ops vivas se '
        'respeta', () async {
      final db = LocalDb.instance;
      final d = await db.db;
      Future<void> sembrar() async {
        await d.delete('clientes');
        for (final id in [1, 2]) {
          await d.insert('clientes', {
            'id': id,
            'data': jsonEncode({'id': id, 'nombre': 'C$id'}),
            'sync_seq': 10,
          });
        }
        await db.setWatermarkTabla('clientes', 777);
      }

      await sembrar();
      final r1 = await db.borrarEspejosConfirmados(['clientes']);
      expect(r1.fallos, isEmpty);
      expect(r1.borradas, 2);
      expect(await db.getWatermarkTabla('clientes'), 0,
          reason: 'F-19 (ampliación): el reseteo vive en la '
              'primitiva, no en el llamador');

      await sembrar();
      final r2 = await db.borrarEspejosConfirmados(['clientes'],
          excluirIds: {
            'clientes': {1}
          });
      expect(r2.borradas, 1);
      final quedan = await d.query('clientes', columns: ['id']);
      expect(quedan.map((f) => f['id']), [1],
          reason: 'la fila con op viva sobrevive al resync');
      expect(await db.getWatermarkTabla('clientes'), 0);
    });
  });

  group('F-21: upsertMirror anti-fantasmas', () {
    test('la escritura optimista (seq 0) no deja la fila '
        'confirmada en 0; el sin-cambio repone el seq mayor',
        () async {
      final db = LocalDb.instance;
      final d = await db.db;
      await d.delete('categorias_suplemento');
      await db.upsertMirror('categorias_suplemento', 5,
          {'id': 5, 'nombre': 'Proteína', 'activa': 1}, 50);
      // Edición optimista como la de editar_categoria: seq 0.
      await db.upsertMirror('categorias_suplemento', 5,
          {'id': 5, 'nombre': 'Proteína X', 'activa': 1}, 0);
      var fila = (await d.query('categorias_suplemento',
          where: 'id = ?', whereArgs: [5])).single;
      expect((fila['sync_seq'] as num).toInt(), 50,
          reason: 'el seq confirmado nunca retrocede');
      expect(jsonDecode(fila['data'] as String)['nombre'],
          'Proteína X',
          reason: 'el dato optimista sí se escribe');
      // Sin cambio con seq entrante mayor: repone el seq.
      final cambio = await db.upsertMirror(
          'categorias_suplemento',
          5,
          {'id': 5, 'nombre': 'Proteína X', 'activa': 1},
          80);
      expect(cambio, isFalse);
      fila = (await d.query('categorias_suplemento',
          where: 'id = ?', whereArgs: [5])).single;
      expect((fila['sync_seq'] as num).toInt(), 80,
          reason: 'el camino sin-cambio repone el seq '
              'entrante si es mayor');
    });

    test('upsertMirrorTexto aplica la misma guarda',
        () async {
      final db = LocalDb.instance;
      final d = await db.db;
      await d.delete('turnos_cierre');
      await db.upsertMirrorTexto('turnos_cierre', 'tc-1',
          {'id': 'tc-1', 'total': 100}, 30);
      await db.upsertMirrorTexto('turnos_cierre', 'tc-1',
          {'id': 'tc-1', 'total': 200}, 0);
      final fila = (await d.query('turnos_cierre',
          where: 'id = ?', whereArgs: ['tc-1'])).single;
      expect((fila['sync_seq'] as num).toInt(), 30);
      expect(jsonDecode(fila['data'] as String)['total'], 200);
    });
  });

  group('F-22: umbral relativo dentro de la primitiva', () {
    test('borrar >50 % sin flag aborta con rastro; con '
        'flag de conteo confirmado borra', () async {
      final db = LocalDb.instance;
      final d = await db.db;
      await d.delete('clientes');
      for (final id in [1, 2, 3]) {
        await d.insert('clientes', {
          'id': id,
          'data': jsonEncode({'id': id, 'nombre': 'C$id'}),
          'sync_seq': 10,
        });
      }
      await db.setMeta('purga_umbral_relativo_clientes', '');
      // El servidor solo ve al 1: borraría 2 de 3 (66 %).
      final sinFlag =
          await db.purgarMirrorAusentes('clientes', {1});
      expect(sinFlag, isEmpty,
          reason: 'F-22: la primitiva aborta la mayoría '
              'sin flag explícito');
      expect(await db.contar('clientes'), 3);
      expect(
          await db.getMeta('purga_umbral_relativo_clientes'),
          isNotEmpty);
      final conFlag = await db.purgarMirrorAusentes(
          'clientes', {1},
          permitirMayoriaConfirmada: true);
      expect(conFlag, hasLength(2));
      expect(await db.contar('clientes'), 1);
    });
  });

  group('F-23/F-24: purga con conservación y sellos', () {
    test('la privada no sincronizada sobrevive entera '
        '(fila, op y foto); la sincronizada se purga; '
        'wm_incidencias rebobina y los sellos caen',
        () async {
      final db = LocalDb.instance;
      final d = await db.db;
      final tmp = await Directory.systemTemp.createTemp('f23_');
      final fotoPen = File(p.join(tmp.path, 'pen.jpg'));
      await fotoPen.writeAsString('foto-pendiente');
      final fotoSyn = File(p.join(tmp.path, 'syn.jpg'));
      await fotoSyn.writeAsString('foto-sincronizada');

      Map<String, Object?> baseInc(String id) => {
            'id': id,
            'tipo': 'sync',
            'entidad': null,
            'entidad_id': null,
            'visibilidad': 'privada',
            'tipo_id': null,
            'descripcion': 'Privada $id',
            'detalle': null,
            'estado': 'pendiente',
            'asignado_a': null,
            'prioridad': 'media',
            'fecha_limite': null,
            'ubicacion': null,
            'creada_por': 'dueno',
            'creada_en': '2026-11-01T10:00:00-05:00',
            'resuelta_por': null,
            'resuelta_en': null,
            'nota_resolucion': null,
            'version': 1,
          };
      await d.delete('incidencias_local');
      await d.delete('incidencias_mirror');
      await d.delete('incidencias_fotos');
      await d.insert('incidencias_local',
          {...baseInc('p-pen'), 'sync_estado': 'pending'});
      await d.insert('incidencias_local',
          {...baseInc('p-syn'), 'sync_estado': 'synced'});
      // p-viva: sincronizada PERO con una op viva — la
      // segunda rama de la conservación F-23.
      await d.insert('incidencias_local',
          {...baseInc('p-viva'), 'sync_estado': 'synced'});
      for (final (id, seq)
          in [('p-pen', 41), ('p-syn', 40), ('p-viva', 42)]) {
        await d.insert('incidencias_mirror', {
          ...baseInc(id),
          'actualizada_en': '2026-11-01T10:00:00-05:00',
          'sync_seq': seq,
        });
      }
      await d.insert('incidencias_fotos', {
        'id': 'f-pen',
        'incidencia_id': 'p-pen',
        'local_path': fotoPen.path,
        'storage_path': null,
        'tipo': 'evidencia',
        'sync_estado': 'pending',
        'creado_en': '2026-11-01T10:00:00-05:00',
      });
      await d.insert('incidencias_fotos', {
        'id': 'f-syn',
        'incidencia_id': 'p-syn',
        'local_path': fotoSyn.path,
        'storage_path': null,
        'tipo': 'evidencia',
        'sync_estado': 'synced',
        'creado_en': '2026-11-01T10:00:00-05:00',
      });
      // Ops: la de p-pen (su crear, viva); las de p-syn ya
      // están APLICADAS (sin op viva que la proteja); y un
      // cambio de estado VIVO sobre p-viva (la protege).
      await _opCruda('op-pen',
          estado: 'pendiente',
          tipo: 'crear_incidencia',
          payload: jsonEncode(
              {'id': 'p-pen', 'visibilidad': 'privada'}));
      await _opCruda('op-syn-crear',
          estado: 'aplicada',
          tipo: 'crear_incidencia',
          payload: jsonEncode(
              {'id': 'p-syn', 'visibilidad': 'privada'}));
      await _opCruda('op-viva-estado',
          estado: 'pendiente',
          tipo: 'cambiar_estado_incidencia',
          payload: jsonEncode({'id': 'p-viva'}));
      await db.setWatermarkTabla('incidencias', 100);
      await db.setMeta('last_sync_ok', '2026-11-11T00:00:00-05:00');
      await db.setMeta('server_seq', '999');

      await db.purgarDatosSensibles();

      // La protegida (pending) sobrevive ENTERA.
      expect(
          await d.query('incidencias_local',
              where: 'id = ?', whereArgs: ['p-pen']),
          hasLength(1));
      expect(
          await d.query('ops_queue',
              where: 'op_uuid = ?', whereArgs: ['op-pen']),
          hasLength(1));
      expect(await fotoPen.exists(), isTrue);
      // La protegida por op viva también sobrevive.
      expect(
          await d.query('incidencias_local',
              where: 'id = ?', whereArgs: ['p-viva']),
          hasLength(1));
      expect(
          await d.query('ops_queue',
              where: 'op_uuid = ?', whereArgs: ['op-viva-estado']),
          hasLength(1));
      // La sincronizada sin op viva se purgó entera.
      expect(
          await d.query('incidencias_local',
              where: 'id = ?', whereArgs: ['p-syn']),
          isEmpty);
      expect(
          await d.query('incidencias_mirror',
              where: 'id = ?', whereArgs: ['p-syn']),
          isEmpty);
      expect(
          await d.query('ops_queue',
              where: 'op_uuid = ?', whereArgs: ['op-syn-crear']),
          isEmpty);
      expect(await fotoSyn.exists(), isFalse);
      // F-24 (ii): el cursor rebobina bajo la purgada más
      // antigua (sync_seq 40 → wm 39).
      expect(await db.getWatermarkTabla('incidencias'), 39);
      // F-24 (iv): los sellos cayeron con la purga.
      expect(await db.getMeta('last_sync_ok'), isNull);
      expect(await db.getMeta('server_seq'), isNull);
      // La señal de purga no queda colgada.
      expect(await db.getMeta('purga_en_curso'), '');
      expect(await db.purgaEnCursoActiva(), isFalse);
      await tmp.delete(recursive: true);
    });
  });
}
