/// SL-3 · G01-5 + G02-3 — las hojas de mis archivos son la
/// hoja de la casa (showHojaIron / HojaAccion), nunca
/// showModalBottomSheet crudo.
///
/// - G01-5: dashboard.dart abría el detalle de ingresos con
///   showModalBottomSheet crudo (su otra hoja, _detalleDia,
///   ya usaba showHojaIron).
/// - G02-3: el aviso de WhatsApp se presentaba con tres
///   hojas distintas; la presentación de MIS archivos es la
///   de listas.dart (_elegirAviso: «Avisar por WhatsApp» /
///   «Solo marcar como avisado», que devuelve 'whatsapp' /
///   'marcar'). Se unifica a la hoja de la casa conservando
///   el contrato de retorno. Las otras dos presentaciones
///   viven en buscar.dart (fuera del mapa de SL-3) y se
///   reportan en el informe, no se invaden.
///
/// Contrato de fuente (la pauta de la casa para superficies):
/// en la base ambos archivos contienen showModalBottomSheet
/// → rojo; corregidos, ninguno.
///
/// F02-HD (z18_tests_sl3-1/2 r2): el contrato de fuente no
/// basta — un grep no toca nada. El grupo de widgets de
/// abajo ejerce los DESTINOS reales: el tap en el segmento
/// «Hoy» del Dashboard abre la hoja de detalle de ingresos,
/// y en Listas la elección del aviso lanza (o no) la URL
/// wa.me del cliente según la opción tocada.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/dashboard.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
import 'package:ironbody_gym/ui/listas.dart';

import 'jornada_ayudas.dart';

/// URLs que el lanzador falso «abrió» (G02-3): el destino
/// real de la opción WhatsApp, sin abrir nada de verdad.
final List<String> _urlsLanzadas = [];

