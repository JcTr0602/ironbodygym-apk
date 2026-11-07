/// 1.27 (caso de campo Duany, 2026-11-06): reconciliación de
/// turnos con el servidor.
///
/// El entrenador veía «11 turnos sin cerrar» en su Inicio
/// aunque el dueño ya los había cerrado administrativamente
/// en el servidor: su lista sale SOLO de la tabla local
/// `turnos` y ningún cierre ajeno baja por los espejos (las
/// tablas de turnos son solo-dueño). TurnoService.
/// reconciliarConServidorDe trae los cierres PROPIOS vía la
/// RPC mis_cierres_turno (el servidor filtra por el JWT: solo
/// los suyos) y marca cerradas las filas locales sin
/// resolver que coincidan.
///
/// Aquí se prueba el núcleo con un fetcher falso:
///  (a) turno abierto con cierre en el servidor → cerrado y
///      fuera de turnosSinResolver;
///  (b) turno abierto sin cierre en el servidor → sigue
///      abierto;
///  (c) fetcher que lanza → no cambia nada ni propaga;
///  (d) cierre de un turno inexistente localmente → no crea
///      filas;
///  (e) respaldo por clave natural (fecha+turno) cuando el
///      turno_id canónico aún no se reconcilió localmente;
///  (f) un no_cerrado con cierre en el servidor también se
///      resuelve (es uno de los estados que pinta la lista).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/turno_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tid = 969869611; // Duany (el caso de campo)

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// Siembra un turno local de [_tid] en fecha pasada (para que
/// cuente como «sin resolver») con el estado pedido.
Future<void> _sembrar(String turnoId, String fecha, String turno,
    String estado) async {
  final (id, _) = await LocalDb.instance.insertarTurno(
    turnoId: turnoId,
    fechaTurno: fecha,
    turno: turno,
    horaApertura: '${fecha}T08:05:00-05:00',
    telegramId: _tid,
  );
  expect(id, turnoId);
  if (estado != 'abierto_local') {
    await LocalDb.instance.marcarEstadoTurno(turnoId, estado);
  }
}

Future<String?> _estado(String turnoId) async {
  final t = await LocalDb.instance.getTurno(turnoId);
  return t == null ? null : '${t['estado']}';
}

Future<List<String>> _sinResolverIds() async {
  final ahora = ahoraHabana();
  final rows = await LocalDb.instance.turnosSinResolver(
      _tid, hoyHabanaIso(), turnoIdDe(ahora));
  return rows.map((r) => '${r['turno_id']}').toList();
}

