/// 1.23 — Auditoría extra de Argón: núcleo.
///
/// - #5: el filtro por usuario de la cola. `opsNecesitanRevision`
///   sin filtro devolvía TODA la cola en revisión del teléfono y
///   `pendientesParaEnvio` sumaba las filas sin autor (user_id
///   NULL) al desglose/cierre de cualquier usuario. Contrato:
///   sin userId → histórico (todo); con userId en revisión →
///   estricto (solo user_id = ?); `soloPropias` en pendientes →
///   estricto, sin el OR IS NULL del push.
/// - #6: `anular_pago` con marca optimista. Al encolar, el espejo
///   queda marcado (anulado=1) y los lectores de dinero excluyen
///   el pago EN EL ACTO. Como el servidor BORRA la fila al anular
///   y un pull previo a la aplicación reescribe el JSON sin la
///   marca, la exclusión se apoya en el overlay de la cola
///   (pagosAnuladosEnCola): sobrevive al pull y se levanta si la
///   op termina rechazada.
/// - #1: queueOp cambiar_estado delega en updateMirrorEstado
///   (el estado se refleja en el espejo al encolar).
/// - #3: conteoSinSubirQuePurgaria cuenta solo lo que la purga
///   de cierre de sesión destruiría sin haber subido.
///
/// Delta del panel (NO APTO → correcciones):
/// - A1: si la op `anular_pago` termina RECHAZADA, la marca
///   optimista del espejo se revierte en la misma transacción
///   (markOp): el pago vuelve a contar SIN pull intermedio, y
///   con doble anulación sigue excluido mientras una siga viva.
/// - A2: el cierre de mi_turno usa el mismo camino de datos que
///   desglosePendientes (forzar + soloPropias + revisión por
///   usuario): aquí se fijan esos argumentos sobre las funciones
///   de LocalDb con ops de A, de B y sin autor.
/// - M1: un fallo de lectura en el conteo de purga produce
///   `indeterminado` y el aviso genérico, nunca «sin pérdida».
/// - N1: las fotos de incidencias privadas cuentan como pérdida
///   en TODO estado no confirmado (≠ 'synced'): la purga las
///   borra sin filtrar por estado.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/cierre_sesion.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _opCruda({
  required String uuid,
  required String tipo,
  required String estado,
  String? userId,
  Map<String, dynamic> payload = const {},
  String? proximoReintento,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': '2026-11-04T08:00:00.000-04:00',
    if (userId != null) 'user_id': userId,
    if (proximoReintento != null) 'proximo_reintento': proximoReintento,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  group('#5 filtro por usuario', () {
    test('opsNecesitanRevision: sin filtro todo, con usuario estricto',
        () async {
      await _opCruda(
          uuid: 'rA', tipo: 'pago_mensual', estado: 'necesita_revision', userId: 'userA');
      await _opCruda(
          uuid: 'rB', tipo: 'pago_mensual', estado: 'necesita_revision', userId: 'userB');
      await _opCruda(
          uuid: 'rN', tipo: 'pago_mensual', estado: 'necesita_revision');

      final todas = await LocalDb.instance.opsNecesitanRevision();
      expect(todas.length, 3);

      final deA = await LocalDb.instance.opsNecesitanRevision(userId: 'userA');
      expect(deA.length, 1);
      expect(deA.single['op_uuid'], 'rA');

      final deB = await LocalDb.instance.opsNecesitanRevision(userId: 'userB');
      expect(deB.length, 1);
      expect(deB.single['op_uuid'], 'rB');
    });

    test('pendientesParaEnvio: soloPropias excluye las sin autor', () async {
      await _opCruda(uuid: 'pA', tipo: 'pago_mensual', estado: 'pendiente', userId: 'userA');
      await _opCruda(uuid: 'pN', tipo: 'pago_mensual', estado: 'pendiente');
      await _opCruda(uuid: 'pB', tipo: 'pago_mensual', estado: 'pendiente', userId: 'userB');

      // Camino del push (histórico): propias + sin autor.
      final push = await LocalDb.instance
          .pendientesParaEnvio('userA', forzar: true);
      expect(push.map((o) => o['op_uuid']).toSet(), {'pA', 'pN'});

      // Camino del desglose/cierre: solo las del usuario.
      final propias = await LocalDb.instance.pendientesParaEnvio('userA',
          forzar: true, soloPropias: true);
      expect(propias.map((o) => o['op_uuid']).toSet(), {'pA'});

      // Sin sesión (userId null): sin filtro, como siempre.
      final sinSesion = await LocalDb.instance
          .pendientesParaEnvio(null, forzar: true, soloPropias: true);
      expect(sinSesion.length, 3);
    });
  });

  group('#6 anular_pago optimista', () {
    test('esPagoAnulado: marca JSON u overlay de cola', () {
      expect(esPagoAnulado({'id': 7}, const {}), isFalse);
      expect(esPagoAnulado({'id': 7, 'anulado': 1}, const {}), isTrue);
      expect(esPagoAnulado({'id': 7, 'anulado': true}, const {}), isTrue);
      expect(esPagoAnulado({'id': 7}, const {7}), isTrue);
      expect(esPagoAnulado({'id': 8}, const {7}), isFalse);
    });

    test(
        'al encolar: marca en el espejo y pagosRealizadosMes lo excluye; '
        'el overlay sobrevive al pull y se levanta si la op se rechaza',
        () async {
      final hoy = hoyHabanaIso();
      await LocalDb.instance.upsertMirror('pagos', 501, {
        'cliente_id': 9001,
        'monto': 2000,
        'fecha': hoy,
        'metodo': 'efectivo',
        'periodo': 'mensual',
      }, 1);
      expect(await pagosRealizadosMes(), 1);

      await LocalDb.instance.queueOp(
          opUuid: 'anul-1',
          tipo: 'anular_pago',
          payload: {'pago_id': 501});

      // Marca optimista escrita en el JSON del espejo.
      final db = await LocalDb.instance.db;
      final filas = await db.query('pagos', where: 'id=?', whereArgs: [501]);
      final data =
          jsonDecode(filas.single['data'] as String) as Map<String, dynamic>;
      expect(data['anulado'], 1);
      expect(await LocalDb.instance.pagosAnuladosEnCola(), contains(501));
      expect(await pagosRealizadosMes(), 0);

      // Un pull que baja ANTES de aplicarse la op reescribe el
      // JSON sin la marca (el servidor aún tiene la fila): la
      // exclusión debe sobrevivir por el overlay de la cola.
      await LocalDb.instance.upsertMirror('pagos', 501, {
        'cliente_id': 9001,
        'monto': 2000,
        'fecha': hoy,
        'metodo': 'efectivo',
        'periodo': 'mensual',
      }, 2);
      expect(await pagosRealizadosMes(), 0);

      // Si el servidor RECHAZA la anulación, el pago vuelve a
      // contar (la marca ya no está y el overlay se levanta).
      await db.update('ops_queue', {'estado': 'rechazada'},
          where: 'op_uuid=?', whereArgs: ['anul-1']);
      expect(await LocalDb.instance.pagosAnuladosEnCola(), isNot(contains(501)));
      expect(await pagosRealizadosMes(), 1);
    });

    test('nómina: clientesQuePagaronElMes excluye el pago anulado en cola',
        () async {
      await LocalDb.instance.upsertMirror('pagos', 502, {
        'cliente_id': 9002,
        'monto': 2000,
        'fecha': '2026-10-15',
        'pagado_hasta': '2026-11-14',
        'metodo': 'efectivo',
        'periodo': 'mensual',
      }, 1);
      expect(await NominaCalc.clientesQuePagaronElMes('2026-10'), 1);

      await LocalDb.instance.queueOp(
          opUuid: 'anul-2',
          tipo: 'anular_pago',
          payload: {'pago_id': 502});
      expect(await NominaCalc.clientesQuePagaronElMes('2026-10'), 0);
    });
  });

  group('#1 cambiar_estado vía queueOp', () {
    test('el espejo refleja el estado al encolar', () async {
      await LocalDb.instance.upsertMirror('clientes', 77, {
        'nombre': 'Cliente Prueba',
        'estado': 'activo',
      }, 1);
      await LocalDb.instance.queueOp(
          opUuid: 'ce-1',
          tipo: 'cambiar_estado',
          payload: {'cliente_id': 77, 'estado': 'suspendido'});
      final filas = await LocalDb.instance.mirrorPorIds('clientes', [77]);
      expect(filas.single['estado'], 'suspendido');
    });
  });

  group('#3 conteo de lo que la purga destruiría sin subir', () {
    test('cuenta comprobantes pendientes y elementos de incidencias privadas',
        () async {
      final db = await LocalDb.instance.db;
      // Comprobante pendiente (cuenta) y subido (no cuenta).
      await db.insert('comprobantes_pago', {
        'comprobante_uuid': 'comp-1',
        'estado': 'pendiente',
        'creado_en': '2026-11-04T08:00:00.000-04:00',
      });
      await db.insert('comprobantes_pago', {
        'comprobante_uuid': 'comp-2',
        'estado': 'subido',
        'creado_en': '2026-11-04T08:00:00.000-04:00',
      });
      // Incidencia privada local + su foto sin subir.
      await db.insert('incidencias_local', {
        'id': 'inc-priv-1',
        'tipo': 'otro',
        'descripcion': 'Incidencia privada de prueba',
        'creada_por': 'dueno',
        'creada_en': '2026-11-04T08:00:00.000-04:00',
        'visibilidad': 'privada',
      });
      await db.insert('incidencias_fotos', {
        'id': 'foto-1',
        'incidencia_id': 'inc-priv-1',
        'local_path': '/tmp/foto-1.jpg',
        'sync_estado': 'pending',
        'creado_en': '2026-11-04T08:00:00.000-04:00',
      });
      // Ops vivas de incidencias privadas: crear (por payload) y
      // cambiar_estado (por referencia). Una op APLICADA de una
      // compartida no debe contar.
      await _opCruda(
          uuid: 'i1',
          tipo: 'crear_incidencia',
          estado: 'pendiente',
          payload: {'visibilidad': 'privada'});
      await _opCruda(
          uuid: 'i2',
          tipo: 'cambiar_estado_incidencia',
          estado: 'error',
          payload: {'incidencia_id': 'inc-priv-1'});
      await _opCruda(
          uuid: 'i3',
          tipo: 'crear_incidencia',
          estado: 'pendiente',
          payload: {'visibilidad': 'compartida'});

      final c = await LocalDb.instance.conteoSinSubirQuePurgaria();
      expect(c.comprobantes, 1);
      // crear privada + cambiar_estado de la privada + su foto.
      expect(c.incidencias, 3);
    });

    test('sin nada pendiente: ceros', () async {
      final c = await LocalDb.instance.conteoSinSubirQuePurgaria();
      expect(c.comprobantes, 0);
      expect(c.incidencias, 0);
    });
  });

  group('delta panel A1: compensación de la marca al rechazo', () {
    test(
        'rechazo SIN pull intermedio: markOp revierte la marca y el '
        'pago vuelve a contar en el acto', () async {
      final hoy = hoyHabanaIso();
      await LocalDb.instance.upsertMirror('pagos', 501, {
        'cliente_id': 9001,
        'monto': 2000,
        'fecha': hoy,
        'metodo': 'efectivo',
        'periodo': 'mensual',
      }, 1);
      expect(await pagosRealizadosMes(), 1);
      expect(await ingresosHoy(), 2000);

      await LocalDb.instance.queueOp(
          opUuid: 'anul-r1',
          tipo: 'anular_pago',
          payload: {'pago_id': 501});
      expect(await pagosRealizadosMes(), 0);
      expect(await ingresosHoy(), 0);

      // El servidor rechaza la anulación. La transición va por
      // markOp (el embudo real del sync) y SIN ningún pull que
      // reescriba la fila: la compensación debe quitar la marca.
      await LocalDb.instance
          .markOp('anul-r1', 'rechazada', error: 'Rechazo de prueba');
      final db = await LocalDb.instance.db;
      final filas = await db.query('pagos', where: 'id=?', whereArgs: [501]);
      final data =
          jsonDecode(filas.single['data'] as String) as Map<String, dynamic>;
      expect(data.containsKey('anulado'), isFalse);
      expect(await LocalDb.instance.pagosAnuladosEnCola(),
          isNot(contains(501)));
      expect(await pagosRealizadosMes(), 1);
      expect(await ingresosHoy(), 2000);
    });

    test(
        'doble anulación del mismo pago: una rechazada y otra viva '
        '→ sigue excluido; al rechazarse la segunda, vuelve', () async {
      final hoy = hoyHabanaIso();
      await LocalDb.instance.upsertMirror('pagos', 503, {
        'cliente_id': 9003,
        'monto': 2000,
        'fecha': hoy,
        'metodo': 'efectivo',
        'periodo': 'mensual',
      }, 1);
      await LocalDb.instance.queueOp(
          opUuid: 'anul-d1',
          tipo: 'anular_pago',
          payload: {'pago_id': 503});
      await LocalDb.instance.queueOp(
          opUuid: 'anul-d2',
          tipo: 'anular_pago',
          payload: {'pago_id': 503});
      expect(await pagosRealizadosMes(), 0);

      // Se rechaza UNA: la otra sigue viva, la marca NO se toca.
      await LocalDb.instance
          .markOp('anul-d1', 'rechazada', error: 'Rechazo de prueba');
      final db = await LocalDb.instance.db;
      var filas = await db.query('pagos', where: 'id=?', whereArgs: [503]);
      var data =
          jsonDecode(filas.single['data'] as String) as Map<String, dynamic>;
      expect(data['anulado'], 1);
      expect(await pagosRealizadosMes(), 0);

      // Se rechaza la segunda: ya no queda anulación viva y la
      // compensación revierte la marca.
      await LocalDb.instance
          .markOp('anul-d2', 'rechazada', error: 'Rechazo de prueba');
      filas = await db.query('pagos', where: 'id=?', whereArgs: [503]);
      data =
          jsonDecode(filas.single['data'] as String) as Map<String, dynamic>;
      expect(data.containsKey('anulado'), isFalse);
      expect(await pagosRealizadosMes(), 1);
    });
  });

  group('delta panel A2: camino de datos del cierre de mi_turno', () {
    // El diálogo «Cierre de turno» de mi_turno.dart no es
    // testeable directo (State + AuthService); se fija aquí el
    // contrato de las funciones que invoca, con los ARGUMENTOS
    // que el diálogo usa tras el delta (los mismos de
    // TurnoService.desglosePendientes): pendientesParaEnvio(uid,
    // forzar: true, soloPropias: true) y
    // opsNecesitanRevision(userId: uid).
    test('solo entran las ops del usuario que cierra, incluso en backoff',
        () async {
      // Pendientes: de A (una lista y otra en backoff), de B y
      // una sin autor.
      await _opCruda(
          uuid: 'cA1', tipo: 'pago_mensual', estado: 'pendiente', userId: 'userA');
      await _opCruda(
          uuid: 'cA2',
          tipo: 'pago_mensual',
          estado: 'error',
          userId: 'userA',
          proximoReintento: '2027-01-01T00:00:00.000-04:00');
      await _opCruda(
          uuid: 'cB1', tipo: 'pago_mensual', estado: 'pendiente', userId: 'userB');
      await _opCruda(uuid: 'cN1', tipo: 'pago_mensual', estado: 'pendiente');
      // En revisión: de A, de B y sin autor.
      await _opCruda(
          uuid: 'cAr', tipo: 'pago_mensual', estado: 'necesita_revision', userId: 'userA');
      await _opCruda(
          uuid: 'cBr', tipo: 'pago_mensual', estado: 'necesita_revision', userId: 'userB');
      await _opCruda(
          uuid: 'cNr', tipo: 'pago_mensual', estado: 'necesita_revision');

      final pendientes = await LocalDb.instance.pendientesParaEnvio('userA',
          forzar: true, soloPropias: true);
      expect(pendientes.map((o) => o['op_uuid']).toSet(), {'cA1', 'cA2'});

      final bloqueadas =
          await LocalDb.instance.opsNecesitanRevision(userId: 'userA');
      expect(bloqueadas.map((o) => o['op_uuid']).toSet(), {'cAr'});

      // La semántica de forzar que el diálogo adopta: sin
      // forzar, la op en backoff NO se informa (por eso el
      // desglose y el diálogo fuerzan: es «lo pendiente del
      // turno», no «lo enviable ahora»).
      final sinForzar = await LocalDb.instance
          .pendientesParaEnvio('userA', soloPropias: true);
      expect(sinForzar.map((o) => o['op_uuid']).toSet(), {'cA1'});
    });
  });

  group('delta panel M1/N1: conteo de purga conservador', () {
    test(
        'M1: un subconteo que falla marca indeterminado y el aviso '
        'es la advertencia genérica, no «sin pérdida»', () async {
      final db = await LocalDb.instance.db;
      // Simula el fallo de lectura del escenario del panel
      // (tabla ausente/error de esquema): la recogida de ids
      // privados revienta y su catch la tragaba en silencio.
      await db.execute('DROP TABLE incidencias_local');
      final c = await LocalDb.instance.conteoSinSubirQuePurgaria();
      expect(c.indeterminado, isTrue);
      expect(await avisoPerdidaAlCerrarSesion(), avisoPerdidaIndeterminado);
    });

    test(
        'N1: fotos en error/uploading de una privada también cuentan '
        '(la purga las borra igual); la synced no', () async {
      final db = await LocalDb.instance.db;
      await db.insert('incidencias_local', {
        'id': 'inc-priv-9',
        'tipo': 'otro',
        'descripcion': 'Privada con fotos en varios estados',
        'creada_por': 'dueno',
        'creada_en': '2026-11-04T08:00:00.000-04:00',
        'visibilidad': 'privada',
      });
      for (final (id, estado) in [
        ('f-pen', 'pending'),
        ('f-err', 'error'),
        ('f-upl', 'uploading'),
        ('f-syn', 'synced'),
      ]) {
        await db.insert('incidencias_fotos', {
          'id': id,
          'incidencia_id': 'inc-priv-9',
          'local_path': '/tmp/$id.jpg',
          'sync_estado': estado,
          'creado_en': '2026-11-04T08:00:00.000-04:00',
        });
      }
      final c = await LocalDb.instance.conteoSinSubirQuePurgaria();
      expect(c.indeterminado, isFalse);
      // pending + error + uploading; synced está en el servidor.
      expect(c.incidencias, 3);
    });
  });
}
