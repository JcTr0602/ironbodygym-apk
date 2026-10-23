/// Eliminar conservando estadísticas (v1.8.0, diseño de Argón
/// con 4 candados): la cáscara (estado='eliminado') sostiene los
/// pagos/ventas anónimos del cliente borrado. Lo que se verifica:
///
/// - `esEliminadoDe` / `esClienteEliminado`: el predicado puro.
/// - `payloadOpEliminarCliente`: el contrato EXACTO de la op.
/// - La cáscara queda FUERA de toda lista/conteo de personas:
///   papelera (clientesInactivos), por vencer, inactivos por
///   vencimiento, inscripciones del mes y el buscador general.
/// - Su DINERO sigue contando: el pago de la cáscara entra en la
///   base de nómina («pagaron el mes») y en el historial de pagos
///   del mes, y su fila se resuelve con nombre «Cliente eliminado».
/// - `fiadoPendienteDeCliente`: la deuda que el diálogo de la
///   ficha avisa que se dará por incobrable (candado 3).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime get _hoy => DateTime.parse(hoyHabanaIso());

Future<void> _cliente(Database db,
    {required int id,
    String nombre = 'Cliente',
    String estado = 'activo',
    String? pagadoHasta,
    String? fechaInscripcion}) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': nombre,
      'estado': estado,
      'pagado_hasta': pagadoHasta,
      'fecha_inscripcion': fechaInscripcion,
    }),
    'sync_seq': 100 + id,
  });
}

