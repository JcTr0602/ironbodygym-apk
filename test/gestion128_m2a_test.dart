/// Gestión 1.28 · oleada M2-A (Dinero y caja): regresiones de
/// los ítems A1–A11 contra el código vivo.
///
///  A1  la segunda liquidación en cola del mismo
///      entrenador+moneda se rechaza en el servicio.
///  A2  pendienteArqueo y idsPendienteArqueo salen de la
///      MISMA decisión por fila (corrección hacia dentro /
///      hacia fuera, anulación en cola, registro sin espejo);
///      el libro C1 sale de las listas de detalle y de los
///      ids confirmables; el detalle de hoy no suma diarios
///      por transferencia.
///  A3  contribucionLibroC1 no resta un pago con anulación
///      en cola; la selección FIFO de la entrega C1 tampoco
///      lo marca.
///  A4  corrección+anulación en cola netean a cero en AMBAS
///      gavetas (fantasma); corregirOrigen hereda la guarda
///      G2 de registrar().
///  A5  el desglose por método parte los diarios por su
///      método real (global y por entrenador).
///  A6  precio de menores de UNA fuente: el tipo del blob
///      manda sobre la clave fija (pura + integración).
///  A7  gastos gemelos legítimos sobreviven al cruce con el
///      espejo (multiplicidad); un monto como texto no tumba
///      los totales.
///  A9  idsLiquidados normaliza el id 185.0; conteoPagosDia
///      excluye las promos; cobradoHoyPorMetodo usa la fecha
///      de negocio (no el substring UTC) para servicios.
///  A10 la marca de conciliación en cola se ve en la bandeja
///      y la segunda marca se rechaza.
///  A11 fotoIngresosDashboard == las diez funciones sueltas
///      sobre la misma foto sembrada.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/conciliacion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

int _seq = 42000;
int _opN = 0;

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

Future<void> _op(String tipo, Map<String, dynamic> payload) =>
    LocalDb.instance.queueOp(
      opUuid: 'm2a-op-${_opN++}',
      tipo: tipo,
      payload: payload,
    );

Future<void> _limpiar(Database db) async {
  for (final t in [
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
    'adelantos',
    'liquidaciones_caja',
    'entregas_efectivo',
    'espejo_entregas_efectivo',
    'clientes',
    'gastos',
    'ops_queue',
  ]) {
    await db.delete(t);
  }
  await db.delete('meta', where: 'k = ?', whereArgs: ['ajustes']);
}

Future<Database> _dbLimpia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await _limpiar(db);
  return db;
}

Future<void> _initDummy() async {
  SharedPreferences.setMockInitialValues({});
  await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
}


/// Los servicios disparan ciclos de sync en segundo plano
/// que se serializan con el lock del motor: esperar un push
/// propio garantiza que todos los ciclos encolados ya
/// terminaron y ningún resetParaTest posterior los pilla a
/// mitad contra la BD cerrada (database_closed).
Future<void> _drenarSync() async {
  try {
    await SyncEngine.instance
        .push()
        .timeout(const Duration(seconds: 30), onTimeout: () {
      throw TimeoutException('drenaje de sync');
    });
  } catch (_) {
    // Sin sesión o sin red en el test: el ciclo no corre y
    // no queda nada vivo que drenar.
  }
}

String get _hoy => hoyHabanaIso();
String get _pref => _hoy.substring(0, 7);

Map<String, dynamic> _pago(
  int id, {
  required double monto,
  String metodo = 'efectivo',
  int tid = 111,
  int clienteId = 7,
  String? fecha,
  int entregado = 0,
}) =>
    {
      'id': id,
      'cliente_id': clienteId,
      'fecha': fecha ?? _hoy,
      'monto': monto,
      'metodo': metodo,
      'entregado': entregado,
      'telegram_user_id': tid,
    };

Future<void> _sembrarPago(Database db, Map<String, dynamic> p) =>
    _espejo(db, 'pagos', (p['id'] as num).toInt(), p, cols: {
      'fecha': p['fecha'],
      'cliente_id': p['cliente_id'],
      'telegram_user_id': p['telegram_user_id'],
      'metodo': p['metodo'],
    });

