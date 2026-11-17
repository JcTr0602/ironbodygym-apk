// Tests de la oleada M2-BC de Gestión 1.28 (estudio M2,
// Bloques B y C: Dinero y caja):
//  B1 resumenLiquidacionTexto (puro, el texto del recibo
//     que el entrenador puede recibir).
//  B2 deshacerLiquidacion + uuidLiquidacionEnCola (la
//     liquidación solo se deshace si su op sigue en el
//     teléfono; aplicada/rechazada no se tocan).
//  B3 pendienteAcumuladoEnAlerta (puros) + dias_pendiente
//     de pendientePorEntrenador (la antigüedad sale de la
//     MISMA foto del Pendiente).
//  B4 ConciliacionService.marcarLoteComprobadas (las que
//     ya tienen marca en cola se omiten y se cuentan).
//  B5 todasLasLiquidaciones (historial global, la más
//     reciente primero).
//  C3 getters de antigüedad de EntrenadorPendiente.
//  C5 los tres esqueletos de dinero pintan sin errores.
//  B6 la hoja «Liquidar con arrastre» pinta el esperado
//     del espejo (el encolado en sí exige sesión de dueño,
//     como en M2-A: aquí se verifica la carga y la
//     validación, no el guardado).
// Arnés: el de gestion128_m2a_test.dart (BD ffi limpia por
// test, espejos sembrados a mano, Supabase dummy).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ironbody_gym/conciliacion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/models/pendiente.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/hoja_liquidar.dart';
import 'package:ironbody_gym/ui/skeleton.dart';

int _seq = 1000;

Future<Database> _dbLimpia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  // La costura del repo (como en M2-A): borra el archivo
  // por proceso y recrea el esquema al abrir; sin esto el
  // isolate abre una BD vacía («no such table: mirror»).
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  for (final t in [
    'pagos',
    'pagos_diarios',
    'adelantos',
    'liquidaciones_caja',
    'ventas_suplementos',
    'servicio_ventas',
    'clientes',
  ]) {
    await db.delete(t);
  }
  await db.delete('ops_queue');
  return db;
}

Future<void> _espejo(Database db, String tabla, int id,
    Map<String, dynamic> data,
    {Map<String, dynamic> cols = const {}}) async {
  // Cada espejo es su PROPIA tabla (id, data, sync_seq +
  // columnas indexadas): no hay tabla genérica «mirror».
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
    ...cols,
  });
}

int _opN = 0;

Future<String> _op(String tipo, Map<String, dynamic> payload) async {
  final uuid = 'm2bc-op-${_opN++}';
  await LocalDb.instance.queueOp(
    opUuid: uuid,
    tipo: tipo,
    payload: payload,
  );
  return uuid;
}

Future<void> _initDummy() async {
  SharedPreferences.setMockInitialValues({});
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
}

String get _hoy => hoyHabanaIso();