List<int> _ids(List<Map<String, dynamic>> filas) =>
    [for (final f in filas) (f['id'] as num).toInt()]..sort();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('esEliminadoDe: solo estado eliminado es cáscara', () {
    expect(LocalDb.esEliminadoDe({'estado': 'eliminado'}), isTrue);
    expect(LocalDb.esEliminadoDe({'estado': 'activo'}), isFalse);
    expect(LocalDb.esEliminadoDe({'estado': 'inactivo'}), isFalse);
    expect(LocalDb.esEliminadoDe({'estado': null}), isFalse);
    expect(LocalDb.esEliminadoDe({}), isFalse);
    expect(esClienteEliminado({'estado': 'eliminado'}), isTrue);
    expect(esClienteEliminado({'estado': 'activo'}), isFalse);
  });

  test('payloadOpEliminarCliente: contrato exacto de la op', () {
    expect(
      payloadOpEliminarCliente(clienteId: 42, modo: 'conservar'),
      {'cliente_id': 42, 'definitivo': true, 'modo': 'conservar'},
    );
    expect(
      payloadOpEliminarCliente(clienteId: 42, modo: 'todo'),
      {'cliente_id': 42, 'definitivo': true, 'modo': 'todo'},
    );
    expect(
      payloadOpEliminarCliente(clienteId: 7, modo: 'cualquier'),
      {'cliente_id': 7, 'definitivo': true, 'modo': 'todo'},
      reason: 'un modo desconocido cae a todo, como el servidor',
    );
  });

  test('la cáscara no sale en papelera, por vencer ni el buscador',
      () async {
    final db = await _abrirDbVacia();
    final hoy = _hoy;
    // Semilla vía upsertMirror (el camino real del pull): es el
    // que mantiene el índice FTS que usa el buscador.
    Future<void> semilla(int id, Map<String, dynamic> data) =>
        LocalDb.instance
            .upsertMirror('clientes', id, {'id': id, ...data}, 100 + id);
    await semilla(1, {
      'nombre': 'Activo Uno',
      'estado': 'activo',
      'pagado_hasta': _iso(hoy.add(const Duration(days: 30))),
      'fecha_inscripcion': '2026-01-15',
    });
    await semilla(2, {
      'nombre': 'Cliente eliminado',
      'estado': 'eliminado',
      'pagado_hasta': _iso(hoy.add(const Duration(days: 3))),
      'fecha_inscripcion': _iso(hoy),
    });
    await semilla(3, {
      'nombre': 'Inactivo Tres',
      'estado': 'inactivo',
    });
    await semilla(5, {
      'nombre': 'Por Vencer Cinco',
      'estado': 'activo',
      'pagado_hasta': _iso(hoy.add(const Duration(days: 3))),
      'fecha_inscripcion': '2026-01-15',
    });

    expect(await LocalDb.instance.idsClientesEliminados(), {2});
    expect(_ids(await clientesInactivos()), [3],
        reason: 'la papelera no ofrece la cáscara como restaurable');
    expect(_ids(await porVencer7Dias()), [5],
        reason: 'la cáscara conserva pagado_hasta pero no vence '
            'como persona');
    expect(await buscarClientes('eliminado'), isEmpty,
        reason: 'el buscador general nunca devuelve la cáscara');
    expect(_ids(await buscarClientes('Activo')), [1],
        reason: 'el buscador sigue encontrando a los activos '
            '(solo busca activos, por diseño)');
    await db.close();
  });

  test('la cáscara no cuenta como inactiva ni como inscripción',
      () async {
    final db = await _abrirDbVacia();
    final hoy = _hoy;
    await _cliente(db,
        id: 2,
        nombre: 'Cliente eliminado',
        estado: 'eliminado',
        pagadoHasta: _iso(hoy.subtract(const Duration(days: 100))),
        fechaInscripcion: _iso(hoy));
    await _cliente(db,
        id: 4,
        nombre: 'Vencido Cuatro',
        pagadoHasta: _iso(hoy.subtract(const Duration(days: 100))),
        fechaInscripcion: '2026-01-15');

    expect(await inactivosCount(), 1,
        reason: 'solo el vencido real; la cáscara no es inactiva');
    expect(await inscripcionesMes(), 0,
        reason: 'la cáscara inscrita este mes ya no es inscripción');
    expect(await nuevosEsteMes(), 0);
    await db.close();
  });

  test('el dinero de la cáscara SIGUE contando (nómina e historial)',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    final base = DateTime.parse('$pref-01');
    // Vencimiento fuera del mes en curso: nadie sale por la
    // excepción de «vence dentro del mes».
    final hastaFuera = _iso(DateTime(base.year, base.month + 1, 10));
    Future<void> pago(int id, int clienteId) => db.insert('pagos', {
          'id': id,
          'data': jsonEncode({
            'id': id,
            'cliente_id': clienteId,
            'fecha': '$pref-05',
            'monto': 2000,
          }),
          'sync_seq': 500 + id,
          'fecha': '$pref-05',
          'cliente_id': clienteId,
          'telegram_user_id': 111,
          'metodo': 'efectivo',
        });
    await _cliente(db,
        id: 2,
        nombre: 'Cliente eliminado',
        estado: 'eliminado',
        pagadoHasta: hastaFuera);
    await pago(2, 2);
    await _cliente(db, id: 1, nombre: 'Activo Uno', pagadoHasta: hastaFuera);
    await pago(1, 1);

    expect(await NominaCalc.clientesQuePagaronElMes(pref), 2,
        reason: 'la base de nómina incluye el pago de la cáscara: '
            'borrar a la persona no reescribe el mes');
    final pagosMes = await LocalDb.instance.pagosDelMes(pref);
    expect(pagosMes.length, 2,
        reason: 'el historial de pagos del mes conserva su pago');
    expect(pagosMes.any((p) => (p['cliente_id'] as num).toInt() == 2),
        isTrue);
    final fila = (await LocalDb.instance.mirrorPorIds('clientes', [2]))
        .single;
    expect(fila['nombre'], 'Cliente eliminado',
        reason: 'el historial lo nombra anónimo, no desaparece');
    await db.close();
  });

  test('fiadoPendienteDeCliente: suma solo el fiado vivo del cliente',
      () async {
    final db = await _abrirDbVacia();
    Future<void> venta(int id, Map<String, dynamic> data) =>
        db.insert('ventas_suplementos', {
          'id': id,
          'data': jsonEncode({'id': id, ...data}),
          'sync_seq': 900 + id,
        });
    // Fiado vivo de la cáscara: 2 × 500 CUP.
    await venta(1, {
      'es_fiado': 1,
      'fiado_cliente_id': 2,
      'cliente_id': 2,
      'cantidad': 2,
      'precio': 500,
      'moneda': 'CUP',
    });
    // Fiado ya saldado localmente: no cuenta.
    await venta(2, {
      'es_fiado': 1,
      'fiado_saldado': 1,
      'fiado_cliente_id': 2,
      'cliente_id': 2,
      'cantidad': 1,
      'precio': 700,
      'moneda': 'CUP',
    });
    // Fiado de OTRO cliente: no cuenta.
    await venta(3, {
      'es_fiado': 1,
      'fiado_cliente_id': 9,
      'cliente_id': 9,
      'cantidad': 1,
      'precio': 300,
      'moneda': 'CUP',
    });
    // Venta normal (no fiado): no cuenta.
    await venta(4, {
      'es_fiado': 0,
      'cliente_id': 2,
      'cantidad': 1,
      'precio': 100,
      'moneda': 'CUP',
    });
    final tot = await LocalDb.instance.fiadoPendienteDeCliente(2);
    expect(tot['CUP'], 1000.0);
    expect(tot['USD'], 0.0);
    await db.close();
  });
}
