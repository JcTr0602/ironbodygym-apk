/// Veredictos Argón #9 (inventario/compras, envíos 1 y 2): regresiones
/// de los defectos verificados contra el código real y corregidos.
/// Solo cubre los helpers puros; los fixes de UI pura (venta rápida,
/// eliminar, simulador, diálogos, dispose, push, transacción de
/// inscripción) van por analyze + prueba de campo.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';
import 'package:ironbody_gym/ui/reporte_margenes.dart';

void main() {
  group('Argón #9-1 margenSuplementoUsd', () {
    test('USD directo: margen y potencial', () {
      final m = margenSuplementoUsd(
        s: {
          'precio_oficial': 100,
          'costo': 60,
          'stock': 5,
          'moneda': 'USD',
        },
      );
      expect(m.margenUnitario, 40);
      expect(m.margenPotencial, 200);
      expect(m.pct, 40);
    });

    test('CUP con tasa: convierte antes de restar', () {
      final m = margenSuplementoUsd(
        s: {
          'precio_oficial': 20000,
          'costo': 50,
          'stock': 2,
          'moneda': 'CUP',
        },
        tasaUsd: 200,
      );
      expect(m.precioUsd, 100);
      expect(m.margenUnitario, 50);
      expect(m.margenPotencial, 100);
    });

    test('CUP sin tasa: sin margen (antes mezclaba 20000-50=19950 USD)',
        () {
      final m = margenSuplementoUsd(
        s: {
          'precio_oficial': 20000,
          'costo': 50,
          'stock': 2,
          'moneda': 'CUP',
        },
      );
      expect(m.margenUnitario, isNull);
      expect(m.margenPotencial, isNull);
      expect(m.pct, isNull);
    });

    test('sin moneda explícita: CUP por defecto (monedaDe)', () {
      final m = margenSuplementoUsd(
        s: {'precio_oficial': 5000, 'costo': 10, 'stock': 1},
        tasaUsd: 250,
      );
      expect(m.precioUsd, 20);
      expect(m.margenUnitario, 10);
    });
  });

  group('Argón #9-7 rankingServicios excluye Casa', () {
    test('cortesía no suma unidades ni monto', () {
      final filas = rankingServicios([
        {
          'cliente_id': 1,
          'cliente_nombre': 'A',
          'tipo': 'dosis_sin_agua',
          'cantidad': 2,
          'precio_unitario': 600,
        },
        {
          'cliente_id': 1,
          'cliente_nombre': 'A',
          'tipo': 'dosis_sin_agua',
          'cantidad': 3,
          'precio_unitario': 0,
          'casa': 1,
        },
      ]);
      expect(filas.length, 1);
      expect(filas.first['unidades'], 2);
      expect(filas.first['monto'], 1200);
    });

    test('solo cortesías: fuera del ranking (monto 0)', () {
      final filas = rankingServicios([
        {
          'cliente_id': 2,
          'cliente_nombre': 'B',
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 0,
          'casa': 1,
        },
      ]);
      expect(filas, isEmpty);
    });
  });

  group('Argón #9 E2-1 totalesFiados', () {
    test('separa CUP y USD; sin moneda es CUP', () {
      final t = totalesFiados([
        {'cantidad': 1, 'precio': 3000, 'moneda': 'CUP'},
        {'cantidad': 2, 'precio': 10, 'moneda': 'USD'},
        {'cantidad': 1, 'precio': 500},
      ]);
      expect(t.cup, 3500);
      expect(t.usd, 20);
    });
  });

  group('Argón #9 E2-2 totalesHistorialVentas', () {
    test('entrenador: venta protegida fuera de los totales', () {
      final t = totalesHistorialVentas(
        [
          {
            'cliente_id': 7,
            'cantidad': 1,
            'precio': 1000,
            'total': 1000,
            'moneda': 'CUP',
          },
          {
            'cliente_id': 8,
            'cantidad': 1,
            'precio': 500,
            'total': 500,
            'moneda': 'CUP',
          },
        ],
        {
          7: {'id': 7, 'protegido': 1},
          8: {'id': 8, 'protegido': 0},
        },
        esDueno: false,
      );
      expect(t.cup, 500);
    });

    test('dueño: nada se excluye', () {
      final t = totalesHistorialVentas(
        [
          {
            'cliente_id': 7,
            'cantidad': 1,
            'precio': 1000,
            'total': 1000,
            'moneda': 'CUP',
          },
        ],
        {
          7: {'id': 7, 'protegido': 1},
        },
        esDueno: true,
      );
      expect(t.cup, 1000);
    });

    test('cliente sin entrada en el mapa: no se excluye', () {
      final t = totalesHistorialVentas(
        [
          {
            'cliente_id': 9,
            'cantidad': 1,
            'precio': 700,
            'total': 700,
            'moneda': 'CUP',
          },
        ],
        {},
        esDueno: false,
      );
      expect(t.cup, 700);
    });
  });

  group('Argón #9 E2-3 ventasServicioSinReversos', () {
    test('par original+reverso: ambos fuera', () {
      final out = ventasServicioSinReversos([
        {'id': 10, 'tipo': 'dosis_sin_agua', 'cantidad': 2},
        {
          'id': 11,
          'tipo': 'dosis_sin_agua',
          'cantidad': -2,
          'reverso_de': 10,
        },
        {'id': 12, 'tipo': 'dosis_sin_agua', 'cantidad': 1},
      ]);
      expect(out.map((v) => v['id']).toList(), [12]);
    });

    test('reverso huérfano: fuera; resto intacto', () {
      final out = ventasServicioSinReversos([
        {
          'id': 11,
          'tipo': 'dosis_sin_agua',
          'cantidad': -2,
          'reverso_de': 99,
        },
        {'id': 12, 'tipo': 'dosis_sin_agua', 'cantidad': 1},
      ]);
      expect(out.map((v) => v['id']).toList(), [12]);
    });
  });
}