Map<String, dynamic> _adelanto(
  int id, {
  required double monto,
  int? descuentaA = 111,
  String metodo = 'efectivo',
  String origen = 'caja_turno',
  int enPendiente = 1,
}) =>
    {
      'id': id,
      'entrenador': 'duany',
      'entrenador_nombre': 'Duany',
      'monto': monto,
      'metodo': metodo,
      'origen': origen,
      'descuenta_a': descuentaA,
      'en_pendiente': enPendiente,
      'mes_nomina': _pref,
      'fecha': _hoy,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M2-A sin sesión (espejo + cola)', () {
    setUp(() async {
      await _initDummy();
    });

    tearDown(() async {
      await _drenarSync();
    });

    test('A2: par esperado/ids con overlay completo de adelantos',
        () async {
      final db = await _dbLimpia();
      const tid = 111;
      await _sembrarPago(db, _pago(1, monto: 2000, tid: tid));
      // 10: gaveta de OTRO (222); corrección en cola lo trae.
      await _espejo(db, 'adelantos', 10,
          _adelanto(10, monto: 300, descuentaA: 222));
      // 11: gaveta de 111; corrección en cola lo saca.
      await _espejo(db, 'adelantos', 11, _adelanto(11, monto: 200));
      // 12: gaveta de 111; anulación en cola.
      await _espejo(db, 'adelantos', 12, _adelanto(12, monto: 150));
      await _op('corregir_origen_adelanto', {
        'adelanto_id': 10,
        'nuevo_origen': 'caja_turno',
        'descuenta_a': tid,
      });
      await _op('corregir_origen_adelanto', {
        'adelanto_id': 11,
        'nuevo_origen': 'fondo_dueno',
      });
      await _op('anular_adelanto', {'adelanto_id': 12});
      // Registro aún sin espejo: descuenta del total en mano
      // pero NO puede entrar al esperado de la liquidación.
      await _op('registrar_adelanto', {
        'entrenador': 'duany',
        'monto': 250,
        'origen': 'caja_turno',
        'metodo': 'efectivo',
        'descuenta_a': tid,
      });

      final arq = await pendienteArqueo(tid);
      expect(arq.cup, 1700,
          reason: 'esperado = 2000 − 300 (solo el corregido '
              'hacia dentro, ya espejado)');
      final ids = await idsPendienteArqueo(tid);
      expect(ids['adelantos'], [10],
          reason: 'la lista y el monto salen de la misma foto');
      expect(ids['pagos'], [1]);
      // Total en mano: sí incluye el registro en cola.
      expect(await adelantosEnPendiente(tid), 550);
      expect(await pendienteEntrega(tid), 1450);
    });

    test('A4: corrección + anulación en cola netean a cero en '
        'ambas gavetas', () async {
      await _dbLimpia();
      final espejo = [_adelanto(13, monto: 400, descuentaA: 222)];
      final ops = <Map<String, dynamic>>[
        {
          'tipo': 'corregir_origen_adelanto',
          'payload': jsonEncode({
            'adelanto_id': 13,
            'nuevo_origen': 'caja_turno',
            'descuenta_a': 111,
          }),
        },
        {
          'tipo': 'anular_adelanto',
          'payload': jsonEncode({'adelanto_id': 13}),
        },
      ];
      double suma(int tid) => sumaAdelantosPendientes(
            espejo: espejo,
            opsPendientes: ops,
            telegramId: tid,
            normalizarTid: LocalDb.normalizarTelegramId,
          );
      expect(suma(111), 0,
          reason: 'antes sumaba 400 por la gaveta NUEVA');
      expect(suma(222), 0,
          reason: 'antes restaba 400 por la gaveta VIEJA');
    });

    test('A4: corregirOrigen exige gaveta para caja+efectivo '
        '(guarda G2)', () async {
      final db = await _dbLimpia();
      await _espejo(db, 'adelantos', 30,
          _adelanto(30, monto: 100, origen: 'fondo_dueno'));
      await expectLater(
        AdelantosService.instance.corregirOrigen(30,
            nuevoOrigen: 'caja_turno',
            descuentaA: null,
            entrenadorId: 'duany',
            mesNomina: _pref),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message',
                contains('Falta la gaveta'))),
      );
      await AdelantosService.instance.corregirOrigen(30,
          nuevoOrigen: 'caja_turno',
          descuentaA: 111,
          entrenadorId: 'duany',
          mesNomina: _pref);
      final ops = await LocalDb.instance.pendingOpsLectura();
      expect(
          ops.where((o) => o['tipo'] == 'corregir_origen_adelanto'),
          hasLength(1));
    });

    test('A3: el libro C1 no resta un pago con anulación en '
        'cola', () async {
      final db = await _dbLimpia();
      await _sembrarPago(db, _pago(7, monto: 600));
      await db.insert('entregas_efectivo', {
        'op_uuid': 'm2a-e1',
        'entrenador_telegram_id': 111,
        'monto_entregado': 600,
        'fecha_habana': _hoy,
        'autor_dueno_id': 735772141,
        'creada_ts': _hoy,
        'op_ids_json': jsonEncode({'pagos': [7]}),
        'resto_sin_ids': 0,
      });
      expect(await contribucionLibroC1(111), 600,
          reason: 'control: sin anulación, el libro resta');
      await _op('anular_pago', {'pago_id': 7});
      expect(await contribucionLibroC1(111), 0,
          reason: 'el total ya excluye el pago anulado: el '
              'libro no puede restarlo otra vez');
    });

    test('A2: el libro C1 sale de detalle, lista plana e ids '
        'confirmables', () async {
      final db = await _dbLimpia();
      await _sembrarPago(db, _pago(5, monto: 800));
      await db.insert('entregas_efectivo', {
        'op_uuid': 'm2a-e2',
        'entrenador_telegram_id': 111,
        'monto_entregado': 800,
        'fecha_habana': _hoy,
        'autor_dueno_id': 735772141,
        'creada_ts': _hoy,
        'op_ids_json': jsonEncode({'pagos': [5]}),
        'resto_sin_ids': 0,
      });
      final detalle = await detallePendienteEntrenador(111);
      expect(detalle.where((i) => i['pago_id'] == 5), isEmpty);
      final plana = await pagosPendientesDetalle();
      expect(
          plana.where((i) => i['id'] == 5 && i['tipo'] == 'mensual'),
          isEmpty);
      final ids = await idsPendientesEntrega(trainerId: 111);
      expect(ids.pagos, isNot(contains(5)));
    });

    test('A2: el detalle de hoy no suma diarios por '
        'transferencia', () async {
      final db = await _dbLimpia();
      await _espejo(db, 'pagos_diarios', 1, {
        'id': 1,
        'fecha': _hoy,
        'total': 200,
        'metodo': 'transferencia',
        'entregado': 0,
        'registrado_por': 111,
      });
      await _espejo(db, 'pagos_diarios', 2, {
        'id': 2,
        'fecha': _hoy,
        'total': 200,
        'metodo': 'efectivo',
        'entregado': 0,
        'registrado_por': 111,
      });
      final d = await pendienteDetalleHoy(111);
      expect(d['diarios'], 200);
      expect(d['n'], 1);
    });

    test('A5: el desglose por método parte los diarios por su '
        'método real', () async {
      final db = await _dbLimpia();
      await _sembrarPago(db, _pago(1, monto: 2000, entregado: 1));
      await _espejo(db, 'pagos_diarios', 1, {
        'id': 1,
        'fecha': _hoy,
        'total': 500,
        'metodo': 'transferencia',
        'registrado_por': 111,
      });
      await _espejo(db, 'pagos_diarios', 2, {
        'id': 2,
        'fecha': _hoy,
        'total': 200,
        'metodo': 'efectivo',
        'registrado_por': 111,
      });
      final global = await ingresosPorMetodo();
      expect(global['efectivo'], 2200);
      expect(global['transferencia'], 500,
          reason: 'antes el diario por transferencia inflaba '
              'el efectivo (2700) y la transferencia salía 0');
      final porEnt = await ingresosPorMetodoEntrenador(111);
      expect(porEnt['efectivo'], 2200); // el pago sembrado también es suyo
      expect(porEnt['transferencia'], 500);
    });

    test('A6: precio de menores de una sola fuente', () async {
      // Pura: el tipo del blob manda sobre la clave fija.
      expect(
          precioMenoresDesdeAjustes({
            'tipos_pago': [
              {'id': 'menores', 'monto': 1800}
            ],
            'mensualidad_menores': 1500,
          }),
          1800);
      expect(
          precioMenoresDesdeAjustes({'mensualidad_menores': 1600}),
          1600);
      expect(precioMenoresDesdeAjustes({}), 1500);
      expect(
          precioMenoresDesdeAjustes({
            'tipos_pago': [
              {'id': 'menores', 'monto': 0}
            ],
            'mensualidad_menores': 1700,
          }),
          1700,
          reason: 'un tipo en 0 no es un precio: manda el '
              'respaldo');
      // Integración: Inscribir (precioMenor) y los precios
      // vigentes leen la MISMA fuente que el diálogo.
      final db = await _dbLimpia();
      await LocalDb.instance.setMeta(
          'ajustes',
          jsonEncode({
            'tipos_pago': [
              {
                'id': 'menores',
                'nombre': 'Mensualidad menores',
                'monto': 1800,
                'dias': 30,
                'solo_menores': true,
              }
            ],
            'mensualidad_menores': 1500,
          }));
      expect(await precioMenor(), 1800,
          reason: 'antes precioMenor jamás alcanzaba el tipo '
              'y cobraba la clave fija (1500)');
      expect((await preciosVigentes())['menores'], 1800);
      expect(db, isNotNull); // la limpieza no dejó residuos
    });

    test('A7: dos gastos gemelos legítimos no se tragan entre '
        'sí; monto como texto no tumba los totales', () async {
      final db = await _dbLimpia();
      await _espejo(db, 'gastos', 1,
          {'id': 1, 'fecha': _hoy, 'concepto': 'Agua', 'monto': 100});
      await _op('gasto',
          {'fecha': _hoy, 'concepto': 'Agua', 'monto': 100});
      await _op('gasto',
          {'fecha': _hoy, 'concepto': 'Agua', 'monto': 100});
      final todos = await gastosTodos();
      final aguas = todos.where((g) => g['concepto'] == 'Agua');
      expect(aguas, hasLength(2),
          reason: 'espejo (1) + UN pendiente: el otro pendiente '
              'es el gemelo del espejo; el cruce por conjunto '
              'escondía TAMBIÉN el segundo');
      expect(
          aguas.fold<double>(
              0, (s, g) => s + (g['monto'] as num).toDouble()),
          200);
      // Monto como texto en el espejo: suma, no revienta.
      await _limpiar(db);
      await _espejo(db, 'gastos', 2, {
        'id': 2,
        'fecha': _hoy,
        'concepto': 'Luz',
        'monto': '1500',
      });
      expect(await gastosDe(_hoy), 1500);
      expect(await gastosDelMes(_pref), 1500);
    });

    test('A9: idsLiquidados normaliza 185.0; conteoPagosDia '
        'excluye promos; cobradoHoy usa la fecha de negocio',
        () async {
      final db = await _dbLimpia();
      await _espejo(db, 'liquidaciones_caja', 1, {
        'id': 1,
        'entrenador_telegram_id': 111,
        'estado': 'completa',
        'op_ids': jsonEncode({
          'pagos': [185.0]
        }),
      });
      expect(await idsLiquidados(111), contains('pagos:185'),
          reason: "la clave cruda era 'pagos:185.0' y jamás "
              'casaba con la de los demás lectores');

      await _sembrarPago(
          db, _pago(1, monto: 0, metodo: 'promo'));
      await _sembrarPago(db, _pago(2, monto: 2000));
      expect(await conteoPagosDia(111), 1,
          reason: 'la promo (monto 0) no es un cobro del día');

      // Servicio cobrado a las 02:00 UTC = 21:00 Habana del
      // día ANTERIOR: por substring crudo era «de hoy».
      await _espejo(db, 'servicio_ventas', 1, {
        'id': 1,
        'fecha': '${_hoy}T02:00:00.000Z',
        'precio_unitario': 100,
        'cantidad': 1,
        'metodo': 'efectivo',
        'casa': 0,
        'registrado_por': 111,
      });
      await _espejo(db, 'servicio_ventas', 2, {
        'id': 2,
        'fecha': _hoy,
        'precio_unitario': 50,
        'cantidad': 1,
        'metodo': 'efectivo',
        'casa': 0,
        'registrado_por': 111,
      });
      final cobrado = await cobradoHoyPorMetodo();
      expect(cobrado['efectivo'], 2050,
          reason: 'pago de hoy (2000) + servicio de hoy (50); '
              'el servicio de las 02:00 UTC es de AYER en '
              'La Habana y no entra (con el substring crudo '
              'sumaría 2150)');
    });

    test('A10: la marca en cola se ve y la segunda se rechaza',
        () async {
      final db = await _dbLimpia();
      await _sembrarPago(db,
          _pago(40, monto: 2500, metodo: 'transferencia')
            ..['conciliacion'] = 'pendiente');
      var rows = await ConciliacionService.instance.transferencias();
      expect(rows.single['_conciliacion'], 'pendiente');
      expect(
          await ConciliacionService.instance.conteoPorComprobar(),
          1);
      await ConciliacionService.instance.marcar(
          pagoId: 40, estado: 'comprobada', estadoEsperado: 'pendiente');
      rows = await ConciliacionService.instance.transferencias();
      expect(rows.single['_conciliacion'], 'comprobada',
          reason: 'el overlay de la cola manda sobre el espejo '
              'viejo');
      expect(rows.single['_conciliacionEnCola'], isTrue);
      expect(
          await ConciliacionService.instance.conteoPorComprobar(),
          0);
      await expectLater(
        ConciliacionService.instance.marcar(
            pagoId: 40,
            estado: 'problema',
            estadoEsperado: 'pendiente',
            nota: 'x'),
        throwsA(isA<StateError>()),
      );
    });

    test('A11: la foto del Dashboard coincide con las diez '
        'funciones sueltas', () async {
      final db = await _dbLimpia();
      final hace5 = sumarDiasIso(_hoy, -5);
      final p = _hoy.split('-').map(int.parse).toList();
      final primeroAnt =
          DateTime.utc(p[0], p[1] - 1, 1);
      final diaMesAnt = '${primeroAnt.year.toString().padLeft(4, '0')}-'
          '${primeroAnt.month.toString().padLeft(2, '0')}-15';
      await _sembrarPago(db, _pago(1, monto: 2000));
      await _sembrarPago(
          db, _pago(2, monto: 2500, metodo: 'transferencia', clienteId: 8));
      await _sembrarPago(
          db, _pago(3, monto: 1200, fecha: hace5, tid: 222));
      await _sembrarPago(
          db, _pago(4, monto: 1500, fecha: diaMesAnt, clienteId: 8));
      await _sembrarPago(
          db, _pago(5, monto: 999, clienteId: 99)); // Casa
      await _sembrarPago(
          db, _pago(6, monto: 700, clienteId: 8)); // anulado en cola
      await _espejo(db, 'clientes', 99,
          {'id': 99, 'nombre': 'Casa', 'cuenta_casa': 1},
          cols: {'cuenta_casa': 1});
      await _op('anular_pago', {'pago_id': 6});
      await _espejo(db, 'pagos_diarios', 1, {
        'id': 1,
        'fecha': _hoy,
        'total': 200,
        'metodo': 'efectivo',
        'registrado_por': 111,
      });
      await _espejo(db, 'pagos_diarios', 2, {
        'id': 2,
        'fecha': _hoy,
        'total': 300,
        'metodo': 'transferencia',
        'registrado_por': 111,
      });
      await _espejo(db, 'pagos_diarios', 3, {
        'id': 3,
        'fecha': diaMesAnt,
        'total': 400,
        'metodo': 'efectivo',
        'registrado_por': 222,
      });
      await _espejo(
          db,
          'ventas_suplementos',
          1,
          {
            'id': 1,
            'fecha': _hoy,
            'total': 350,
            'moneda': 'CUP',
            'registrado_por': 111,
            'entregado': 0,
          },
          cols: {'moneda': 'CUP'});
      await _espejo(
          db,
          'ventas_suplementos',
          2,
          {
            'id': 2,
            'fecha': _hoy,
            'total': 20,
            'moneda': 'USD',
            'registrado_por': 111,
            'entregado': 0,
          },
          cols: {'moneda': 'USD'});
      await _espejo(db, 'servicio_ventas', 1, {
        'id': 1,
        'fecha': _hoy,
        'precio_unitario': 100,
        'cantidad': 2,
        'metodo': 'efectivo',
        'registrado_por': 111,
        'casa': 0,
      });
      // Par original + reverso: netos quedan fuera.
      await _espejo(db, 'servicio_ventas', 3, {
        'id': 3,
        'fecha': _hoy,
        'precio_unitario': 100,
        'cantidad': 1,
        'metodo': 'efectivo',
        'registrado_por': 111,
        'casa': 0,
      });
      await _espejo(db, 'servicio_ventas', 4, {
        'id': 4,
        'fecha': _hoy,
        'precio_unitario': 100,
        'cantidad': 1,
        'metodo': 'efectivo',
        'registrado_por': 111,
        'casa': 0,
        'reverso_de': 3,
      });

      final foto = await fotoIngresosDashboard();
      expect(foto.hoy, await ingresosHoy());
      expect(foto.semana, await ingresosSemana());
      expect(foto.mes, await ingresosMes());
      expect(foto.mesAnterior, await ingresosMesAnterior());
      expect(foto.proyeccion, await proyeccionMes());
      expect(foto.porMetodo, await ingresosPorMetodo());
      expect(foto.porTipo, await ingresosPorTipo());
      expect(foto.mejorPeor, await mejorPeorDia());
      expect(foto.ultimos7, await ingresosUltimos7Dias());
      expect(foto.ultimos30, await ingresosUltimos30Dias());
      // Anclas absolutas del día sembrado: 2000 ef + 2500 tr
      // + 200 diario ef + 300 diario tr + 350 venta + 200
      // servicio = 5550 (Casa y el anulado fuera).
      expect(foto.hoy, 5550);
      expect(foto.porMetodo['transferencia'], 2800);
    });
  });
}
