/// 1.23 B6 — Feedback y errores clasificados (veredicto de
/// Argón): duraciones por clase, política de prioridades
/// P1/P2 con protección de 3 s de la barra crítica frente a
/// avisos AUTOMÁTICOS, Deshacer con ventana visual de 8 s y
/// configuración pura de las clases de error C1–C5.
///
/// Sin temporizadores reales: los tests de widget avanzan el
/// reloj falso con pump(Duration) (patrón de
/// avisos_gramatica_123_test) y las decisiones de política se
/// prueban como funciones puras.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

/// Monta una app mínima y devuelve el contexto del Builder.
Future<BuildContext> _montar(WidgetTester t) async {
  late BuildContext ctx;
  await t.pumpWidget(MaterialApp(
    home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold(body: SizedBox());
    }),
  ));
  return ctx;
}

void main() {
  group('B6 duraciones por clase (puro)', () {
    test('éxito/info/neutral 3 s, alerta/agotado 4 s, error 6 s',
        () {
      expect(duracionAviso(SignificadoChip.exito),
          const Duration(seconds: 3));
      expect(duracionAviso(SignificadoChip.info),
          const Duration(seconds: 3));
      expect(duracionAviso(SignificadoChip.neutral),
          const Duration(seconds: 3));
      expect(duracionAviso(SignificadoChip.alerta),
          const Duration(seconds: 4));
      expect(duracionAviso(SignificadoChip.agotado),
          const Duration(seconds: 4));
      expect(duracionAviso(SignificadoChip.error),
          const Duration(seconds: 6));
    });

    test('la ventana visual del Deshacer es 8 s y la protección '
        'de la barra crítica es 3 s', () {
      expect(kDuracionVisualDeshacer, const Duration(seconds: 8));
      expect(
          kProteccionAvisoCritico, const Duration(seconds: 3));
    });
  });

  group('B6 política de prioridades (puro)', () {
    test('una P2 es todo error y toda barra con acción', () {
      expect(avisoEsCritico(SignificadoChip.error), isTrue);
      expect(
          avisoEsCritico(SignificadoChip.neutral, conAccion: true),
          isTrue);
      expect(avisoEsCritico(SignificadoChip.exito), isFalse);
      expect(avisoEsCritico(SignificadoChip.alerta), isFalse);
    });

    test('P1 automático NO pisa una P2 de menos de 3 s', () {
      expect(
          avisoEntranteSeDescarta(
            activaEsCritica: true,
            antiguedadActiva: const Duration(seconds: 1),
            entranteEsCritica: false,
            origenEntrante: OrigenAviso.automatico,
          ),
          isTrue);
      expect(
          avisoEntranteSeDescarta(
            activaEsCritica: true,
            antiguedadActiva: Duration.zero,
            entranteEsCritica: false,
            origenEntrante: OrigenAviso.automatico,
          ),
          isTrue);
    });

    test('P1 automático SÍ entra si la P2 ya cumplió 3 s', () {
      expect(
          avisoEntranteSeDescarta(
            activaEsCritica: true,
            antiguedadActiva: const Duration(seconds: 3),
            entranteEsCritica: false,
            origenEntrante: OrigenAviso.automatico,
          ),
          isFalse);
      expect(
          avisoEntranteSeDescarta(
            activaEsCritica: true,
            antiguedadActiva: const Duration(seconds: 30),
            entranteEsCritica: false,
            origenEntrante: OrigenAviso.automatico,
          ),
          isFalse);
    });

    test('una acción directa del usuario pisa siempre', () {
      expect(
          avisoEntranteSeDescarta(
            activaEsCritica: true,
            antiguedadActiva: Duration.zero,
            entranteEsCritica: false,
            origenEntrante: OrigenAviso.usuario,
          ),
          isFalse);
    });

    test('un P2 automático tampoco se descarta, y sin P2 activa '
        'no hay protección', () {
      expect(
          avisoEntranteSeDescarta(
            activaEsCritica: true,
            antiguedadActiva: Duration.zero,
            entranteEsCritica: true,
            origenEntrante: OrigenAviso.automatico,
          ),
          isFalse);
      expect(
          avisoEntranteSeDescarta(
            activaEsCritica: false,
            antiguedadActiva: Duration.zero,
            entranteEsCritica: false,
            origenEntrante: OrigenAviso.automatico,
          ),
          isFalse);
    });
  });

  group('B6 errores clasificados C1–C5 (puro)', () {
    test('configuración exacta por clase', () {
      final c1 = configErrorClasificado(ClaseError.lectura);
      expect(c1.significado, SignificadoChip.alerta);
      expect(c1.duracion, const Duration(seconds: 5));
      expect(c1.etiquetaAccion, 'Reintentar');

      final c2 = configErrorClasificado(ClaseError.escrituraLocal);
      expect(c2.significado, SignificadoChip.error);
      expect(c2.duracion, const Duration(seconds: 6));
      expect(c2.etiquetaAccion, isNull);

      final c3 =
          configErrorClasificado(ClaseError.confirmacionIncierta);
      expect(c3.significado, SignificadoChip.alerta);
      expect(c3.duracion, const Duration(seconds: 6));
      expect(c3.etiquetaAccion, 'Verificar');

      final c4 = configErrorClasificado(ClaseError.validacion);
      expect(c4.duracion, const Duration(seconds: 5));
      expect(c4.etiquetaAccion, isNull);

      final c5 = configErrorClasificado(ClaseError.rechazoSync);
      expect(c5.significado, SignificadoChip.error);
      expect(c5.duracion, const Duration(seconds: 6));
      expect(c5.etiquetaAccion, 'Ver cola');
    });

    test('SOLO C1 ofrece Reintentar; C3 jamás', () {
      for (final clase in ClaseError.values) {
        final etiqueta = configErrorClasificado(clase).etiquetaAccion;
        if (clase == ClaseError.lectura) {
          expect(etiqueta, 'Reintentar');
        } else {
          expect(etiqueta, isNot('Reintentar'),
              reason: '$clase no puede ofrecer Reintentar');
        }
      }
      expect(
          configErrorClasificado(ClaseError.confirmacionIncierta)
              .etiquetaAccion,
          'Verificar');
    });

    test('textos canónicos de C1 y C3; el resto pone el suyo',
        () {
      expect(textoCanonicoErrorClasificado(ClaseError.lectura),
          contains('Sin conexión al servidor'));
      expect(
          textoCanonicoErrorClasificado(
              ClaseError.confirmacionIncierta),
          contains('No sabemos aún'));
      expect(
          textoCanonicoErrorClasificado(ClaseError.escrituraLocal),
          isNull);
      expect(textoCanonicoErrorClasificado(ClaseError.validacion),
          isNull);
      expect(
          textoCanonicoErrorClasificado(ClaseError.rechazoSync),
          isNull);
    });
  });

  group('B6 avisos en widget', () {
    testWidgets('un aviso de éxito (3 s) ya no vive a los 5 s',
        (t) async {
      final ctx = await _montar(t);
      mostrarSnack(ctx, 'Guardado',
          significado: SignificadoChip.exito);
      await t.pump();
      expect(find.text('Guardado'), findsOneWidget);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Guardado'), findsNothing);
    });

    testWidgets('un error (6 s) sigue vivo a los 3,5 s', (t) async {
      final ctx = await _montar(t);
      mostrarSnack(ctx, 'Fallo grave',
          significado: SignificadoChip.error);
      await t.pump();
      for (var i = 0; i < 7; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Fallo grave'), findsOneWidget);
    });

    testWidgets('la barra Deshacer lleva la ventana visual de '
        '8 s y sigue viva a los 7 s', (t) async {
      final ctx = await _montar(t);
      mostrarSnack(ctx, 'Venta registrada',
          accion: 'Deshacer',
          alAccion: () {},
          duracion: kDuracionVisualDeshacer);
      await t.pump();
      expect(find.text('Deshacer'), findsOneWidget);
      // La duración construida es la constante B6 (8 s).
      final barra = t.widget<SnackBar>(find.byType(SnackBar));
      expect(barra.duration, kDuracionVisualDeshacer);
      // A los 7 s sigue viva: ni la duración de alerta (4 s)
      // ni la de error (6 s) la habrían mantenido. El
      // vencimiento real de una barra con acción lo fija el
      // helper central con persist: false (en el framework,
      // una SnackBar con acción nace persistente y no vence
      // sola; ver la nota en mostrarSnack).
      for (var i = 0; i < 14; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Venta registrada'), findsOneWidget);
    });

    testWidgets('P2 joven: un aviso AUTOMÁTICO P1 se descarta; '
        'uno del usuario pisa', (t) async {
      // Reloj de avisos congelado: la P2 tiene antigüedad 0.
      final ahora = DateTime(2026, 1, 1, 12);
      fijarRelojAvisosParaTest(() => ahora);
      addTearDown(() => fijarRelojAvisosParaTest(null));
      final ctx = await _montar(t);
      mostrarSnack(ctx, 'Fallo grave',
          significado: SignificadoChip.error);
      await t.pump();
      expect(find.text('Fallo grave'), findsOneWidget);

      mostrarSnack(ctx, 'Sync de fondo terminó',
          significado: SignificadoChip.exito,
          origen: OrigenAviso.automatico);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Sync de fondo terminó'), findsNothing);
      expect(find.text('Fallo grave'), findsOneWidget);

      mostrarSnack(ctx, 'Hecho por ti',
          significado: SignificadoChip.exito);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Fallo grave'), findsNothing);
      expect(find.text('Hecho por ti'), findsOneWidget);
    });

    testWidgets('P2 con 3 s cumplidos: el aviso automático ya '
        'puede reemplazarla', (t) async {
      // La antigüedad se envejece en el RELOJ DE AVISOS: el
      // pump de testWidgets mueve temporizadores pero no
      // mueve DateTime.now().
      var ahora = DateTime(2026, 1, 1, 12);
      fijarRelojAvisosParaTest(() => ahora);
      addTearDown(() => fijarRelojAvisosParaTest(null));
      final ctx = await _montar(t);
      mostrarSnack(ctx, 'Fallo grave',
          significado: SignificadoChip.error);
      await t.pump();
      ahora = ahora.add(const Duration(seconds: 4));
      expect(find.text('Fallo grave'), findsOneWidget);

      mostrarSnack(ctx, 'Sync de fondo terminó',
          significado: SignificadoChip.exito,
          origen: OrigenAviso.automatico);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Fallo grave'), findsNothing);
      expect(find.text('Sync de fondo terminó'), findsOneWidget);
    });

    testWidgets('la variante CONTROLADA (Deshacer de Servicios) '
        'devuelve controlador y queda protegida como P2',
        (t) async {
      // Panel Bloque 4: el Deshacer ya no construye su barra
      // por fuera — pasa por el mecanismo central y un aviso
      // automático P1 no puede matarlo en sus primeros 3 s.
      final ahora = DateTime(2026, 1, 1, 12);
      fijarRelojAvisosParaTest(() => ahora);
      addTearDown(() => fijarRelojAvisosParaTest(null));
      final ctx = await _montar(t);
      final messenger = ScaffoldMessenger.of(ctx);
      final ctrl = mostrarSnackControladoEnMessenger(
        messenger,
        'Venta registrada',
        significado: SignificadoChip.exito,
        duracion: kDuracionVisualDeshacer,
        accion: 'Deshacer',
        alAccion: () {},
      );
      expect(ctrl, isNotNull);
      await t.pump();
      expect(find.text('Venta registrada'), findsOneWidget);
      expect(find.text('Deshacer'), findsOneWidget);

      mostrarSnackEnMessenger(messenger, 'Sync de fondo terminó',
          significado: SignificadoChip.exito,
          origen: OrigenAviso.automatico);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Sync de fondo terminó'), findsNothing);
      expect(find.text('Venta registrada'), findsOneWidget);
    });
  });

  group('B6 EstadoError clasificado', () {
    Future<void> montarError(WidgetTester t, EstadoError w) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: w),
      ));
    }

    testWidgets('C3 ofrece «Verificar», nunca «Reintentar»',
        (t) async {
      await montarError(
          t,
          EstadoError(
            titulo: 'Confirmación incierta',
            claseError: ClaseError.confirmacionIncierta,
            onReintentar: () {},
          ));
      expect(find.text('Verificar'), findsOneWidget);
      expect(find.text('Reintentar'), findsNothing);
    });

    testWidgets('C1 ofrece «Reintentar»', (t) async {
      await montarError(
          t,
          EstadoError(
            claseError: ClaseError.lectura,
            onReintentar: () {},
          ));
      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets('C2 no ofrece botón aunque haya callback',
        (t) async {
      await montarError(
          t,
          EstadoError(
            claseError: ClaseError.escrituraLocal,
            onReintentar: () {},
          ));
      expect(find.byType(BotonSecundario), findsNothing);
    });

    testWidgets('sin clase conserva el «Reintentar» histórico',
        (t) async {
      await montarError(t, EstadoError(onReintentar: () {}));
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  group('B6 mostrarErrorClasificado', () {
    testWidgets('C3 se muestra con acción «Verificar»',
        (t) async {
      final ctx = await _montar(t);
      mostrarErrorClasificado(
        ctx,
        ClaseError.confirmacionIncierta,
        textoCanonicoErrorClasificado(
            ClaseError.confirmacionIncierta)!,
        alAccion: () {},
      );
      await t.pump();
      expect(find.text('Verificar'), findsOneWidget);
      expect(find.text('Reintentar'), findsNothing);
    });

    testWidgets('C5 se muestra con acción «Ver cola»', (t) async {
      final ctx = await _montar(t);
      mostrarErrorClasificado(
        ctx,
        ClaseError.rechazoSync,
        'El servidor rechazó una operación',
        alAccion: () {},
      );
      await t.pump();
      expect(find.text('Ver cola'), findsOneWidget);
    });

    testWidgets('C2 se muestra sin acción', (t) async {
      final ctx = await _montar(t);
      mostrarErrorClasificado(
        ctx,
        ClaseError.escrituraLocal,
        'No se pudo guardar localmente',
        alAccion: () {},
      );
      await t.pump();
      expect(find.byType(SnackBarAction), findsNothing);
    });
  });

  group('B6 pines de migración', () {
    test('los sitios directos migrados ya no usan showSnackBar',
        () {
      final login = File('lib/ui/login.dart').readAsStringSync();
      final main = File('lib/main.dart').readAsStringSync();
      final bandeja =
          File('lib/ui/bandeja_whatsapp.dart').readAsStringSync();
      expect(login.contains('.showSnackBar('), isFalse);
      expect(main.contains('.showSnackBar('), isFalse);
      expect(bandeja.contains('.showSnackBar('), isFalse);
      expect(login.contains('mostrarSnackEnMessenger('), isTrue);
      expect(main.contains('messengerState:'), isTrue);
    });

    test('Servicios: Deshacer visual 8 s y feedback sobre el '
        'messenger capturado', () {
      final servicios =
          File('lib/ui/servicios.dart').readAsStringSync();
      // Panel Bloque 4: la barra del Deshacer pasa por el
      // mecanismo central (queda registrada como P2); ya NO
      // construye su SnackBar directo.
      expect(
          servicios.contains('mostrarSnackControladoEnMessenger('),
          isTrue);
      expect(servicios.contains('duracion: kDuracionVisualDeshacer'),
          isTrue);
      expect(servicios.contains('messenger.showSnackBar('), isFalse);
      // Sin persist: false la duración sería nominal (una
      // SnackBar con acción nace persistente en el framework):
      // lo fija el helper central, no la pantalla.
      final componentes =
          File('lib/ui/componentes.dart').readAsStringSync();
      expect(componentes.contains('persist: false'), isTrue);
      expect(
          componentes.contains('mostrarSnackControladoEnMessenger'),
          isTrue);
      expect(
          servicios
              .contains("mostrarSnackEnMessenger(messenger, "
                  "'Venta deshecha')"),
          isTrue);
      // El descarte de la barra al salir de la pantalla sigue.
      expect(servicios.contains('_ctrlDeshacer?.close()'), isTrue);
    });
  });
}