void main() {
  test('G01-5 · dashboard.dart: sin hoja cruda; el detalle de '
      'ingresos usa showHojaIron', () {
    final src = File('lib/ui/dashboard.dart').readAsStringSync();
    expect(src.contains('showModalBottomSheet('), isFalse,
        reason: 'dashboard.dart no debe abrir hojas crudas');
    final i = src.indexOf('Future<void> _detalleIngresos');
    expect(i, greaterThanOrEqualTo(0));
    final cuerpo = src.substring(i, src.indexOf('Widget _filaDetalle', i));
    expect(cuerpo.contains('showHojaIron'), isTrue,
        reason: 'el detalle de ingresos abre con la hoja de la casa');
  });

  test('G02-3 · listas.dart: sin hoja cruda; _elegirAviso usa '
      'showHojaIron y conserva su contrato', () {
    final src = File('lib/ui/listas.dart').readAsStringSync();
    expect(src.contains('showModalBottomSheet('), isFalse,
        reason: 'listas.dart no debe abrir hojas crudas');
    final i = src.indexOf('Future<String?> _elegirAviso');
    expect(i, greaterThanOrEqualTo(0));
    final cuerpo = src.substring(i, src.indexOf('Future<bool> _abrirWhatsapp', i));
    expect(cuerpo.contains('showHojaIron'), isTrue,
        reason: 'la elección del aviso WA abre con la hoja de la casa');
    expect(cuerpo.contains("'whatsapp'"), isTrue);
    expect(cuerpo.contains("'marcar'"), isTrue);
  });

  group('destinos reales (widgets)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUpAll(() async {
      await jornadaSetUpAll();
      await jornadaCargarRoboto();
      // Lanzador falso: registra la URL y dice que SÍ abrió.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'),
              (call) async {
        if (call.method == 'launch' || call.method == 'launchUrl') {
          final args = call.arguments;
          if (args is Map && args['url'] != null) {
            _urlsLanzadas.add('${args['url']}');
          } else if (args is String) {
            _urlsLanzadas.add(args);
          }
          return true;
        }
        if (call.method == 'canLaunch') return true;
        return null;
      });
    });

    tearDownAll(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'),
              null);
    });

    testWidgets('G01-5 · tap real en el segmento «Hoy» del '
        'Dashboard: se abre la hoja de detalle de ingresos',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('pagos', 71, {
          'id': 71,
          'cliente_id': 5,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': hoyHabanaIso(),
        }, 1);
      });
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const DashboardScreen()));
      await jornadaDrenar(tester);
      expect(tester.takeException(), isNull);
      final segmento = find
          .ancestor(
              of: find.byIcon(Icons.today_rounded),
              matching: find.byType(InkWell))
          .first;
      await tester.ensureVisible(segmento);
      await tester.tap(segmento);
      await jornadaDrenar(tester, vueltas: 6);
      // La hoja resultante es la de la casa con el detalle
      // DEL PERÍODO (no el detalle del día): si el tap
      // volviera a _detalleDia o _detalleIngresos quedara
      // muerto, esto iría a rojo.
      final hoja = find.byType(HojaAccion);
      expect(hoja, findsOneWidget,
          reason: 'G01-5: el detalle de ingresos se presenta '
              'en la hoja de la casa (HojaAccion)');
      expect(
          find.descendant(
              of: hoja, matching: find.text('Ingresos de hoy')),
          findsOneWidget);
      expect(
          find.descendant(of: hoja, matching: find.text('Efectivo')),
          findsOneWidget,
          reason: 'el desglose por método vive en la hoja');
      expect(
          find.descendant(of: hoja, matching: find.text('Total')),
          findsOneWidget);
      expect(
          find.descendant(
              of: hoja,
              matching: find.text('1 movimientos registrados')),
          findsOneWidget,
          reason: 'el detalle corresponde al pago sembrado '
              'de hoy, no a una hoja genérica');
      await jornadaCerrarCascara(tester);
    });

    Future<void> sembrarAtrasado(WidgetTester tester,
        {required int id, required String nombre}) async {
      await tester.runAsync(() async {
        final hace10 = sumarDiasCalendario(ahoraHabana(), -10);
        String iso(DateTime d) =>
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        await LocalDb.instance.upsertMirror('clientes', id, {
          'id': id,
          'nombre': nombre,
          'telefono': '58112233',
          'estado': 'activo',
          'pagado_hasta': iso(hace10),
          'fecha_inscripcion': '2026-08-01',
        }, id);
      });
    }

    Future<void> abrirEleccionAviso(WidgetTester tester) async {
      await jornadaDrenar(tester, vueltas: 8);
      await jornadaEsperar(tester, find.byTooltip('Marcar como avisado'));
      await tester.tap(find.byTooltip('Marcar como avisado').first);
      await jornadaDrenar(tester, vueltas: 5);
    }

    testWidgets('G02-3 · destino WhatsApp: la hoja ofrece '
        'las dos opciones reales y elegir WhatsApp lanza la '
        'URL wa.me del cliente', (tester) async {
      _urlsLanzadas.clear();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await sembrarAtrasado(tester, id: 501, nombre: 'Aviso Prueba');
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const ListasScreen(inicial: 2)));
      await jornadaEsperar(tester, find.text('Aviso Prueba'));
      await abrirEleccionAviso(tester);
      // Las dos opciones son filas REALES de la hoja de la
      // casa (icono + título), no dos cadenas en el fuente.
      final hoja = find.byType(HojaAccion);
      expect(hoja, findsOneWidget,
          reason: 'G02-3: la elección del aviso se presenta '
              'en la hoja de la casa');
      expect(
          find.descendant(
              of: hoja, matching: find.text('Avisar por WhatsApp')),
          findsOneWidget);
      expect(
          find.descendant(
              of: hoja,
              matching: find.text('Solo marcar como avisado')),
          findsOneWidget);
      expect(
          find.descendant(
              of: hoja,
              matching:
                  find.byIcon(Icons.check_circle_outline_rounded)),
          findsOneWidget,
          reason: 'la opción de marcar lleva su icono de '
              'destino en la fila montada');
      await tester.tap(find.descendant(
          of: hoja, matching: find.text('Avisar por WhatsApp')));
      await jornadaDrenar(tester, vueltas: 6);
      // El destino real de 'whatsapp': se lanzó wa.me con
      // el móvil del cliente (53 + 8 dígitos).
      expect(_urlsLanzadas, isNotEmpty,
          reason: 'G02-3: elegir WhatsApp abre WhatsApp de '
              'verdad (el retorno no basta: hay lanzamiento)');
      expect(_urlsLanzadas.first,
          startsWith('https://wa.me/5358112233'),
          reason: 'la URL lanzada es la del cliente sembrado');
      // Confirmado el envío, la marca cae sobre el cliente.
      await jornadaEsperar(tester, find.text('Sí, enviado'));
      await tester.tap(find.text('Sí, enviado'));
      await jornadaDrenar(tester, vueltas: 5);
      expect(find.text('Aviso Prueba marcado como avisado'),
          findsOneWidget);
      await jornadaCerrarCascara(tester);
    });

    testWidgets('G02-3 · destino marcar: elegir «Solo marcar '
        'como avisado» NO lanza WhatsApp y deja la marca',
        (tester) async {
      _urlsLanzadas.clear();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await sembrarAtrasado(tester, id: 502, nombre: 'Marca Prueba');
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const ListasScreen(inicial: 2)));
      await jornadaEsperar(tester, find.text('Marca Prueba'));
      await abrirEleccionAviso(tester);
      final hoja = find.byType(HojaAccion);
      expect(hoja, findsOneWidget);
      await tester.tap(find.descendant(
          of: hoja,
          matching: find.text('Solo marcar como avisado')));
      await jornadaDrenar(tester, vueltas: 5);
      // El destino real de 'marcar': marca sin lanzar nada
      // (si ambas opciones devolvieran lo mismo, o el
      // llamador ignorara el retorno, esto iría a rojo).
      expect(_urlsLanzadas, isEmpty,
          reason: 'G02-3: «marcar» no abre WhatsApp: solo '
              'deja la marca local');
      expect(find.text('Marca Prueba marcado como avisado'),
          findsOneWidget);
      expect(find.byTooltip('Avisado (toca para quitar)'),
          findsWidgets,
          reason: 'la fila refleja la marca: el botón pasa '
              'a estado avisado');
      await jornadaCerrarCascara(tester);
    });
  });
}
