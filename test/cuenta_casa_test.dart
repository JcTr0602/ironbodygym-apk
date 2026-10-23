/// Cuenta a la Casa (v1.7.0, oleada A++): el flag ortogonal NO
/// toca pagado_hasta ni el dinero. Lo que se verifica aquí:
///
/// - `cuentaCasaDe` / `nivelGympediaDe`: los predicados puros.
/// - `payloadOpCuentaCasa`: el contrato EXACTO de la op.
/// - Exclusiones con BD: la Casa queda FUERA de vencimientos,
///   atrasados, por vencer, morosos, inactivos y de la base de
///   nómina («pagaron el mes») — incluso con un pago insertado —
///   y DENTRO de «al día» (predicado de acceso, no de dinero).
/// - `updateMirrorCuentaCasa`: reflejo optimista + conteo.
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
    bool casa = false,
    String? pagadoHasta,
    String estado = 'activo'}) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': 'Cliente $id',
      'estado': estado,
      'pagado_hasta': pagadoHasta,
      if (casa) 'cuenta_casa': 1,
    }),
    'sync_seq': 100 + id,
  });
}

List<int> _ids(List<Map<String, dynamic>> filas) =>
    [for (final f in filas) (f['id'] as num).toInt()]..sort();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cuentaCasaDe: solo 1/true/\'1\' son Casa', () {
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': 1}), isTrue);
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': true}), isTrue);
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': '1'}), isTrue);
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': 0}), isFalse);
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': false}), isFalse);
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': '0'}), isFalse);
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': null}), isFalse);
    expect(LocalDb.cuentaCasaDe({}), isFalse);
    expect(LocalDb.cuentaCasaDe({'cuenta_casa': 2}), isFalse);
  });

  test('nivelGympediaDe: JSON válido manda; si no, regla de slugs', () {
    expect(LocalDb.nivelGympediaDe({'nivel': 'esencial'}), 'esencial');
    expect(LocalDb.nivelGympediaDe({'nivel': 'ESENCIAL'}), 'esencial');
    expect(LocalDb.nivelGympediaDe({'nivel': 'plus'}), 'plus');
    expect(LocalDb.nivelGympediaDe({'id': 'tu-primer-mes'}), 'esencial');
    expect(
        LocalDb.nivelGympediaDe({'id': 'entrenar-de-joven'}), 'esencial');
    expect(LocalDb.nivelGympediaDe({'id': 'otro-tema'}), 'plus');
    expect(
        LocalDb.nivelGympediaDe(
            {'nivel': 'raro', 'id': 'dolor-o-lesion'}),
        'esencial',
        reason: 'nivel inválido: cae a la regla de slugs');
    expect(
        LocalDb.nivelGympediaDe({'nivel': 'raro', 'id': 'otro'}),
        'plus');
    expect(LocalDb.nivelGympediaDe({}), 'plus');
    expect(LocalDb.slugsGympediaEsenciales.length, 7);
  });

  test('payloadOpCuentaCasa: contrato exacto de la op', () {
    expect(
      payloadOpCuentaCasa(clienteId: 42, activar: true, motivo: ' familia '),
      {'cliente_id': 42, 'activar': true, 'motivo': 'familia'},
    );
    expect(
      payloadOpCuentaCasa(clienteId: 42, activar: false),
      {'cliente_id': 42, 'activar': false},
      reason: 'sin motivo no viaja la clave',
    );
    expect(
      payloadOpCuentaCasa(clienteId: 7, activar: true, motivo: '   '),
      {'cliente_id': 7, 'activar': true},
      reason: 'motivo en blanco se omite',
    );
  });

  test('NominaCalc.excluirCuentasCasa (puro)', () {
    final ids = {1, 2, 3};
    NominaCalc.excluirCuentasCasa(ids, {2});
    expect(ids, {1, 3});
  });

  test('exclusiones de Casa en vencimientos y listados', () async {
    final db = await _abrirDbVacia();
    final hoy = _hoy;
    await _cliente(db, id: 1, casa: true); // Casa, pagado_hasta NULL
    await _cliente(db,
        id: 2,
        casa: true,
        pagadoHasta: _iso(hoy.subtract(const Duration(days: 100))));
    await _cliente(db,
        id: 3, pagadoHasta: _iso(hoy.subtract(const Duration(days: 1))));
    await _cliente(db, id: 4, pagadoHasta: _iso(hoy));
    await _cliente(db,
        id: 5, pagadoHasta: _iso(hoy.add(const Duration(days: 2))));
    await _cliente(db,
        id: 6, pagadoHasta: _iso(hoy.subtract(const Duration(days: 100))));

    expect(_ids(await vencenHoy()), [4],
        reason: 'la Casa nunca «vence hoy»');
    expect(_ids(await atrasados(masDe30: false)), [3]);
    expect(_ids(await atrasados(masDe30: true)), [6],
        reason: 'la Casa con fecha vieja NO es atrasada');
    expect(_ids(await porVencer()), [5]);
    expect(_ids(await porVencer7Dias()), [4, 5]);
    expect(await morosos(), 2,
        reason: 'morosos: solo los normales vencidos (3 y 6)');
    expect(await inactivosCount(), 1,
        reason: 'inactivos: solo el normal de hace 100 días');
    expect(_ids(await clientesAlDia()), [1, 2, 4, 5],
        reason: 'al día es predicado de ACCESO: la Casa siempre '
            'está al día, con fecha o sin ella');
    await db.close();
  });

  test('nómina: la Casa no entra en «pagaron el mes» ni con pago',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    final base = DateTime.parse('$pref-01');
    // Vencimiento FUERA del mes en curso (día 10 del siguiente):
    // la regla de vencimiento no excluye a nadie por ese motivo.
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
    await _cliente(db, id: 1, casa: true, pagadoHasta: hastaFuera);
    await pago(1, 1); // la Casa «pagó» un mes suelto: no genera base
    await _cliente(db, id: 2, pagadoHasta: hastaFuera);
    await pago(2, 2);
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 1,
        reason: 'solo cuenta el cliente normal');
    await db.close();
  });

  test('updateMirrorCuentaCasa: reflejo optimista y conteo', () async {
    final db = await _abrirDbVacia();
    await LocalDb.instance
        .upsertMirror('clientes', 7, {'nombre': 'Prima', 'estado': 'activo'}, 1);
    expect(await LocalDb.instance.conteoCuentasCasa(), 0);
    await LocalDb.instance.updateMirrorCuentaCasa(7,
        activar: true,
        motivo: 'familia',
        enIso: '2026-10-23T10:00:00',
        por: 'jctr0602');
    expect(await LocalDb.instance.conteoCuentasCasa(), 1);
    expect(await LocalDb.instance.idsCuentasCasa(), {7});
    final fila = (await LocalDb.instance.allMirror('clientes'))
        .firstWhere((c) => c['id'] == 7);
    expect(fila['cuenta_casa'], 1);
    expect(fila['cuenta_casa_motivo'], 'familia');
    final col = await db.query('clientes',
        columns: ['cuenta_casa'], where: 'id=?', whereArgs: [7]);
    expect(col.single['cuenta_casa'], 1);
    // Al quitar: el flag cae y el motivo se limpia.
    await LocalDb.instance.updateMirrorCuentaCasa(7, activar: false);
    expect(await LocalDb.instance.conteoCuentasCasa(), 0);
    final fila2 = (await LocalDb.instance.allMirror('clientes'))
        .firstWhere((c) => c['id'] == 7);
    expect(LocalDb.cuentaCasaDe(fila2), isFalse);
    expect(fila2['cuenta_casa_motivo'], isNull);
    await db.close();
  });
}
