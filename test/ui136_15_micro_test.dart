/// UI136-15 (adjudicación ARGON-136-UI, hallazgo H13):
/// micro-interacciones — botones adyacentes sin separación,
/// dos mecanismos de plegado conviviendo en la misma
/// pantalla, y la cabecera sticky de Actividad que ignora
/// overlapsContent (sin separación cuando el contenido
/// pasa por debajo).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  test('UI136-15 · Rellenar y Salida llevan separación', () {
    final s = _src('lib/ui/servicios_admin.dart');
    final iFila = s.indexOf('Widget _filaPomo(');
    expect(iFila, greaterThanOrEqualTo(0));
    final fila = s.substring(iFila, iFila + 5200);
    final i = fila.indexOf("child: const Text('Rellenar'),");
    expect(i, greaterThanOrEqualTo(0));
    final tramo = fila.substring(i, i + 380);
    expect(tramo.contains('SizedBox(width: AppEspacio.sm)'), isTrue,
        reason: 'entre Rellenar y Salida hay un respiro');
    expect(tramo.contains("Text('Salida')"), isTrue);
  });

  test('UI136-15 · un solo mecanismo de plegado en el Hub', () {
    final s = _src('lib/ui/hub_turnos.dart');
    expect(s.contains('ExpansionTile('), isFalse,
        reason: 'el Hub pliega con su patrón propio '
            '(ListTile + ClipRect/Align, contrato M3-B2/C2)');
    expect(s.contains('_ayudaHubAbierta'), isTrue,
        reason: '«¿Cómo funciona este hub?» usa el mismo patrón');
    expect('ClipRect('.allMatches(s).length, greaterThanOrEqualTo(2));
  });

  test('UI136-15 · la sticky de Actividad se separa al solapar', () {
    final s = _src('lib/ui/actividad.dart');
    final i = s.indexOf('class _EncabezadoFechaSticky');
    expect(i, greaterThanOrEqualTo(0));
    final tramo = s.substring(i, i + 1900);
    expect(tramo.contains('overlapsContent ?'), isTrue,
        reason: 'con contenido debajo, la cabecera gana '
            'borde/sombra de separación');
    expect(tramo.contains('BorderSide'), isTrue);
  });
}
