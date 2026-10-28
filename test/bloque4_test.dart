/// Tests del Bloque 4 (Gestión 1.13.0, veredicto Argón AMARILLO):
/// bloqueo separado dosis/pomos, venta múltiple (N/M, grupo único,
/// deshacer completo), reponer lote (sin repartir, saldo, lote
/// cerrado bloquea), Deshacer 15 s + synced==0 vs Reversión,
/// persistencia de Avisos WhatsApp, Estadísticas sin NaN y F4 con
/// el espejo real (CONTRATO_F4_20261024).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ultimo_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _limpiar() async {
  final d = await LocalDb.instance.db;
  for (final t in [
    'ops_queue',
    'servicio_botes',
    'servicio_lotes',
    'servicio_ventas',
    'servicio_salidas',
    'servicio_agua_movimientos',
    'servicio_pomos', // 1.15
    'ultimo_sync',
    'avisos_wa_contactados',
    'cliente_mediciones',
  ]) {
    try {
      await d.delete(t);
    } catch (_) {}
  }
}

Future<void> _espejo(
    String tabla, int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla,
      {'id': id, 'data': jsonEncode(data), 'sync_seq': 1});
}

Future<List<Map<String, dynamic>>> _opsPendientes() async {
  final d = await LocalDb.instance.db;
  return d.query('ops_queue', where: "estado = 'pendiente'");
}

Map<String, dynamic> _payload(Map<String, dynamic> op) =>
    jsonDecode(op['payload'] as String) as Map<String, dynamic>;

/// Siembra bote + lote activo + agua para las pruebas de venta.
Future<void> _siembraVenta() async {
  await _espejo('servicio_botes', 1, {
    'dosis_rendimiento': 100,
    'costo_bote': 10000,
    'estado': 'activo',
  });
  await _espejo('servicio_lotes', 10, {
    'bote_id': 1,
    'dosis_iniciales': 40,
    'dosis_repuestas': 0,
    'estado': 'activo',
  });
  // 1.15: la venta múltiple ya valida contra el pomo, no el lote.
  await _espejo('servicio_pomos', 10, {
    'suplemento_id': 1,
    'titular_telegram_id': 969869611,
    'es_principal': 0,
    'dosis_asignadas': 40,
    'dosis_repartidas': 0,
    'activo': 1,
  });
  await _espejo('servicio_agua_movimientos', 1, {
    'tipo': 'entrada',
    'cantidad': 10,
    'costo_unitario': 50,
  });
  // Comisión configurada (50 CUP por dosis, regla del negocio).
  await LocalDb.instance
      .setMeta('ajustes', jsonEncode({'servicio_comision_dosis': 50}));
}

