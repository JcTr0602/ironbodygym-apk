/// Tests del Bloque 2 NÚCLEO (1.10.0, Argón AMARILLO).
///
/// - Precedencia D6 pura (calcularPrecioCobro): Casa, especial por
///   método, método en null, periodo cruzado, vencida, aún no
///   vigente, menores con especial, Oferta, estándar.
/// - Unicidad DB: una sola fila activa por (cliente, periodo) y
///   otorgar desactiva la anterior en la misma transacción.
/// - Siembra: INSERT OR IGNORE no duplica ni resucita.
/// - Split básico/sensible: solo claves no null + cliente_id.
/// - Subtotales E4: anuladas excluidas.
/// - Lista blanca G1: prohibidas quedan literales y se reportan.
/// - Frescura G1: null solo con sync fresca y sin cola.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plantilla_mensaje.dart';
import 'package:ironbody_gym/precio_cobro.dart';
import 'package:ironbody_gym/tarifa_especial.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _precios = <String, double>{
  'mensual': 2000,
  'menores': 1500,
  'transfer': 2500,
  'semanal': 600,
  'quincenal': 1200,
};

/// Especial tipo Kevin: efectivo 1000, transferencia null.
Map<String, dynamic> _espKevin({String? hasta, String? desde}) => {
      'periodo': 'mensual',
      'monto_efectivo': 1000,
      'monto_transferencia': null,
      'vigente_desde': desde ?? '2026-01-01',
      'vigente_hasta': hasta,
    };

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

