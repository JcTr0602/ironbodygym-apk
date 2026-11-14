/// Yunque 4 · L2-4 (franja de Vender: el conteo netea
/// con el signo del reverso, como el dinero desde K6-2)
/// y L2-1/L2-2/L2-3 (clase K6-3: los tres lectores de
/// ajustes con cast duro que quedaban pasan por
/// montoAjusteTolerante — pin de fuente, patrón M6-6).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/servicios.dart';

void main() {
  group('L2-4 · resumenFranjaDelDia', () {
    Map<String, dynamic> venta(
            {int cant = 1,
            double precio = 900,
            String tipo = 'dosis',
            String metodo = 'efectivo',
            int? reversoDe,
            bool enCola = false}) =>
        {
          'cantidad': cant,
          'precio_unitario': precio,
          'tipo': tipo,
          'metodo': metodo,
          if (reversoDe != null) 'reverso_de': reversoDe,
          if (enCola) 'en_cola': true,
        };

    test('venta + reverso el mismo día: 0 dosis y 0 CUP', () {
      final (dosis, efectivo, _) = resumenFranjaDelDia([
        venta(),
        venta(cant: -1, reversoDe: 5),
      ]);
      expect(dosis, 0);
      expect(efectivo, 0);
    });

    test('el agua suelta no cuenta como dosis; la cola cuenta', () {
      final (dosis, efectivo, porSync) = resumenFranjaDelDia([
        venta(tipo: 'agua_suelta', precio: 300),
        venta(enCola: true),
      ]);
      expect(dosis, 1);
      expect(efectivo, 1200);
      expect(porSync, 1);
    });
  });

  group('L2-1/L2-2/L2-3 · sin cast duro sobre ajustes', () {
    String fuente(String ruta) => File(ruta).readAsStringSync();

    test('el Centro de Precios lee las claves C6 con el '
        'lector tolerante', () {
      final s = fuente('lib/ui/panel_resto_caja.dart');
      expect(s.contains('montoAjusteTolerante(aj[k])'), isTrue);
      expect(s.contains('(aj[k] as num?)'), isFalse);
    });

    test('el Panel aplica la config con el lector tolerante',
        () {
      final s = fuente('lib/ui/admin.dart');
      expect(s.contains('montoAjusteTolerante(aj[clave])'),
          isTrue);
      expect(s.contains('aj[clave] as num?'), isFalse);
    });

    test('el diff legacy de precios de servicio compara con '
        'el lector tolerante', () {
      final s = fuente('lib/ui/servicios_precios.dart');
      expect(
          s.contains(
              'montoAjusteTolerante(ajustes[legacyDe[stem]])'),
          isTrue);
      expect(s.contains('as num?)?.toDouble()'), isFalse);
    });
  });
}
