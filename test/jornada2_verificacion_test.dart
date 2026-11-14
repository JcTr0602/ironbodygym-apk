// JORNADA 2 · Verificación nominal a 360 dp + texto 1.3
//
// Tres verificaciones de la Jornada 1 llevadas al viewport
// nominal exigido por la Jornada 2: 360×800 dp y
// textScaler 1.3 (accesibilidad). En cada caso se afirma:
//  - takeException() == null (sin excepción de layout /
//    desborde de RenderFlex),
//  - el texto clave sigue presente en el árbol,
//  - los controles siguen alcanzables (tap real con efecto).
//
//  a. S14: diálogo de edición de la ficha — la fila de chips
//     Sexo es Wrap desde 62ef148 (antes Row: desbordaba 20 px
//     a ancho de teléfono, sin escalar texto).
//  b. S17: fila de cliente con chip «Cuenta a la Casa · sin
//     vencimiento» y trailing de dos botones — Flexible +
//     elipsis desde 8fa2e98 (lib/ui/buscar.dart FilaCliente).
//  c. S20: fila de Papelera (leading checkbox + trailing
//     Recuperar/Renovar, como en lib/ui/papelera.dart) con
//     BadgeEstado de texto largo — Flexible + elipsis en
//     componentes.dart desde 2a87dbd (desbordaba 158 px).
//     La primera corrida de esta batería cazó un SEGUNDO
//     desborde, de la fila entera: badge ya sano por dentro,
//     pero checkbox + foto + columna + los dos botones de
//     texto en fila sumaban 16 px de más a 360 dp + 1.3.
//     Corrección de la Jornada 2: en papelera.dart las dos
//     acciones van apiladas y compactas; la réplica de abajo
//     refleja esa construcción y la pantalla real lo manda.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/papelera.dart';

import 'jornada_ayudas.dart';

/// Viewport nominal Jornada 2: 360×800, DPR 1.
void _viewport360(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Envuelve [hijo] con textScaler 1.3 real.
Widget _conTexto13(Widget hijo) {
  return Builder(
    builder: (context) {
      final mq = MediaQuery.of(context);
      return MediaQuery(
        data: mq.copyWith(textScaler: const TextScaler.linear(1.3)),
        child: hijo,
      );
    },
  );
}

Widget _app(Widget home) {
  return MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: _conTexto13(home),
  );
}