void main() {
  setUpAll(_abrirDbVacia);
  setUp(_limpiar);

  // ---------- 1. Bloqueo separado dosis vs pomos ----------
  group('bloqueo separado dosis/pomos', () {
    test('sin dosis y con pomos: 600 y 900 OFF, agua ON', () {
      final s600 = estadoBotonVentaServicio(
          tipo: 'dosis_sin_agua',
          tienePomo: true,
          dosisRestantes: 0,
          pomos: 5,
          esDueno: true,
          precio: 600);
      final s900 = estadoBotonVentaServicio(
          tipo: 'dosis_con_agua',
          tienePomo: true,
          dosisRestantes: 0,
          pomos: 5,
          esDueno: true,
          precio: 900);
      final a300 = estadoBotonVentaServicio(
          tipo: 'agua_suelta',
          tienePomo: true,
          dosisRestantes: 0,
          pomos: 5,
          esDueno: true,
          precio: 300);
      expect(s600.habilitado, isFalse);
      expect(s600.motivo, 'No quedan dosis en tu pomo');
      expect(s900.habilitado, isFalse);
      expect(a300.habilitado, isTrue);
    });

    test('con dosis y sin pomos: 600 ON, 900 y agua OFF', () {
      final s600 = estadoBotonVentaServicio(
          tipo: 'dosis_sin_agua',
          tienePomo: true,
          dosisRestantes: 10,
          pomos: 0,
          esDueno: true,
          precio: 600);
      final s900 = estadoBotonVentaServicio(
          tipo: 'dosis_con_agua',
          tienePomo: true,
          dosisRestantes: 10,
          pomos: 0,
          esDueno: true,
          precio: 900);
      final a300 = estadoBotonVentaServicio(
          tipo: 'agua_suelta',
          tienePomo: true,
          dosisRestantes: 10,
          pomos: 0,
          esDueno: true,
          precio: 300);
      expect(s600.habilitado, isTrue);
      expect(s900.habilitado, isFalse);
      expect(s900.motivo, 'Sin pomos de agua en stock');
      expect(a300.habilitado, isFalse);
      expect(a300.motivo, 'Sin pomos de agua en stock');
    });

    test('entrenador ciego: sin dosis local NO se le bloquea', () {
      final s600 = estadoBotonVentaServicio(
          tipo: 'dosis_sin_agua',
          tienePomo: true,
          dosisRestantes: 0,
          pomos: 5,
          esDueno: false,
          precio: 600);
      expect(s600.habilitado, isTrue);
    });

    test('sin lote: dosis OFF; precio sin fijar apaga todo', () {
      final sinLote = estadoBotonVentaServicio(
          tipo: 'dosis_sin_agua',
          tienePomo: false,
          dosisRestantes: 0,
          pomos: 5,
          esDueno: true,
          precio: 600);
      expect(sinLote.habilitado, isFalse);
      expect(sinLote.motivo, 'Sin pomo activo');
      final sinPrecio = estadoBotonVentaServicio(
          tipo: 'agua_suelta',
          tienePomo: true,
          dosisRestantes: 5,
          pomos: 5,
          esDueno: true,
          precio: 0);
      expect(sinPrecio.habilitado, isFalse);
      expect(sinPrecio.motivo, 'Precio sin fijar');
    });
  });

  // ---------- 2. Venta múltiple ----------
  group('venta múltiple B2', () {
    test('N/M fuera de rango lanzan antes de tocar la cola', () async {
      await _siembraVenta();
      await expectLater(
          registrarVentaMultipleServicio(
              pomoId: 10,
              dosisN: 1,
              pomosM: 0,
              metodo: 'efectivo',
              vendedorEsDueno: false,
              topeDosis: 40,
              topePomos: 10),
          throwsException);
      await expectLater(
          registrarVentaMultipleServicio(
              pomoId: 10,
              dosisN: 41,
              pomosM: 0,
              metodo: 'efectivo',
              vendedorEsDueno: false,
              topeDosis: 40,
              topePomos: 10),
          throwsException);
      await expectLater(
          registrarVentaMultipleServicio(
              pomoId: 10,
              dosisN: 3,
              pomosM: 4,
              metodo: 'efectivo',
              vendedorEsDueno: false,
              topeDosis: 40,
              topePomos: 10),
          throwsException);
      await expectLater(
          registrarVentaMultipleServicio(
              pomoId: 10,
              dosisN: 3,
              pomosM: 3,
              metodo: 'efectivo',
              vendedorEsDueno: false,
              topeDosis: 40,
              topePomos: 2),
          throwsException);
      expect(await _opsPendientes(), isEmpty);
    });

    test('N=3 M=2: dos ops con venta_grupo_id común, comisión 50×N',
        () async {
      await _siembraVenta();
      final uuids = await registrarVentaMultipleServicio(
          pomoId: 10,
          dosisN: 3,
          pomosM: 2,
          metodo: 'efectivo',
          vendedorEsDueno: false,
          topeDosis: 40,
          topePomos: 10);
      expect(uuids, hasLength(2));
      final ops = await _opsPendientes();
      expect(ops, hasLength(2));
      final pays = ops.map(_payload).toList();
      final grupo = pays.first['venta_grupo_id'];
      expect(grupo, isNotNull);
      expect(pays.every((pay) => pay['venta_grupo_id'] == grupo),
          isTrue);
      final conAgua = pays.firstWhere(
          (pay) => pay['tipo'] == 'dosis_con_agua');
      final sinAgua = pays.firstWhere(
          (pay) => pay['tipo'] == 'dosis_sin_agua');
      expect(conAgua['cantidad'], 2);
      expect(sinAgua['cantidad'], 1);
      expect(conAgua['comision_unitaria'], 50);
      expect(sinAgua['comision_unitaria'], 50);
    });

    test('M=0: una sola op sin agua; M=N: una sola op con agua',
        () async {
      await _siembraVenta();
      final u0 = await registrarVentaMultipleServicio(
          pomoId: 10,
          dosisN: 4,
          pomosM: 0,
          metodo: 'efectivo',
          vendedorEsDueno: false,
          topeDosis: 40,
          topePomos: 10);
      expect(u0, hasLength(1));
      var ops = await _opsPendientes();
      expect(_payload(ops.single)['tipo'], 'dosis_sin_agua');
      expect(_payload(ops.single)['cantidad'], 4);
      await _limpiar();
      await _siembraVenta();
      final uN = await registrarVentaMultipleServicio(
          pomoId: 10,
          dosisN: 2,
          pomosM: 2,
          metodo: 'efectivo',
          vendedorEsDueno: false,
          topeDosis: 40,
          topePomos: 10);
      expect(uN, hasLength(1));
      ops = await _opsPendientes();
      expect(_payload(ops.single)['tipo'], 'dosis_con_agua');
    });

    test('Deshacer E3 borra el grupo completo', () async {
      await _siembraVenta();
      final uuids = await registrarVentaMultipleServicio(
          pomoId: 10,
          dosisN: 3,
          pomosM: 1,
          metodo: 'efectivo',
          vendedorEsDueno: false,
          topeDosis: 40,
          topePomos: 10);
      expect(await _opsPendientes(), hasLength(2));
      final ok = await deshacerVentaServicio(uuids, ahoraHabana());
      expect(ok, isTrue);
      expect(await _opsPendientes(), isEmpty);
    });
  });

  // ---------- 3. Reponer lote ----------
  group('reponer lote', () {
    test('reposición: op + espejo optimista + sin repartir baja',
        () async {
      await _siembraVenta();
      expect(await sinRepartirLocal(1), 60);
      final uuid = await reponerLoteServicio(loteId: 10, dosis: 5);
      expect(uuid, isNotEmpty);
      final ops = await _opsPendientes();
      expect(ops, hasLength(1));
      expect(ops.single['tipo'], 'reponer_lote');
      expect(_payload(ops.single)['dosis'], 5);
      final lotes =
          await LocalDb.instance.allMirror('servicio_lotes');
      expect(lotes.single['dosis_repuestas'], 5);
      expect(await sinRepartirLocal(1), 55);
      // Saldo = iniciales + reposiciones − ventas − salidas.
      // La op reponer pendiente NO se suma de nuevo (el espejo
      // optimista ya la incluye).
      expect(
          saldoLoteDesde(
            lote: lotes.single,
            ventasEspejo: [],
            salidasEspejo: [],
            opsPendientes: await LocalDb.instance.pendingOps(),
          ),
          45);
    });

    test('más que el sin repartir, o lote cerrado: lanza', () async {
      await _siembraVenta();
      await expectLater(reponerLoteServicio(loteId: 10, dosis: 61),
          throwsException);
      await expectLater(reponerLoteServicio(loteId: 10, dosis: 0),
          throwsException);
      final d = await LocalDb.instance.db;
      await d.update('servicio_lotes',
          {'data': jsonEncode({'bote_id': 1, 'dosis_iniciales': 40,
            'dosis_repuestas': 0, 'estado': 'cerrado'})},
          where: 'id = ?', whereArgs: [10]);
      await expectLater(reponerLoteServicio(loteId: 10, dosis: 1),
          throwsException);
    });

    test('revertir optimismo resta dosis_repuestas', () async {
      await _siembraVenta();
      await reponerLoteServicio(loteId: 10, dosis: 5);
      await LocalDb.instance.revertirOptimismoReponerLote(
          {'lote_id': 10, 'dosis': 5});
      final lotes =
          await LocalDb.instance.allMirror('servicio_lotes');
      expect(lotes.single['dosis_repuestas'], 0);
    });
  });

  // ---------- 4. Deshacer 15 s + synced==0 ----------
  group('Deshacer E3', () {
    test('límite 15 s exactos', () {
      final cobrado = DateTime(2026, 10, 24, 19, 0, 0);
      expect(puedeDeshacerVenta(
          cobrado, cobrado.add(const Duration(seconds: 15))), isTrue);
      expect(puedeDeshacerVenta(
          cobrado, cobrado.add(const Duration(seconds: 16))), isFalse);
      expect(puedeDeshacerVenta(
          cobrado, cobrado.subtract(const Duration(seconds: 1))),
          isFalse);
    });

    test('op ya subida (synced != 0) no se puede deshacer', () async {
      const uuid = 'uuid-deshacer-1';
      await LocalDb.instance.queueOp(
        opUuid: uuid,
        tipo: 'venta_servicio',
        payload: {'tipo': 'dosis_sin_agua'},
      );
      final d = await LocalDb.instance.db;
      await d.update('ops_queue', {'estado': 'enviada'},
          where: 'op_uuid = ?', whereArgs: [uuid]);
      final ok =
          await deshacerVentaServicio([uuid], ahoraHabana());
      expect(ok, isFalse);
      final fila = await LocalDb.instance.opEnCola(uuid);
      expect(fila, isNotNull);
      expect(fila!['estado'], 'enviada');
    });
  });

  // ---------- 5. Avisos WhatsApp persistentes ----------
  group('avisos WhatsApp en SQLite', () {
    test('marcar/desmarcar persiste y se lee por día', () async {
      expect(
          await LocalDb.instance.avisosWaContactados('2026-10-24'),
          isEmpty);
      await LocalDb.instance
          .marcarAvisoWaContactado(7, 'vencido', '2026-10-24');
      await LocalDb.instance
          .marcarAvisoWaContactado(7, 'cumple', '2026-10-24');
      await LocalDb.instance
          .marcarAvisoWaContactado(9, 'vencido', '2026-10-24');
      var set = await LocalDb.instance
          .avisosWaContactados('2026-10-24');
      expect(set, {'vencido_7', 'cumple_7', 'vencido_9'});
      // Otro día no ve los de hoy.
      expect(
          await LocalDb.instance.avisosWaContactados('2026-10-25'),
          isEmpty);
      await LocalDb.instance
          .desmarcarAvisoWaContactado(7, 'vencido', '2026-10-24');
      set = await LocalDb.instance.avisosWaContactados('2026-10-24');
      expect(set, {'cumple_7', 'vencido_9'});
    });

    test('remarcar la misma clave no duplica (PK triple)', () async {
      await LocalDb.instance
          .marcarAvisoWaContactado(7, 'vencido', '2026-10-24');
      await LocalDb.instance
          .marcarAvisoWaContactado(7, 'vencido', '2026-10-24');
      final set = await LocalDb.instance
          .avisosWaContactados('2026-10-24');
      expect(set, {'vencido_7'});
    });
  });

  // ---------- 6. Estadísticas sin NaN ----------
  group('estadísticas sin NaN', () {
    test('bote nuevo (0 vendidas) → pendiente, nunca NaN', () {
      final ind = indicadoresBote(
        costoBote: 10000,
        rendimiento: 100,
        ingresosComerciales: 0,
        dosisComerciales: 0,
        costosComerciales: 0,
      );
      expect(ind.pendiente, isTrue);
      expect(ind.margenPct, isNull);
      expect(ind.puntoEquilibrioDosis, isNull);
    });

    test('con ventas: margen % y punto de equilibrio', () {
      final ind = indicadoresBote(
        costoBote: 10000,
        rendimiento: 100,
        ingresosComerciales: 12000,
        dosisComerciales: 20,
        costosComerciales: 2000,
      );
      expect(ind.pendiente, isFalse);
      expect(ind.margenPct, closeTo(83.33, 0.01));
      // costo/dosis 100, precio medio 600 → 10000/500 = 20 dosis.
      expect(ind.puntoEquilibrioDosis, closeTo(20, 0.001));
    });

    test('día de semana Habana desde fecha (sin zona del teléfono)',
        () {
      // 2026-10-24 es sábado.
      expect(diaSemanaHabana('2026-10-24'), 6);
      expect(diaSemanaHabana('2026-10-26'), 1);
      expect(diaSemanaHabana('basura'), isNull);
      expect(diaSemanaHabana(null), isNull);
    });

    test('franjas: madrugada/mañana/tarde/noche/sin_hora', () {
      expect(franjaDeHora('05:30'), 'madrugada');
      expect(franjaDeHora('08:00'), 'manana');
      expect(franjaDeHora('15:00'), 'tarde');
      expect(franjaDeHora('22:00'), 'noche');
      expect(franjaDeHora(null), 'sin_hora');
      expect(franjaDeHora('xx'), 'sin_hora');
    });

    test('franja: horas inválidas caen en sin_hora (panel 1.13)', () {
      expect(franjaDeHora('99:99'), 'sin_hora');
      expect(franjaDeHora('24:00'), 'sin_hora');
      expect(franjaDeHora('12:60'), 'sin_hora');
      expect(franjaDeHora('23:59'), 'noche');
    });

    test('agrupar por día: Casa y agua suelta no cuentan', () {
      final ventas = [
        {'tipo': 'dosis_sin_agua', 'cantidad': 2,
         'precio_unitario': 600, 'fecha': '2026-10-24'},
        {'tipo': 'dosis_con_agua', 'cantidad': 1,
         'precio_unitario': 900, 'fecha': '2026-10-24'},
        {'tipo': 'dosis_sin_agua', 'cantidad': 5,
         'precio_unitario': 600, 'fecha': '2026-10-24', 'casa': 1},
        {'tipo': 'agua_suelta', 'cantidad': 3,
         'precio_unitario': 300, 'fecha': '2026-10-24'},
      ];
      final porDia = agruparPorDiaSemana(ventas);
      expect(porDia[6]?.dosis, 3);
      expect(porDia[6]?.ingresos, 2100);
    });

    test('agrupar por franja usa la hora del payload', () {
      final ventas = [
        {'tipo': 'dosis_sin_agua', 'cantidad': 1,
         'fecha': '2026-10-24', 'hora': '08:15'},
        {'tipo': 'dosis_sin_agua', 'cantidad': 2,
         'fecha': '2026-10-24'},
      ];
      final porFranja = agruparPorFranja(ventas);
      expect(porFranja['manana'], 1);
      expect(porFranja['sin_hora'], 2);
    });

    test('resumen semanal I3: texto con semana, dosis, pomos, CUP',
        () {
      final txt = textoResumenSemanal(
        lunes: '2026-10-19',
        domingo: '2026-10-25',
        dosis: 12,
        pomosSueltos: 4,
        ingresos: 8400,
        comisiones: 600,
      );
      expect(txt, contains('2026-10-19 al 2026-10-25'));
      expect(txt, contains('Dosis vendidas: 12'));
      expect(txt, contains('Pomos sueltos: 4'));
      expect(txt, contains('8400 CUP'));
    });

    test('simulador B6: costo por dosis y márgenes', () {
      final sim = simularPrecios(
        costoBote: 10000,
        rendimiento: 100,
        precioSinAgua: 600,
        precioConAgua: 900,
      );
      expect(sim.costoPorDosis, 100);
      expect(sim.margenSinAgua, 500);
      expect(sim.margenConAgua, 800);
    });

    test('CSV escapa comas y comillas', () {
      final csv = csvEstadisticas(
        ['Bote', 'Nota'],
        [
          ['Pre-entreno, X', 'dice "hola"'],
        ],
      );
      expect(csv, contains('"Pre-entreno, X"'));
      expect(csv, contains('"dice ""hola"""'));
    });
  });

  // ---------- 7. D4 medidas: validación ----------
  group('D4 medidas', () {
    test('validarMedicion: rangos y lista cerrada', () {
      expect(validarMedicion({}), isNotNull);
      expect(validarMedicion({'peso_kg': 85}), isNull);
      expect(validarMedicion({'peso_kg': 500}), isNotNull);
      expect(validarMedicion({'altura_cm': 180}), isNotNull);
      expect(validarMedicion({'grasa_pct': 0}), isNotNull);
    });
  });

  // ---------- 8. F4 ultimo_sync (espejo real) ----------
  group('F4 ultimo_sync', () {
    test('watermark 0 con tabla vacía; MAX tras upserts', () async {
      expect(await LocalDb.instance.watermarkUltimoSync(), 0);
      await LocalDb.instance.upsertUltimoSync([
        {
          'telegram_user_id': 111,
          'nombre': 'Gabriel',
          'ultimo_sync_at': '2026-10-24T19:12:33-04:00',
          'sync_seq': 100412,
        },
        {
          'telegram_user_id': 222,
          'nombre': 'Duany',
          'ultimo_sync_at': '2026-10-24T18:00:00-04:00',
          'sync_seq': 100300,
        },
      ]);
      expect(await LocalDb.instance.watermarkUltimoSync(), 100412);
    });

    test('replace idempotente por telegram_user_id', () async {
      await LocalDb.instance.upsertUltimoSync([
        {
          'telegram_user_id': 111,
          'nombre': 'Gabriel',
          'ultimo_sync_at': '2026-10-24T19:12:33-04:00',
          'sync_seq': 100412,
        },
      ]);
      await LocalDb.instance.upsertUltimoSync([
        {
          'telegram_user_id': 111,
          'nombre': 'Gabriel',
          'ultimo_sync_at': '2026-10-25T08:00:00-04:00',
          'sync_seq': 100500,
        },
      ]);
      final filas = await LocalDb.instance.filasUltimoSync();
      expect(filas, hasLength(1));
      expect(filas.single['ultimo_sync_at'],
          '2026-10-25T08:00:00-04:00');
      expect(await LocalDb.instance.watermarkUltimoSync(), 100500);
    });

    test('filas incompletas se ignoran (nunca fila a medias)',
        () async {
      await LocalDb.instance.upsertUltimoSync([
        {'nombre': 'Sin id', 'ultimo_sync_at': '2026-10-24T00:00:00-04:00'},
        {'telegram_user_id': 333, 'nombre': 'Sin fecha'},
      ]);
      expect(await LocalDb.instance.filasUltimoSync(), isEmpty);
    });

    test('ultimoSyncPorTelefono devuelve las filas locales', () async {
      await LocalDb.instance.upsertUltimoSync([
        {
          'telegram_user_id': 111,
          'nombre': 'Gabriel',
          'ultimo_sync_at': '2026-10-24T19:12:33-04:00',
          'sync_seq': 100412,
        },
      ]);
      final filas = await ultimoSyncPorTelefono();
      expect(filas, hasLength(1));
      expect(filas.single['nombre'], 'Gabriel');
    });

    test('haceX: minutos, horas, días; sin fila = Sin registro',
        () {
      final ahora = DateTime(2026, 10, 24, 19, 42, 33);
      expect(haceX('2026-10-24T19:12:33-04:00', ahora),
          'hace 30 min');
      expect(haceX('2026-10-24T18:12:33-04:00', ahora), 'hace 1 h');
      expect(
          haceX('2026-10-22T19:12:33-04:00', ahora), 'hace 2 días');
      expect(haceX('2026-10-23T19:12:33-04:00', ahora), 'hace 1 día');
      expect(haceX('basura', ahora), isNull);
      expect(haceX(null, ahora), isNull);
      expect(etiquetaUltimoSync(null, ahora), 'Sin registro de sync');
      expect(
          etiquetaUltimoSync(
              {'ultimo_sync_at': '2026-10-24T19:12:33-04:00'},
              ahora),
          'Última sync: hace 30 min');
    });
  });
}
