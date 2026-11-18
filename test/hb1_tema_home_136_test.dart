/// H-B1 (1.36): filas Hy4 CONFIRMADO media-baja/baja —
/// grupo tema + Home: 136-326, 136-329, 136-330, 136-332,
/// 136-333, 136-334, 136-335, 136-336, 136-346, 136-348.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
/// Pruebas de tema reales + contratos de fuente (patrón H-A1/H-A2).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-348 · scaffold en alto contraste', () {
    test('claro HC = blanco puro; oscuro HC = negro puro', () {
      expect(AppTema.sol(altoContraste: true).scaffoldBackgroundColor,
          Colors.white);
      expect(
          AppTema.tacticoOscuro(altoContraste: true)
              .scaffoldBackgroundColor,
          Colors.black);
    });
    test('sin HC el fondo táctico se conserva', () {
      expect(AppTema.sol().scaffoldBackgroundColor, AppColores.papelFrio);
      expect(AppTema.tacticoOscuro().scaffoldBackgroundColor,
          AppColores.pizarra);
    });
  });

  group('136-346 · roles de texto naranja por brillo', () {
    test('TextButton: claro = naranjaTexto, oscuro = naranja', () {
      final claro = AppTema.sol()
          .textButtonTheme
          .style!
          .foregroundColor!
          .resolve(<WidgetState>{});
      final oscuro = AppTema.tacticoOscuro()
          .textButtonTheme
          .style!
          .foregroundColor!
          .resolve(<WidgetState>{});
      expect(claro, AppColores.naranjaTexto);
      expect(oscuro, AppColores.naranja);
    });
    test('floatingLabel: claro = naranjaTexto, oscuro = naranja', () {
      expect(AppTema.sol().inputDecorationTheme.floatingLabelStyle!.color,
          AppColores.naranjaTexto);
      expect(
          AppTema.tacticoOscuro()
              .inputDecorationTheme
              .floatingLabelStyle!
              .color,
          AppColores.naranja);
    });
    test('chip de cumpleaños de la ficha usa textoNaranja(context)', () {
      expect(_src('lib/ui/ficha.dart'),
          contains('AppColores\n                                              .textoNaranja(context)'));
    });
  });

  group('136-326 · themeAnimationDuration según Reducir movimiento', () {
    test('main.dart fija la duración de animación del tema', () {
      final s = _src('lib/main.dart');
      expect(s, contains('themeAnimationDuration:'));
      expect(s, contains('reducirMov ? Duration.zero'));
    });
  });

  group('Home · contratos de fuente', () {
    final home = _src('lib/ui/home.dart');
    test('136-330 · _verificarPermisos repinta tras cargar()', () {
      final i = home.indexOf('Future<void> _verificarPermisos()');
      final tramo = home.substring(i, i + 500);
      expect(tramo, contains('setState(() {});'));
    });
    test('136-332 · Cerrar turno con icono de cierre', () {
      expect(home, contains('Icons.lock_rounded'));
      expect(home, isNot(contains('Icons.lock_open_rounded')));
    });
    test('136-333 · esqueleto en la primera carga del Mostrador', () {
      expect(home, contains('home-cargando-esqueleto'));
      expect(home, contains('SkeletonDashboard()'));
    });
    test('136-334 · el banner de sync muestra el fallo guardado', () {
      expect(home, contains('_falloSync!'));
    });
    test('136-329 · el vacío del dueño nombra lo que queda visible', () {
      expect(home,
          contains('«Por Decidir» sigue visible arriba.'));
    });
    test('136-336 · plural real y descarte anunciado', () {
      expect(home, contains('1 turno sin reporte:'));
      expect(home, contains('turnos sin reporte:'));
      expect(home, contains('Descartar aviso'));
    });
  });
}
