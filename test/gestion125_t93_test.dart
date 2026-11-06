/// 1.25 T93: el período del Extracto — la pertenencia
/// de una fecha a hoy/semana/mes/todo, con la semana
/// anclada al lunes por aritmética de fecha pura.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/centro_compras.dart';

void main() {
  // 2026-11-06 es viernes; su lunes es 2026-11-02.
  const hoy = '2026-11-06';

  group('filaEnPeriodoExtracto', () {
    test('todo acepta cualquier fecha', () {
      expect(filaEnPeriodoExtracto('2020-01-01', 'todo', hoy), isTrue);
      expect(filaEnPeriodoExtracto('', 'todo', hoy), isTrue);
    });

    test('hoy solo el mismo día', () {
      expect(filaEnPeriodoExtracto('2026-11-06', 'hoy', hoy), isTrue);
      expect(filaEnPeriodoExtracto('2026-11-05', 'hoy', hoy), isFalse);
    });

    test('semana desde el lunes, sin futuro', () {
      expect(filaEnPeriodoExtracto('2026-11-02', 'semana', hoy), isTrue);
      expect(filaEnPeriodoExtracto('2026-11-06', 'semana', hoy), isTrue);
      // El domingo anterior es de la semana pasada.
      expect(filaEnPeriodoExtracto('2026-11-01', 'semana', hoy), isFalse);
      // Mañana aún no cuenta.
      expect(filaEnPeriodoExtracto('2026-11-07', 'semana', hoy), isFalse);
    });

    test('mes por prefijo AAAA-MM', () {
      expect(filaEnPeriodoExtracto('2026-11-01', 'mes', hoy), isTrue);
      expect(filaEnPeriodoExtracto('2026-10-31', 'mes', hoy), isFalse);
      expect(filaEnPeriodoExtracto('2025-11-06', 'mes', hoy), isFalse);
    });

    test('fecha vacía no cae en ningún período cerrado', () {
      expect(filaEnPeriodoExtracto('', 'hoy', hoy), isFalse);
      expect(filaEnPeriodoExtracto('', 'mes', hoy), isFalse);
    });
  });
}
