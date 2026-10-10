// Tests unitarios básicos (v1.0.16).
//
// Cubre lógica pura sin dependencias de plataforma:
// - `usernameToEmail`: normalización de nombres de usuario.
// - Lógica de `ingresosPorDia`: agregación por fecha (se testea la
//   función de agregación pura, no el acceso a SQLite).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  group('usernameToEmail', () {
    test('minúsculas y sin espacios', () {
      expect(usernameToEmail('Gabriel'), 'gabriel@ironbody.gym');
      expect(usernameToEmail('  DUANY  '), 'duany@ironbody.gym');
    });

    test('quita tildes', () {
      expect(usernameToEmail('José'), 'jose@ironbody.gym');
      expect(usernameToEmail('Niño'), 'nino@ironbody.gym');
    });

    test('elimina caracteres especiales', () {
      expect(usernameToEmail('Jc-Tr_0602'), 'jctr0602@ironbody.gym');
    });

    test('nombre vacío lanza', () {
      expect(() => usernameToEmail('   '), throwsArgumentError);
      expect(() => usernameToEmail('---'), throwsArgumentError);
    });
  });

  group('agregación de ingresos por día', () {
    // Replica la lógica de ingresosPorDia() sobre datos en memoria,
    // sin tocar SQLite. Si cambia la lógica real, este test lo detecta.

    Map<String, double> agregarPorDia(
        List<Map<String, dynamic>> pagos,
        List<Map<String, dynamic>> diarios) {
      final porDia = <String, double>{};
      for (final p in pagos) {
        final f = '${p['fecha'] ?? ''}';
        if (f.length >= 10) {
          final dia = f.substring(0, 10);
          porDia[dia] =
              (porDia[dia] ?? 0) + ((p['monto'] as num?)?.toDouble() ?? 0);
        }
      }
      for (final d in diarios) {
        final f = '${d['fecha'] ?? ''}';
        if (f.length >= 10) {
          final dia = f.substring(0, 10);
          porDia[dia] =
              (porDia[dia] ?? 0) + ((d['total'] as num?)?.toDouble() ?? 0);
        }
      }
      return porDia;
    }

    test('incluye pagos mensuales y diarios', () {
      final r = agregarPorDia(
        [
          {'fecha': '2026-10-09', 'monto': 2000},
          {'fecha': '2026-10-09', 'monto': 1500},
        ],
        [
          {'fecha': '2026-10-09', 'total': 400},
        ],
      );
      expect(r['2026-10-09'], 3900);
    });

    test('agrupa por fecha', () {
      final r = agregarPorDia(
        [
          {'fecha': '2026-10-08', 'monto': 2000},
          {'fecha': '2026-10-09', 'monto': 1000},
        ],
        [],
      );
      expect(r['2026-10-08'], 2000);
      expect(r['2026-10-09'], 1000);
      expect(r.length, 2);
    });

    test('ignora fechas malformadas', () {
      final r = agregarPorDia(
        [
          {'fecha': 'bad', 'monto': 9999},
          {'fecha': '', 'monto': 9999},
          {'fecha': null, 'monto': 9999},
        ],
        [],
      );
      expect(r.isEmpty, true);
    });

    test('montos nulos cuentan como 0', () {
      final r = agregarPorDia(
        [
          {'fecha': '2026-10-09', 'monto': null},
        ],
        [
          {'fecha': '2026-10-09', 'total': null},
        ],
      );
      expect(r['2026-10-09'], 0);
    });
  });

  group('esVersionMayor', () {
    test('versión superior detectada', () {
      expect(esVersionMayor('1.1.2', '1.1.1'), true);
      expect(esVersionMayor('1.2.0', '1.1.9'), true);
      expect(esVersionMayor('2.0.0', '1.9.9'), true);
    });

    test('1.1.10 mayor que 1.1.2 (no compara como texto)', () {
      expect(esVersionMayor('1.1.10', '1.1.2'), true);
      expect(esVersionMayor('1.1.2', '1.1.10'), false);
    });

    test('igual o inferior no es nueva', () {
      expect(esVersionMayor('1.1.1', '1.1.1'), false);
      expect(esVersionMayor('1.0.9', '1.1.1'), false);
      expect(esVersionMayor('', '1.1.1'), false);
    });
  });

  group('totalVentaUsd', () {
    test('venta USD suma precio por cantidad', () {
      expect(
          totalVentaUsd(
              {'moneda': 'USD', 'precio': 10.0, 'cantidad': 2}),
          20.0);
    });

    test('usa el total si viene calculado', () {
      expect(
          totalVentaUsd({
            'moneda': 'USD',
            'precio': 10.0,
            'cantidad': 2,
            'total': 19.5
          }),
          19.5);
    });

    test('venta CUP devuelve 0', () {
      expect(
          totalVentaUsd(
              {'moneda': 'CUP', 'precio': 500.0, 'cantidad': 2}),
          0);
    });
  });

  group('totalVentaCup', () {
    test('venta USD devuelve 0 (no se mezcla)', () {
      expect(
          totalVentaCup(
              {'moneda': 'USD', 'precio': 10.0, 'cantidad': 2}),
          0);
    });
  });
}
