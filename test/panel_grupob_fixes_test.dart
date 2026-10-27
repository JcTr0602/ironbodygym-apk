/// Tests de los fixes del panel de código Grupo B 1.15 (2026-10-26).
///
/// - Fix 2: normalizarFechaCobro valida la parte fecha con round-trip
///   ANTES de convertir (la rama con Z/offset hacía tryParse sin
///   validar y normalizaba fechas imposibles).
/// - Fix 3: _fechaCalendario, misma validación, vía la superficie
///   pública NominaCalc.clientesQuePagaronElMes (fila del espejo con
///   pagado_hasta corrupto). El caso discriminante es noviembre:
///   '2026-10-32T12:00:00Z' con el código viejo se convertía a
///   2026-11-01 (dentro del mes → excluido, 0); con el fix es null
///   (sin fecha interpretable → se conserva, 1).
/// - Fix 6: diasVencidosCobro sobre fechas de calendario en UTC (el
///   código viejo con medianoches locales perdía un día al cruzar
///   el cambio de hora de Cuba, 2026-03-08).
/// - N7: fila del espejo con id no interpretable en el JSON. Nota:
///   mirrorPorIds fuerza el id de la COLUMNA SQL sobre el JSON, así
///   que por esta vía f['id'] siempre es el id de columna y la rama
///   `idTolerante(f['id']) == null` es defensa en profundidad; el
///   test prueba el comportamiento alcanzable: un id JSON corrupto
///   ('abc') NO rompe la exclusión (el id de columna manda).
/// - M6: los 4 sitios `esCasa: esCasa` de pagoDialogo (actual() y
///   montoEtiqueta() para mensual/menores y semanal/quincenal)
///   pasan por calcularPrecioCobro; Casa debe dar 0 en los 4.
/// - m8: el formatter de monto del diálogo (especificación: solo
///   dígitos, punto y coma).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/precio_cobro.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

int _seq = 9000;

Future<void> _pago(dynamic db,
    {required int id,
    required int? clienteIdDato,
    required String fecha,
    String periodo = 'mensual',
    dynamic monto = 2000,
    String metodo = 'efectivo'}) async {
  // Sin snapshot: el pago antiguo usa el espejo actual (fallback).
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': clienteIdDato,
      'fecha': fecha,
      'periodo': periodo,
      'monto': monto,
      'metodo': metodo,
    }),
    'sync_seq': _seq++,
    'fecha': fecha,
    'cliente_id': clienteIdDato is int ? clienteIdDato : null,
    'telegram_user_id': 111,
    'metodo': metodo,
  });
}

