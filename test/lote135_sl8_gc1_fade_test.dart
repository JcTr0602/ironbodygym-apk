/// SL-8 · GC-1: FadeEntrada (lib/ui/componentes.dart) se
/// mueve con los tokens de la casa (AppMovimiento), no con
/// duraciones literales: el fundido usa AppMovimiento.media
/// y AppMovimiento.curvaSuave.
///
/// Estado en la base ead3d63: el fundido YA quedó tokenizado
/// en la 1.30 (D6, UI130-32) — este test es el guardián de
/// esa referencia (discrimina por la REFERENCIA al token,
/// acotado al cuerpo de FadeEntrada, no por el valor, que
/// coincide con el literal histórico de 220 ms).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GC-1 · el fundido de FadeEntrada referencia los tokens', () {
    final src = File('lib/ui/componentes.dart').readAsStringSync();
    final inicio = src.indexOf('class FadeEntrada extends');
    expect(inicio, greaterThan(0));
    final fin = src.indexOf('class CruceEstados', inicio);
    expect(fin, greaterThan(inicio));
    final cuerpo = src.substring(inicio, fin);
    expect(cuerpo, contains('duration: AppMovimiento.media'),
        reason: 'la duración del fundido sale del token de la casa');
    expect(cuerpo, contains('curve: AppMovimiento.curvaSuave'),
        reason: 'la curva del fundido sale del token de la casa');
    expect(cuerpo, isNot(contains('Duration(milliseconds: 220)')),
        reason: 'el literal histórico de 220 ms no debe volver: '
            '220 ms es AppMovimiento.media');
  });
}
