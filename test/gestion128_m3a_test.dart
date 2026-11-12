/// Gestión 1.28 · Oleada M3-A (Servicios, turnos y nómina):
/// A1 cierre blindado · A2 derivados con lectura de dinero ·
/// A3 venta simple de varias dosis + Deshacer · A4 nómina (foto
/// única, bonos rechazados/recientes, flag texto) · A5/A8
/// reconciliación (lote, respaldo normalizado, hora honesta,
/// ventana) · A7 hub/franjas (minutos de pared, aperturas por
/// franja) · A9 datos sucios (fechas imposibles, Casa, precios
/// en texto) · A10 cadencia del manifiesto · A11 huella sin
/// decodificar · A12 apertura atómica.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_bonos.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/nomina_foto.dart';
import 'package:ironbody_gym/nomina_precalc.dart';
import 'package:ironbody_gym/nomina_total.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/turno_service.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tid = 969869611; // Duany

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _espejo(String tabla, int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {'id': id, 'data': jsonEncode(data), 'sync_seq': 1});
}

/// Fecha ISO de hace [dias] días (calendario en UTC, regla de la casa).
String _haceDias(int dias) {
  final h = ahoraHabana();
  final f = DateTime.utc(h.year, h.month, h.day - dias);
  return '${f.year.toString().padLeft(4, '0')}-'
      '${f.month.toString().padLeft(2, '0')}-'
      '${f.day.toString().padLeft(2, '0')}';
}