Future<void> _cliente(dynamic db,
    {required int id, String? pagadoHasta, dynamic cuentaCasa}) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': 'Cliente $id',
      'estado': 'activo',
      'pagado_hasta': pagadoHasta,
      if (cuentaCasa != null) 'cuenta_casa': cuentaCasa,
    }),
    'sync_seq': _seq++,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Panel Grupo B fix 2: normalizarFechaCobro con Z/offset', () {
    test('fecha imposible con Z y con offset da null', () {
      expect(normalizarFechaCobro('2026-02-30T12:00:00Z'), isNull);
      expect(normalizarFechaCobro('2026-02-30T12:00:00-04:00'), isNull);
      expect(normalizarFechaCobro('2026-13-01T00:00:00Z'), isNull);
    });

    test('fecha válida con Z/offset sigue convirtiendo a día Habana', () {
      // Oct 2026: Habana UTC-4. 02:30 UTC del 26 es 22:30 del 25.
      expect(normalizarFechaCobro('2026-10-26T02:30:00Z'), '2026-10-25');
      expect(normalizarFechaCobro('2026-10-26T10:00:00-04:00'),
          '2026-10-26');
    });
  });

  group('Panel Grupo B fix 6: diasVencidosCobro con DST', () {
    test('cruzar el cambio de hora de Cuba no pierde un día', () {
      // 2026-03-08 Cuba adelanta el reloj (día de 23 h). Con
      // medianoches locales el viejo daba 1; en calendario son 2.
      expect(diasVencidosCobro('2026-03-07', '2026-03-09'), 2);
      expect(diasVencidosCobro('2026-03-09', '2026-03-07'), -2);
    });

    test('casos sin DST no cambian', () {
      expect(diasVencidosCobro('2026-03-05', '2026-03-07'), 2);
      expect(diasVencidosCobro('2026-10-10', '2026-10-10'), 0);
      expect(diasVencidosCobro('no-fecha', '2026-10-10'), isNull);
    });
  });

  group('Panel Grupo B m8: formatter de monto', () {
    test('solo dígitos, punto y coma; letras fuera', () {
      final f = FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'));
      final out = f.formatEditUpdate(
        const TextEditingValue(text: '1'),
        const TextEditingValue(text: '12a.3,4b'),
      );
      expect(out.text, '12.3,4');
    });
  });

  group('Panel Grupo B M6: Casa da 0 en los 4 sitios del diálogo', () {
    const precios = <String, double>{
      'mensual': 2000,
      'menores': 1500,
      'transfer': 2500,
      'semanal': 600,
      'quincenal': 1200,
    };

    test('actual() mensual/menores y montoEtiqueta() mensual/menores', () {
      // Ambos sitios llaman al motor con periodo 'mensual'.
      expect(
          calcularPrecioCobro(
            periodo: 'mensual',
            metodo: 'efectivo',
            esCasa: true,
            esMenor: false,
            precios: precios,
            hoyHabana: '2026-10-26',
          ).monto,
          0);
      expect(
          calcularPrecioCobro(
            periodo: 'mensual',
            metodo: 'efectivo',
            esCasa: true,
            esMenor: true,
            precios: precios,
            hoyHabana: '2026-10-26',
          ).monto,
          0);
    });

    test('actual() y montoEtiqueta() semanal/quincenal', () {
      for (final periodo in ['semanal', 'quincenal']) {
        expect(
            calcularPrecioCobro(
              periodo: periodo,
              metodo: 'efectivo',
              esCasa: true,
              esMenor: false,
              precios: precios,
              hoyHabana: '2026-10-26',
            ).monto,
            0);
      }
    });

    test('control: sin Casa los precios no son 0', () {
      expect(
          calcularPrecioCobro(
            periodo: 'mensual',
            metodo: 'efectivo',
            esCasa: false,
            esMenor: false,
            precios: precios,
            hoyHabana: '2026-10-26',
          ).monto,
          2000);
      expect(
          calcularPrecioCobro(
            periodo: 'semanal',
            metodo: 'efectivo',
            esCasa: false,
            esMenor: false,
            precios: precios,
            hoyHabana: '2026-10-26',
          ).monto,
          600);
    });
  });

  group('Panel Grupo B fix 3: _fechaCalendario vía nómina', () {
    test('timestamp imposible con Z no excluye (viejo: excluía)', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _pago(db, id: 1, clienteIdDato: 10, fecha: '2026-11-05');
      await _cliente(db, id: 10, pagadoHasta: '2026-10-32T12:00:00Z');
      expect(await NominaCalc.clientesQuePagaronElMes('2026-11'), 1,
          reason: 'fecha imposible → null → sin fecha interpretable → '
              'se conserva');
      await db.close();
    });

    test('timestamp imposible con offset tampoco excluye', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _pago(db, id: 1, clienteIdDato: 10, fecha: '2026-11-05');
      await _cliente(db, id: 10, pagadoHasta: '2026-10-32T12:00:00-04:00');
      expect(await NominaCalc.clientesQuePagaronElMes('2026-11'), 1);
      await db.close();
    });

    test('control: timestamp válido con Z dentro del mes sí excluye',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _pago(db, id: 1, clienteIdDato: 10, fecha: '2026-11-05');
      await _cliente(db, id: 10, pagadoHasta: '2026-11-15T12:00:00Z');
      expect(await NominaCalc.clientesQuePagaronElMes('2026-11'), 0);
      await db.close();
    });
  });

  group('Panel Grupo B N7: id del espejo no interpretable', () {
    test('id JSON corrupto no rompe la exclusión (manda la columna)',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _pago(db, id: 1, clienteIdDato: 10, fecha: '2026-10-05');
      // Fila con id de columna 10 pero id JSON 'abc': mirrorPorIds
      // devuelve f['id'] = 10 y la exclusión aplica igual.
      await db.insert('clientes', {
        'id': 10,
        'data': jsonEncode({
          'id': 'abc',
          'nombre': 'Cliente 10',
          'estado': 'activo',
          'pagado_hasta': '2026-10-15',
        }),
        'sync_seq': _seq++,
      });
      expect(await NominaCalc.clientesQuePagaronElMes('2026-10'), 0);
      await db.close();
    });
  });
}
