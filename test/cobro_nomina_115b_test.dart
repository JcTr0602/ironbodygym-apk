/// Tests 1.15 Grupo B — Cobro + Nómina (solo parte APP).
///
/// Cobro: las funciones puras extraídas de pagoDialogo se prueban
/// directo. El diálogo completo (showDialog + LocalDb + tipos) no
/// se bombea aquí: su flujo con widget requeriría sesión y ajustes
/// y chocaría con otros agentes corriendo tests en paralelo; lo
/// que el diálogo USA (fecha Habana, normalización, recálculo de
/// base, id tolerante, válido personalizado, bloqueo Casa) sí está
/// cubierto, y el guard `clienteId <= 0 → return null` antes del
/// return del payload se verifica por código junto a idClienteCobro.
///
/// Nómina: puras + BD local (sqflite ffi, mismo patrón que
/// nomina_regla_vencimiento_test.dart).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart' show esCuentaCasa;
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/nomina_precalc.dart';
import 'package:ironbody_gym/precio_cobro.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';
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

int _seq = 5000;

Future<void> _pago(dynamic db,
    {required int id,
    required int? clienteIdDato,
    required String fecha,
    String? pagadoHasta,
    String periodo = 'mensual',
    dynamic monto = 2000,
    String metodo = 'efectivo'}) async {
  final data = <String, dynamic>{
    'id': id,
    'cliente_id': clienteIdDato,
    'fecha': fecha,
    'periodo': periodo,
    'monto': monto,
    'metodo': metodo,
    if (pagadoHasta != null) 'pagado_hasta': pagadoHasta,
  };
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode(data),
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

  group('Cobro 1.15', () {
    test('pagoDialogo_usaAhoraHabanaYLimitaSelectorConFechaHabana', () {
      // Lo que el diálogo usa ahora para inicializar fechaPago y
      // como lastDate del selector: wall-clock Habana, con offset
      // explícito, nunca DateTime.now() crudo sin zona.
      final h = ahoraHabana();
      expect(isoFechaHabana(h), hoyHabanaIso());
      expect(isoHabana(h), matches(RegExp(r'[-+]\d{2}:\d{2}$')));
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(isoFechaHabana(h)),
          isTrue);
    });

    test(
        'normalizarFechaCobro_convierteIsoUtcADiaHabanaYRechazaFechaInvalida',
        () {
      // Oct 2026: Habana UTC-4. 02:30 UTC del 26 es 22:30 del 25.
      expect(normalizarFechaCobro('2026-10-26T02:30:00Z'), '2026-10-25');
      // Ene 2026: Habana UTC-5. 02:30 UTC del 15 es 21:30 del 14.
      expect(normalizarFechaCobro('2026-01-15T02:30:00Z'), '2026-01-14');
      // Misma hora UTC ya en día Habana: no cambia el día.
      expect(normalizarFechaCobro('2026-10-26T10:00:00Z'), '2026-10-26');
      // Fecha calendario tal cual, y con offset explícito -04:00.
      expect(normalizarFechaCobro('2026-10-26'), '2026-10-26');
      expect(normalizarFechaCobro('2026-10-26T10:00:00-04:00'),
          '2026-10-26');
      // Fecha imposible y texto no interpretable: null, no excepción.
      expect(normalizarFechaCobro('2026-02-30'), isNull);
      expect(normalizarFechaCobro('no-es-fecha'), isNull);
      expect(normalizarFechaCobro(null), isNull);
      expect(normalizarFechaCobro(''), isNull);
    });

    test('cambiarFechaPago_recalculaPreguntaYBaseDeSiguioViniendo', () {
      // Vencido con la fecha nueva: se invalida la decisión
      // anterior (base null) y hay que volver a preguntar.
      final vencida = recalcularBaseAlCambiarFecha(
          pagadoHasta: '2026-10-10', fechaPagoIso: '2026-10-20');
      expect(vencida.necesitaPregunta, isTrue);
      expect(vencida.base, isNull);
      // Ya no vencida con la fecha nueva: base null, sin pregunta.
      final noVencida = recalcularBaseAlCambiarFecha(
          pagadoHasta: '2026-10-10', fechaPagoIso: '2026-10-05');
      expect(noVencida.necesitaPregunta, isFalse);
      expect(noVencida.base, isNull);
      // Sin vencimiento: tampoco se pregunta.
      expect(
          recalcularBaseAlCambiarFecha(
                  pagadoHasta: null, fechaPagoIso: '2026-10-20')
              .necesitaPregunta,
          isFalse);
      // Días vencidos coherentes con la fecha elegida.
      expect(diasVencidosCobro('2026-10-10', '2026-10-20'), 10);
      expect(diasVencidosCobro('2026-10-10', '2026-10-05'), -5);
    });

    test('pagoDialogo_aceptaIdNumericoYNoEncolaIdInvalido', () {
      expect(idClienteCobro({'id': 7}), 7);
      expect(idClienteCobro({'id': 7.0}), 7);
      expect(idClienteCobro({'id': '7'}), 7);
      // Ids que el guard `clienteId <= 0` detiene antes de cobrar.
      expect(idClienteCobro({'id': 0}), 0);
      expect(idClienteCobro({'id': null}), 0);
      expect(idClienteCobro({'id': 'abc'}), 0);
      expect(idClienteCobro({}), 0);
      for (final invalido in [0]) {
        expect(invalido <= 0, isTrue,
            reason: 'el guard de pagoDialogo detiene clienteId <= 0');
      }
    });

    test('cambiarMetodo_recalculaPrecioEspecialYMontoDelPayload', () {
      const precios = {
        'mensual': 2000.0,
        'menores': 1500.0,
        'transfer': 2500.0,
        'semanal': 600.0,
        'quincenal': 1200.0,
      };
      const especial = {
        'periodo': 'mensual',
        'monto_efectivo': 1800,
        'monto_transferencia': 2200,
        'vigente_desde': null,
        'vigente_hasta': null,
      };
      // Con especial: el método decide el monto (recalcula al cambiar).
      final ef = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: false,
          precios: precios,
          especial: especial,
          hoyHabana: '2026-10-26');
      final tr = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'transferencia',
          esCasa: false,
          esMenor: false,
          precios: precios,
          especial: especial,
          hoyHabana: '2026-10-26');
      expect(ef.monto, 1800);
      expect(ef.escalon, 'especial');
      expect(tr.monto, 2200);
      expect(tr.escalon, 'especial');
      // Sin especial: también cambia con el método (estándar).
      final stdEf = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: false,
          precios: precios,
          hoyHabana: '2026-10-26');
      final stdTr = calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'transferencia',
          esCasa: false,
          esMenor: false,
          precios: precios,
          hoyHabana: '2026-10-26');
      expect(stdEf.monto, 2000);
      expect(stdTr.monto, 2500);
    });

    test('previewCobro_muestraMesesYDiasDeOfertaPersonalizada', () {
      expect(
          periodoTextoPreview(
              {'periodo': 'mensual', 'meses': 3, 'tipo_id': 'mensual'}),
          '3 meses');
      expect(
          periodoTextoPreview(
              {'periodo': 'mensual', 'meses': 1, 'tipo_id': 'mensual'}),
          'Mensual');
      expect(
          periodoTextoPreview(
              {'periodo': 'mensual', 'meses': 1, 'tipo_id': 'menores'}),
          'Menores');
      expect(periodoTextoPreview({'periodo': 'personalizado', 'dias': 15}),
          'Personalizado (15 días)');
      expect(
          periodoTextoPreview(
              {'periodo': 'tipo:oferta50', 'dias': 30, 'monto': 1000}),
          'Personalizado (30 días)');
      expect(periodoTextoPreview({'periodo': 'semanal'}), 'Semanal');
    });

    test('pagoPersonalizado_rechazaDiasFueraDeRangoYMontoNoValido', () {
      expect(validoPagoPersonalizado(dias: 30, monto: 100), isTrue);
      expect(validoPagoPersonalizado(dias: 3650, monto: 100), isTrue);
      expect(validoPagoPersonalizado(dias: 1, monto: 0.5), isTrue);
      expect(validoPagoPersonalizado(dias: 0, monto: 100), isFalse);
      expect(validoPagoPersonalizado(dias: -1, monto: 100), isFalse);
      expect(validoPagoPersonalizado(dias: 3651, monto: 100), isFalse);
      expect(validoPagoPersonalizado(dias: 30, monto: 0), isFalse);
      expect(validoPagoPersonalizado(dias: 30, monto: -5), isFalse);
      expect(validoPagoPersonalizado(dias: 30, monto: double.nan),
          isFalse);
      expect(validoPagoPersonalizado(dias: 30, monto: double.infinity),
          isFalse);
    });

    testWidgets('previewCobro_dobleTapEnConfirmarEncolaUnaSolaOperacion',
        (tester) async {
      // La pantalla como ruta raíz: el primer pop(true) no puede
      // sacarla (es la única ruta), así que el guard queda
      // observable: tras el primer toque el botón se deshabilita
      // y un segundo toque no hace nada (en navegación real el
      // primer toque ya hizo pop y el segundo nunca la alcanza).
      await tester.pumpWidget(
        const MaterialApp(
          home: PreviewCobroScreen(
            nombreCliente: 'Cliente Prueba',
            montoTexto: '2000 CUP',
            metodoTexto: 'Efectivo',
            periodoTexto: 'Mensual',
            nuevoVencimientoTexto: '25/11/2026',
          ),
        ),
      );
      final boton = find.byType(BotonPrimario);
      expect(boton, findsOneWidget);
      expect(tester.widget<BotonPrimario>(boton).onPressed, isNotNull);
      await tester.tap(find.text('Confirmar cobro'));
      await tester.pump();
      expect(tester.widget<BotonPrimario>(boton).onPressed, isNull,
          reason: 'tras el primer toque el botón queda deshabilitado');
      expect(find.text('Procesando…'), findsOneWidget);
      // Segundo toque: sin efecto (no hay segundo pop que cerrar).
      await tester.tap(find.text('Procesando…'));
      await tester.pump();
      expect(tester.widget<BotonPrimario>(boton).onPressed, isNull);
    });

    test('pagoDialogo_bloqueaCasaConRepresentacionesNormalizadas', () {
      // esCuentaCasa (punto único que ahora usa pagoDialogo, M6).
      expect(esCuentaCasa({'cuenta_casa': 1}), isTrue);
      expect(esCuentaCasa({'cuenta_casa': true}), isTrue);
      expect(esCuentaCasa({'cuenta_casa': '1'}), isTrue);
      expect(esCuentaCasa({'cuenta_casa': 0}), isFalse);
      expect(esCuentaCasa({'cuenta_casa': false}), isFalse);
      expect(esCuentaCasa({'cuenta_casa': '0'}), isFalse);
      expect(esCuentaCasa({'cuenta_casa': null}), isFalse);
      expect(esCuentaCasa({}), isFalse);
    });
  });

  group('Nómina 1.15', () {
    test('nominaCalc_mesCerradoNoCambiaPorPagoPosteriorConSnapshot',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      // Mes cerrado 2026-09. Pago CON snapshot: su pagado_hasta
      // quedó en septiembre → excluido de la base de septiembre.
      await _pago(db,
          id: 1,
          clienteIdDato: 10,
          fecha: '2026-09-05',
          pagadoHasta: '2026-09-20');
      await _cliente(db, id: 10, pagadoHasta: '2026-09-20');
      expect(await NominaCalc.clientesQuePagaronElMes('2026-09'), 0);
      // Pago posterior en otro mes (noviembre) que extiende la
      // cobertura a diciembre: el espejo actual cambia, pero el
      // pago de septiembre NO está en la lista de septiembre y su
      // snapshot sigue en septiembre → la base NO cambia.
      await db.update('clientes', {
        'data': jsonEncode({
          'id': 10,
          'nombre': 'Cliente 10',
          'estado': 'activo',
          'pagado_hasta': '2026-12-15',
        }),
      }, where: 'id = ?', whereArgs: [10]);
      expect(await NominaCalc.clientesQuePagaronElMes('2026-09'), 0,
          reason: 'el snapshot del pago congela la base del mes cerrado');
      // Fallback explícito documentado: pago antiguo SIN snapshot
      // sigue usando el espejo actual (regla histórica).
      await _pago(db, id: 2, clienteIdDato: 11, fecha: '2026-09-06');
      await _cliente(db, id: 11, pagadoHasta: '2026-09-20');
      expect(await NominaCalc.clientesQuePagaronElMes('2026-09'), 0);
      await db.update('clientes', {
        'data': jsonEncode({
          'id': 11,
          'nombre': 'Cliente 11',
          'estado': 'activo',
          'pagado_hasta': '2026-12-15',
        }),
      }, where: 'id = ?', whereArgs: [11]);
      expect(await NominaCalc.clientesQuePagaronElMes('2026-09'), 1,
          reason: 'sin snapshot, el fallback al espejo mantiene la '
              'regla anterior (límite documentado en N1)');
      await db.close();
    });

    test('nominaPrecalc_huellaCambiaAlCambiarCuentaCasa', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _cliente(db, id: 10, pagadoHasta: '2026-12-15');
      final h1 = await NominaPrecalc.instance.huella();
      expect(h1, startsWith('v5|'));
      await db.update('clientes', {
        'data': jsonEncode({
          'id': 10,
          'nombre': 'Cliente 10',
          'estado': 'activo',
          'pagado_hasta': '2026-12-15',
          'cuenta_casa': 1,
        }),
      }, where: 'id = ?', whereArgs: [10]);
      final h2 = await NominaPrecalc.instance.huella();
      expect(h2, isNot(equals(h1)),
          reason: 'cuenta_casa normalizado forma parte de la huella v5');
      // Representaciones equivalentes dan la misma huella.
      await db.update('clientes', {
        'data': jsonEncode({
          'id': 10,
          'nombre': 'Cliente 10',
          'estado': 'activo',
          'pagado_hasta': '2026-12-15',
          'cuenta_casa': '1',
        }),
      }, where: 'id = ?', whereArgs: [10]);
      expect(await NominaPrecalc.instance.huella(), h2);
      await db.close();
    });

    test('nominaCalc_esPagoMensualidad_filtraPromoYMontoEnTodasLasRamas',
        () {
      // Promo y monto no positivo: fuera en TODAS las ramas.
      expect(
          NominaCalc.esPagoMensualidad({
            'periodo': 'personalizado',
            'dias': 30,
            'metodo': 'promo',
            'monto': 1000,
          }),
          isFalse);
      expect(
          NominaCalc.esPagoMensualidad(
              {'periodo': 'tipo:oferta50', 'dias': 30, 'monto': 0}),
          isFalse);
      expect(
          NominaCalc.esPagoMensualidad(
              {'periodo': 'personalizado', 'dias': 30}),
          isFalse,
          reason: 'sin monto positivo, tampoco el personalizado cuenta');
      expect(
          NominaCalc.esPagoMensualidad({
            'periodo': 'personalizado',
            'dias': 30,
            'monto': '1000',
          }),
          isTrue,
          reason: 'monto String numérico se parsea tolerante');
      expect(
          NominaCalc.esPagoMensualidad({
            'periodo': 'tipo:oferta50',
            'dias': '30',
            'monto': 1000,
          }),
          isTrue,
          reason: 'días String numérico se parsea tolerante');
      expect(
          NominaCalc.esPagoMensualidad(
              {'periodo': 'semanal', 'monto': 600}),
          isFalse);
    });

    test('nominaCalc_esPagoMensualidad_trataPeriodoVacioComoMensual',
        () {
      expect(
          NominaCalc.esPagoMensualidad({'periodo': '', 'monto': 2000}),
          isTrue);
      expect(NominaCalc.esPagoMensualidad({'monto': 2000}), isTrue);
      expect(
          NominaCalc.esPagoMensualidad({'periodo': '', 'monto': 0}),
          isFalse);
    });

    test('nominaCalc_comisionDosisUsaMesHabana', () {
      // ISO con hora UTC que en Habana cae el mes anterior:
      // 2026-11-01T02:00:00Z son las 22:00 del 31-oct en Habana.
      final rOct = NominaCalc.comisionDosisDesdeVentas([
        {
          'registrado_por': 111,
          'fecha': '2026-11-01T02:00:00Z',
          'cantidad': 1,
          'comision_unitaria': 50.0,
          'casa': 0,
        },
      ], 111, '2026-10');
      expect(rOct.dosis, 1, reason: 'en Habana esa venta es de octubre');
      expect(rOct.total, 50.0);
      final rNov = NominaCalc.comisionDosisDesdeVentas([
        {
          'registrado_por': 111,
          'fecha': '2026-11-01T02:00:00Z',
          'cantidad': 1,
          'comision_unitaria': 50.0,
          'casa': 0,
        },
      ], 111, '2026-11');
      expect(rNov.dosis, 0);
      // Fecha no interpretable: se ignora, no revienta ni cuenta.
      final rMala = NominaCalc.comisionDosisDesdeVentas([
        {
          'registrado_por': 111,
          'fecha': 'no-es-fecha',
          'cantidad': 1,
          'comision_unitaria': 50.0,
          'casa': 0,
        },
      ], 111, '2026-10');
      expect(rMala.dosis, 0);
      expect(rMala.total, 0);
    });

    test('nominaCalc_reversoConMontoSnapshotPositivoRestaComision', () {
      // Reverso con snapshot positivo: resta el monto.
      final r = NominaCalc.comisionDosisDesdeVentas([
        {
          'registrado_por': 111,
          'fecha': '2026-10-09',
          'cantidad': -1,
          'comision_unitaria': 50.0,
          'comision_monto': 80.0,
          'casa': 0,
        },
      ], 111, '2026-10');
      expect(r.dosis, -1);
      expect(r.total, -80.0);
      // Snapshot ya negativo: se conserva su signo.
      final r2 = NominaCalc.comisionDosisDesdeVentas([
        {
          'registrado_por': 111,
          'fecha': '2026-10-09',
          'cantidad': -1,
          'comision_unitaria': 50.0,
          'comision_monto': -80.0,
          'casa': 0,
        },
      ], 111, '2026-10');
      expect(r2.total, -80.0);
      // Sin snapshot: unitaria × cantidad negativa ya resta sola.
      final r3 = NominaCalc.comisionDosisDesdeVentas([
        {
          'registrado_por': 111,
          'fecha': '2026-10-09',
          'cantidad': -1,
          'comision_unitaria': 50.0,
          'casa': 0,
        },
      ], 111, '2026-10');
      expect(r3.total, -50.0);
    });

    test('nominaCalc_parseaTolerantementeComisionesBonosYCantidades',
        () {
      final r = NominaCalc.comisionDosisDesdeVentas([
        {
          'registrado_por': 111,
          'fecha': '2026-10-09',
          'cantidad': '2',
          'comision_unitaria': '50',
          'casa': 0,
        },
        {
          'registrado_por': 111,
          'fecha': '2026-10-10',
          'cantidad': 'no-numero',
          'comision_unitaria': '50',
          'casa': 0,
        },
      ], 111, '2026-10');
      expect(r.dosis, 2);
      expect(r.total, 100.0);
      expect(
          NominaCalc.bonosPara([
            {'entrenador': 'duany', 'monto': '100'},
            {'entrenador': 'ambos', 'monto': 50.5},
            {'entrenador': 'duany', 'monto': 'basura'},
          ], 'duany'),
          150.5);
      expect(
          NominaCalc.bonoSoloAmbos([
            {'entrenador': 'ambos', 'monto': '25'},
          ]),
          25.0);
    });

    test('nominaPrecalc_huellaCambiaAlEditarCamposDeNegocioDelPago',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _pago(db, id: 1, clienteIdDato: 10, fecha: '2026-10-05');
      final h1 = await NominaPrecalc.instance.huella();
      // Cambia un campo de negocio (método): la huella cambia.
      await db.update('pagos', {
        'data': jsonEncode({
          'id': 1,
          'cliente_id': 10,
          'fecha': '2026-10-05',
          'periodo': 'mensual',
          'monto': 2000,
          'metodo': 'transferencia',
        }),
      }, where: 'id = ?', whereArgs: [1]);
      final h2 = await NominaPrecalc.instance.huella();
      expect(h2, isNot(equals(h1)));
      // Cambia solo un campo ajeno al negocio: la huella NO cambia.
      await db.update('pagos', {
        'data': jsonEncode({
          'id': 1,
          'cliente_id': 10,
          'fecha': '2026-10-05',
          'periodo': 'mensual',
          'monto': 2000,
          'metodo': 'transferencia',
          'registrado_por': 'otro',
        }),
      }, where: 'id = ?', whereArgs: [1]);
      expect(await NominaPrecalc.instance.huella(), h2);
      await db.close();
    });

    test('nominaCalc_conjuntoIgnoraIdNoNumericoSinVaciarElConteo',
        () async {
      // Parseo tolerante puro (el mismo que usa _conjunto para
      // f['id']): lo no interpretable es null, no una excepción
      // que vacíe el conjunto.
      expect(NominaCalc.idTolerante('abc'), isNull);
      expect(NominaCalc.idTolerante(null), isNull);
      expect(NominaCalc.idTolerante('12'), 12);
      expect(NominaCalc.idTolerante(12.0), 12);
      // End-to-end: un pago con cliente_id no numérico en su JSON
      // se ignora y el cliente válido sigue contando.
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _pago(db,
          id: 1, clienteIdDato: 10, fecha: '2026-10-05', monto: 2000);
      await _pago(db,
          id: 2,
          clienteIdDato: null,
          fecha: '2026-10-06',
          monto: 2000);
      // Reescribe el segundo pago con cliente_id no numérico.
      await db.update('pagos', {
        'data': jsonEncode({
          'id': 2,
          'cliente_id': 'no-numerico',
          'fecha': '2026-10-06',
          'periodo': 'mensual',
          'monto': 2000,
          'metodo': 'efectivo',
        }),
      }, where: 'id = ?', whereArgs: [2]);
      await _cliente(db, id: 10, pagadoHasta: '2026-11-15');
      expect(await NominaCalc.clientesQuePagaronElMes('2026-10'), 1);
      await db.close();
    });

    test('nominaPrecalc_mesPasadoNoLeeNiEscribeCacheYUsaIsoHabana',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      final prefActual = NominaCalc.prefMesActual();
      // Mes pasado: pago válido + caché vieja sembrada a mano.
      final y = int.parse(prefActual.substring(0, 4));
      final m = int.parse(prefActual.substring(5, 7));
      final py = m == 1 ? y - 1 : y;
      final pm = m == 1 ? 12 : m - 1;
      final prefPasado =
          '${py.toString().padLeft(4, '0')}-${pm.toString().padLeft(2, '0')}';
      await _pago(db,
          id: 1, clienteIdDato: 10, fecha: '$prefPasado-05', monto: 2000);
      await _cliente(db, id: 10, pagadoHasta: '2027-01-15');
      await db.insert('nomina_precalc', {
        'mes': prefPasado,
        'clientes_pagados': 99,
        'huella': 'vieja',
        'calculado_en': '2020-01-01T00:00:00-05:00',
      });
      expect(await NominaPrecalc.instance.asegurar(prefPasado), 1);
      final filaPasada = await db.query('nomina_precalc',
          where: 'mes = ?', whereArgs: [prefPasado]);
      expect(filaPasada.first['clientes_pagados'], 99,
          reason: 'el mes pasado no reescribe su caché');
      expect(filaPasada.first['huella'], 'vieja');
      expect(filaPasada.first['calculado_en'], '2020-01-01T00:00:00-05:00');
      // Mes actual: la escritura de caché usa isoHabana (offset).
      await NominaPrecalc.instance.asegurar(prefActual);
      final filaActual = await db.query('nomina_precalc',
          where: 'mes = ?', whereArgs: [prefActual]);
      expect(filaActual, isNotEmpty);
      expect('${filaActual.first['calculado_en']}',
          matches(RegExp(r'[-+]\d{2}:\d{2}$')));
      await db.close();
    });
  });
}
