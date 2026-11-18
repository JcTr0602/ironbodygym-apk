/// UI136-11 (adjudicación ARGON-136-UI, hallazgo H11):
/// layout de diálogos — compensaciones duplicadas y
/// contenidos sin scroll que desbordan en pantallas bajas
/// o con la escala de letra grande.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

String _tramo(String s, String marca, int chars) {
  final i = s.indexOf(marca);
  expect(i, greaterThanOrEqualTo(0), reason: 'no aparece $marca');
  final fin = i + chars > s.length ? s.length : i + chars;
  return s.substring(i, fin);
}

void main() {
  test('UI136-11 · el selector de cliente no compensa viewInsets', () {
    final s = _src('lib/ui/servicios.dart');
    final t = _tramo(s, "titulo: 'Cliente del gym'", 500);
    expect(t.contains('viewInsetsOf'), isFalse,
        reason: 'DialogoApp (AlertDialog) ya acolcha sobre '
            'el teclado; la compensación propia duplicaba');
    expect(t.contains('height: 380'), isTrue,
        reason: 'la caja de resultados conserva su altura');
  });

  test('UI136-11 · vender servicio y rellenar pomo ruedan', () {
    final s = _src('lib/ui/servicios.dart');
    final t = _tramo(s, 'class _DialogoVentaServicioState', 6500);
    expect(t.contains('SingleChildScrollView'), isTrue);
    final a = _src('lib/ui/servicios_admin.dart');
    final t2 = _tramo(a, 'class _DialogoRellenarPomoState', 6500);
    expect(t2.contains('SingleChildScrollView'), isTrue);
  });

  test('UI136-11 · PINs masivos: altura acotada, sin shrinkWrap', () {
    final s = _src('lib/ui/control_acceso.dart');
    final t = _tramo(s, 'void _mostrarResultadosMasivos(', 1200);
    expect(t.contains('ConstrainedBox'), isTrue);
    expect(t.contains('maxHeight: 320'), isTrue);
    expect(t.contains('shrinkWrap: true'), isFalse);
  });

  test('UI136-11 · fotos con error: la lista rueda acotada', () {
    final s = _src('lib/ui/cola.dart');
    final t = _tramo(s, 'Future<void> _verFallosFotos(', 1900);
    expect(t.contains('ConstrainedBox'), isTrue);
    expect(t.contains('maxHeight: 400'), isTrue);
    expect(t.contains('SingleChildScrollView'), isTrue);
  });
}
