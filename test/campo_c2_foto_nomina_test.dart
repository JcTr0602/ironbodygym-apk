/// 1.36 CAMPO C-2: la foto del cierre de nómina por
/// entrenador. La individual lleva SOLO los datos de ese
/// entrenador (nombre y cifras: el otro no aparece ni en
/// texto ni en cifras) y su total es su neto; la conjunta
/// no cambia (los dos, y su «TOTAL A PAGAR» excluye al
/// ya liquidado, como siempre). Nivel pantalla: el botón
/// «Compartir su foto» de la tarjeta y los «Solo <nombre>»
/// de la vista conjunta abren la individual correcta.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart' show fmtMonto;
import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';
import 'package:ironbody_gym/ui/nomina.dart';

import 'jornada_ayudas.dart';

const _filaDuany = FilaCierreNomina(
  nombre: 'Duany',
  base: 6000,
  bono: 500,
  comision: 0,
  adelantos: 1000,
  deuda: 0,
  neto: 5500,
  liquidada: false,
);

const _filaGabriel = FilaCierreNomina(
  nombre: 'Gabriel',
  base: 6000,
  bono: 0,
  comision: 2750,
  adelantos: 0,
  deuda: 250,
  neto: 8500,
  liquidada: false,
);

String _textosDe(WidgetTester tester, Finder raiz) {
  return tester
      .widgetList<Text>(find.descendant(of: raiz, matching: find.byType(Text)))
      .map((t) => t.data ?? '')
      .join(' | ');
}

Widget _imagen(List<FilaCierreNomina> filas, {bool individual = false}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ImagenCierreNomina(
          mesEtiqueta: 'Octubre de 2026',
          generadoEtiqueta: 'Generada el 31 de octubre de 2026',
          filas: filas,
          individual: individual,
        ),
      ),
    ),
  );
}