String _iso(DateTime d) => isoHabana(d).substring(0, 10);

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada 2 · 360 dp + texto 1.3', () {
    testWidgets(
        'S14: el diálogo de edición de la ficha abre sin '
        'desborde y sus chips de Sexo son alcanzables',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final hasta = _iso(ahoraHabana().add(const Duration(days: 30)));
      await LocalDb.instance.upsertMirror('clientes', 20, {
        'id': 20,
        'nombre': 'Verificacion Jornada Dos',
        'estado': 'activo',
        'pagado_hasta': hasta,
        'telefono': '58112233',
        'carnet': '900115',
        'sexo': 'M',
      }, 1);
      _viewport360(tester);
      await tester.pumpWidget(_app(const FichaScreen(clienteId: 20)));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Editar'));
      expect(tester.takeException(), isNull,
          reason: 'la ficha a 360 dp + 1.3 no desborda al abrir');

      // Abrir el diálogo de edición en sitio.
      await tester.scrollUntilVisible(find.text('Editar'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Editar'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Sexo: '));
      expect(find.text('Masculino'), findsOneWidget);
      expect(find.text('Femenino'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'el diálogo con la fila Wrap de Sexo no '
              'desborda a 360 dp + texto 1.3');

      // Controles alcanzables: tocar el chip Femenino lo
      // selecciona y Cancelar cierra el diálogo.
      await tester.tap(find.text('Femenino'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final chip = tester.widget<ChoiceChip>(find
          .ancestor(of: find.text('Femenino'),
              matching: find.byType(ChoiceChip))
          .first);
      expect(chip.selected, isTrue,
          reason: 'el chip Femenino respondió al toque a '
              '360 dp + 1.3 (alcanzable, no recortado)');
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('Sexo: '), findsNothing,
          reason: 'Cancelar cerró el diálogo');
      expect(tester.takeException(), isNull);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'S17: fila con chip Cuenta a la Casa y trailing de '
        'dos botones sin desborde', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      _viewport360(tester);
      var toquesTrailing = 0;
      final clienteCasa = <String, dynamic>{
        'id': 40,
        'nombre': 'Casa Verificacion Nombre Largo Jornada',
        'estado': 'activo',
        'pagado_hasta': null,
        'cuenta_casa': 1,
        'telefono': '58112233',
        'carnet': '900115',
        'sexo': 'F',
      };
      await tester.pumpWidget(_app(Scaffold(
        body: FilaCliente(
          cliente: clienteCasa,
          // Trailing de Listas: dos botones (avisar + cobrar).
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_rounded),
                tooltip: 'Marcar como avisado',
                onPressed: () => toquesTrailing++,
              ),
              IconButton(
                icon: const Icon(Icons.payments_rounded),
                tooltip: 'Cobrar',
                onPressed: () => toquesTrailing++,
              ),
            ],
          ),
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Cuenta a la Casa · sin vencimiento'),
          findsOneWidget,
          reason: 'el chip completo de la Casa está en la fila');
      expect(tester.takeException(), isNull,
          reason: 'la fila de la Casa con dos botones no '
              'desborda a 360 dp + texto 1.3');
      // Ambos botones del trailing dentro del viewport y
      // alcanzables con tap real.
      for (final tooltip in ['Marcar como avisado', 'Cobrar']) {
        final rect = tester.getRect(find.byTooltip(tooltip));
        expect(rect.right, lessThanOrEqualTo(360),
            reason: '«$tooltip» queda dentro de los 360 dp');
        expect(rect.left, greaterThanOrEqualTo(0));
      }
      await tester.tap(find.byTooltip('Cobrar'));
      await tester.pumpAndSettle();
      expect(toquesTrailing, 1,
          reason: 'el segundo botón del trailing respondió');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'S20: fila de Papelera con BadgeEstado de texto '
        'largo sin desborde', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      _viewport360(tester);
      var recuperar = 0;
      var renovar = 0;
      // Vencido hace 400 días: BadgeEstado «VENCIDO 400 DÍAS».
      final vencido = _iso(
          ahoraHabana().subtract(const Duration(days: 400)));
      final clientePapelera = <String, dynamic>{
        'id': 51,
        'nombre': 'Papelera Verificacion Nombre Largo Jornada',
        'estado': 'inactivo',
        'pagado_hasta': vencido,
        'carnet': '900115',
        'sexo': 'F',
      };
      await tester.pumpWidget(_app(Scaffold(
        body: FilaCliente(
          cliente: clientePapelera,
          // Réplica fiel de la fila de PapeleraScreen:
          // leading checkbox + trailing con las dos acciones
          // APILADAS y compactas (corrección Jornada 2).
          leading: Checkbox(value: false, onChanged: (_) {}),
          trailing: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.restore_from_trash_rounded,
                    size: 18),
                label: const Text('Recuperar'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => recuperar++,
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Renovar'),
                onPressed: () => renovar++,
              ),
            ],
          ),
        ),
      )));
      await tester.pumpAndSettle();
      // El badge de texto largo está en el árbol (su texto
      // puede ir con elipsis visual, el widget conserva el
      // texto completo). El texto real del chip de vencido
      // (chipEstadoFila) es «Venció <fecha> · hace 400 días».
      expect(find.textContaining('hace 400 días'), findsWidgets,
          reason: 'el BadgeEstado de texto largo está pintado');
      expect(tester.takeException(), isNull,
          reason: 'la fila de Papelera con badge largo, '
              'checkbox y dos botones no desborda a '
              '360 dp + texto 1.3');
      await tester.tap(find.text('Recuperar'));
      await tester.pumpAndSettle();
      expect(recuperar, 1, reason: 'Recuperar es alcanzable');
      await tester.tap(find.text('Renovar'));
      await tester.pumpAndSettle();
      expect(renovar, 1, reason: 'Renovar es alcanzable');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'S20 (pantalla real): PapeleraScreen a 360 dp + 1.3 '
        'con un vencido de hace 400 días', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final vencido = _iso(
          ahoraHabana().subtract(const Duration(days: 400)));
      await LocalDb.instance.upsertMirror('clientes', 51, {
        'id': 51,
        'nombre': 'Papelera Verificacion Nombre Largo Jornada',
        'estado': 'inactivo',
        'pagado_hasta': vencido,
        'carnet': '900115',
        'sexo': 'F',
      }, 1);
      _viewport360(tester);
      await tester.pumpWidget(_app(const PapeleraScreen()));
      await tester.pumpAndSettle();
      await jornadaEsperar(
          tester, find.text('Papelera Verificacion Nombre Largo Jornada'));
      expect(find.textContaining('hace 400 días'), findsWidgets,
          reason: 'la pantalla real pinta el badge largo');
      expect(tester.takeException(), isNull,
          reason: 'la Papelera real no desborda a 360 dp + 1.3');
      await jornadaCerrarCascara(tester);
    });
  });
}
