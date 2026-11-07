/// Correcciones de la Auditoría 1 (correctitud) de la 1.28.
///
/// - D1 (media): la subida monolítica de fotos de incidencias
///   no recibía la guarda QoS `debePausarPorCobro` — durante
///   su PUT y sus reintentos, un cobro encolado no la pausaba.
///   Fijado por fuente: TODA llamada a `_subirFotoSimple` debe
///   pasar el callback (la guarda vive dentro del método y
///   solo se re-consulta si el callback llega).
/// - D2 (baja): `evaluarCierreMes`/`confirmarPasoCierreMes`
///   reventaban con un `manuales` corrupto (cast duro) y la
///   pantalla quedaba en «cargando» eterno (sin try/catch).
/// - D3 (baja): `resumenIngresosDia` sumaba los pagos Casa
///   que las barras excluyen (burbuja ≠ barra) y el día en 0
///   no era tocable en el gráfico.
/// - D4 (baja): el paso esqueleto→contenido en Dashboard,
///   Pendiente y Arqueo era un ternario seco; ahora va con
///   `CruceEstados` (fundido de la casa).
/// - D5 (baja): el estimado «≈ por cobrar» de la pestaña
///   «Atrasados -30d» no sumaba al grupo sin fecha, que la
///   pestaña sí cuenta y muestra en su cola.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cierre_mes.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/listas.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _initDb(String archivo) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = archivo;
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D1 · guarda QoS en todas las subidas monolíticas', () {
    test('cada llamada a _subirFotoSimple pasa debePausarPorCobro',
        () {
      final sync = File('lib/sync.dart').readAsStringSync();
      // Llamadas = apariciones que NO son la declaración.
      final llamadas = RegExp(r'_subirFotoSimple\(')
          .allMatches(sync)
          .where((m) =>
              !sync.substring(m.start - 20, m.start).contains('Future<bool>'))
          .toList();
      expect(llamadas, hasLength(3),
          reason: 'se esperaban las 3 llamadas monolíticas '
              '(suplementos, cola, incidencias)');
      for (final m in llamadas) {
        final ventana = sync.substring(m.start, m.start + 260);
        expect(ventana, contains('debePausarPorCobro'),
            reason: 'llamada sin la guarda QoS en: '
                '${ventana.substring(0, 80)}…');
      }
    });
  });

  group('D2 · cierre de mes con el progreso corrupto', () {
    setUp(() => _initDb('test_corr_a1_cierre.db'));

    test('un «manuales» que no es mapa no tumba la evaluación '
        'ni la confirmación', () async {
      // Dato sucio: manuales como LISTA (tipo inesperado).
      await LocalDb.instance.setMeta(
          'cierre_mes_2026-10',
          jsonEncode({
            'manuales': ['nomina'],
            'cerradoEn': null,
          }));
      // Antes: TypeError dentro de evaluarCierreMes y la
      // pantalla en «cargando» para siempre.
      final estado = await evaluarCierreMes('2026-10');
      expect(estado, isNotNull);
      // La confirmación de un paso tampoco revienta y deja
      // el mapa bien formado.
      await confirmarPasoCierreMes('2026-10', 'nomina');
      final txt = await LocalDb.instance.getMeta('cierre_mes_2026-10');
      final p = jsonDecode(txt!) as Map<String, dynamic>;
      expect(p['manuales'], isA<Map>());
      expect((p['manuales'] as Map)['nomina'], isNotNull);
    });

    test('la pantalla protege su carga con error y reintento', () {
      final ui = File('lib/ui/cierre_mes.dart').readAsStringSync();
      expect(ui, contains('_errorCarga'),
          reason: 'sin estado de error, un fallo de carga deja '
              'la pantalla en el spinner eterno');
    });
  });

  group('D3 · la burbuja del día excluye Casa como las barras', () {
    setUp(() => _initDb('test_corr_a1_dia.db'));

    test('resumenIngresosDia no suma pagos Casa (bandera ni '
        'cliente Casa)', () async {
      // Cliente Casa (id 7) y cliente normal (id 8).
      await LocalDb.instance.upsertMirror('clientes', 7, {
        'nombre': 'De la Casa',
        'estado': 'activo',
        'cuenta_casa': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('clientes', 8, {
        'nombre': 'Normal',
        'estado': 'activo',
      }, 2);
      // Pago normal del día: SÍ cuenta.
      await LocalDb.instance.upsertMirror('pagos', 1, {
        'monto': 2000,
        'metodo': 'efectivo',
        'fecha': '2026-11-02',
        'cliente_id': 8,
      }, 1);
      // Pago con la bandera casa en la fila: NO cuenta.
      await LocalDb.instance.upsertMirror('pagos', 2, {
        'monto': 1500,
        'metodo': 'efectivo',
        'fecha': '2026-11-02',
        'cliente_id': 8,
        'casa': 1,
      }, 2);
      // Pago de un cliente Casa (sin bandera en la fila): NO.
      await LocalDb.instance.upsertMirror('pagos', 3, {
        'monto': 1000,
        'metodo': 'transferencia',
        'fecha': '2026-11-02',
        'cliente_id': 7,
      }, 3);
      final r = await resumenIngresosDia('2026-11-02');
      expect(r.efectivo, 2000);
      expect(r.transferencia, 0);
      expect(r.total, 2000);
      expect(r.movimientos, 1);
    });

    test('el día en 0 también es tocable en el gráfico', () {
      final ui = File('lib/ui/dashboard.dart').readAsStringSync();
      expect(ui, contains('onTap: () => _seleccionarDia'),
          reason: 'el toque no debe depender del monto del día');
      expect(ui, isNot(contains('onTap: monto > 0')));
    });
  });

  group('D4 · fundido esqueleto→contenido con CruceEstados', () {
    test('Dashboard, Pendiente y Arqueo cruzan con fundido', () {
      for (final f in [
        'lib/ui/dashboard.dart',
        'lib/ui/pendiente.dart',
        'lib/ui/arqueo.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src, contains('CruceEstados('),
            reason: '$f sigue cambiando esqueleto→contenido '
                'con un ternario seco');
        expect(src, contains("estado: _cargando ? 'cargando' : 'contenido'"),
            reason: '$f no declara el cruce por estado');
      }
    });
  });

  group('D5 · el estimado de «Atrasados -30d» suma a los sin fecha',
      () {
    testWidgets('la cabecera suma atrasado + sin fecha', (tester) async {
      await tester.runAsync(() async {
        await _initDb('test_corr_a1_listas.db');
        final hace10 = sumarDiasCalendario(ahoraHabana(), -10);
        String iso(DateTime d) =>
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        // Atrasado de menos de 30 días (su mensualidad: 2000).
        await LocalDb.instance.upsertMirror('clientes', 11, {
          'nombre': 'Atrasado Diez',
          'estado': 'activo',
          'pagado_hasta': iso(hace10),
        }, 1);
        // Sin fecha (nunca pagó): la pestaña lo cuenta y lo
        // muestra en la cola; su mensualidad también es 2000.
        await LocalDb.instance.upsertMirror('clientes', 12, {
          'nombre': 'Sin Fecha',
          'estado': 'activo',
        }, 2);
      });
      await tester.pumpWidget(
          const MaterialApp(home: ListasScreen(inicial: 2)));
      // La carga es asíncrona (BD real) y la cabecera anima
      // su cifra 500 ms desde 0 (_NumeroAnimado): bombear
      // hasta que el estimado FINAL se pinte (tope ~12 s).
      String? textoCabecera() {
        final f = find.textContaining('CUP por cobrar');
        if (f.evaluate().isEmpty) return null;
        return (f.evaluate().first.widget as Text).data;
      }

      var texto = textoCabecera();
      for (var i = 0;
          i < 120 && !(texto?.contains(fmtMonto(4000)) ?? false);
          i++) {
        await tester
            .runAsync(() => Future<void>.delayed(
                const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 120));
        texto = textoCabecera();
      }
      expect(texto, isNotNull,
          reason: 'la pestaña de atrasados no pintó su cabecera');
      expect(texto, contains('≈ ${fmtMonto(4000)}'),
          reason: 'el estimado debe sumar al atrasado (2000) '
              'y al sin fecha (2000); se vio: $texto');
    });
  });
}
