/// LOTE 1.35 · SL-5 (Caja, arqueo y nómina) — tests
/// discriminantes de las fichas G07-1, G07-2, G07-3, G07-4,
/// G07-5, G07-7, G07-8 y G04-10.
///
/// Arnés Jornada (BD FFI real): cada test parte de la base
/// limpia; el fallo de lectura se fuerza DROPando la tabla
/// espejo que la pantalla lee (la lectura real lanza, como
/// en campo cuando el espejo está roto), no con mocks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/arqueo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';
import 'package:ironbody_gym/ui/diferencias_caja.dart';
import 'package:ironbody_gym/ui/liquidaciones_historial.dart';
import 'package:ironbody_gym/ui/nomina.dart';
import 'package:ironbody_gym/ui/widgets.dart';

import 'jornada_ayudas.dart';

Future<void> _montar(WidgetTester tester, Widget pantalla) async {
  jornadaViewport(tester);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: pantalla,
  ));
  await jornadaDrenar(tester, vueltas: 8);
}

Future<void> _drop(WidgetTester tester, String tabla) async {
  await tester.runAsync(() async {
    final d = await LocalDb.instance.db;
    await d.execute('DROP TABLE IF EXISTS $tabla');
  });
}

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('SL-5 · G07-1 error ≠ vacío', () {
    testWidgets(
        'Arqueo: si la lectura de pagos FALLA, no dice '
        '«Todo cuadrado»: pinta error con Reintentar',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _drop(tester, 'pagos');
      await _montar(tester, const ArqueoScreen());
      expect(find.text('Nada pendiente. Todo cuadrado.'),
          findsNothing,
          reason: 'la calma no se afirma sin datos leídos');
      expect(find.byType(EstadoError), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'Diferencias: si la lectura FALLA, no dice «No hay '
        'diferencias»: pinta error con Reintentar',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _drop(tester, 'diferencias_caja');
      await _montar(tester, const DiferenciasCajaScreen());
      expect(find.text('No hay diferencias de caja abiertas'),
          findsNothing);
      expect(find.byType(EstadoError), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      await jornadaCerrarCascara(tester);
    });
  });

  group('SL-5 · G07-2/G07-4 vacíos y sync en el Arqueo', () {
    testWidgets(
        'Arqueo en cero (lectura OK): la calma SÍ se afirma, '
        'sin SyncBanner propio y sin tarjeta de Diferencias '
        'en cero', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _montar(tester, const ArqueoScreen());
      expect(find.text('Nada pendiente. Todo cuadrado.'),
          findsOneWidget,
          reason: 'con datos leídos, el vacío tranquilo es '
              'la verdad y se pinta');
      expect(find.byType(SyncBanner), findsNothing,
          reason: 'la sync se dice una sola vez en la '
              'cáscara: esta pantalla ya no monta su banda');
      expect(find.text('Diferencias de caja'), findsNothing,
          reason: 'tarjeta fija en cero fuera: la lista de '
              'entrenadores manda');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'Diferencias en cero (lectura OK): sin tarjeta en '
        'cero', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _montar(tester, const DiferenciasCajaScreen());
      expect(find.text('No hay diferencias de caja abiertas'),
          findsOneWidget);
      expect(find.byType(Tarjeta), findsNothing,
          reason: 'el vacío va sin marco: ninguna tarjeta '
              'se pinta en cero');
      await jornadaCerrarCascara(tester);
    });
  });

  group('SL-5 · G07-3 nombres por hecho real', () {
    testWidgets(
        'Arqueo dice «Bajar cambios del arqueo», Diferencias '
        'dice «Releer» y Nómina dice «Bajar cambios» (ninguna '
        '«Actualizar» genérico)', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _montar(tester, const ArqueoScreen());
      expect(find.byTooltip('Bajar cambios del arqueo'),
          findsOneWidget);
      expect(find.byTooltip('Sincronizar arqueo'), findsNothing);
      await _montar(tester, const DiferenciasCajaScreen());
      expect(find.byTooltip('Releer'), findsOneWidget,
          reason: 'ese botón solo relee lo local y su '
              'nombre lo dice');
      await _montar(tester, const NominaScreen());
      expect(find.byTooltip('Bajar cambios'), findsOneWidget);
      expect(find.byTooltip('Actualizar'), findsNothing);
      await jornadaCerrarCascara(tester);
    });
  });

  group('SL-5 · G07-5/G07-8 detalle del arqueo', () {
    testWidgets(
        'historial del detalle: fecha habanera y autor '
        'legible (no ISO ni id crudos) y chip de la casa',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('liquidaciones_caja', 901, {
          'id': 901,
          'entrenador_telegram_id': 1403501391,
          'entrenador_nombre': 'Gabriel',
          'monto_esperado': 2900,
          'monto_entregado': 2000,
          'saldo_arrastre': 900,
          'moneda': 'CUP',
          'estado': 'parcial',
          'creada_en': '2026-11-10T15:04:00',
          'creada_por': 'Jc',
          'op_ids': '{}',
        }, 1);
      });
      await _montar(
          tester,
          const DetalleArqueoScreen(
              telegramId: 1403501391, nombre: 'Gabriel'));
      await jornadaEsperar(tester, find.textContaining('10/11/2026'));
      expect(find.textContaining('10/11/2026'), findsWidgets,
          reason: 'fmtFecha: 10/11/2026, no el ISO crudo');
      expect(find.textContaining('2026-11-10T'), findsNothing);
      expect(find.textContaining('por Jc'), findsWidgets);
      expect(find.byType(ChipEstado), findsWidgets,
          reason: 'el estado Parcial va con ChipEstado de '
              'la casa, no con un Container a mano');
      await jornadaCerrarCascara(tester);
    });
  });

  group('SL-5 · G07-7/G07-8 historial de liquidaciones', () {
    testWidgets(
        'el filtro de mes es SelectorIron (sin radios '
        'propios) y el estado va con ChipEstado',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await tester.runAsync(() async {
        for (final (id, mes) in [(911, '2026-10'), (912, '2026-11')]) {
          await LocalDb.instance.upsertMirror('liquidaciones_caja', id, {
            'id': id,
            'entrenador_telegram_id': 1403501391,
            'entrenador_nombre': 'Gabriel',
            'monto_esperado': 1000,
            'monto_entregado': 1000,
            'saldo_arrastre': 0,
            'moneda': 'CUP',
            'estado': 'completa',
            'creada_en': '$mes-05T10:00:00',
            'creada_por': 'Jc',
            'op_ids': '{}',
          }, 1);
        }
      });
      await _montar(tester, const LiquidacionesHistorialScreen());
      await jornadaEsperar(tester, find.text('Gabriel'));
      expect(find.byType(SelectorIron<String>), findsOneWidget,
          reason: 'el selector de meses es el de la casa');
      expect(find.byType(RadioListTile<String>), findsNothing);
      expect(find.byType(ChipEstado), findsWidgets);
      await jornadaCerrarCascara(tester);
    });
  });

  group('SL-5 · G04-10 fiados en cero', () {
    testWidgets(
        'Fiados por cobrar sin fiados: la tarjeta «0 '
        'fiado(s)» no existe', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _montar(tester, const CuentasPorCobrarScreen());
      await jornadaEsperar(
          tester, find.text('Sin fiados pendientes'));
      expect(find.textContaining('fiado(s) pendiente(s)'),
          findsNothing,
          reason: 'en cero la tarjeta de totales no se '
              'pinta (regla de filas en cero)');
      expect(find.text('Sin fiados pendientes'), findsOneWidget);
      await jornadaCerrarCascara(tester);
    });
  });
}