Future<void> _sembrarTurno(
    String turnoId, String fecha, String turno, String estado) async {
  await LocalDb.instance.insertarTurno(
    turnoId: turnoId,
    fechaTurno: fecha,
    turno: turno,
    horaApertura: '${fecha}T08:05:00-05:00',
    telegramId: _tid,
  );
  if (estado != 'abierto_local') {
    await LocalDb.instance.marcarEstadoTurno(turnoId, estado);
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await _bdVacia();
  });

  // ------------------------------------------------------------
  // A1 · marcarEstadoTurnoSi (el reclamo guardado)
  // ------------------------------------------------------------
  group('A1 cierre blindado', () {
    test('marca solo si el estado actual está en «desde»', () async {
      await _sembrarTurno('t-a1', _haceDias(1), 'manana', 'abierto_local');
      final n = await LocalDb.instance.marcarEstadoTurnoSi(
          't-a1', 'cerrado_local',
          desde: {'abierto_local', 'abierto_sincronizado', 'no_cerrado'});
      expect(n, 1);
      expect((await LocalDb.instance.getTurno('t-a1'))!['estado'],
          'cerrado_local');
    });

    test('no pisa un cerrado_sincronizado del servidor', () async {
      await _sembrarTurno(
          't-a1b', _haceDias(1), 'manana', 'cerrado_sincronizado');
      // La carrera cazada: confirmarCierre intentaba marcar
      // cerrado_local DESPUÉS de que el servidor ya cerró.
      final n = await LocalDb.instance.marcarEstadoTurnoSi(
          't-a1b', 'cerrado_local',
          desde: {'abierto_local', 'abierto_sincronizado', 'no_cerrado'});
      expect(n, 0);
      final t = await LocalDb.instance.getTurno('t-a1b');
      expect(t!['estado'], 'cerrado_sincronizado');
    });
  });

  // ------------------------------------------------------------
  // A12 · abrirTurnoAtomico
  // ------------------------------------------------------------
  group('A12 apertura atómica', () {
    test('inserta, marca el anterior no_cerrado y encola en la '
        'misma transacción', () async {
      await _sembrarTurno('t-viejo', _haceDias(1), 'manana', 'abierto_local');
      var encoladas = 0;
      final (id, creado) = await LocalDb.instance.abrirTurnoAtomico(
        turnoId: 't-nuevo',
        fechaTurno: hoyHabanaIso(),
        turno: 'manana',
        horaApertura: isoHabana(ahoraHabana()),
        telegramId: _tid,
        encolarApertura: (txn) async {
          encoladas++;
          await LocalDb.instance.queueOp(
            opUuid: 'op-apertura-1',
            tipo: 'apertura_turno',
            payload: {'turno_id': 't-nuevo'},
            txn: txn,
          );
        },
      );
      expect(creado, isTrue);
      expect(id, 't-nuevo');
      expect(encoladas, 1);
      expect((await LocalDb.instance.getTurno('t-viejo'))!['estado'],
          'no_cerrado');
      final op = await LocalDb.instance.opEnCola('op-apertura-1');
      expect(op, isNotNull);
    });

    test('segunda apertura del mismo (fecha, franja): no crea '
        'ni re-encola', () async {
      Future<(String, bool)> abrir() =>
          LocalDb.instance.abrirTurnoAtomico(
            turnoId: 't-x',
            fechaTurno: hoyHabanaIso(),
            turno: 'tarde',
            horaApertura: isoHabana(ahoraHabana()),
            telegramId: _tid,
            encolarApertura: (txn) async {
              await LocalDb.instance.queueOp(
                opUuid: 'op-ap-x',
                tipo: 'apertura_turno',
                payload: {'turno_id': 't-x'},
                txn: txn,
              );
            },
          );
      final (id1, c1) = await abrir();
      // Segundo intento con OTRO id candidato: gana el existente.
      final (id2, c2) = await LocalDb.instance.abrirTurnoAtomico(
        turnoId: 't-otro',
        fechaTurno: hoyHabanaIso(),
        turno: 'tarde',
        horaApertura: isoHabana(ahoraHabana()),
        telegramId: _tid,
        encolarApertura: (_) async =>
            fail('no debe encolar si ya existía'),
      );
      expect((id1, c1), ('t-x', true));
      expect((id2, c2), ('t-x', false));
    });

    test('un anterior ya cerrado en el servidor NO resucita a '
        'no_cerrado', () async {
      await _sembrarTurno(
          't-cerrado-srv', _haceDias(1), 'manana', 'cerrado_sincronizado');
      await LocalDb.instance.abrirTurnoAtomico(
        turnoId: 't-hoy',
        fechaTurno: hoyHabanaIso(),
        turno: 'manana',
        horaApertura: isoHabana(ahoraHabana()),
        telegramId: _tid,
        encolarApertura: (_) async {},
      );
      expect((await LocalDb.instance.getTurno('t-cerrado-srv'))!['estado'],
          'cerrado_sincronizado');
    });
  });

  // ------------------------------------------------------------
  // A5/A8 · reconciliación con el servidor
  // ------------------------------------------------------------
  group('A5/A8 reconciliación de cierres', () {
    test('hora de cierre honesta: queda NULL y el origen va en '
        'el snapshot', () async {
      final fecha = _haceDias(3);
      await _sembrarTurno('t-a8', fecha, 'tarde', 'abierto_sincronizado');
      await TurnoService.instance.reconciliarConServidorDe(_tid,
          traerCierres: () async => [
                {'turno_id': 't-a8', 'fecha': fecha, 'turno': 'tarde'}
              ]);
      final t = await LocalDb.instance.getTurno('t-a8');
      expect(t!['estado'], 'cerrado_sincronizado');
      expect(t['hora_cierre'], isNull,
          reason: 'la RPC no trae la hora real: no se fabrica');
      expect('${t['cierre_snapshot']}', contains('cierre_servidor'));
    });

    test('respaldo normalizado: fecha con hora y franja '
        '«Mañana» casan con la fila local', () async {
      final fecha = _haceDias(2);
      await _sembrarTurno('t-a8b', fecha, 'manana', 'abierto_local');
      await TurnoService.instance.reconciliarConServidorDe(_tid,
          traerCierres: () async => [
                {
                  'turno_id': 't-canonico-otro',
                  'fecha': '${fecha}T00:00:00',
                  'turno': 'Mañana',
                }
              ]);
      expect((await LocalDb.instance.getTurno('t-a8b'))!['estado'],
          'cerrado_sincronizado');
    });

    test('el respaldo por clave natural NO cierra mi apertura '
        'de HOY (sin turno_id casable)', () async {
      await _sembrarTurno(
          't-hoy-abierto', hoyHabanaIso(), 'manana', 'abierto_local');
      await TurnoService.instance.reconciliarConServidorDe(_tid,
          traerCierres: () async => [
                {
                  'turno_id': 't-otro-id',
                  'fecha': hoyHabanaIso(),
                  'turno': 'manana',
                }
              ]);
      expect((await LocalDb.instance.getTurno('t-hoy-abierto'))!['estado'],
          'abierto_local',
          reason: 'un cierre de hoy sin id casable es del flujo '
              'propio, no un rescate administrativo');
    });

    test('por turno_id SÍ cierra un turno de hoy', () async {
      await _sembrarTurno(
          't-hoy-id', hoyHabanaIso(), 'manana', 'abierto_local');
      await TurnoService.instance.reconciliarConServidorDe(_tid,
          traerCierres: () async => [
                {
                  'turno_id': 't-hoy-id',
                  'fecha': hoyHabanaIso(),
                  'turno': 'manana',
                }
              ]);
      expect((await LocalDb.instance.getTurno('t-hoy-id'))!['estado'],
          'cerrado_sincronizado');
    });

    test('cierres de más de 92 días se omiten', () async {
      final fecha = _haceDias(120);
      await _sembrarTurno('t-viejo-120', fecha, 'manana', 'abierto_local');
      await TurnoService.instance.reconciliarConServidorDe(_tid,
          traerCierres: () async => [
                {'turno_id': 't-viejo-120', 'fecha': fecha, 'turno': 'manana'}
              ]);
      expect((await LocalDb.instance.getTurno('t-viejo-120'))!['estado'],
          'abierto_local');
    });
  });

  // ------------------------------------------------------------
  // A7 · franjas y hub (puros)
  // ------------------------------------------------------------
  group('A7 franjas', () {
    test('instanteParedDeMinutos: negativos y más de un día', () {
      final f = DateTime(2026, 3, 8); // día de cambio de hora en Cuba
      expect(instanteParedDeMinutos(f, 6 * 60 - 45),
          DateTime(2026, 3, 8, 5, 15));
      expect(instanteParedDeMinutos(f, -30), DateTime(2026, 3, 7, 23, 30));
      expect(instanteParedDeMinutos(f, 1500), DateTime(2026, 3, 9, 1, 0));
    });

    test('huboAperturaEnFranja cuenta aperturas ya cerradas de '
        'ese día', () {
      final dia = DateTime(2026, 11, 2); // lunes
      AperturaTurno ap(int h, int m, {bool viva = true}) => (
            nombre: 'Duany',
            aperturaEn: DateTime(2026, 11, 2, h, m),
            viva: viva,
            cubreA: null,
          );
      expect(
          huboAperturaEnFranja(
              fecha: dia, franja: 'manana', aperturas: [ap(7, 0)]),
          isTrue);
      // Apertura de la mañana no cuenta para la tarde.
      expect(
          huboAperturaEnFranja(
              fecha: dia, franja: 'tarde', aperturas: [ap(7, 0)]),
          isFalse);
      // Aunque ya no esté viva (cerró), pasó: cuenta igual.
      expect(
          huboAperturaEnFranja(
              fecha: dia, franja: 'manana', aperturas: [ap(7, 0, viva: false)]),
          isTrue);
      // Domingo: sin franjas.
      expect(
          huboAperturaEnFranja(
              fecha: DateTime(2026, 11, 1),
              franja: 'manana',
              aperturas: const []),
          isFalse);
    });

    test('A9 correspondencia: telegram en texto casa con el de '
        'número y NO cae a nombres', () {
      final apertura = {
        'turno': 'manana',
        'telegram_id': 969869611,
        'entrenador_nombre': 'Duany',
        'fecha_turno': '2026-11-02',
        'hora_apertura': '2026-11-02T07:00:00',
      };
      final cierreTexto = {
        'turno': 'manana',
        'telegram_id': '969869611', // el espejo lo trae como texto
        'entrenador_nombre': 'Otro Nombre',
        'fecha': '2026-11-02',
      };
      expect(cierreCorrespondeApertura(cierreTexto, apertura), isTrue);
      final cierreOtro = {
        'turno': 'manana',
        'telegram_id': '1403501391',
        'entrenador_nombre': 'Duany', // mismo nombre, otro telegram
        'fecha': '2026-11-02',
      };
      expect(cierreCorrespondeApertura(cierreOtro, apertura), isFalse,
          reason: 'con telegram en ambos lados manda el telegram, '
              'no el nombre');
    });
  });

  // ------------------------------------------------------------
  // A2/A11 · derivados de Servicios
  // ------------------------------------------------------------
  group('A2/A11 servicios', () {
    Future<void> sembrarPomo() async {
      await _espejo('servicio_pomos', 10, {
        'suplemento_id': 1,
        'titular_telegram_id': _tid,
        'es_principal': 0,
        'dosis_asignadas': 10,
        'dosis_repartidas': 0,
        'activo': 1,
      });
      await LocalDb.instance
          .setMeta('ajustes', jsonEncode({'servicio_comision_dosis': 50}));
    }

    test('A2: una venta en estado «enviada» SÍ descuenta del '
        'saldo (no hay sobreventa)', () async {
      await sembrarPomo();
      await LocalDb.instance.queueOp(
        opUuid: 'op-v-enviada',
        tipo: 'venta_servicio',
        payload: {
          'tipo': 'dosis_sin_agua',
          'pomo_id': 10,
          'cantidad': 3,
        },
      );
      final d = await LocalDb.instance.db;
      await d.update('ops_queue', {'estado': 'enviada'},
          where: 'op_uuid = ?', whereArgs: ['op-v-enviada']);
      expect(await saldoPomoLocal(10), 7,
          reason: 'con pendingOps la op enviada desaparecía del '
              'derivado y el saldo volvía a 10');
    });

    test('A11: el saldo lee solo las ventas del pomo (las de '
        'otro pomo no contaminan)', () async {
      await sembrarPomo();
      await _espejo('servicio_ventas', 1, {
        'pomo_id': 10,
        'cantidad': 2,
        'op_uuid': 'v-propia',
      });
      await _espejo('servicio_ventas', 2, {
        'pomo_id': 99,
        'cantidad': 5,
        'op_uuid': 'v-ajena',
      });
      expect(await saldoPomoLocal(10), 8);
    });

    test('A3: la simple rechaza varias dosis; la múltiple las '
        'vende y el Deshacer borra también en «error»', () async {
      await sembrarPomo();
      await _espejo('servicio_agua_movimientos', 1, {
        'tipo': 'entrada',
        'cantidad': 10,
        'costo_unitario': 50,
      });
      await expectLater(
        registrarVentaServicio(
          tipo: 'dosis_sin_agua',
          pomoId: 10,
          cantidad: 3,
          metodo: 'efectivo',
          vendedorEsDueno: false,
          actorEsDueno: false,
        ),
        throwsA(predicate((e) => '$e'.contains('de una en una'))),
      );
      final uuids = await registrarVentaMultipleServicio(
        pomoId: 10,
        dosisN: 3,
        pomosM: 0,
        metodo: 'efectivo',
        vendedorEsDueno: false,
        actorEsDueno: false,
        topeDosis: 10,
        topePomos: 10,
      );
      expect(uuids, hasLength(1));
      expect(await saldoPomoLocal(10), 7);
      // La op pasa a 'error' (fallo de red recuperable): el
      // Deshacer debe seguir pudiendo borrarla (la comprobación
      // y el borrado discreparon hasta la 1.28).
      final d = await LocalDb.instance.db;
      await d.update('ops_queue', {'estado': 'error'},
          where: 'op_uuid = ?', whereArgs: [uuids.single]);
      expect(await deshacerVentaServicio(uuids, ahoraHabana()), isTrue);
      expect(await LocalDb.instance.opEnCola(uuids.single), isNull);
      expect(await saldoPomoLocal(10), 10);
    });

    test('A3: «enviada» nunca se deshace', () async {
      await LocalDb.instance.queueOp(
        opUuid: 'op-v-env2',
        tipo: 'venta_servicio',
        payload: {'tipo': 'dosis_sin_agua'},
      );
      final d = await LocalDb.instance.db;
      await d.update('ops_queue', {'estado': 'enviada'},
          where: 'op_uuid = ?', whereArgs: ['op-v-env2']);
      expect(await deshacerVentaServicio(['op-v-env2'], ahoraHabana()),
          isFalse);
      expect(await LocalDb.instance.opEnCola('op-v-env2'), isNotNull);
    });
  });

  // ------------------------------------------------------------
  // A9 · datos sucios (puros)
  // ------------------------------------------------------------
  group('A9 datos sucios', () {
    test('diaSemanaHabana: fecha imposible → null (no se '
        'normaliza a otra)', () {
      expect(diaSemanaHabana('2026-02-31'), isNull);
      expect(diaSemanaHabana('2026-11-07'), 6); // sábado
      expect(diaSemanaHabana('2026-13-01'), isNull);
      expect(diaSemanaHabana(null), isNull);
    });

    test('esCasaTolerante: 1, true y «1» valen; el resto no', () {
      expect(esCasaTolerante(1), isTrue);
      expect(esCasaTolerante(true), isTrue);
      expect(esCasaTolerante('1'), isTrue);
      expect(esCasaTolerante(0), isFalse);
      expect(esCasaTolerante('0'), isFalse);
      expect(esCasaTolerante(false), isFalse);
      expect(esCasaTolerante(null), isFalse);
    });

    test('precios en texto: precioServicioMetodo y '
        'metodoServicioActivo no lanzan ni inventan', () {
      final ajustes = <String, dynamic>{
        'servicio_precio_sin_agua': '600',
        'servicio_precios_metodo': {
          'racion': {'efectivo': '650', 'activo_efectivo': '0'},
        },
      };
      expect(precioServicioMetodo(ajustes, 'dosis_sin_agua', 'efectivo'),
          650);
      expect(precioServicioMetodo(ajustes, 'dosis_con_agua', 'efectivo'),
          900); // default intacto
      expect(metodoServicioActivo(ajustes, 'dosis_sin_agua', 'efectivo'),
          isFalse,
          reason: 'un «0» en texto desactivaba el método: antes '
              'caía al «todo habilitado»');
      expect(metodoServicioActivo(ajustes, 'dosis_sin_agua', 'transferencia'),
          isTrue);
    });
  });

  // ------------------------------------------------------------
  // A4 · nómina
  // ------------------------------------------------------------
  group('A4 nómina', () {
    test('fusión: un bono rechazado se MUESTRA marcado y NO '
        'suma', () {
      final fusion = fusionarBonosNomina(
        espejo: const [],
        opsPendientes: const [],
        opsRechazadas: [
          {
            'tipo': kTipoOpRegistrarBonoNomina,
            'payload': jsonEncode({
              'bono_uuid': 'b-rech',
              'mes': '2026-11',
              'entrenador': 'duany',
              'monto': 500,
              'nota': 'extra',
              'creado_en': '2026-11-05T10:00:00',
            }),
          },
        ],
      );
      expect(fusion, hasLength(1));
      expect(fusion.single['rechazado'], isTrue);
      expect(NominaCalc.bonosPara(fusion, 'duany'), 0,
          reason: 'el dinero rechazado no se paga');
      expect(NominaCalc.bonoSoloAmbos(fusion), 0);
    });

    test('fusión: el flag eliminada como TEXTO «1» también '
        'descarta la fila', () {
      final fusion = fusionarBonosNomina(
        espejo: [
          {
            'bono_uuid': 'b-txt',
            'mes': '2026-11',
            'entrenador': 'ambos',
            'monto': 300,
            'eliminada': '1',
          },
        ],
        opsPendientes: const [],
      );
      expect(fusion, isEmpty,
          reason: 'con el cast estricto la fila RESUCITABA');
    });

    test('servicio: rechazada visible y aplicada reciente sin '
        'espejar también (sin parpadeo)', () async {
      final mes = hoyHabanaIso().substring(0, 7);
      // Bono rechazado por el servidor.
      await LocalDb.instance.queueOp(
        opUuid: 'op-b-rech',
        tipo: kTipoOpRegistrarBonoNomina,
        payload: {
          'bono_uuid': 'b-rech-srv',
          'mes': mes,
          'entrenador': 'gabriel',
          'monto': 700,
          'nota': '',
          'creado_en': isoHabana(ahoraHabana()),
        },
      );
      // Bono APLICADO hace un minuto, aún sin bajar al espejo.
      await LocalDb.instance.queueOp(
        opUuid: 'op-b-apl',
        tipo: kTipoOpRegistrarBonoNomina,
        payload: {
          'bono_uuid': 'b-apl-srv',
          'mes': mes,
          'entrenador': 'gabriel',
          'monto': 200,
          'nota': '',
          'creado_en': isoHabana(ahoraHabana()),
        },
      );
      final d = await LocalDb.instance.db;
      await d.update('ops_queue', {'estado': 'rechazada'},
          where: 'op_uuid = ?', whereArgs: ['op-b-rech']);
      await d.update('ops_queue', {'estado': 'aplicada'},
          where: 'op_uuid = ?', whereArgs: ['op-b-apl']);

      final bonos = await BonosNominaService.instance.leerBonos(mes);
      final porUuid = {for (final b in bonos) '${b['bono_uuid']}': b};
      expect(porUuid.keys, containsAll(['b-rech-srv', 'b-apl-srv']));
      expect(porUuid['b-rech-srv']!['rechazado'], isTrue);
      expect(porUuid['b-apl-srv']!['rechazado'], isNot(true));
      // Solo suma el aplicado (200), no el rechazado (700).
      expect(NominaCalc.bonosPara(bonos, 'gabriel'), 200);
    });

    test('totalNetoNominaMes sale de la foto: foto incompleta '
        '→ null; completa → cifra', () async {
      final pref = hoyHabanaIso().substring(0, 7);
      // Sin usuarios_apk: la foto no tiene personas → null
      // (antes esta función devolvía una cifra ensamblada por
      // su cuenta, distinta de la del Panel).
      expect(await totalNetoNominaMes(pref), isNull);
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {
              'id': 'uid-d',
              'telegram_id': _tid,
              'nombre': 'Duany',
              'username': 'duany',
            },
            {
              'id': 'uid-g',
              'telegram_id': 1403501391,
              'nombre': 'Gabriel',
              'username': 'gabriel',
            },
          ]));
      final total = await totalNetoNominaMes(pref);
      expect(total, isNotNull);
      // Sin pagos ni extras, la cifra de la foto es 0.
      final foto = await fotoNominaMes(pref);
      final esperado = netoTotalDueno(foto,
          clientesPagados: await NominaPrecalc.instance.asegurar(pref),
          bonos: await leerBonosMesConMigracion(pref));
      expect(total, esperado);
    });
  });

  // ------------------------------------------------------------
  // A10 · cadencia del manifiesto
  // ------------------------------------------------------------
  group('A10 manifiesto', () {
    test('un intento fallido acota el reintento a una vez al '
        'día (y nunca se sella como OK)', () async {
      var llamadas = 0;
      Future<int> fake() async {
        llamadas++;
        return -1;
      }

      await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake);
      expect(llamadas, 1);
      expect(await LocalDb.instance.getMeta('ultimo_manifiesto'), isNull,
          reason: 'un fallo jamás se sella como verificación buena');
      expect(await LocalDb.instance.getMeta('manifiesto_intento_fallido'),
          hoyHabanaIso());
      await SyncEngine.instance.manifiestoDiarioSiToca(verificar: fake);
      expect(llamadas, 1,
          reason: 'el segundo ciclo del mismo día no re-martillea '
              'la RPC caída');
    });
  });

  // ------------------------------------------------------------
  // A11 · huella del precálculo
  // ------------------------------------------------------------
  group('A11 huella', () {
    test('prefijo v6: un campo de negocio cambia la huella y '
        'uno ajeno no (contrato v5, sin decodificar)', () async {
      await _espejo('clientes', 10, {
        'nombre': 'Cliente 10',
        'pagado_hasta': '2026-12-15',
      });
      await _espejo('pagos', 1, {
        'cliente_id': 10,
        'fecha': '2026-11-05',
        'periodo': 'mensual',
        'metodo': 'efectivo',
        'monto': 2000,
        'pagado_hasta': '2026-12-05',
        'registrado_por': 'Jc',
      });
      final h1 = await NominaPrecalc.instance.huella();
      expect(h1, startsWith('v6|'));
      final d = await LocalDb.instance.db;
      Future<void> tocarPago(Map<String, dynamic> cambios) async {
        final filas = await d.query('pagos', where: 'id = 1');
        final data = jsonDecode(filas.single['data'] as String)
            as Map<String, dynamic>;
        data.addAll(cambios);
        await d.update('pagos', {'data': jsonEncode(data)},
            where: 'id = 1');
      }

      // Campo ajeno al conteo: la huella NO cambia (contrato
      // fijado por los tests de la 1.15).
      await tocarPago({'registrado_por': 'Otro'});
      expect(await NominaPrecalc.instance.huella(), h1);
      // Representación equivalente del monto: tampoco.
      await tocarPago({'monto': '2000'});
      expect(await NominaPrecalc.instance.huella(), h1);
      // Campo de negocio: invalida.
      await tocarPago({'metodo': 'transferencia'});
      expect(await NominaPrecalc.instance.huella(), isNot(h1));
    });
  });
}