void main() {
  group('C-2 · nivel imagen', () {
    testWidgets('la individual contiene SOLO a ese '
        'entrenador (nombre y cifras) y el total es su neto',
        (tester) async {
      await tester.pumpWidget(_imagen(const [_filaDuany], individual: true));
      await tester.pump();
      final textos = _textosDe(tester, find.byType(ImagenCierreNomina));
      expect(textos, contains('Duany'));
      expect(textos, contains('Neto: ${fmtMonto(5500)} CUP'));
      expect(textos, contains('NETO A PAGAR'));
      // El total de la individual es el neto de Duany.
      expect(textos, contains('${fmtMonto(5500)} CUP'));
      // Gabriel no aparece: ni su nombre ni NINGUNA de
      // sus cifras (comisión, deuda, neto).
      expect(textos, isNot(contains('Gabriel')));
      expect(textos, isNot(contains(fmtMonto(2750))));
      expect(textos, isNot(contains(fmtMonto(8500))));
      expect(textos, isNot(contains(fmtMonto(250))));
      // La marca y el pie de la casa se conservan.
      expect(textos, contains('IRON BODY GYM'));
      expect(textos, contains('58191577'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('la individual de un liquidado: el total '
        'sigue siendo su neto (no cae a cero)', (tester) async {
      const liquidada = FilaCierreNomina(
        nombre: 'Gabriel',
        base: 6000,
        bono: 0,
        comision: 0,
        adelantos: 0,
        deuda: 0,
        neto: 6000,
        liquidada: true,
      );
      await tester.pumpWidget(_imagen(const [liquidada], individual: true));
      await tester.pump();
      final textos = _textosDe(tester, find.byType(ImagenCierreNomina));
      expect(textos, contains('✓ Liquidada'));
      expect(textos, contains('${fmtMonto(6000)} CUP'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('la conjunta NO cambia: los dos '
        'entrenadores y el total excluye al liquidado',
        (tester) async {
      const gabrielLiquidado = FilaCierreNomina(
        nombre: 'Gabriel',
        base: 6000,
        bono: 0,
        comision: 2750,
        adelantos: 0,
        deuda: 250,
        neto: 8500,
        liquidada: true,
      );
      await tester.pumpWidget(
          _imagen(const [_filaDuany, gabrielLiquidado]));
      await tester.pump();
      final textos = _textosDe(tester, find.byType(ImagenCierreNomina));
      expect(textos, contains('Duany'));
      expect(textos, contains('Gabriel'));
      expect(textos, contains('TOTAL A PAGAR'));
      // Total conjunto = solo el neto de Duany (5500):
      // el de Gabriel, liquidado, no suma — como siempre.
      expect(textos, contains('${fmtMonto(5500)} CUP'));
      expect(totalAPagarCierre(const [_filaDuany, gabrielLiquidado]),
          5500);
      // Sin liquidar, el total conjunto suma los dos
      // netos (5500 + 8500): la exclusión es solo del
      // ya liquidado.
      expect(totalAPagarCierre(const [_filaDuany, _filaGabriel]),
          14000);
      expect(tester.takeException(), isNull);
    });
  });

  group('C-2 · nivel pantalla (Nómina del mes)', () {
    setUpAll(() async {
      await jornadaSetUpAll();
      await jornadaCargarRoboto();
    });

    Future<void> montarNomina(WidgetTester tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 969869611, 'username': 'duany', 'nombre': 'Duany'},
            {
              'telegram_id': 1403501391,
              'username': 'gabriel',
              'nombre': 'Gabriel'
            },
          ]),
        );
      });
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const NominaScreen(),
      ));
      await jornadaDrenar(tester, vueltas: 8);
    }

    testWidgets('cada tarjeta trae «Compartir su foto» y '
        'abre la individual sin el otro entrenador',
        (tester) async {
      await montarNomina(tester);
      // Corrección del relevo (verificación C-CAMPO): la
      // ListView de la pantalla es perezosa y en el
      // viewport real de 420×800 la segunda tarjeta no se
      // construye hasta desplazar — afirmar «2 botones a
      // la vez» era inalcanzable por construcción, no un
      // defecto del código. Se verifica una entrada por
      // tarjeta desplazando entre ambas.
      expect(find.text('Compartir su foto'), findsOneWidget,
          reason: 'la tarjeta visible trae su entrada');
      await tester.ensureVisible(find.text('Compartir su foto').first);
      await tester.pump();
      await tester.tap(find.text('Compartir su foto').first);
      await jornadaDrenar(tester, vueltas: 6);
      expect(find.text('Foto de Duany'), findsOneWidget);
      var textosImagen =
          _textosDe(tester, find.byType(ImagenCierreNomina));
      expect(textosImagen, contains('Duany'));
      expect(textosImagen, isNot(contains('Gabriel')),
          reason: 'privacidad: la individual no enseña al otro');
      // Cerrar el diálogo y bajar hasta la otra tarjeta:
      // también trae su «Compartir su foto» y abre la suya.
      await tester.tap(find.text('Cerrar'));
      await jornadaDrenar(tester, vueltas: 4);
      // Bajar la lista hasta la tarjeta de Gabriel (es la
      // última de entrenador; su botón es el que queda
      // construido y visible tras el desplazamiento).
      for (var i = 0; i < 4; i++) {
        await tester.drag(
            find.byType(ListView), const Offset(0, -500));
        await tester.pump();
      }
      expect(find.text('Compartir su foto'), findsWidgets,
          reason: 'la segunda tarjeta también trae su entrada');
      await tester.ensureVisible(find.text('Compartir su foto').last);
      await tester.pump();
      await tester.tap(find.text('Compartir su foto').last);
      await jornadaDrenar(tester, vueltas: 6);
      expect(find.text('Foto de Gabriel'), findsOneWidget);
      textosImagen = _textosDe(tester, find.byType(ImagenCierreNomina));
      expect(textosImagen, contains('Gabriel'));
      expect(textosImagen, isNot(contains('Duany')),
          reason: 'privacidad: la individual no enseña al otro');
      await jornadaCerrarCascara(tester);
    });

    testWidgets('desde la vista conjunta, «Solo Gabriel» '
        'salta a su individual', (tester) async {
      await montarNomina(tester);
      await tester.tap(find.byTooltip('Foto del cierre'));
      await jornadaDrenar(tester, vueltas: 6);
      expect(find.text('Foto del cierre de mes'), findsOneWidget);
      expect(find.text('Solo Duany'), findsOneWidget);
      expect(find.text('Solo Gabriel'), findsOneWidget);
      await tester.tap(find.text('Solo Gabriel'));
      await jornadaDrenar(tester, vueltas: 6);
      expect(find.text('Foto de Gabriel'), findsOneWidget);
      final textosImagen =
          _textosDe(tester, find.byType(ImagenCierreNomina));
      expect(textosImagen, contains('Gabriel'));
      expect(textosImagen, isNot(contains('Duany')));
      await jornadaCerrarCascara(tester);
    });
  });
}
