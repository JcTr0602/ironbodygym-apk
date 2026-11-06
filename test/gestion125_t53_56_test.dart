// 1.25 T53 + T55 + T56: progreso del período de la ficha,
// y agrupación del historial por meses.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  test('T53: progreso del período a mitad de camino', () {
    final hoy = ahoraHabana();
    final ini = hoy.subtract(const Duration(days: 15));
    final fin = hoy.add(const Duration(days: 15));
    final p = progresoPeriodoFicha(
        fechaInicioRaw: iso(ini), pagadoHastaRaw: iso(fin));
    expect(p, isNotNull);
    expect(p!.totalDias, 30);
    expect(p.diasRest, 15);
    expect(p.frac, closeTo(0.5, 0.04));
  });

  test('T53: sin período válido devuelve null', () {
    expect(
        progresoPeriodoFicha(fechaInicioRaw: null, pagadoHastaRaw: null),
        isNull);
    expect(
        progresoPeriodoFicha(
            fechaInicioRaw: '2026-11-01', pagadoHastaRaw: '2026-11-01'),
        isNull);
    expect(
        progresoPeriodoFicha(
            fechaInicioRaw: '2026-12-01', pagadoHastaRaw: '2026-11-01'),
        isNull);
  });

  test('T53: vencido se acota a fracción 1 y días negativos', () {
    final hoy = ahoraHabana();
    final p = progresoPeriodoFicha(
        fechaInicioRaw: iso(hoy.subtract(const Duration(days: 40))),
        pagadoHastaRaw: iso(hoy.subtract(const Duration(days: 10))));
    expect(p!.frac, 1.0);
    expect(p.diasRest, -10);
  });

  test('T56: agrupa por mes con conteo y suma de pagos', () {
    final grupos = gruposHistorialPorMes([
      {
        'tipo': 'pago',
        'fecha': '2026-11-03',
        'pago': {'monto': 2000}
      },
      {
        'tipo': 'venta',
        'fecha': '2026-11-01',
      },
      {
        'tipo': 'pago',
        'fecha': '2026-10-05',
        'pago': {'monto': 2000}
      },
      {
        'tipo': 'pago',
        'fecha': '2026-10-20',
        'pago': {'monto': 1500}
      },
      {'tipo': 'venta', 'fecha': ''},
    ]);
    expect(grupos.length, 3);
    expect(grupos[0].titulo, 'Noviembre 2026');
    expect(grupos[0].nPagos, 1);
    expect(grupos[0].sumaPagos, 2000);
    expect(grupos[1].titulo, 'Octubre 2026');
    expect(grupos[1].nPagos, 2);
    expect(grupos[1].sumaPagos, 3500);
    expect(grupos[2].titulo, 'Sin fecha');
    expect(grupos[2].nPagos, 0);
  });

  test('T57: resumen de la última medida con su variación', () {
    Map<String, dynamic> med(String fecha, double? peso) => {
          'fecha_medicion': fecha,
          'medidas': {if (peso != null) 'peso_kg': peso},
        };
    final r = resumenUltimaMedida([
      med('2026-11-01', 82.5),
      med('2026-10-01', 84.0),
    ]);
    expect(r!.peso, 82.5);
    expect(r.delta, -1.5);
    expect(r.fecha, '2026-11-01');
    // Sin anterior comparable: delta null; sin peso: null.
    expect(resumenUltimaMedida([med('2026-11-01', 80)])!.delta, isNull);
    expect(resumenUltimaMedida([med('2026-11-01', null)]), isNull);
    // La más reciente sin peso no tapa a la última con peso.
    final r2 = resumenUltimaMedida([
      med('2026-11-05', null),
      med('2026-11-01', 82.5),
      med('2026-10-01', 81.0),
    ]);
    expect(r2!.peso, 82.5);
    expect(r2.delta, 1.5);
  });
}
