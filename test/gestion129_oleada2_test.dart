/// Gestión 1.29 · Oleada 2 (dinero): batería de la oleada.
///
/// Cubre, contra el código vivo:
/// - GD-12 + D-12: la tarjeta de día de «Pendiente a
///   recoger» pinta TODOS los pagos (el caso Gabriel:
///   4 diarios + 1 venta de servicio) sin enlace de
///   expansión, y «Cobrar este día» es un botón con
///   texto y objetivo ≥ 48. Las hojas de cobro/liquidar
///   confirman con BotonPrimario ≥ 48.
/// - D-A2: equivalencia de cifras de ingresos entre el
///   camino viejo (espejos enteros en memoria) y el
///   nuevo (consultas de rango), con los bordes reales
///   (timestamp UTC de madrugada, anulada, USD, fiado).
/// - D-A4: el resumen de diferencias pinta 5 + «y N más».
/// - D-B2-01 (H-05/P-13): la foto de nómina suma espejo
///   + cola por LA MISMA atribución; deduplicación por
///   op_uuid; el reverso pendiente cancela su venta;
///   borde UTC/Habana.
/// - D-B2-05: la comisión se suma sobre TODOS los
///   telegram_id del entrenador.
/// - FB-14: el contador de ventas sin subir atribuye
///   bien (vendedor manda; la espejada no cuenta).
/// - D-B2-02: una op de reserva en 'enviada' bloquea su
///   tarjeta con la lectura de dinero.
/// - D-B2-03: el apartado vencido no ofrece «Cobrar».
/// - D-11: color categórico de método.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diferencias_caja.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/hoja_cobrar_parcial.dart';
import 'package:ironbody_gym/ui/hoja_liquidar.dart';
import 'package:ironbody_gym/ui/pendiente.dart';
import 'package:ironbody_gym/ui/reservas.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ----------------------------------------------------------------
// Arnés común (patrón de la casa: FFI + sesión de mentira)
// ----------------------------------------------------------------

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000ee',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000ee',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  for (final t in [
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
    'ops_queue',
    'gastos',
    'liquidaciones_caja',
    'entregas_efectivo',
    'espejo_entregas_efectivo',
  ]) {
    await db.delete(t);
  }
  await db.delete('meta', where: 'k = ?', whereArgs: ['usuarios_apk']);
}

/// Las lecturas FFI no resuelven bajo FakeAsync: se
/// bombea con tiempo real intercalado (patrón del banco
/// widget / home_scroll).
/// Carga real de una pantalla que lee la BD al abrir:
/// TODO el trabajo asíncrono (siembra, pumpWidget y las
/// esperas) va DENTRO de runAsync — el patrón del arnés
/// de Home. Los awaits de BD fuera de runAsync se quedan
/// colgados en la zona falsa de testWidgets (así se
/// atascó la primera versión de este archivo).
Future<void> _pumpReal(WidgetTester tester,
    {int vueltas = 10}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < vueltas; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 16));
    }
  });
}

// ----------------------------------------------------------------
// Fábricas de filas
// ----------------------------------------------------------------

Map<String, dynamic> _ventaEspejo({
  required int id,
  String? opUuid,
  int cantidad = 2,
  double comisionUnitaria = 50,
  double? comisionMonto = 100,
  int? comisionEntrenadorId = 111,
  int? registradoPor = 999,
  String fecha = '2026-11-05',
  int casa = 0,
}) =>
    {
      'id': id,
      if (opUuid != null) 'op_uuid': opUuid,
      'tipo': 'dosis_sin_agua',
      'cantidad': cantidad,
      'precio_unitario': 600,
      'comision_unitaria': comisionUnitaria,
      if (comisionMonto != null) 'comision_monto': comisionMonto,
      'comision_entrenador_id': comisionEntrenadorId,
      'registrado_por': registradoPor,
      'fecha': fecha,
      'casa': casa,
      'metodo': 'efectivo',
    };

