import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

/// H-02/H-03 (1.19): la purga por reconciliación solo borra cuando la
/// pasada es completa y el conjunto es fiable. Cada invariante se
/// prueba por separado: un solo invariante roto debe bloquear.
void main() {
  bool base({
    bool viable = true,
    bool completa = true,
    int vistos = 10,
    int locales = 10,
    bool conteo = false,
    int? total,
    bool troncal = false,
  }) =>
      SyncEngine.purgaPermitida(
        viable: viable,
        pasadaCompleta: completa,
        idsVistos: vistos,
        filasLocales: locales,
        conteoConfirmado: conteo,
        totalServidor: total,
        esTroncal: troncal,
      );

  test('caso feliz: pasada completa con ids', () {
    expect(base(), isTrue);
  });

  test('sin viable no purga', () {
    expect(base(viable: false), isFalse);
  });

  test('sin pasada completa no purga (corte por página corta, stall)',
      () {
    expect(base(completa: false), isFalse);
  });

  test('conjunto vacío sin conteo NO purga (hueco viejo, no troncales)',
      () {
    expect(base(vistos: 0, locales: 10), isFalse);
  });

  // 1.23 (Argón Pull H-01, BLOQUEANTE — invierte el caso que
  // antes lo celebraba): un conjunto vacío con conteo 0 puede
  // ser una lectura rota (200 [] con RLS degradado), no la
  // verdad. Con filas locales, el vacío no purga: ni en
  // troncales (nunca) ni en el resto con 5+ filas.
  test('conjunto vacío con conteo 0 y 10 locales NO purga', () {
    expect(base(vistos: 0, locales: 10, conteo: true, total: 0),
        isFalse);
  });

  test('conjunto vacío en TRONCAL con 1 local NO purga', () {
    expect(
        base(
            vistos: 0,
            locales: 1,
            conteo: true,
            total: 0,
            troncal: true),
        isFalse);
  });

  test('conjunto vacío no troncal con 3 locales SÍ purga '
      '(vacío real de tabla menor)', () {
    expect(base(vistos: 0, locales: 3, conteo: true, total: 0),
        isTrue);
  });

  test('troncal con ids vistos y conteo coherente SÍ purga', () {
    expect(
        base(
            vistos: 8,
            locales: 10,
            conteo: true,
            total: 8,
            troncal: true),
        isTrue);
  });

  test('local vacío sin ids: nada que borrar, purga inocua', () {
    expect(base(vistos: 0, locales: 0), isTrue);
  });

  test('anti-wipe: 10 locales y 3 vistos sin conteo NO purga', () {
    expect(base(vistos: 3, locales: 10), isFalse);
  });

  test('anti-wipe con conteo que confirma 3 de 3 SÍ purga', () {
    expect(base(vistos: 3, locales: 10, conteo: true, total: 3), isTrue);
  });

  test('conteo que dice más de lo visto NO purga (pasada incompleta)',
      () {
    expect(base(vistos: 3, locales: 3, conteo: true, total: 100),
        isFalse);
  });

  test('menos de 5 locales no dispara anti-wipe', () {
    expect(base(vistos: 2, locales: 4), isTrue);
  });
}
