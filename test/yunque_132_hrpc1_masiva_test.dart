/// 1.32 · Pieza 4 (H-RPC-1, Corte A): en la generación masiva,
/// un resultado sin PIN nunca cuenta como generado. La RPC
/// individual omite a propósito al convertido con vale vivo
/// (`ok:true, omitido:true, pin_temporal:NULL`) y la masiva
/// viva lo traduce a `ok:false, omitido:true`; la app clasifica
/// por PIN real: el omitido no sale de «sin acceso», no se
/// pinta como PIN y se enseña con su motivo.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/control_acceso.dart';

void main() {
  group('H-RPC-1: clasificación de resultados masivos', () {
    final generado = <String, dynamic>{
      'cliente_id': 10,
      'ok': true,
      'nombre': 'Ana',
      'telefono': '53112233',
      'pin_temporal': '483920',
    };
    // La forma CRUDA de la RPC individual (si alguna vez la
    // masiva la dejara pasar tal cual).
    final omitidoCrudo = <String, dynamic>{
      'cliente_id': 11,
      'ok': true,
      'omitido': true,
      'motivo': 'conversion_con_vale_vivo',
      'nombre': 'Beto',
      'telefono': '54221100',
      'pin_temporal': null,
      'mensaje': 'Acceso de conversión con vale de canje vivo.',
    };
    // La forma que la masiva viva devuelve hoy para el omitido.
    final omitidoMasiva = <String, dynamic>{
      'cliente_id': 12,
      'ok': false,
      'omitido': true,
      'motivo': 'conversion_con_vale_vivo',
      'nombre': 'Carla',
      'telefono': '55998877',
      'mensaje': 'Acceso de conversión con vale de canje vivo.',
    };
    final okSinPin = <String, dynamic>{
      'cliente_id': 13,
      'ok': true,
      'nombre': 'Dario',
      'telefono': '51009988',
      'pin_temporal': '',
    };
    final error = <String, dynamic>{
      'cliente_id': 14,
      'ok': false,
      'error': 'sin telefono',
    };

    test('generado exige ok + PIN no vacío + no omitido', () {
      expect(resultadoMasivoEsGenerado(generado), isTrue);
      expect(resultadoMasivoEsGenerado(omitidoCrudo), isFalse);
      expect(resultadoMasivoEsGenerado(omitidoMasiva), isFalse);
      expect(resultadoMasivoEsGenerado(okSinPin), isFalse);
      expect(resultadoMasivoEsGenerado(error), isFalse);
    });

    test('omitido: la omisión deliberada y el ok sin PIN', () {
      expect(resultadoMasivoEsOmitido(omitidoCrudo), isTrue);
      expect(resultadoMasivoEsOmitido(omitidoMasiva), isTrue);
      expect(resultadoMasivoEsOmitido(okSinPin), isTrue);
      expect(resultadoMasivoEsOmitido(generado), isFalse);
      expect(resultadoMasivoEsOmitido(error), isFalse);
    });

    test('idsGeneradosMasivos: solo el generado sale de la '
        'lista «sin acceso»', () {
      final ids = idsGeneradosMasivos(
          [generado, omitidoCrudo, omitidoMasiva, okSinPin, error]);
      expect(ids, {10},
          reason: 'el omitido (11/12) y el ok sin PIN (13) se '
              'quedan en «sin acceso»: no hay acceso que entregar');
    });

    test('cliente_id como texto también resuelve', () {
      final ids = idsGeneradosMasivos([
        {'cliente_id': '21', 'ok': true, 'pin_temporal': '112233'},
        {'cliente_id': 'x', 'ok': true, 'pin_temporal': '445566'},
      ]);
      expect(ids, {21});
    });
  });
}
