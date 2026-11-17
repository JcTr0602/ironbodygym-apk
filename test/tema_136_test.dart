/// 1.36 · S1-SISTEMA-TEMA: sellos de las filas del tema de
/// diseño (136-262, 136-265, 136-268, 136-269, 136-271,
/// 136-272, 136-278, 136-280, 136-281, 136-285, 136-287).
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';

double _luminancia(Color c) {
  double canal(double v) {
    final s = v / 255.0;
    return s <= 0.04045
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * canal(c.r * 255) +
      0.7152 * canal(c.g * 255) +
      0.0722 * canal(c.b * 255);
}

double _contraste(Color a, Color b) {
  final la = _luminancia(a);
  final lb = _luminancia(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('136-262 esquema explícito completo', () {
    test('ningún papel del par de producción nace de una semilla', () {
      final fuente =
          File('lib/ui/diseno.dart').readAsStringSync();
      expect(fuente.contains('ColorScheme.fromSeed'), isFalse,
          reason: 'el esquema es explícito (esquemaIron)');
      for (final tema in [AppTema.sol(), AppTema.tacticoOscuro()]) {
        final e = tema.colorScheme;
        expect(e.primaryContainer, isNotNull);
        expect(e.onPrimaryContainer, isNotNull);
        expect(e.secondaryContainer, isNotNull);
        expect(e.tertiaryContainer, isNotNull);
        expect(e.errorContainer, AppColores.errorFondo);
        expect(e.surfaceTint, Colors.transparent);
        expect(e.inversePrimary, AppColores.naranja);
      }
    });

    test('papeles fijados del par de producción', () {
      final sol = AppTema.sol().colorScheme;
      expect(sol.primary, AppColores.cobaltoOscuro);
      expect(sol.surface, Colors.white);
      expect(sol.surfaceContainerHighest, AppColores.grisTecnico);
      final oscuro = AppTema.tacticoOscuro().colorScheme;
      expect(oscuro.primary, AppColores.cobalto);
      expect(oscuro.surface, AppColores.grafitoTactico);
      expect(oscuro.surfaceContainerHighest, AppColores.acero);
    });
  });

  group('136-265 un solo par de producción', () {
    test('claro()/oscuro() delegan en el par instalado', () {
      expect(AppTema.claro().colorScheme.surface,
          AppTema.sol().colorScheme.surface);
      expect(AppTema.claro().scaffoldBackgroundColor,
          AppTema.sol().scaffoldBackgroundColor);
      expect(AppTema.oscuro().colorScheme.surface,
          AppTema.tacticoOscuro().colorScheme.surface);
    });

    test('el alto contraste conserva la capa táctica', () {
      final hc = AppTema.tacticoOscuro(altoContraste: true);
      expect(hc.colorScheme.outline, Colors.white);
      final hcSol = AppTema.sol(altoContraste: true);
      expect(hcSol.colorScheme.outline, Colors.black);
      final fuente = File('lib/main.dart').readAsStringSync();
      expect(fuente.contains('highContrastTheme:'), isFalse,
          reason: 'la app aplica su variante en theme/darkTheme');
    });
  });

  group('136-268/269 semántica única y chips en AppColores', () {
    testWidgets('verdeDe/ambarDe/rojoDe SON los papeles *Texto',
        (tester) async {
      for (final tema in [AppTema.sol(), AppTema.tacticoOscuro()]) {
        late BuildContext ctx;
        await tester.pumpWidget(MaterialApp(
          theme: tema,
          home: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }),
        ));
        expect(AppColores.verdeDe(ctx), AppColores.exitoTexto(ctx));
        expect(AppColores.ambarDe(ctx), AppColores.alertaTexto(ctx));
        expect(AppColores.rojoDe(ctx), AppColores.errorTexto(ctx));
      }
    });

    test('la tabla de chips vive en AppColores con sus valores', () {
      expect(AppColores.chipTexto(0, false), AppColores.exitoTextoClaro);
      expect(AppColores.chipTexto(0, true), AppColores.chipExitoOscuro);
      expect(AppColores.chipTexto(2, false), AppColores.avisoFondo);
      expect(AppColores.chipTexto(4, false), AppColores.chipNeutralClaro);
      expect(AppColores.chipTexto(5, true), AppColores.chipAgotadoOscuro);
    });
  });

  group('136-271/272 opacidad y elevación', () {
    test('AppOpacidad fija el tinte del sistema', () {
      expect(AppOpacidad.tinte, 0.14);
      expect(AppOpacidad.bordeTinte, 0.35);
    });

    testWidgets('AppElevacion da borde luminoso en oscuro',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      final borde = AppElevacion.borde(ctx, 1);
      expect(borde.top.color, AppColores.luzBarra);
      expect(AppElevacion.sombra(ctx, 1), isNotEmpty);
    });
  });

  group('136-278 contraste contra los temas INSTALADOS', () {
    test('papeles de texto claro ≥4,5 sobre grisTecnico y papelFrio', () {
      for (final superficie in [
        AppColores.grisTecnico,
        AppColores.papelFrio,
        Colors.white,
      ]) {
        expect(_contraste(AppColores.exitoTextoClaro, superficie),
            greaterThanOrEqualTo(4.5),
            reason: 'exitoTextoClaro sobre $superficie');
        expect(_contraste(AppColores.naranjaTexto, superficie),
            greaterThanOrEqualTo(4.5),
            reason: 'naranjaTexto sobre $superficie');
        expect(
            _contraste(AppColores.textoSecundarioClaro, superficie),
            greaterThanOrEqualTo(4.5),
            reason: 'textoSecundarioClaro sobre $superficie');
      }
    });

    test('papeles de texto oscuro ≥4,5 sobre grafito/acero/pizarra', () {
      for (final superficie in [
        AppColores.grafitoTactico,
        AppColores.acero,
        AppColores.pizarra,
      ]) {
        for (final papel in [
          AppColores.exitoTextoOscuro,
          AppColores.errorTextoOscuro,
          AppColores.alertaTextoOscuro,
          AppColores.infoTextoOscuro,
        ]) {
          expect(_contraste(papel, superficie),
              greaterThanOrEqualTo(4.5),
              reason: '$papel sobre $superficie');
        }
      }
    });
  });

  group('136-280/281/287 texto, fósiles y gradiente', () {
    test('TextTheme completo: 15 ranuras y bodyMedium = cuerpo', () {
      final t = AppTema.sol().textTheme;
      for (final estilo in [
        t.displayLarge, t.displayMedium, t.displaySmall,
        t.headlineLarge, t.headlineMedium, t.headlineSmall,
        t.titleLarge, t.titleMedium, t.titleSmall,
        t.bodyLarge, t.bodyMedium, t.bodySmall,
        t.labelLarge, t.labelMedium, t.labelSmall,
      ]) {
        expect(estilo, isNotNull);
      }
      expect(t.bodyMedium!.fontSize, 14);
      expect(AppTexto.etiqueta.fontWeight, AppPesos.semibold);
      expect(AppTexto.metadato.fontWeight, isNot(AppPesos.semibold));
    });

    test('fósiles borrados, no deprecados', () {
      final fuente =
          File('lib/ui/diseno.dart').readAsStringSync();
      expect(fuente.contains('class AppSombra'), isFalse);
      expect(fuente.contains('gradienteDial'), isFalse);
      expect(fuente.contains('bannerFotosA'), isFalse);
      expect(fuente.contains('sobreNaranja '), isFalse,
          reason: 'renombrado a contenidoClaro (136-286)');
    });

    test('el gradiente de marca contiene la marca (136-287)', () {
      expect(AppColores.gradienteNaranja.colors,
          [AppColores.naranja, AppColores.naranjaOscuro]);
    });
  });
}
