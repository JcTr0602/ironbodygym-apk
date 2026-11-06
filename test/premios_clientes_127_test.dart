/// 1.27 (S3/G3) — Pestaña Clientes de Premios:
/// parseo del detalle (progreso, vales, sello,
/// marcas) y el flujo buscar → detalle → conceder
/// vale con nota obligatoria.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
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

  group('diasQuitablesVale (S7)', () {
    test('la ventana manda sobre el pagado_hasta lejano', () {
      // Canje el 1-nov por 7 días: ventana hasta el 8.
      // Hoy 6-nov: quedan 2 días de ventana aunque el
      // cliente haya renovado hasta diciembre.
      final k = diasQuitablesVale(
        pagadoHasta: '2026-12-01',
        resueltoEn: '2026-11-01T11:00:00Z',
        premioDias: 7,
        hoy: DateTime(2026, 11, 6),
      );
      expect(k, 2);
    });

    test('el pagado_hasta cercano manda sobre la ventana', () {
      final k = diasQuitablesVale(
        pagadoHasta: '2026-11-07',
        resueltoEn: '2026-11-01T11:00:00Z',
        premioDias: 15,
        hoy: DateTime(2026, 11, 6),
      );
      expect(k, 1);
    });

    test('vale consumido o datos ilegibles: 0', () {
      expect(
          diasQuitablesVale(
            pagadoHasta: '2026-11-05',
            resueltoEn: '2026-10-01T11:00:00Z',
            premioDias: 15,
            hoy: DateTime(2026, 11, 6),
          ),
          0);
      expect(
          diasQuitablesVale(
            pagadoHasta: null,
            resueltoEn: '2026-11-01',
            premioDias: 15,
            hoy: DateTime(2026, 11, 6),
          ),
          0);
    });
  });

  testWidgets('anular un vale canjeado: elige modo y nota',
      (tester) async {
    // Fechas relativas a hoy: canje hace 5 días por 7
    // días de premio -> ventana viva con 2 días por
    // consumir (el diálogo usa hoyHabana() real).
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final hoy = DateTime.now();
    final detalle = _jsonDetalle();
    (detalle['vales'] as List)[0]['resuelto_en'] =
        '${iso(hoy.subtract(const Duration(days: 5)))}T11:00:00Z';
    final hastaFutura = iso(hoy.add(const Duration(days: 25)));
    (int, String, int, String, String)? anulacion;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PremiosClientesTab(
          buscarClientes: () async => [
            (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
          ],
          cargarDetalle: (_) async => detalle,
          cargarCatalogo: () async => const [],
          concederVale: (_, __, ___, ____) async => {'ok': true},
          reiniciarCiclo: (_, __) async => {'ok': true},
          pagadoHastaDe: (_) async => hastaFutura,
          anulacionEnCursoDe: (_) async => false,
          anularVale: (id, vale, modo, k, nota) async {
            anulacion = (id, vale.logroId, vale.id, modo, nota);
            // k viaja aparte: se verifica por el diálogo.
            expect(k, 2);
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ana Prueba'));
    await tester.pumpAndSettle();
    // El vale canjeado (id 3, manual) trae el botón.
    await tester.scrollUntilVisible(find.text('Anular vale'), 200);
    await tester.tap(find.text('Anular vale'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Se quitan 2 días'), findsOneWidget);
    // Sin nota no pasa.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Anular vale'));
    await tester.pumpAndSettle();
    expect(anulacion, isNull);
    expect(find.textContaining('La nota es obligatoria'),
        findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Nota (obligatoria)'),
        'Se arrepintió');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Anular vale'));
    await tester.pumpAndSettle();
    expect(anulacion, (7, 'manual', 3, 'no_consumidos', 'Se arrepintió'));
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
          pagadoHastaDe: (_) async => '2026-12-01',
          anulacionEnCursoDe: (_) async => false,
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

  // H-01 (Argón 1.27): la guarda _operando se toma
  // SÍNCRONA antes del primer await: con la carga del
  // catálogo en vuelo, el botón queda deshabilitado y
  // un segundo toque no vuelve a pedir el catálogo ni
  // apila un segundo diálogo.
  testWidgets('H-01: doble toque en Conceder no apila '
      'dos diálogos', (tester) async {
    var cargasCatalogo = 0;
    final enVuelo = Completer<List<EntradaCatalogoPremio>>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PremiosClientesTab(
          buscarClientes: () async => [
            (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
          ],
          cargarDetalle: (_) async => _jsonDetalle(),
          cargarCatalogo: () {
            cargasCatalogo++;
            return enVuelo.future;
          },
          concederVale: (_, __, ___, ____) async => {'ok': true},
          reiniciarCiclo: (_, __) async => {'ok': true},
          pagadoHastaDe: (_) async => '2026-12-01',
          anulacionEnCursoDe: (_) async => false,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ana Prueba'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conceder vale'));
    await tester.pump();
    expect(cargasCatalogo, 1);
    final boton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Conceder vale'));
    expect(boton.onPressed, isNull);
    // Segundo toque con la operación en curso: no-op.
    await tester.tap(find.text('Conceder vale'));
    await tester.pump();
    expect(cargasCatalogo, 1);
    enVuelo.complete(const [
      EntradaCatalogoPremio(
        logroId: 'manual',
        nombre: 'Vale manual',
        metaDias: 1,
        premioDias: 0,
        activo: false,
        ultimoCambioTexto: null,
      ),
    ]);
    await tester.pumpAndSettle();
    // Un solo diálogo de concesión.
    expect(find.text('Crear vale'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    // La guarda se liberó en el finally: el botón revive.
    final boton2 = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Conceder vale'));
    expect(boton2.onPressed, isNotNull);
  });

  // H-01: la guarda también cubre Anular — con el
  // diálogo abierto sigue tomada (el botón de la
  // tarjeta, deshabilitado) y se libera al cerrarlo.
  testWidgets('H-01: la guarda de Anular vive lo que '
      'dura el diálogo', (tester) async {
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final hoy = DateTime.now();
    final detalle = _jsonDetalle();
    (detalle['vales'] as List)[0]['resuelto_en'] =
        '${iso(hoy.subtract(const Duration(days: 5)))}T11:00:00Z';
    final hastaFutura = iso(hoy.add(const Duration(days: 25)));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PremiosClientesTab(
          buscarClientes: () async => [
            (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
          ],
          cargarDetalle: (_) async => detalle,
          cargarCatalogo: () async => const [],
          concederVale: (_, __, ___, ____) async => {'ok': true},
          reiniciarCiclo: (_, __) async => {'ok': true},
          pagadoHastaDe: (_) async => hastaFutura,
          anulacionEnCursoDe: (_) async => false,
          anularVale: (_, __, ___, ____, _____) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ana Prueba'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Anular vale'), 200);
    await tester.tap(find.text('Anular vale'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ya se aplicó'), findsOneWidget);
    final durante = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Anular vale'));
    expect(durante.onPressed, isNull);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    final despues = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Anular vale'));
    expect(despues.onPressed, isNotNull);
  });

  // H-03 (Argón 1.27): el subtítulo del modo completo
  // enseña la fecha estimada (pagado_hasta − premio)
  // y avisa de que la exacta la confirma el servidor.
  testWidgets('H-03: el modo completo muestra la fecha '
      'estimada y el aviso del servidor', (tester) async {
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final hoy = DateTime.now();
    final detalle = _jsonDetalle();
    (detalle['vales'] as List)[0]['resuelto_en'] =
        '${iso(hoy.subtract(const Duration(days: 5)))}T11:00:00Z';
    final hastaFutura = iso(hoy.add(const Duration(days: 25)));
    // Vale de 7 días: la estimación del modo completo
    // es hastaFutura − 7 días = hoy + 18.
    final estimada = iso(hoy.add(const Duration(days: 18)));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PremiosClientesTab(
          buscarClientes: () async => [
            (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
          ],
          cargarDetalle: (_) async => detalle,
          cargarCatalogo: () async => const [],
          concederVale: (_, __, ___, ____) async => {'ok': true},
          reiniciarCiclo: (_, __) async => {'ok': true},
          pagadoHastaDe: (_) async => hastaFutura,
          anulacionEnCursoDe: (_) async => false,
          anularVale: (_, __, ___, ____, _____) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ana Prueba'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Anular vale'), 200);
    await tester.tap(find.text('Anular vale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quitar el pago completo'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('pasaría de ${fmtFecha(hastaFutura)} '
            'a ${fmtFecha(estimada)}'),
        findsOneWidget);
    expect(
        find.textContaining(
            'la fecha exacta la confirma el servidor'),
        findsOneWidget);
  });
}
