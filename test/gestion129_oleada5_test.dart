/// Gestión 1.29 · Oleada 5 (Home y Panel) + D-21 + D-23.
///
/// Contrato que se fija:
/// · D-04: el banner de sync resuelve gradiente y letra
///   por variante pura tokenizada (fuera los literales de
///   widgets.dart); sobre los dos ámbar la letra es
///   grafito y pasa AA en ambos extremos del gradiente.
/// · D-23: badge y franja «POR REVISAR» salen de la MISMA
///   derivación pura de ítems por módulo (badge ==
///   ítems.length por construcción, por fuente, 0/1/N;
///   hoy y ayer desagregados en Equipo).
/// · FA-04: el contador de tarifas por revisar del Panel
///   consume la misma fuente fusionada y el mismo
///   predicado que la pantalla de Tarifas.
/// · FB-12: el buzón de Home suma TRES fuentes locales
///   (reservas, adelantos, rellenos) con texto por partes.
/// · FB-15: el buscador encuentra el compositor por
///   «anuncio» y el centro por «avisos», sin ambigüedad.
/// · D-21/D-14: cabecera premium (wordmark, logo en
///   tarjeta, botón de sync vivo) y glifo canónico de
///   «añadir persona» en Home.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/widgets.dart';

// Contraste WCAG (la misma cuenta del test de fundación).
double _luminancia(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double _contraste(Color a, Color b) {
  final la = _luminancia(a);
  final lb = _luminancia(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('D-04 · variante del banner por foto del motor', () {
    test('las fases activas y el error mapean directo', () {
      expect(varianteBannerDe(const SyncStatus(phase: SyncPhase.uploading)),
          VarianteBanner.enviando);
      expect(
          varianteBannerDe(const SyncStatus(phase: SyncPhase.downloading)),
          VarianteBanner.descargando);
      expect(varianteBannerDe(const SyncStatus(phase: SyncPhase.photos)),
          VarianteBanner.fotos);
      expect(varianteBannerDe(const SyncStatus(phase: SyncPhase.error)),
          VarianteBanner.error);
    });

    test('el reposo se parte por sus tres dimensiones', () {
      expect(varianteBannerDe(const SyncStatus(enLinea: false)),
          VarianteBanner.sinConexion);
      expect(varianteBannerDe(const SyncStatus(pending: 3)),
          VarianteBanner.pendientes);
      expect(varianteBannerDe(const SyncStatus(hayNovedades: true)),
          VarianteBanner.novedades);
      expect(varianteBannerDe(const SyncStatus()),
          VarianteBanner.sinSincronizar);
      expect(
          varianteBannerDe(SyncStatus(lastOk: DateTime(2026, 11, 7))),
          VarianteBanner.alDia);
      // Prioridad del reposo: sin conexión manda sobre
      // pendientes, y pendientes sobre novedades.
      expect(
          varianteBannerDe(
              const SyncStatus(enLinea: false, pending: 2)),
          VarianteBanner.sinConexion);
      expect(
          varianteBannerDe(
              const SyncStatus(pending: 2, hayNovedades: true)),
          VarianteBanner.pendientes);
    });
  });

  group('D-04 · gradientes tokenizados y letra segura', () {
    test('cada variante pinta su par de tokens', () {
      expect(coloresBanner(VarianteBanner.enviando).gradiente,
          [AppColores.bannerEnviandoA, AppColores.bannerEnviandoB]);
      expect(coloresBanner(VarianteBanner.descargando).gradiente,
          [AppColores.info, AppColores.infoOscuro]);
      expect(coloresBanner(VarianteBanner.fotos).gradiente,
          [AppColores.bannerFotosA, AppColores.bannerFotosB]);
      expect(coloresBanner(VarianteBanner.error).gradiente,
          [AppColores.error, AppColores.errorOscuro]);
      expect(coloresBanner(VarianteBanner.pendientes).gradiente,
          [AppColores.bannerAlertaA, AppColores.alertaOscuro]);
      expect(coloresBanner(VarianteBanner.novedades).gradiente,
          [AppColores.bannerInfoA, AppColores.bannerInfoB]);
      expect(coloresBanner(VarianteBanner.sinConexion).gradiente,
          [AppColores.bannerGrisA, AppColores.bannerGrisB]);
      expect(coloresBanner(VarianteBanner.sinSincronizar).gradiente,
          [AppColores.bannerGrisA, AppColores.bannerGrisB]);
      expect(coloresBanner(VarianteBanner.alDia).gradiente,
          [AppColores.exito, AppColores.exitoOscuro]);
    });

    test('sobre los dos ámbar la letra es grafito y pasa '
        'AA en AMBOS extremos (el blanco daba 2,15 y 1,69)',
        () {
      for (final v in [
        VarianteBanner.enviando,
        VarianteBanner.pendientes,
      ]) {
        final c = coloresBanner(v);
        expect(c.frente, AppColores.sobreMarca, reason: '$v');
        for (final extremo in c.gradiente) {
          expect(_contraste(c.frente, extremo),
              greaterThanOrEqualTo(4.5),
              reason: '$v sobre $extremo');
        }
        // La cuenta del defecto que se corrige.
        expect(_contraste(Colors.white, c.gradiente.first),
            lessThan(2.2),
            reason: 'el blanco era ilegible en el extremo '
                'claro de $v');
      }
    });

    test('widgets.dart no conserva ningún literal de color', () {
      final src = File('lib/ui/widgets.dart').readAsStringSync();
      expect(src.contains('Color(0x'), isFalse,
          reason: 'D-04: todo gradiente del banner y de la '
              'píldora sale de tokens de diseno.dart');
    });

    testWidgets('el banner pinta el título con el frente '
        'de su variante (reposo sin sincronizar = blanco)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SyncBanner()),
      ));
      await tester.pump();
      final titulo = tester.widget<Text>(find.text('Sin sincronizar'));
      expect(titulo.style?.color, Colors.white);
      expect(
          coloresBanner(varianteBannerDe(
                  const SyncStatus()))
              .frente,
          Colors.white);
    });
  });
}
