/// 1.32 (Escalón 3, Pieza 3): la bandeja «Por Decidir» bajo
/// la COMPUERTA 1 del veredicto g132.
///
/// La regla de oro que se fija aquí: «Todo al día · 0
/// decisiones pendientes» SOLO puede salir si TODAS las
/// fuentes verificaron (locales leídas y las 4 remotas con
/// valor). Si una remota devuelve null (sin conexión o
/// respuesta degradada), la bandeja lo dice una sola vez
/// en la línea «Bandejas sin verificar — sin conexión»
/// (redacción 1.35 M-3; antes cada fila enseñaba su
/// «sin verificar» y la línea iba en minúsculas) —
/// jamás pliega el desconocido a un 0.
///
/// El arnés del dueño con sesión no existe en el banco
/// (ver cabecera de banco_widget_test): la bandeja se prueba
/// sola, con sus cargadores inyectados, que es su costura.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _envolver(BandejaPorDecidir b) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: b)),
    );

BandejaPorDecidir _bandeja({
  int incidencias = 0,
  Future<ConteosRemotosPorDecidir> Function()? remotas,
}) {
  return BandejaPorDecidir(
    incidencias: incidencias,
    rellenos: 0,
    adelantos: 0,
    onIr: (_) {},
    cargarRemotas: remotas ??
        () async => const ConteosRemotosPorDecidir(
            vales: 0, plus: 0, comunidad: 0, solicitudes: 0),
    cargarCongelaciones: () async => (ok: true, pendientes: 0),
    cargarArqueos: () async => const [],
    // 1.32 (Fase 3): la bandeja sumó la fuente local de
    // catálogo (Momento 4); el arnés la inyecta como las
    // demás para que «todo verificado» lo sea de verdad.
    cargarCatalogo: () async => 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('titularPorDecidir (puro)', () {
    test('todo verificado y en 0 → Todo al día', () {
      final t = titularPorDecidir(
        locales: 0,
        remotasEfectivas: const ConteosRemotosPorDecidir(
            vales: 0, plus: 0, comunidad: 0, solicitudes: 0),
        remotasVerificadasAhora: true,
      );
      expect(t.todoAlDia, isTrue);
      expect(t.titular, contains('Todo al día'));
    });

    test('remotas SIN verificar y suma 0 → jamás «Todo al día»', () {
      final t = titularPorDecidir(
        locales: 0,
        remotasEfectivas: const ConteosRemotosPorDecidir(),
        remotasVerificadasAhora: false,
      );
      expect(t.todoAlDia, isFalse);
      expect(t.titular, isNot(contains('Todo al día')));
      expect(t.titular, isNot(contains('0 decisiones')));
    });

    test('cuenta locales + remotas verificadas', () {
      final t = titularPorDecidir(
        locales: 2,
        remotasEfectivas: const ConteosRemotosPorDecidir(
            vales: 1, plus: 0, comunidad: 0, solicitudes: 0),
        remotasVerificadasAhora: true,
      );
      expect(t.todoAlDia, isFalse);
      expect(t.titular, '3 decisiones pendientes');
    });
  });

  group('foto persistida de remotas', () {
    test('guardar y leer devuelve los mismos conteos', () async {
      await guardarFotoPorDecidir(const ConteosRemotosPorDecidir(
          vales: 3, plus: null, comunidad: 1, solicitudes: 0));
      final foto = await leerFotoPorDecidir();
      expect(foto, isNotNull);
      expect(foto!.conteos.vales, 3);
      expect(foto.conteos.plus, isNull);
      expect(foto.conteos.comunidad, 1);
      expect(foto.conteos.solicitudes, 0);
    });

    test('sin foto guardada, leer devuelve null (no un cero)',
        () async {
      expect(await leerFotoPorDecidir(), isNull);
    });
  });

  group('BandejaPorDecidir (widget)', () {
    testWidgets(
        'remotas caídas: la bandeja lo dice una sola vez '
        '(M-3) y nunca el cero alegre',
        (tester) async {
      await tester.pumpWidget(_envolver(_bandeja(
        remotas: () async => const ConteosRemotosPorDecidir(),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.text('Bandejas sin verificar — sin conexión'),
          findsOneWidget);
      // M-3: las filas individuales ya no repiten
      // «sin verificar» — ni una sola fila remota se pinta.
      expect(find.text('sin verificar'), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(find.textContaining('Todo al día'), findsNothing);
    });

    testWidgets('todo verificado en 0: pliega a «Todo al día»',
        (tester) async {
      await tester.pumpWidget(_envolver(_bandeja()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Todo al día · 0 decisiones pendientes'),
          findsOneWidget);
      expect(find.textContaining('sin verificar'), findsNothing);
    });

    testWidgets(
        'con locales pendientes manda el conteo aunque la red caiga',
        (tester) async {
      await tester.pumpWidget(_envolver(_bandeja(
        incidencias: 2,
        remotas: () async => const ConteosRemotosPorDecidir(),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('2 decisiones pendientes'), findsOneWidget);
      expect(
          find.text('Bandejas sin verificar — sin conexión'),
          findsOneWidget);
    });
  });
}
