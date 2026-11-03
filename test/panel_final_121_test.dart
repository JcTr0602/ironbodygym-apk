/// Panel final 1.21 (Terra por Zen, vía de respaldo ante la
/// caída de Token Supply): tests de las correcciones aplicadas
/// tras verificar sus hallazgos contra el código vivo.
///  - overlayAdelantosEnCola: correcciones (la última manda) y
///    anulaciones encoladas que idsPendientesEntrega ahora
///    comparte con sumaAdelantosPendientes.
///  - botePorVentana: un bote con cerrado_en registrado y
///    anterior a la venta ya NO recibe la venta por el fallback
///    «último abierto antes».
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload) =>
    {'tipo': tipo, 'payload': jsonEncode(payload)};

void main() {
  group('Panel final: overlayAdelantosEnCola', () {
    test('correcciones por adelanto: la última encolada manda', () {
      final o = overlayAdelantosEnCola([
        _op('corregir_origen_adelanto',
            {'adelanto_id': 5, 'nuevo_origen': 'fondo_dueno'}),
        _op('registrar_adelanto', {'monto': 300}),
        _op('corregir_origen_adelanto', {
          'adelanto_id': 5,
          'nuevo_origen': 'caja_turno',
          'descuenta_a': 111,
        }),
      ]);
      expect(o.correcciones.keys, [5]);
      expect(o.correcciones[5]!['nuevo_origen'], 'caja_turno');
      expect(o.correcciones[5]!['descuenta_a'], 111);
      expect(o.anuladosEnCola, isEmpty);
    });

    test('anulaciones encoladas por adelanto_id', () {
      final o = overlayAdelantosEnCola([
        _op('anular_adelanto', {'adelanto_id': 7}),
        _op('anular_adelanto', {'adelanto_id': 9}),
        _op('anular_adelanto', {'sin_id': true}),
      ]);
      expect(o.anuladosEnCola, {7, 9});
      expect(o.correcciones, isEmpty);
    });

    test('payload corrupto se salta sin romper el overlay', () {
      final o = overlayAdelantosEnCola([
        {'tipo': 'corregir_origen_adelanto', 'payload': '{roto'},
        _op('corregir_origen_adelanto',
            {'adelanto_id': 3, 'nuevo_origen': 'caja_turno'}),
      ]);
      expect(o.correcciones.keys, [3]);
    });
  });

  group('Panel final: botePorVentana y el bote ya cerrado', () {
    final botes = <Map<String, dynamic>>[
      {
        'id': 11,
        'abierto_en': '2026-09-01 08:00:00',
        'cerrado_en': '2026-10-15 20:00:00',
      },
      {
        'id': 12,
        'abierto_en': '2026-11-01 08:00:00',
        'cerrado_en': null,
      },
    ];

    test('venta tras el cierre, sin bote nuevo: NO va al cerrado',
        () {
      // Antes: el fallback atribuía la venta del 2026-10-20 al
      // bote 11, cerrado el 2026-10-15 (dosis/ingreso/margen
      // inflados de un bote muerto). Ahora cae al respaldo.
      expect(
          botePorVentana(botes.sublist(0, 1), '2026-10-20',
              respaldo: 99),
          99);
    });

    test('venta dentro de la ventana del bote 11: va al 11', () {
      expect(botePorVentana(botes, '2026-10-10', respaldo: 99), 11);
    });

    test('sin cerrado_en registrado, el último abierto antes vale',
        () {
      final sinCierre = <Map<String, dynamic>>[
        {'id': 11, 'abierto_en': '2026-09-01 08:00:00'},
      ];
      expect(
          botePorVentana(sinCierre, '2026-10-20', respaldo: 99), 11);
    });

    test('venta con el bote 12 ya abierto: va al 12', () {
      expect(botePorVentana(botes, '2026-11-05', respaldo: 99), 12);
    });
  });
}
