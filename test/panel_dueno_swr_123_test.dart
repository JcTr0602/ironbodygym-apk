/// 1.23 (B3): estado SWR de las bandejas RPC del Panel del
/// dueño — un fallo de red jamás se disfraza de bandeja vacía.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/panel_dueno_swr.dart';

void main() {
  final t1 = DateTime(2026, 11, 3, 9, 41);
  final t2 = DateTime(2026, 11, 3, 13, 5);

  group('BandejaSwr (B3)', () {
    test('recién creada está cargando, sin error ni caché', () {
      final b = BandejaSwr<int>();
      expect(b.cargando, isTrue);
      expect(b.error, isFalse);
      expect(b.conCache, isFalse);
      expect(b.notaSinRed, '');
    });

    test('un fallo sin caché se declara error, no vacío', () {
      final b = BandejaSwr<int>();
      b.fallo();
      expect(b.cargando, isFalse);
      expect(b.error, isTrue);
      expect(b.conCache, isFalse);
      expect(b.datos, isEmpty);
      expect(b.notaSinRed, '');
    });

    test('un fallo con caché conserva datos y sello, con nota',
        () {
      final b = BandejaSwr<int>();
      b.exito([1, 2], t1);
      b.fallo();
      expect(b.datos, [1, 2]);
      expect(b.sello, t1);
      expect(b.error, isTrue);
      expect(b.notaSinRed, 'Sin red · datos de 9:41 AM');
    });

    test('la nota formatea la tarde en AM/PM', () {
      final b = BandejaSwr<int>();
      b.exito([1], t2);
      b.fallo();
      expect(b.notaSinRed, 'Sin red · datos de 1:05 PM');
    });

    test('el éxito posterior limpia el error y mueve el sello',
        () {
      final b = BandejaSwr<int>();
      b.exito([1], t1);
      b.fallo();
      b.exito([3], t2);
      expect(b.error, isFalse);
      expect(b.datos, [3]);
      expect(b.sello, t2);
      expect(b.notaSinRed, '');
    });

    test('éxito con lista vacía es un vacío HONESTO (hay sello)',
        () {
      final b = BandejaSwr<int>();
      b.exito([], t1);
      expect(b.conCache, isTrue);
      expect(b.cargando, isFalse);
      expect(b.error, isFalse);
    });

    // Panel B3 (Alta): la caché se mide por el SELLO, no por
    // los datos — vacío confirmado + fallo posterior NO es
    // «sin cargar», es «vacío sin revalidar».
    test('vacío confirmado + fallo = vacioSinRevalidar, no '
        'sinCargar', () {
      final b = BandejaSwr<int>();
      b.exito([], t1);
      b.fallo();
      expect(b.sinCargar, isFalse);
      expect(b.vacioSinRevalidar, isTrue);
      expect(b.notaSinRed, 'Sin red · datos de 9:41 AM');
    });

    test('fallo sin éxito previo = sinCargar', () {
      final b = BandejaSwr<int>();
      b.fallo();
      expect(b.sinCargar, isTrue);
      expect(b.vacioSinRevalidar, isFalse);
    });

    test('con datos + fallo: ni sinCargar ni vacioSinRevalidar',
        () {
      final b = BandejaSwr<int>();
      b.exito([1], t1);
      b.fallo();
      expect(b.sinCargar, isFalse);
      expect(b.vacioSinRevalidar, isFalse);
    });
  });
}
