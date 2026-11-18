/// H-B1 (1.36): componentes + login + PIN —
/// 136-416, 136-417, 136-420, 136-422, 136-423, 136-424,
/// 136-425, 136-426, 136-428, 136-429, 136-430, 136-431,
/// 136-432, 136-435, 136-436, 136-437, 136-440, 136-441,
/// 136-443.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-422 · limpiarDigitosTelefono sin hueco de 9', () {
    test('9 dígitos empezando en 53 ya no devuelven 9', () {
      final r = limpiarDigitosTelefono('535123456');
      expect(r.length, lessThanOrEqualTo(8));
    });
    test('el internacional de 10 colapsa a los 8 locales', () {
      expect(limpiarDigitosTelefono('5351234567'), '51234567');
    });
    test('el local de 8 pasa intacto; el largo se acota a 8', () {
      expect(limpiarDigitosTelefono('51234567'), '51234567');
      expect(limpiarDigitosTelefono('512345678901'), '51234567');
      expect(limpiarDigitosTelefono('+53 5123 4567'), '51234567');
    });
    test('ninguna entrada supera 8 dígitos', () {
      for (final crudo in [
        '535123456',
        '53512345678',
        '999999999999',
        '53',
        '',
        'abc'
      ]) {
        expect(limpiarDigitosTelefono(crudo).length,
            lessThanOrEqualTo(8),
            reason: crudo);
      }
    });
  });

  testWidgets('136-416 · CampoTexto oscuro con ojo que alterna',
      (t) async {
    final ctrl = TextEditingController(text: 'secreto');
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(
        body: CampoTexto(controller: ctrl, obscure: true),
      ),
    ));
    var campo = t.widget<TextField>(find.byType(TextField));
    expect(campo.obscureText, isTrue);
    expect(find.byTooltip('Mostrar'), findsOneWidget);
    await t.tap(find.byTooltip('Mostrar'));
    await t.pump();
    campo = t.widget<TextField>(find.byType(TextField));
    expect(campo.obscureText, isFalse);
    expect(find.byTooltip('Ocultar'), findsOneWidget);
  });

  testWidgets('136-416 · CampoTexto claro no lleva ojo', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: const Scaffold(body: CampoTexto()),
    ));
    expect(find.byTooltip('Mostrar'), findsNothing);
    expect(find.byTooltip('Ocultar'), findsNothing);
  });

  testWidgets('136-420 · el vacío de barras es uno solo', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.sol(),
      home: const Scaffold(
        body: Column(
          children: [
            GraficoBarrasDiarias(datos: [], altura: 84),
            GraficoBarrasDiarias(
              datos: [
                {'fecha': '2026-11-17', 'total': 0},
                {'fecha': '2026-11-18', 'total': 0},
              ],
              altura: 84,
            ),
          ],
        ),
      ),
    ));
    expect(find.text('Sin actividad en el período'), findsNWidgets(2));
    for (final e in find.byType(GraficoBarrasDiarias).evaluate()) {
      expect(e.size!.height, 84);
    }
  });

  group('contratos de fuente', () {
    final comp = _src('lib/ui/componentes.dart');
    test('136-423/424/426/430 · Tarjeta y spinners de marca', () {
      expect(comp, contains('altoContraste ||'));
      expect(comp, contains('color: AppColores.naranja'));
      expect(comp, contains('splashColor: AppColores.naranja'));
      expect(comp, contains('size: 18, color: AppColores.naranja),'));
    });
    test('136-425 · errorTexto en los tres sitios', () {
      expect('errorTexto(context)'.allMatches(comp).length,
          greaterThanOrEqualTo(3));
      expect(comp, contains('AppColores.errorTexto(ctx)'));
    });
    test('136-428/429/431 · cruce, selector y vacío', () {
      expect(comp, contains('layoutBuilder: (actual, anteriores)'));
      expect(comp, contains('AnimatedRotation('));
      expect(comp, contains('sinMarco\n          ? (compacto ? 72.0 : 96.0)'));
    });
    test('136-417 · sin Colors.grey en EncabezadoSeccion ni barras', () {
      final encab = comp.substring(
          comp.indexOf('class EncabezadoSeccion'),
          comp.indexOf('class EncabezadoSeccion') + 4200);
      expect(encab, isNot(contains('Colors.grey')));
      final barras = comp.substring(
          comp.indexOf('class GraficoBarrasDiarias'),
          comp.indexOf('class GraficoBarrasDiarias') + 6500);
      expect(barras, isNot(contains('Colors.grey')));
    });
    test('136-432/435/436/437 · login', () {
      final s = _src('lib/ui/login.dart');
      expect(s, contains('if (!mounted) return;'));
      expect(s, contains('_errorEsAviso'));
      expect(s, contains('_limpiarErrorAlTeclear'));
      expect(s, contains('textoSobreOscuroMedio),'));
    });
    test('136-440/441/424 · pin_lock', () {
      final s = _src('lib/ui/pin_lock.dart');
      expect(s, contains('onPressed: _verificando ? null : _olvidePin'));
      expect(s, contains("label: 'Borrar'"));
      expect(s, contains('color: AppColores.naranja)'));
    });
    test('136-443 · modal del PIN con PopScope', () {
      final s = _src('lib/ui/modal_pin_acceso.dart');
      expect(s, contains('PopScope('));
      expect(s, contains('canPop: _cierrePermitido'));
    });
  });
}
