/// 1.35 FASE 4 — UX-05 (recibo), UX-06 (puerta única) y
/// UX-07 (plantilla «tarjeta Iron Body»).
///
/// - UX-05: la confirmación compone el recibo de la
///   casa — check en el anillo naranja con su color de
///   estado, cabecera grafito de la plantilla DENTRO
///   del ticket (la foto del comprobante la hereda),
///   corte con muescas y monto protagonista.
/// - UX-06: login y PIN comparten el escenario del
///   rayo a pantalla completa; el logo ya no va en
///   círculo y los campos son cristal grafito.
/// - UX-07: el cierre de nómina adopta el fondo y la
///   cabecera de la plantilla y la vista previa habla
///   los tokens (sin literales propios); el pie
///   firmado no cambia ni una letra.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';
import 'package:ironbody_gym/ui/confirmacion_cobro.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/tarjeta_imagen.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('UX-05 · recibo', () {
    testWidgets('el ticket lleva la cabecera de la '
        'plantilla y la marca en su anillo', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: const ConfirmacionOperacionScreen(
          titulo: 'Pago registrado',
          monto: '2 000 CUP',
          etiquetaMonto: 'Cobrado',
          detalles: [(etiqueta: 'Cliente', valor: 'Luis Gómez')],
          comprobantePie: 'pie',
        ),
      ));
      await tester.pump();
      // La cabecera grafito de la plantilla, dentro del
      // ticket fotografiable.
      expect(find.byType(CabeceraTarjetaIron), findsOneWidget);
      expect(find.text('IRON BODY GYM'), findsWidgets);
      // La marca de hecho y el monto protagonista.
      expect(find.byIcon(Icons.check_circle_rounded),
          findsOneWidget);
      expect(find.text('2 000 CUP'), findsOneWidget);
      expect(find.text('Luis Gómez'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('la fuente trae el corte con muescas y el '
        'anillo de marca', () {
      final f = _fuente('lib/ui/confirmacion_cobro.dart');
      expect(f.contains('class _CorteTicket'), isTrue);
      expect(f.contains('color: AppColores.naranja, width: 3)'),
          isTrue);
      expect(f.contains('AppTexto.displayPequeno'), isTrue,
          reason: 'el monto sube a protagonista');
    });
  });

  group('UX-06 · puerta única', () {
    test('login: escenario del rayo, sin degradado '
        'carbón ni logo en círculo', () {
      final f = _fuente('lib/ui/login.dart');
      expect(f.contains('assets/arte_marca_rayo.jpg'), isTrue);
      expect(f.contains('gradienteCarbon'), isFalse);
      expect(f.contains('AppRadio.circular'), isFalse,
          reason: 'el logo ya no se recorta en círculo');
      expect(f.contains('grafitoTactico.withValues(alpha: 0.78)'),
          isTrue,
          reason: 'los campos son cristal grafito');
    });

    test('PIN: la misma puerta, cortina más ligera', () {
      final f = _fuente('lib/ui/pin_lock.dart');
      expect(f.contains('assets/arte_marca_rayo.jpg'), isTrue);
      expect(f.contains('withValues(alpha: 0.80)'), isTrue);
      expect(f.contains('withValues(alpha: 0.86)'), isFalse);
    });
  });

  group('UX-07 · plantilla Iron Body', () {
    testWidgets('el cierre de nómina se viste con la '
        'plantilla y firma al pie', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImagenCierreNomina(
              mesEtiqueta: 'Octubre de 2026',
              generadoEtiqueta: 'Generada el 31 de octubre de 2026',
              filas: [
                FilaCierreNomina(
                  nombre: 'Duany',
                  base: 3000,
                  bono: 0,
                  comision: 0,
                  adelantos: 0,
                  deuda: 0,
                  neto: 3000,
                  liquidada: false,
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('IRON BODY GYM'), findsOneWidget);
      expect(find.text('TOTAL A PAGAR'), findsOneWidget);
      // El pie firmado, intacto: la línea oficial y el
      // número de respuestas del gym.
      expect(find.text(lineaOficialTarjetaImagen),
          findsOneWidget);
      expect(find.text(lineaContactoTarjetaImagen),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('las superficies hablan los tokens de la '
        'plantilla', () {
      final cierre = _fuente('lib/ui/cierre_nomina_imagen.dart');
      expect(cierre.contains('AppColores.grafitoTactico'), isTrue);
      expect(cierre.contains('0xFF1C1C1F'), isFalse);
      final previa = _fuente('lib/ui/vista_previa_cliente.dart');
      expect(previa.contains('0xFF121214'), isFalse);
      expect(previa.contains('0xFF1E1E20'), isFalse);
      expect(previa.contains('AppColores.pizarra'), isTrue);
      // El pie firmado no cambia ni una letra.
      expect(lineaOficialTarjetaImagen,
          'Mensaje automático de nuestro sistema de gestión');
      expect(lineaContactoTarjetaImagen,
          'Si vas a responder, escríbenos al 58191577');
    });
  });
}
