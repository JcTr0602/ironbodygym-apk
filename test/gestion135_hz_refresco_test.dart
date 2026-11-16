// test/gestion135_hz_refresco_test.dart
// 1.35 (HZ-2): la alta tasa de refresco se pide UNA
// sola vez al arrancar (llamada global en main, tras
// el binding), solo en Android, y un fallo del plugin
// — o la ausencia misma del canal, como en este
// entorno de test — no rompe el arranque. Aquí se
// fija el contrato de la pieza (la concesión real
// del modo queda en manos de la plataforma: en LTPO
// manda el sistema y no se verá diferencia).
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/refresco.dart';

void main() {
  test('en Android la llamada se hace exactamente una vez',
      () async {
    var llamadas = 0;
    await pedirAltaTasaDeRefresco(
      esAndroid: true,
      accion: () async => llamadas++,
    );
    expect(llamadas, 1);
  });

  test('fuera de Android ni se intenta', () async {
    var llamadas = 0;
    await pedirAltaTasaDeRefresco(
      esAndroid: false,
      accion: () async => llamadas++,
    );
    expect(llamadas, 0);
  });

  test('un plugin que lanza no rompe el arranque: el '
      'fallo se traga y la función vuelve normal',
      () async {
    await expectLater(
      pedirAltaTasaDeRefresco(
        esAndroid: true,
        accion: () async =>
            throw StateError('el fabricante no lo soporta'),
      ),
      completes,
    );
  });

  test('sin canal de plataforma (entorno de test) la '
      'llamada real tampoco rompe el arranque', () async {
    // Sin acción inyectada: va al plugin real, que en
    // el entorno de test no tiene implementación
    // nativa detrás; la excepción del canal debe
    // quedar tragada igual que un fallo del panel.
    await expectLater(
      pedirAltaTasaDeRefresco(esAndroid: true),
      completes,
    );
  });
}