Future<int> _conteoTurnos() async {
  final db = await LocalDb.instance.db;
  final r = await db.rawQuery('SELECT COUNT(*) AS n FROM turnos');
  return (r.first['n'] as num).toInt();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await _abrirDbVacia();
  });

  test(
      '(a) turno abierto con cierre en el servidor queda cerrado '
      'y desaparece de turnosSinResolver', () async {
    await _sembrar('t-srv-a', '2026-11-03', 'tarde', 'abierto_sincronizado');
    expect(await _sinResolverIds(), contains('t-srv-a'));

    await TurnoService.instance.reconciliarConServidorDe(_tid,
        traerCierres: () async => [
              {
                'turno_id': 't-srv-a',
                'fecha': '2026-11-03',
                'turno': 'tarde',
              }
            ]);

    final t = await LocalDb.instance.getTurno('t-srv-a');
    expect(t, isNotNull);
    expect(t!['estado'], 'cerrado_sincronizado');
    // 1.28 (M3-A8): hora_cierre queda NULL — la RPC no trae la
    // hora del cierre administrativo y rellenarla con la hora
    // de reconciliar fabricaba duraciones falsas («turnos
    // cortos» que nunca ocurrieron). Antes este test exigía
    // isNotNull: fijaba el comportamiento corregido.
    expect(t['hora_cierre'], isNull);
    // El origen queda anotado en el snapshot de auditoría.
    expect('${t['cierre_snapshot']}', contains('cierre_servidor'));
    expect(await _sinResolverIds(), isNot(contains('t-srv-a')));
  });

  test('(b) turno abierto sin cierre en el servidor queda abierto',
      () async {
    await _sembrar('t-srv-b', '2026-11-02', 'manana', 'abierto_local');

    await TurnoService.instance.reconciliarConServidorDe(_tid,
        traerCierres: () async => [
              {
                'turno_id': 'otro-turno',
                'fecha': '2026-10-30',
                'turno': 'manana',
              }
            ]);

    expect(await _estado('t-srv-b'), 'abierto_local');
    expect(await _sinResolverIds(), contains('t-srv-b'));
  });

  test(
      '(c) fetcher que lanza: no cambia nada y no propaga el '
      'error', () async {
    await _sembrar('t-srv-c', '2026-11-03', 'tarde', 'abierto_local');

    await TurnoService.instance.reconciliarConServidorDe(_tid,
        traerCierres: () async => throw Exception('sin red'));

    expect(await _estado('t-srv-c'), 'abierto_local');
    expect(await _sinResolverIds(), contains('t-srv-c'));
  });

  test(
      '(d) cierre del servidor de un turno inexistente '
      'localmente: no crea filas', () async {
    await _sembrar('t-srv-d', '2026-11-03', 'tarde', 'abierto_local');
    final antes = await _conteoTurnos();

    await TurnoService.instance.reconciliarConServidorDe(_tid,
        traerCierres: () async => [
              {
                'turno_id': 'no-existe-local',
                'fecha': '2026-10-17',
                'turno': 'manana',
              }
            ]);

    expect(await _conteoTurnos(), antes);
    expect(await LocalDb.instance.getTurno('no-existe-local'), isNull);
    expect(await _estado('t-srv-d'), 'abierto_local');
  });

  test(
      '(e) respaldo por clave natural: el turno_id del '
      'servidor difiere del local pero fecha+turno coinciden',
      () async {
    await _sembrar('t-local-e', '2026-10-31', 'manana', 'abierto_local');

    await TurnoService.instance.reconciliarConServidorDe(_tid,
        traerCierres: () async => [
              {
                'turno_id': 't-canonico-e',
                'fecha': '2026-10-31',
                'turno': 'manana',
              }
            ]);

    // Se cierra la fila LOCAL (su PK no se reescribe: eso es
    // el carril de reconciliarTurnoIdCanonico).
    expect(await _estado('t-local-e'), 'cerrado_sincronizado');
    expect(await LocalDb.instance.getTurno('t-canonico-e'), isNull);
    expect(await _sinResolverIds(), isNot(contains('t-local-e')));
  });

  test(
      '(f) un no_cerrado con cierre en el servidor también se '
      'resuelve', () async {
    await _sembrar('t-srv-f', '2026-10-26', 'manana', 'no_cerrado');
    expect(await _sinResolverIds(), contains('t-srv-f'));

    await TurnoService.instance.reconciliarConServidorDe(_tid,
        traerCierres: () async => [
              {
                'turno_id': 't-srv-f',
                'fecha': '2026-10-26',
                'turno': 'manana',
              }
            ]);

    expect(await _estado('t-srv-f'), 'cerrado_sincronizado');
    expect(await _sinResolverIds(), isNot(contains('t-srv-f')));
  });

  test(
      '(g) el cierre de OTRO entrenador no toca las filas de '
      'este (la RPC filtra en el servidor; aquí la fila local '
      'es de otro telegram y no se toca)', () async {
    // Fila de Gabriel con el mismo turno_id que «devuelve» la
    // RPC: la reconciliación corre con el tid de Duany y no
    // debe tocarla.
    final (_, _) = await LocalDb.instance.insertarTurno(
      turnoId: 't-ajeno-g',
      fechaTurno: '2026-11-03',
      turno: 'tarde',
      horaApertura: '2026-11-03T14:05:00-05:00',
      telegramId: 1403501391,
    );

    await TurnoService.instance.reconciliarConServidorDe(_tid,
        traerCierres: () async => [
              {
                'turno_id': 't-ajeno-g',
                'fecha': '2026-11-03',
                'turno': 'tarde',
              }
            ]);

    final t = await LocalDb.instance.getTurno('t-ajeno-g');
    expect(t!['estado'], 'abierto_local');
  });
}