Map<String, dynamic> _opVenta({
  required String uuid,
  int autor = 111,
  int? vendedor,
  int cantidad = 1,
  double comisionUnitaria = 50,
  String fecha = '2026-11-06',
}) =>
    {
      'op_uuid': uuid,
      'tipo': 'venta_servicio',
      'telegram_id': autor,
      'creada_ts': '2026-11-06T10:00:00.000-05:00',
      'payload': jsonEncode({
        'tipo': 'dosis_sin_agua',
        'cantidad': cantidad,
        'precio_unitario': 600,
        'comision_unitaria': comisionUnitaria,
        if (vendedor != null) 'vendedor_id': vendedor,
        'fecha': fecha,
        'metodo': 'efectivo',
      }),
    };

Map<String, dynamic> _opReverso({
  required String uuid,
  required int ventaId,
  String creadaTs = '2026-11-20T09:00:00.000-05:00',
}) =>
    {
      'op_uuid': uuid,
      'tipo': 'revertir_venta_servicio',
      'telegram_id': 999,
      'creada_ts': creadaTs,
      'payload': jsonEncode({'venta_id': ventaId, 'motivo': 'error'}),
    };

({int dosis, double total}) _foto(
        List<Map<String, dynamic>> ventas, int tid, String pref) =>
    NominaCalc.comisionDosisDesdeVentas(ventas, tid, pref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  // --------------------------------------------------------------
  group('D-B2-01 · foto de nómina espejo + cola (H-05)', () {
    test('una venta en cola propia entra en la foto', () {
      final filas = filasNominaDesdeCola(
        ventasEspejo: const [],
        ops: [_opVenta(uuid: 'op-1')],
        tidSesion: 111,
      );
      final c = _foto(filas, 111, '2026-11');
      expect(c.dosis, 1);
      expect(c.total, 50);
    });

    test('una venta en cola de OTRO entrenador no entra '
        'en mi foto', () {
      final filas = filasNominaDesdeCola(
        ventasEspejo: const [],
        ops: [_opVenta(uuid: 'op-2', autor: 222, vendedor: 222)],
        tidSesion: 111,
      );
      expect(_foto(filas, 111, '2026-11').total, 0,
          reason: 'la venta es de 222: en la foto de 111 '
              'no puede aparecer');
      expect(_foto(filas, 222, '2026-11').total, 50);
    });

    test('venta registrada por el dueño a nombre del '
        'entrenador: gana el vendedor', () {
      final filas = filasNominaDesdeCola(
        ventasEspejo: const [],
        ops: [_opVenta(uuid: 'op-3', autor: 999, vendedor: 111)],
        tidSesion: 999,
      );
      expect(_foto(filas, 111, '2026-11').total, 50);
      expect(_foto(filas, 999, '2026-11').total, 0);
    });

    test('P-13: la misma venta en cola y en espejo '
        '(mismo op_uuid) cuenta UNA vez', () {
      final espejo = [
        _ventaEspejo(id: 10, opUuid: 'uuid-dup'),
      ];
      final filas = filasNominaDesdeCola(
        ventasEspejo: espejo,
        ops: [_opVenta(uuid: 'uuid-dup', cantidad: 2)],
        tidSesion: 111,
      );
      expect(filas, isEmpty,
          reason: 'la de la cola ya bajó al espejo: la '
              'foto la cuenta desde el espejo, no dos veces');
      final c = _foto([...espejo, ...filas], 111, '2026-11');
      expect(c.dosis, 2);
      expect(c.total, 100);
    });

    test('un reverso pendiente cancela su venta del '
        'espejo antes de sumar', () {
      final espejo = [_ventaEspejo(id: 10, opUuid: 'uuid-v')];
      final filas = filasNominaDesdeCola(
        ventasEspejo: espejo,
        ops: [_opReverso(uuid: 'op-r1', ventaId: 10)],
        tidSesion: 999,
      );
      final c = _foto([...espejo, ...filas], 111, '2026-11');
      expect(c.total, 0,
          reason: 'venta con su reverso en cola no suma');
      expect(c.dosis, 0);
    });

    test('el reverso resta en el mes en que ocurre, no '
        'en el de la venta', () {
      final espejo = [
        _ventaEspejo(id: 10, opUuid: 'uuid-v', fecha: '2026-10-05'),
      ];
      final filas = filasNominaDesdeCola(
        ventasEspejo: espejo,
        ops: [
          _opReverso(
              uuid: 'op-r2',
              ventaId: 10,
              creadaTs: '2026-11-02T09:00:00.000-05:00'),
        ],
        tidSesion: 999,
      );
      final todas = [...espejo, ...filas];
      expect(_foto(todas, 111, '2026-10').total, 100,
          reason: 'en octubre la venta contó entera');
      expect(_foto(todas, 111, '2026-11').total, -100,
          reason: 'en noviembre el reverso resta');
    });

    test('un reverso ya espejado no se duplica desde la '
        'cola', () {
      final espejo = [
        _ventaEspejo(id: 10, opUuid: 'uuid-v'),
        {
          ..._ventaEspejo(id: 11, opUuid: 'uuid-r', cantidad: -2),
          'comision_monto': -100.0,
          'reverso_de': 10,
          'fecha': '2026-11-20',
        },
      ];
      final filas = filasNominaDesdeCola(
        ventasEspejo: espejo,
        ops: [_opReverso(uuid: 'op-r3', ventaId: 10)],
        tidSesion: 999,
      );
      expect(filas, isEmpty,
          reason: 'el reverso ya vive en el espejo: la op '
              'en cola no emite otra fila sintética');
      expect(_foto(espejo, 111, '2026-11').total, 0);
    });

    test('borde UTC/Habana: la venta de madrugada UTC es '
        'del mes anterior en La Habana', () {
      final espejo = [
        _ventaEspejo(
            id: 12, opUuid: 'uuid-b', fecha: '2026-11-01T02:30:00Z'),
      ];
      expect(_foto(espejo, 111, '2026-11').total, 0,
          reason: '2026-11-01T02:30Z es 31-oct en La '
              'Habana: no suma en noviembre');
      expect(_foto(espejo, 111, '2026-10').total, 100);
    });

    test('H-04 (Argón, ajustes a la 1.29): venta en cola '
        'SIN fecha en el payload se fecha por la creación '
        'de la op', () {
      // El payload puede no traer 'fecha' (la fija el
      // servidor al aplicar la op): la fila sintética cae a
      // op['creada_ts']. Con la fecha vacía de antes, la
      // atribución ignoraba la fila y la comisión no
      // aparecía en la foto hasta que bajaba el espejo.
      final op = <String, dynamic>{
        'op_uuid': 'op-h04',
        'tipo': 'venta_servicio',
        'telegram_id': 111,
        'creada_ts': '2026-11-06T10:00:00.000-05:00',
        'payload': jsonEncode({
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 600,
          'comision_unitaria': 50,
          'metodo': 'efectivo',
        }),
      };
      final filas = filasNominaDesdeCola(
        ventasEspejo: const [],
        ops: [op],
        tidSesion: 111,
      );
      expect(filas.single['fecha'],
          '2026-11-06T10:00:00.000-05:00');
      expect(_foto(filas, 111, '2026-11').total, 50,
          reason: 'la venta cuenta en su mes desde la cola');
    });

    test('H-04 (Argón, ajustes a la 1.29): la venta en cola '
        'propaga el comision_monto del payload (el snapshot '
        'manda)', () {
      final op = <String, dynamic>{
        'op_uuid': 'op-h04b',
        'tipo': 'venta_servicio',
        'telegram_id': 111,
        'creada_ts': '2026-11-06T10:00:00.000-05:00',
        'payload': jsonEncode({
          'tipo': 'dosis_con_agua',
          'cantidad': 2,
          'precio_unitario': 900,
          'comision_unitaria': 50,
          'comision_monto': 130,
          'fecha': '2026-11-06',
          'metodo': 'efectivo',
        }),
      };
      final filas = filasNominaDesdeCola(
        ventasEspejo: const [],
        ops: [op],
        tidSesion: 111,
      );
      expect(filas.single['comision_monto'], 130.0);
      // Sin propagar, la foto recalcularía 50 × 2 = 100 y
      // la comisión de la cola discreparía de la del espejo
      // cuando la venta bajara con su snapshot.
      expect(_foto(filas, 111, '2026-11').total, 130);
    });
  });

  // --------------------------------------------------------------
  group('D-B2-05 · comisión con TODOS los telegram_id', () {
    test('el conjunto completo suma lo del tid histórico '
        'y lo del actual', () {
      final ventas = [
        _ventaEspejo(id: 20, comisionEntrenadorId: 111),
        _ventaEspejo(id: 21, comisionEntrenadorId: 333),
      ];
      // La suma que hace «Mi Nómina» sobre el conjunto.
      var dosis = 0;
      var total = 0.0;
      for (final t in [111, 333]) {
        final c = _foto(ventas, t, '2026-11');
        dosis += c.dosis;
        total += c.total;
      }
      expect(total, 200);
      expect(dosis, 4);
      // Con un solo tid (el defecto) se perdía la mitad.
      expect(_foto(ventas, 333, '2026-11').total, 100);
    });
  });

  // --------------------------------------------------------------
  group('FB-14 · contador de ventas sin subir', () {
    test('atribuye al vendedor, ignora las de otro y las '
        'ya espejadas', () {
      final ops = [
        _opVenta(uuid: 'c-1', autor: 111),
        _opVenta(uuid: 'c-2', autor: 999, vendedor: 111),
        _opVenta(uuid: 'c-3', autor: 222, vendedor: 222),
        _opVenta(uuid: 'c-4', autor: 111),
      ];
      final n = ventasEnColaDeEntrenador(
        ops: ops,
        uuidsEspejo: {'c-4'},
        telegramId: 111,
        tidSesion: 999,
      );
      expect(n, 2,
          reason: 'c-1 (autor) y c-2 (vendedor) son de '
              '111; c-3 es de otro y c-4 ya bajó al espejo');
      expect(
        ventasEnColaDeEntrenador(
          ops: ops,
          uuidsEspejo: const {},
          telegramId: 222,
          tidSesion: 999,
        ),
        1,
      );
    });
  });

  // --------------------------------------------------------------
  group('D-A2 · equivalencia de ingresos por período', () {
    test('las cifras del camino nuevo == camino viejo '
        '(con los bordes reales)', () async {
      await _bdVacia();
      final db = LocalDb.instance;
      var seq = 7000;
      Future<void> esp(String tabla, int id, Map<String, dynamic> d) =>
          db.upsertMirror(tabla, id, d, seq++);
      // pagos
      await esp('pagos', 1,
          {'fecha': '2026-11-10', 'monto': 2000, 'metodo': 'efectivo'});
      await esp('pagos', 2, {
        'fecha': '2026-11-01T02:30:00Z',
        'monto': 2500,
        'metodo': 'transferencia',
      });
      await esp('pagos', 3,
          {'fecha': '2026-10-15', 'monto': 9999, 'metodo': 'efectivo'});
      await esp('pagos', 4,
          {'fecha': '2026-11-12', 'monto': 0, 'metodo': 'efectivo'});
      await esp('pagos', 5, {
        'fecha': '2026-11-12',
        'monto': 500,
        'metodo': 'efectivo',
        'anulada': 1,
      });
      // pagos_diarios
      await esp('pagos_diarios', 1,
          {'fecha': '2026-11-10', 'total': 400, 'metodo': 'efectivo'});
      await esp('pagos_diarios', 2, {
        'fecha': '2026-11-20',
        'total': 200,
        'metodo': 'transferencia',
      });
      await esp('pagos_diarios', 3,
          {'fecha': '2026-09-01', 'total': 777, 'metodo': 'efectivo'});
      // ventas_suplementos
      await esp('ventas_suplementos', 1, {
        'fecha': '2026-11-11',
        'total': 900,
        'metodo': 'efectivo',
        'moneda': 'CUP',
      });
      await esp('ventas_suplementos', 2, {
        'fecha': '2026-11-11',
        'total': 50,
        'metodo': 'efectivo',
        'moneda': 'USD',
      });
      await esp('ventas_suplementos', 3, {
        'fecha': '2026-11-11',
        'total': 700,
        'metodo': 'efectivo',
        'es_fiado': 1,
        'fiado_saldado': 0,
      });
      await esp('ventas_suplementos', 4, {
        'fecha': '2026-11-12',
        'total': 700,
        'metodo': 'transferencia',
        'es_fiado': 1,
        'fiado_saldado': 1,
      });
      // servicio_ventas
      await esp('servicio_ventas', 1, {
        'fecha': '2026-11-10',
        'tipo': 'dosis_sin_agua',
        'precio_unitario': 600,
        'cantidad': 2,
        'metodo': 'efectivo',
      });
      await esp('servicio_ventas', 2, {
        'fecha': '2026-11-10',
        'tipo': 'agua_suelta',
        'precio_unitario': 300,
        'cantidad': 1,
        'metodo': 'transferencia',
      });
      await esp('servicio_ventas', 3, {
        'fecha': '2026-11-10',
        'tipo': 'dosis_sin_agua',
        'precio_unitario': 600,
        'cantidad': 1,
        'metodo': 'efectivo',
        'casa': 1,
      });
      await esp('servicio_ventas', 4, {
        'fecha': '2026-10-31',
        'tipo': 'dosis_sin_agua',
        'precio_unitario': 600,
        'cantidad': 5,
        'metodo': 'efectivo',
      });

      const desde = '2026-11-01';
      const hasta = '2026-11-30';
      // Camino viejo: espejos enteros + filtro en Dart.
      final viejas = <FilaIngreso>[];
      for (final fuente in const [
        'pagos',
        'pagos_diarios',
        'ventas_suplementos',
        'servicio_ventas',
      ]) {
        for (final r in await db.allMirror(fuente)) {
          final f = filaIngresoDesdeEspejo(fuente, r);
          if (f != null) viejas.add(f);
        }
      }
      final rViejo = resumenIngresos(viejas, desde, hasta);
      final rNuevo = resumenIngresos(
          await filasIngresoPeriodo(desde, hasta), desde, hasta);
      expect(rNuevo.efectivo, rViejo.efectivo);
      expect(rNuevo.transferencia, rViejo.transferencia);
      expect(rNuevo.total, rViejo.total);
      expect(rNuevo.porConcepto, rViejo.porConcepto);
      // Y las cifras esperadas a mano (el borde UTC entra
      // por su fecha cruda 2026-11-01, no por la columna):
      expect(rNuevo.efectivo, 4500);
      expect(rNuevo.transferencia, 3700);
      expect(rNuevo.total, 8200);
      expect(rNuevo.porConcepto['mensualidades'], 4500);
      expect(rNuevo.porConcepto['diarios'], 600);
      expect(rNuevo.porConcepto['suplementos'], 1600);
      expect(rNuevo.porConcepto['dosis'], 1200);
      expect(rNuevo.porConcepto['agua'], 300);
    });
  });

  // --------------------------------------------------------------
  group('D-B2-02 · reservas con op en «enviada»', () {
    test('la lectura de dinero bloquea la tarjeta; la '
        'del push no la veía', () async {
      await _bdVacia();
      final d = await LocalDb.instance.db;
      await d.insert('ops_queue', {
        'op_uuid': 'op-res-enviada',
        'tipo': 'cobrar_reserva',
        'payload': jsonEncode({'reserva_id': 42, 'metodo': 'efectivo'}),
        'estado': 'enviada',
        'creada_ts': '2026-11-07T08:00:00.000-05:00',
        'telegram_id': 111111,
      });
      final delPush = await LocalDb.instance.pendingOps();
      expect(
          delPush.any((o) => o['op_uuid'] == 'op-res-enviada'),
          isFalse,
          reason: 'pendingOps es la lectura del push: la '
              'op enviada ya no está para él');
      final deLectura = await LocalDb.instance.pendingOpsLectura();
      expect(deLectura.any((o) => o['op_uuid'] == 'op-res-enviada'),
          isTrue);
      expect(reservasConOpPendiente(deLectura), contains(42),
          reason: 'con la lectura de dinero, la tarjeta de '
              'la reserva 42 queda bloqueada hasta que el '
              'espejo baje');
      expect(reservasConOpPendiente(delPush), isNot(contains(42)));
    });
  });

  // --------------------------------------------------------------
  group('D-B2-03 · apartado vencido sin «Cobrar»', () {
    ReservaVista vista({required String estado, String? expiraEn}) =>
        ReservaVista(
          id: 7,
          clienteId: 3,
          clienteNombre: 'Cliente Prueba',
          suplementoId: 1,
          suplementoNombre: 'Proteína',
          cantidad: 1,
          precioUnitario: 5000,
          precioVigente: 5000,
          estado: estado,
          creadaTs: '2026-11-01T10:00:00.000-05:00',
          expiraEn: expiraEn,
          notaResolucion: null,
        );

    test('apartadoVencido: solo reservada con expira_en '
        'pasado', () {
      final ahora = DateTime(2026, 11, 7, 12);
      expect(
          vista(estado: 'reservada', expiraEn: '2026-11-06T12:00:00')
              .apartadoVencido(ahora),
          isTrue);
      expect(
          vista(estado: 'reservada', expiraEn: '2026-11-08T12:00:00')
              .apartadoVencido(ahora),
          isFalse);
      expect(
          vista(estado: 'solicitada', expiraEn: '2026-11-06T12:00:00')
              .apartadoVencido(ahora),
          isFalse,
          reason: 'las solicitadas no tienen stock '
              'apartado: no son «apartados vencidos»');
      expect(vista(estado: 'reservada').apartadoVencido(ahora),
          isFalse);
    });

    testWidgets('la tarjeta vencida no ofrece Cobrar y '
        'lo dice; la vigente sí', (tester) async {
      Widget tarjeta(ReservaVista r) => MaterialApp(
            home: Scaffold(
              body: TarjetaReserva(
                reserva: r,
                bloqueada: false,
                onConfirmar: () {},
                onRechazar: () {},
                onCancelar: () {},
                onCobrar: () {},
              ),
            ),
          );
      await tester.pumpWidget(tarjeta(vista(
          estado: 'reservada', expiraEn: '2020-01-01T00:00:00')));
      await tester.pump();
      expect(find.text('Cobrar'), findsNothing,
          reason: 'un apartado vencido no se puede cobrar');
      expect(find.textContaining('Apartado vencido'), findsOneWidget);
      await tester.pumpWidget(tarjeta(vista(
          estado: 'reservada', expiraEn: '2999-01-01T00:00:00')));
      await tester.pump();
      expect(find.text('Cobrar'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------
  group('D-A4 · resumen de diferencias sin corte mudo', () {
    testWidgets('7 expedientes: 5 filas + «y 2 más» que '
        'avisa', (tester) async {
      var toques = 0;
      final exps = [
        for (var i = 1; i <= 7; i++)
          {
            'monto': 100.0 * i,
            'moneda': 'CUP',
            'fecha': '2026-11-0$i',
            'estado': 'abierta',
          },
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListaDiferenciasResumen(
            expedientes: exps,
            onVerMas: () => toques++,
          ),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('Faltan'), findsNWidgets(5));
      expect(find.text('y 2 más'), findsOneWidget);
      await tester.tap(find.text('y 2 más'));
      expect(toques, 1);
      // Con 5 o menos no hay enlace.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListaDiferenciasResumen(
            expedientes: exps.take(5).toList(),
            onVerMas: () => toques++,
          ),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('y '), findsNothing);
    });
  });

  // --------------------------------------------------------------
  group('D-11 · método con su color', () {
    test('efectivo dorado, transferencia azul', () {
      expect(colorDeMetodo('efectivo'), AppColores.metodoEfectivo);
      expect(colorDeMetodo('transferencia'),
          AppColores.metodoTransferencia);
      expect(colorDeMetodo('Transferencia'), AppColores.metodoTransferencia);
    });

    testWidgets('PuntoMetodo pinta el color categórico',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: PuntoMetodo(metodo: 'efectivo')),
      ));
      final cont = tester.widget<Container>(find.byType(Container));
      final deco = cont.decoration as BoxDecoration;
      expect(deco.color, AppColores.metodoEfectivo);
    });
  });

  // --------------------------------------------------------------
  group('D-12 · acciones de dinero grandes y con nombre', () {
    testWidgets('HojaCobrarParcial: «Confirmar cobro» '
        'mide ≥ 48 de alto', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: HojaCobrarParcial(
              nombre: 'Gabriel', total: 1700, arrastre: 0),
        ),
      ));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '100');
      await tester.pump();
      final boton = find.byType(BotonPrimario);
      expect(boton, findsOneWidget);
      expect(tester.getSize(boton).height, greaterThanOrEqualTo(48));
    });

    testWidgets('HojaLiquidar: «Liquidar» mide ≥ 48 de '
        'alto', (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
            body: HojaLiquidar(telegramId: 222222, nombre: 'Gabriel'),
          ),
        ));
      });
      await _pumpReal(tester);
      final boton = find.byType(BotonPrimario);
      expect(boton, findsOneWidget);
      expect(tester.getSize(boton).height, greaterThanOrEqualTo(48));
    });
  });

  // --------------------------------------------------------------
  group('GD-12 · la tarjeta de día pinta TODOS los pagos',
      () {
    testWidgets('el caso Gabriel: 4 diarios + 1 servicio '
        '= 5 filas visibles y total comprobable',
        (tester) async {
      // Siembra + sesión + primer pintado DENTRO de
      // runAsync (patrón del arnés de Home): fuera, los
      // awaits de BD se cuelgan en la zona falsa.
      await tester.runAsync(() async {
        await _bdVacia();
        await _fijarSesion('jctr0602@ironbody.gym', 735772141);
        final db = LocalDb.instance;
        var seq = 9000;
        final hoy = hoyHabanaIso();
        for (var i = 1; i <= 4; i++) {
          await db.upsertMirror('pagos_diarios', i, {
            'fecha': hoy,
            'total': 200,
            'metodo': 'efectivo',
            'registrado_por': 222222,
            'registrado_por_nombre': 'Gabriel',
          }, seq++);
        }
        await db.upsertMirror('servicio_ventas', 21, {
          'fecha': hoy,
          'tipo': 'dosis_con_agua',
          'precio_unitario': 900,
          'cantidad': 1,
          'metodo': 'efectivo',
          'responsable_efectivo_id': 222222,
          'registrado_por': 222222,
          'registrado_por_nombre': 'Gabriel',
        }, seq++);
        await db.setMeta(
          'usuarios_apk',
          jsonEncode([
            {
              'telegram_id': 222222,
              'nombre': 'Gabriel',
              'username': 'gabriel'
            },
          ]),
        );
        await tester.pumpWidget(
            const MaterialApp(home: PendienteScreen()));
      });
      // 412 dp de ancho (un teléfono real; a 360 la fila
      // «% del total» de la cabecera desborda — defecto
      // preexistente ajeno a GD-12).
      tester.view.physicalSize = const Size(824, 1830);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await _pumpReal(tester, vueltas: 12);
      // La tarjeta del entrenador arranca plegada: se abre.
      final titulo = find.text('Gabriel');
      expect(titulo, findsOneWidget,
          reason: 'la tarjeta de Gabriel debe cargarse');
      await tester.tap(titulo);
      await _pumpReal(tester, vueltas: 6);
      // Las 5 filas del día, visibles sin expandir nada más.
      expect(find.textContaining('Pago diario'), findsNWidgets(4));
      expect(find.textContaining('Dosis con agua'),
          findsOneWidget);
      // El total del día (4×200 + 900) se comprueba.
      expect(find.textContaining('1700 CUP'), findsWidgets);
      // Sin mecanismo de expansión de pagos.
      expect(find.textContaining('pagos más'), findsNothing);
      expect(find.text('Ocultar detalles'), findsNothing);
      // «Cobrar este día»: botón con texto y ≥ 48.
      final cobrar = find.widgetWithText(TextButton, 'Cobrar');
      expect(cobrar, findsOneWidget);
      expect(tester.getSize(cobrar).height, greaterThanOrEqualTo(48));
    });
  });
}