void main() {
  group('precedencia D6 (pura)', () {
    test('Casa rige sobre todo y vale 0', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: true,
          esMenor: false,
          precios: _precios,
          especial: _espKevin(),
          hoyHabana: '2026-10-24');
      expect(r.monto, 0);
      expect(r.escalon, 'casa');
      expect(r.avisos,
          contains('Es Casa y tiene tarifa especial: rige Casa (0 CUP)'));
    });

    test('especial efectivo (Kevin) aplica en efectivo', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: false,
          precios: _precios,
          especial: _espKevin(),
          hoyHabana: '2026-10-24');
      expect(r.monto, 1000);
      expect(r.escalon, 'especial');
    });

    test('método en null cae a estándar (no menor)', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'transferencia',
          esCasa: false,
          esMenor: false,
          precios: _precios,
          especial: _espKevin(),
          hoyHabana: '2026-10-24');
      expect(r.monto, 2500);
      expect(r.escalon, 'estandar');
    });

    test('método en null cae a menores (menor)', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'transferencia',
          esCasa: false,
          esMenor: true,
          precios: _precios,
          especial: _espKevin(),
          hoyHabana: '2026-10-24');
      expect(r.monto, 1500);
      expect(r.escalon, 'menores');
    });

    test('periodo cruzado: especial mensual NO aplica a semanal', () {
      final r = calcularPrecioCobro(
          periodo: 'semanal',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: false,
          precios: _precios,
          especial: _espKevin(),
          hoyHabana: '2026-10-24');
      expect(r.monto, 600);
      expect(r.escalon, 'estandar');
    });

    test('especial vencida no pre-rellena + aviso exacto', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: false,
          precios: _precios,
          especial: _espKevin(hasta: '2026-10-01'),
          hoyHabana: '2026-10-24');
      expect(r.monto, 2000);
      expect(r.escalon, 'estandar');
      expect(r.avisos,
          contains('Especial vencida el 2026-10-01 · se aplica tarifa normal'));
    });

    test('especial aún no vigente avisa y sigue', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: false,
          precios: _precios,
          especial: _espKevin(desde: '2026-11-01'),
          hoyHabana: '2026-10-24');
      expect(r.monto, 2000);
      expect(r.avisos, contains('Especial aún no vigente (desde 2026-11-01)'));
    });

    test('menores con especial: rige la especial + aviso', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: true,
          precios: _precios,
          especial: _espKevin(),
          hoyHabana: '2026-10-24');
      expect(r.monto, 1000);
      expect(r.escalon, 'especial');
      expect(r.avisos, contains('Tiene menores y especial: rige la especial'));
    });

    test('Oferta (monto explícito) entre menores y estándar', () {
      final r = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: false,
          precios: _precios,
          montoOferta: 1000,
          hoyHabana: '2026-10-24');
      expect(r.monto, 1000);
      expect(r.escalon, 'oferta');
    });

    test('estándar por periodo y método', () {
      PrecioCobro c(String periodo, String metodo) =>
          calcularPrecioCobro(
              periodo: periodo,
              metodo: metodo,
              esCasa: false,
              esMenor: false,
              precios: _precios,
              hoyHabana: '2026-10-24');
      expect(c('semanal', 'efectivo').monto, 600);
      expect(c('quincenal', 'efectivo').monto, 1200);
      expect(c('mensual', 'efectivo').monto, 2000);
      expect(c('mensual', 'transferencia').monto, 2500);
    });
  });

  group('split básico / sensible', () {
    test('payloadBasico solo incluye claves no null + cliente_id', () {
      final p = payloadBasico(
          clienteId: 70, nombre: 'Kevin', telefono: '51234567');
      expect(p, {'cliente_id': 70, 'nombre': 'Kevin', 'telefono': '51234567'});
    });

    test('payloadSensible solo incluye claves no null + cliente_id', () {
      final p = payloadSensible(clienteId: 70, pagadoHasta: '2026-11-30');
      expect(p, {'cliente_id': 70, 'pagado_hasta': '2026-11-30'});
      final p2 = payloadSensible(clienteId: 70, cuentaCasa: true);
      expect(p2['cuenta_casa'], 1);
    });
  });

  group('Extracto E4 (puro)', () {
    test('total + subtotales, anuladas excluidas', () {
      final r = resumenExtracto([
        {'tipo': 'suplemento', 'monto': 1000, 'anulada': 0},
        {'tipo': 'servicio', 'monto': 600, 'anulada': 0},
        {'tipo': 'suplemento', 'monto': 5000, 'anulada': 1},
        {'tipo': 'servicio', 'monto': 900, 'anulada': true},
      ]);
      expect(r.total, {'CUP': 1600.0});
      expect(r.suplementos, {'CUP': 1000.0});
      expect(r.servicios, {'CUP': 600.0});
    });

    test('monedas NO se mezclan: USD aparte de CUP', () {
      // Caso real 2026-10-26: 3 ventas USD (25 + 40 + 60) que el
      // Extracto pintaba como CUP y sumaba con los CUP de dosis.
      final r = resumenExtracto([
        {'tipo': 'suplemento', 'monto': 25, 'moneda': 'USD', 'anulada': 0},
        {'tipo': 'suplemento', 'monto': 40, 'moneda': 'USD', 'anulada': 0},
        {'tipo': 'suplemento', 'monto': 60, 'moneda': 'USD', 'anulada': 0},
        {'tipo': 'servicio', 'monto': 1200, 'moneda': 'CUP', 'anulada': 0},
        {'tipo': 'suplemento', 'monto': 999, 'moneda': 'USD', 'anulada': 1},
      ]);
      expect(r.total, {'USD': 125.0, 'CUP': 1200.0});
      expect(r.suplementos, {'USD': 125.0});
      expect(r.servicios, {'CUP': 1200.0});
      expect(textoMontosPorMoneda(r.total), '1200 CUP · 125 USD');
      expect(textoMontosPorMoneda(r.suplementos), '125 USD');
      expect(textoMontosPorMoneda({}), '0 CUP');
    });
  });

  group('lista blanca G1 (pura)', () {
    test('blancas se sustituyen, prohibidas quedan literales', () {
      final r = renderPlantilla(
          'Hola {{nombre}}, vence {{fecha_vencimiento}}. '
          'Motivo: {{motivo}} de {{otorgado_por}}. Notas: {{notas}}. '
          'Te ahorras {{te_ahorras}}.',
          {'nombre': 'Kevin', 'fecha_vencimiento': '30/11/2026'});
      expect(r.texto, contains('Hola Kevin, vence 30/11/2026.'));
      expect(r.texto, contains('Motivo: {{motivo}}'));
      expect(r.texto, contains('de {{otorgado_por}}'));
      expect(r.texto, contains('Notas: {{notas}}'));
      expect(r.texto, contains('Te ahorras {{te_ahorras}}'));
      expect(r.bloqueadas,
          containsAll(['motivo', 'otorgado_por', 'notas', 'te_ahorras']));
    });

    test('frescura: null solo con sync fresca y sin cola', () {
      final ahora = DateTime.parse('2026-10-24T12:00:00-04:00');
      expect(
          avisoFrescura(
              ultimoPullIso: '2026-10-24T11:30:00-04:00',
              opsPendientes: 0,
              ahora: ahora),
          isNull);
      expect(
          avisoFrescura(
              ultimoPullIso: '2026-10-24T11:30:00-04:00',
              opsPendientes: 2,
              ahora: ahora),
          contains('Confirma si el cliente ya pagó en el turno'));
      expect(
          avisoFrescura(
              ultimoPullIso: '2026-10-24T08:00:00-04:00',
              opsPendientes: 0,
              ahora: ahora),
          contains('Última sync hace 4 h'));
      expect(
          avisoFrescura(
              ultimoPullIso: null, opsPendientes: 0, ahora: ahora),
          contains('Sin registro de sincronización'));
    });
  });

  group('tarifa_especial en BD', () {
    test('índice único parcial: 2ª activa mismo (cliente, periodo) falla',
        () async {
      final db = await _abrirDbVacia();
      await db.insert('tarifa_especial', {
        'id': 't1',
        'cliente_id': 900001,
        'nombre': 'A',
        'periodo': 'mensual',
        'vigente_desde': '2026-10-24',
        'activa': 1,
        'creada_ts': '2026-10-24T10:00:00-04:00',
        'actualizada_ts': '2026-10-24T10:00:00-04:00',
      });
      expect(
          () => db.insert('tarifa_especial', {
                'id': 't2',
                'cliente_id': 900001,
                'nombre': 'B',
                'periodo': 'mensual',
                'vigente_desde': '2026-10-24',
                'activa': 1,
                'creada_ts': '2026-10-24T10:00:00-04:00',
                'actualizada_ts': '2026-10-24T10:00:00-04:00',
              }),
          throwsA(isA<DatabaseException>()));
      // Pero una inactiva sí puede coexistir con la activa.
      await db.insert('tarifa_especial', {
        'id': 't3',
        'cliente_id': 900001,
        'nombre': 'C',
        'periodo': 'mensual',
        'vigente_desde': '2026-10-24',
        'activa': 0,
        'creada_ts': '2026-10-24T10:00:00-04:00',
        'actualizada_ts': '2026-10-24T10:00:00-04:00',
      });
      final activas = await db.query('tarifa_especial',
          where: 'cliente_id=? AND activa=1', whereArgs: [900001]);
      expect(activas.length, 1);
    });

    test('otorgar desactiva la anterior en la misma transacción', () async {
      await _abrirDbVacia();
      final id1 = await otorgarTarifaEspecial(
          clienteId: 900002,
          nombre: 'Primera',
          montoEfectivo: 1000,
          motivo: 'prueba');
      final id2 = await otorgarTarifaEspecial(
          clienteId: 900002,
          nombre: 'Segunda',
          montoEfectivo: 1200,
          motivo: 'prueba 2');
      final activa = await tarifaActivaPara(900002, 'mensual');
      expect(activa?['id'], id2);
      final vieja = await LocalDb.instance.db.then((db) => db.query(
          'tarifa_especial',
          where: 'id=?',
          whereArgs: [id1]));
      expect(vieja.first['activa'], 0);
      expect('${vieja.first['historial']}',
          contains('inactivada_por_nueva'));
    });

    test('revocar no borra y la legacy sigue muerta', () async {
      await _abrirDbVacia();
      final id = await otorgarTarifaEspecial(
          clienteId: 900003,
          nombre: 'Para revocar',
          montoEfectivo: 1000,
          motivo: 'prueba');
      await revocarTarifaEspecial(id: id, motivo: 'ya no aplica');
      expect(await tarifaActivaPara(900003, 'mensual'), isNull);
      expect(await tieneAlgunRegistroTarifa(900003), isTrue);
      // precioCobroParaCliente: con registro (aunque inactivo) y
      // legacy, la legacy se ignora → estándar.
      final r = await precioCobroParaCliente(
          cliente: {
            'id': 900003,
            'tarifa_especial_transferencia': 2000,
          },
          periodo: 'mensual',
          metodo: 'transferencia',
          precios: _precios);
      expect(r.monto, 2500);
      expect(r.escalon, 'estandar');
    });

    test('legacy solo actúa sin ningún registro (transferencia mensual)',
        () async {
      await _abrirDbVacia();
      final r = await precioCobroParaCliente(
          cliente: {
            'id': 900004,
            'tarifa_especial_transferencia': 2000,
          },
          periodo: 'mensual',
          metodo: 'transferencia',
          precios: _precios);
      expect(r.monto, 2000);
      expect(r.escalon, 'especial');
      // En efectivo la legacy NO aplica.
      final r2 = await precioCobroParaCliente(
          cliente: {
            'id': 900004,
            'tarifa_especial_transferencia': 2000,
          },
          periodo: 'mensual',
          metodo: 'efectivo',
          precios: _precios);
      expect(r2.monto, 2000);
      expect(r2.escalon, 'estandar');
    });

    test('INSERT OR IGNORE con id semilla no duplica ni cambia el monto',
        () async {
      final db = await _abrirDbVacia();
      await db.rawInsert(
          'INSERT OR IGNORE INTO tarifa_especial '
          '(id, cliente_id, nombre, monto_transferencia, periodo, '
          'vigente_desde, activa) VALUES (?,?,?,?,?,?,1)',
          ['seed_esp_145', 145, 'otro', 9999, 'mensual', '2026-10-24']);
      final filas = await db.query('tarifa_especial',
          where: 'id=?', whereArgs: ['seed_esp_145']);
      expect(filas.length, 1);
      expect(filas.first['monto_transferencia'], 2000,
          reason: 'la siembra original no se pisa');
    });
  });
}
