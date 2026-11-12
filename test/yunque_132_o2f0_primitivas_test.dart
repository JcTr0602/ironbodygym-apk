/// 1.32 (Oleada 2, Fase 0): las PRIMITIVAS TRANSVERSALES
/// (PadNumerico, DeslizarConfirmar, Tacto) viven en
/// primitivas.dart como componentes compartidos, con el
/// MISMO comportamiento con el que nacieron en la hoja de
/// Liquidar Arqueo. La hoja las sigue consumiendo vía
/// re-export (compatibilidad de llamadores).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/hoja_liquidar_arqueo.dart'
    as hoja; // el re-export histórico
import 'package:ironbody_gym/ui/primitivas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PadNumerico (desde primitivas)', () {
    Future<String Function()> montar(WidgetTester tester) async {
      var valor = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PadNumerico(
              valor: valor,
              onCambia: (v) => setState(() => valor = v),
            ),
          ),
        ),
      ));
      return () => valor;
    }

    testWidgets('teclear compone el importe con sus reglas',
        (tester) async {
      final leer = await montar(tester);
      Future<void> tecla(String t) async {
        await tester.tap(find.byKey(ValueKey('pad-$t')));
        // Sin pump entre toques, el pad aún no se reconstruyó
        // y cada toque partiría del valor viejo.
        await tester.pump();
      }

      await tecla('1');
      await tecla('2');
      await tecla('.');
      await tecla('5');
      expect(leer(), '12.5');
      // Segundo punto decimal: rechazado.
      await tecla('.');
      expect(leer(), '12.5');
      // Tercer decimal: rechazado (tope de 2).
      await tecla('5');
      await tecla('5');
      expect(leer(), '12.55');
      // Borrar y limpiar.
      await tecla('⌫');
      expect(leer(), '12.5');
      await tecla('C');
      expect(leer(), '');
    });

    testWidgets('el re-export de la hoja es la misma clase',
        (tester) async {
      expect(hoja.PadNumerico, PadNumerico);
      expect(hoja.DeslizarConfirmar, DeslizarConfirmar);
    });
  });

  group('DeslizarConfirmar (desde primitivas)', () {
    testWidgets('un toque no confirma; el arrastre completo sí',
        (tester) async {
      var confirmaciones = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: DeslizarConfirmar(
              texto: 'Desliza para confirmar →',
              habilitado: true,
              onConfirmar: () => confirmaciones++,
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('deslizar-pulgar')));
      await tester.pump();
      expect(confirmaciones, 0);
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(600, 0));
      await tester.pump();
      expect(confirmaciones, 1);
    });

    testWidgets('deshabilitado no confirma ni arrastrando',
        (tester) async {
      var confirmaciones = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DeslizarConfirmar(
            texto: 'Desliza para confirmar →',
            habilitado: false,
            onConfirmar: () => confirmaciones++,
          ),
        ),
      ));
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(600, 0));
      await tester.pump();
      expect(confirmaciones, 0);
    });

    testWidgets('si la hoja aborta tras confirmar y el '
        'control se rehabilita, el carril vuelve al inicio '
        '(Corte B H-CB-2)', (tester) async {
      var confirmaciones = 0;
      Widget arbol(bool hab) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 420,
                child: DeslizarConfirmar(
                  texto: 'Desliza para liquidar →',
                  habilitado: hab,
                  onConfirmar: () => confirmaciones++,
                ),
              ),
            ),
          );
      await tester.pumpWidget(arbol(true));
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(600, 0));
      await tester.pump();
      expect(confirmaciones, 1);
      expect(find.text('Liquidando…'), findsOneWidget);
      // La hoja aborta (la guarda D2-04 pide revisar la
      // cifra, o el intento lanzó): se deshabilita mientras
      // resuelve y luego se REHABILITA sin cerrar la hoja.
      await tester.pumpWidget(arbol(false));
      await tester.pump();
      await tester.pumpWidget(arbol(true));
      await tester.pump();
      expect(find.text('Desliza para liquidar →'),
          findsOneWidget,
          reason: 'el rótulo vuelve al inicial: el carril '
              'ya no está confirmado ni clavado al final');
      expect(find.text('Liquidando…'), findsNothing);
      // Y un nuevo arrastre confirma de verdad otra vez.
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(600, 0));
      await tester.pump();
      expect(confirmaciones, 2);
    });

    testWidgets('si cambia el texto tras confirmar, el '
        'carril también se reinicia (Corte B H-CB-2)',
        (tester) async {
      var confirmaciones = 0;
      Widget arbol(String texto) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 420,
                child: DeslizarConfirmar(
                  texto: texto,
                  habilitado: true,
                  onConfirmar: () => confirmaciones++,
                ),
              ),
            ),
          );
      await tester.pumpWidget(arbol('Desliza para liquidar →'));
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(600, 0));
      await tester.pump();
      expect(confirmaciones, 1);
      // La hoja cambia de modo (cierre → entrega C1): el
      // rótulo es otro y la confirmación anterior no vale.
      await tester.pumpWidget(arbol('Desliza para entregar →'));
      await tester.pump();
      expect(find.text('Desliza para entregar →'),
          findsOneWidget);
      expect(find.text('Liquidando…'), findsNothing);
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(600, 0));
      await tester.pump();
      expect(confirmaciones, 2);
    });
  });

  group('Tacto (motor háptico)', () {
    test('las cinco intenciones disparan su patrón del sistema',
        () async {
      final llamadas = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform,
              (call) async {
        llamadas.add(call.method);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      Tacto.seleccion();
      Tacto.ligero();
      Tacto.confirmacion();
      Tacto.exito();
      Tacto.error();
      // HapticFeedback viaja como invocaciones de plataforma
      // (HapticFeedback.vibrate con su tipo): cinco gestos,
      // cinco llamadas, ninguna excepción.
      expect(llamadas.length, 5);
    });
  });
}