/// Siembra un pago mensual en el espejo (tid 111 por
/// defecto; fecha hoy salvo que se pase otra).
Future<void> _sembrarPago(Database db, int id,
    {int tid = 111,
    double monto = 2000,
    String? fecha,
    String metodo = 'efectivo',
    bool entregado = false}) {
  final f = fecha ?? _hoy;
  return _espejo(db, 'pagos', id, {
    'id': id,
    'cliente_id': 7,
    'cliente_nombre': 'Ana',
    'monto': monto,
    'metodo': metodo,
    'fecha': f,
    'entregado': entregado ? 1 : 0,
    'moneda': 'CUP',
    'registrado_por': tid,
    // pagosEfectivoPorEntrenador NO fusiona la columna:
    // el tid se lee del propio data (como en producción).
    'telegram_user_id': tid,
    'tipo_cliente': 'normal',
    'conciliacion':
        metodo == 'transferencia' ? 'pendiente' : null,
  }, cols: {
    'fecha': f,
    'cliente_id': 7,
    'telegram_user_id': tid,
    'metodo': metodo,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    await _initDummy();
  });

  tearDown(() async {
    // Patrón M2-A: los servicios disparan ciclos de sync en
    // segundo plano que se serializan con el lock del
    // motor; esperar un push propio garantiza que ningún
    // ciclo encolado quede vivo contra la BD que el
    // siguiente resetParaTest va a recrear.
    try {
      await SyncEngine.instance.push().timeout(
          const Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('drenaje de sync');
      });
    } catch (_) {}
  });

  group('B1 · resumen de liquidación (puro)', () {
    test('parcial con arrastre: líneas y conteos por origen',
        () {
      final t = resumenLiquidacionTexto(
        nombre: 'Duany',
        fecha: DateTime(2026, 11, 7),
        esperado: 9800,
        entregado: 6100,
        moneda: 'CUP',
        opIds: const {
          'pagos': [1, 2, 3],
          'pagos_diarios': [9],
          'servicio_ventas': [5, 6],
          'adelantos': [7],
        },
      );
      expect(t, contains('Entrenador: Duany'));
      expect(t, contains('Fecha: 07/11/2026'));
      expect(t, contains('Esperado: 9800 CUP'));
      expect(t, contains('Entregado: 6100 CUP'));
      expect(t, contains('Queda de arrastre: 3700 CUP'));
      expect(
          t,
          contains('Salió de: 3 mensualidades · 1 pagos '
              'diarios · 2 servicios · 1 adelantos saldados'));
    });

    test('exacto: «Sin diferencia» y sin línea de arrastre',
        () {
      final t = resumenLiquidacionTexto(
        nombre: 'Gabriel',
        fecha: DateTime(2026, 11, 7),
        esperado: 5000,
        entregado: 5000,
        moneda: 'CUP',
        opIds: const {
          'ventas_suplementos': [1],
        },
        nota: 'Entrega en mano',
      );
      expect(t, contains('Sin diferencia: todo entregado.'));
      expect(t, isNot(contains('Queda de arrastre')));
      expect(t, contains('Salió de: 1 ventas de suplementos'));
      expect(t, contains('Nota: Entrega en mano'));
    });

    test('sin ops: sale del saldo de arrastre anterior', () {
      final t = resumenLiquidacionTexto(
        nombre: 'Gabriel',
        fecha: DateTime(2026, 11, 7),
        esperado: 1200,
        entregado: 1200,
        moneda: 'USD',
        opIds: const {},
      );
      expect(t,
          contains('Salió del saldo de arrastre anterior.'));
    });
  });

  group('B2 · deshacer liquidación', () {
    Map<String, dynamic> payloadLiq() => {
          'entrenador_telegram_id': 111,
          'moneda': 'CUP',
          'monto_esperado': 2000,
          'monto_entregado': 2000,
          'op_ids': {'pagos': [1]},
          'fecha': _hoy,
        };

    test('op pendiente: se borra y la guarda del doble '
        'cobro se libera', () async {
      await _dbLimpia();
      final uuid = await _op('liquidar_caja', payloadLiq());
      expect(await liquidacionEnCola(111, 'CUP'), isTrue);
      expect(await uuidLiquidacionEnCola(111, 'CUP'), uuid);
      expect(await deshacerLiquidacion(uuid), isTrue);
      expect(await liquidacionEnCola(111, 'CUP'), isFalse);
      expect(await uuidLiquidacionEnCola(111, 'CUP'), isNull);
      expect(await LocalDb.instance
          .pendingOps(), isEmpty);
    });

    test('op APLICADA: no se deshace (ya es del servidor)',
        () async {
      final db = await _dbLimpia();
      final uuid = await _op('liquidar_caja', payloadLiq());
      await db.update('ops_queue', {'estado': 'aplicada'},
          where: 'op_uuid = ?', whereArgs: [uuid]);
      expect(await deshacerLiquidacion(uuid), isFalse);
      final ops = await db.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: [uuid]);
      expect(ops, hasLength(1),
          reason: 'la op aplicada queda intacta');
    });

    test('op de otro tipo y uuid inexistente: false sin '
        'tocar nada', () async {
      await _dbLimpia();
      final uuid = await _op('marcar_conciliacion',
          {'pago_id': 1, 'estado': 'comprobada'});
      expect(await deshacerLiquidacion(uuid), isFalse);
      expect(await deshacerLiquidacion('no-existe'), isFalse);
      expect(await LocalDb.instance.pendingOps(), hasLength(1));
    });

    test('uuid por moneda: CUP y USD son independientes',
        () async {
      await _dbLimpia();
      final uuidCup = await _op('liquidar_caja', payloadLiq());
      await _op('liquidar_caja',
          {...payloadLiq(), 'moneda': 'USD'});
      expect(await uuidLiquidacionEnCola(111, 'CUP'), uuidCup);
      expect(await uuidLiquidacionEnCola(111, 'USD'), isNotNull);
      expect(await uuidLiquidacionEnCola(222, 'CUP'), isNull);
    });
  });

  group('B3 · alerta de pendiente acumulado', () {
    test('umbrales puros: días, CUP y USD en el borde', () {
      expect(
          pendienteAcumuladoEnAlerta(
              dias: kDiasAlertaPendiente, cup: 0, usd: 0),
          isTrue);
      expect(
          pendienteAcumuladoEnAlerta(
              dias: kDiasAlertaPendiente - 1,
              cup: kMontoAlertaPendienteCup - 1,
              usd: kMontoAlertaPendienteUsd - 1),
          isFalse);
      expect(
          pendienteAcumuladoEnAlerta(
              dias: 0, cup: kMontoAlertaPendienteCup, usd: 0),
          isTrue);
      expect(
          pendienteAcumuladoEnAlerta(
              dias: 0, cup: 0, usd: kMontoAlertaPendienteUsd),
          isTrue);
      expect(
          pendienteAcumuladoEnAlerta(dias: 0, cup: 0, usd: 0),
          isFalse);
    });

    test('pendientePorEntrenador trae dias_pendiente de la '
        'fecha más vieja sin entregar', () async {
      final db = await _dbLimpia();
      final hace5 = sumarDiasIso(_hoy, -5);
      await _sembrarPago(db, 1, fecha: hace5);
      await _sembrarPago(db, 2); // hoy: no baja la antigüedad
      await _sembrarPago(db, 3, tid: 222, monto: 500);
      final rows = await pendientePorEntrenador();
      final d = rows.singleWhere((r) => r['id'] == 111);
      expect(d['dias_pendiente'], 5);
      expect(d['fecha_mas_vieja'], hace5);
      expect(d['total'], 4000);
      final g = rows.singleWhere((r) => r['id'] == 222);
      expect(g['dias_pendiente'], 0);
      // Un entregado viejo NO cuenta para la antigüedad.
      await _sembrarPago(db, 4,
          fecha: sumarDiasIso(_hoy, -30), entregado: true);
      final rows2 = await pendientePorEntrenador();
      expect(
          rows2.singleWhere((r) => r['id'] == 111)
              ['dias_pendiente'],
          5);
    });
  });

  group('B4 · conciliación en lote', () {
    test('marca varias y omite la que ya tiene marca en '
        'cola', () async {
      final db = await _dbLimpia();
      await _sembrarPago(db, 40,
          monto: 2500, metodo: 'transferencia');
      await _sembrarPago(db, 41,
          monto: 2500, metodo: 'transferencia');
      await _sembrarPago(db, 42,
          monto: 2500, metodo: 'transferencia');
      await ConciliacionService.instance.marcar(
          pagoId: 42,
          estado: 'comprobada',
          estadoEsperado: 'pendiente');
      final filas =
          await ConciliacionService.instance.transferencias();
      expect(filas, hasLength(3));
      final r = await ConciliacionService.instance
          .marcarLoteComprobadas(filas);
      expect(r.marcadas, 2);
      expect(r.omitidas, 1,
          reason: 'la 42 ya tenía su marca en cola');
      expect(
          await ConciliacionService.instance
              .conteoPorComprobar(),
          0);
      // Segunda pasada con las mismas filas: todo omitido.
      final r2 = await ConciliacionService.instance
          .marcarLoteComprobadas(filas);
      expect(r2.marcadas, 0);
      expect(r2.omitidas, 3);
    });

    test('lote vacío: cero y cero', () async {
      await _dbLimpia();
      final r = await ConciliacionService.instance
          .marcarLoteComprobadas(const []);
      expect(r.marcadas, 0);
      expect(r.omitidas, 0);
    });
  });

  group('B5 · historial de liquidaciones', () {
    test('todas, la más reciente primero, con su estado',
        () async {
      final db = await _dbLimpia();
      await _espejo(db, 'liquidaciones_caja', 1, {
        'id': 1,
        'entrenador_telegram_id': 111,
        'moneda': 'CUP',
        'monto_esperado': 2000,
        'monto_entregado': 2000,
        'estado': 'completa',
        'saldo_arrastre': 0,
        'creada_en': '2026-11-01T10:00:00',
      });
      await _espejo(db, 'liquidaciones_caja', 2, {
        'id': 2,
        'entrenador_telegram_id': 222,
        'moneda': 'CUP',
        'monto_esperado': 5000,
        'monto_entregado': 3000,
        'estado': 'parcial',
        'saldo_arrastre': 2000,
        'creada_en': '2026-11-06T10:00:00',
      });
      final todas = await todasLasLiquidaciones();
      // allMirror normaliza el id a texto.
      expect(todas.map((r) => '${r['id']}'), ['2', '1']);
      expect(todas.first['estado'], 'parcial',
          reason: 'la vista deriva «Parcial» de estado');
      expect(todas.first['saldo_arrastre'], 2000);
      final deUno = await liquidacionesDeEntrenador(111);
      expect(deUno.map((r) => '${r['id']}'), ['1'],
          reason: 'el historial por entrenador de M2-A no '
              'cambia');
    });
  });

  group('C3 · antigüedad en el modelo de Pendiente', () {
    test('diasMasViejo y nivelAlertaMax salen de los días',
        () {
      final hoy = aHabana(ahoraHabana());
      PendienteDia dia(int hace) {
        final f = DateTime(hoy.year, hoy.month, hoy.day)
            .subtract(Duration(days: hace));
        return PendienteDia(
          fecha: f,
          pagos: [
            PagoPendiente(
              id: hace + 1,
              monto: 100,
              moneda: 'CUP',
              fecha: f,
              tipo: 'mensual',
              descripcion: 'Mensualidad',
              entrenador: 'Duany',
              trainerTelegramId: '111',
            ),
          ],
        );
      }

      final ent = EntrenadorPendiente(
        nombre: 'Duany',
        trainerTelegramId: '111',
        dias: [dia(5), dia(1)],
      );
      expect(ent.diasMasViejo, 5);
      expect(ent.nivelAlertaMax, 2,
          reason: '5 días = crítico (4+) en la escala del '
              'modelo');
      const sinDias = EntrenadorPendiente(
        nombre: 'Gabriel',
        trainerTelegramId: '222',
        dias: [],
      );
      expect(sinDias.diasMasViejo, 0);
      expect(sinDias.nivelAlertaMax, 0);
    });
  });

  group('C5 · esqueletos de dinero', () {
    testWidgets('los tres pintan sin errores', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SkeletonDashboard()),
      ));
      await tester.pump();
      expect(find.byType(SkeletonLinea), findsWidgets);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SkeletonPendiente()),
      ));
      await tester.pump();
      expect(find.byType(SkeletonLinea), findsWidgets);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SkeletonArqueo()),
      ));
      await tester.pump();
      expect(find.byType(SkeletonLinea), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('B6 · hoja «Liquidar con arrastre»', () {
    testWidgets('carga el esperado del espejo y valida el '
        'monto vacío', (tester) async {
      await tester.runAsync(() async {
        final db = await _dbLimpia();
        await _sembrarPago(db, 1, monto: 2500);
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    showModalBottomSheet<ResultadoLiquidacion>(
                  context: ctx,
                  builder: (_) => const HojaLiquidar(
                      telegramId: 111, nombre: 'Duany'),
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('abrir'));
      await tester.pump();
      // La carga de la hoja lee la BD ffi: sus respuestas
      // llegan por el isolate en tiempo REAL y la zona fake
      // de testWidgets las recoge al bombear. Bucle acotado:
      // ventanas reales cortas + bombeo, hasta que el
      // esperado se pinte (máx. ~6 s).
      var pintado = false;
      for (var i = 0; i < 12 && !pintado; i++) {
        await tester.runAsync(() => Future<void>.delayed(
            const Duration(milliseconds: 500)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        pintado = find
            .text('Pendiente confirmado: 2500 CUP')
            .evaluate()
            .isNotEmpty;
      }
      expect(find.text('Liquidar con arrastre · Duany'),
          findsOneWidget);
      expect(find.text('Pendiente confirmado: 2500 CUP'),
          findsOneWidget);
      // Vaciar el monto y liquidar: aviso de validación,
      // sin encolar nada. G07-6 (desbloqueo lote 141): la
      // confirmación es DESLIZAR (DeslizarConfirmar, la
      // forma de la casa para dinero), no un toque — el
      // gesto es el patrón de jornada1_arqueo/yunque_132:
      // arrastrar el pulgar ≥92 % de la pista.
      await tester.enterText(
          find.widgetWithText(TextField, 'Monto entregado (CUP)'),
          '');
      expect(find.text('Liquidar'), findsNothing,
          reason: 'ya no hay botón de un toque para liquidar');
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(1000, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Escribe un monto válido.'),
          findsOneWidget);
      expect(
          await tester
              .runAsync(() => LocalDb.instance.pendingOps()),
          isEmpty);
    });
  });
}
