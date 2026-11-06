/// 1.27 (S3/G3) — Pestaña Clientes de Premios:
/// parseo del detalle (progreso, vales, sello,
/// marcas) y el flujo buscar → detalle → conceder
/// vale con nota obligatoria.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/ui/panel_premios_clientes.dart';

Map<String, dynamic> _jsonDetalle() => {
      'ok': true,
      'cliente_id': 7,
      'nombre': 'Ana Prueba',
      'progreso': {
        'logro_id': 'constancia_real',
        'meta_dias': 90,
        'premio_dias': 15,
        'dias': 45,
        'faltan': 45,
        'ciclo_desde': null,
      },
      'sesiones_que_sumaron': ['2026-11-05', '2026-11-04'],
      'vales': [
        {
          'id': 3,
          'logro_id': 'manual',
          'premio_dias': 7,
          'dias_al_reclamar': 40,
          'estado': 'canjeado',
          'creado_en': '2026-11-01T10:00:00Z',
          'creado_nota': 'Cortesía especial',
          'resuelto_en': '2026-11-01T11:00:00Z',
          'resuelto_nota': null,
          'pago_uuid': 'uuid-pago-3',
        },
        {
          'id': 4,
          'logro_id': 'constancia_real',
          'premio_dias': 15,
          'dias_al_reclamar': 90,
          'estado': 'reclamado',
          'creado_en': '2026-11-06T09:00:00Z',
          'creado_nota': null,
          'resuelto_en': null,
          'resuelto_nota': null,
          'pago_uuid': null,
        },
      ],
      'sello': {
        'sello': {'primer_paso': '2026-10-02'},
        'actualizado_en': '2026-11-05T08:00:00Z',
      },
      'marcas': [
        {'desde': '2026-10-20T00:00:00Z', 'nota': 'Corrección'},
      ],
    };

void main() {
  group('parseDetallePremiosCliente', () {
    test('lee progreso, vales, sello y marcas', () {
      final d = parseDetallePremiosCliente(_jsonDetalle());
      expect(d.dias, 45);
      expect(d.faltan, 45);
      expect(d.fraccionBarra, 0.5);
      expect(d.vales, hasLength(2));
      expect(d.vales.first.canjeado, isTrue);
      expect(d.vales.first.creadoNota, 'Cortesía especial');
      expect(d.vales.first.pagoUuid, 'uuid-pago-3');
      expect(d.vales.last.reclamado, isTrue);
      expect(d.sello, {'primer_paso': '2026-10-02'});
      expect(d.marcas.single.nota, 'Corrección');
      expect(d.sesionesQueSumaron,
          ['2026-11-05', '2026-11-04']);
    });

    test('ok falso o json inválido degrada a vacío', () {
      expect(parseDetallePremiosCliente({'ok': false}).vales,
          isEmpty);
      expect(parseDetallePremiosCliente(null).dias, 0);
    });
  });

  testWidgets('buscar → detalle → conceder vale con nota',
      (tester) async {
    (int, String, int, String)? concesion;
    var detalleJson = _jsonDetalle();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PremiosClientesTab(
          buscarClientes: () async => [
            (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
            (id: 8, nombre: 'Beto', telefono: ''),
          ],
          cargarDetalle: (_) async => detalleJson,
          cargarCatalogo: () async => const [
            EntradaCatalogoPremio(
              logroId: 'manual',
              nombre: 'Vale manual',
              metaDias: 1,
              premioDias: 0,
              activo: false,
              ultimoCambioTexto: null,
            ),
          ],
          concederVale: (id, logro, dias, nota) async {
            concesion = (id, logro, dias, nota);
            return {'ok': true, 'vale_id': 9};
          },
          reiniciarCiclo: (_, __) async => {'ok': true},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Ana Prueba'), findsOneWidget);
    await tester.tap(find.text('Ana Prueba'));
    await tester.pumpAndSettle();
    expect(find.textContaining('45 de 90 días verificados'),
        findsOneWidget);
    expect(find.textContaining('Cortesía especial'), findsWidgets);
    // Conceder: sin nota no pasa; con nota sí.
    await tester.tap(find.text('Conceder vale'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Días de mensualidad gratis'),
        '7');
    await tester.tap(find.text('Crear vale'));
    await tester.pumpAndSettle();
    expect(concesion, isNull);
    expect(find.textContaining('La nota es obligatoria'),
        findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Nota (obligatoria)'),
        'Premio especial');
    await tester.tap(find.text('Crear vale'));
    await tester.pumpAndSettle();
    expect(concesion, (7, 'manual', 7, 'Premio especial'));
    detalleJson = _jsonDetalle();
  });
}
