import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/mi_nomina.dart';
import 'package:ironbody_gym/ui/reporte_mensual_diarios.dart';
import 'package:ironbody_gym/ui/transferencia.dart';

void main() {
  test('T72: serie de días del mes y mejor día', () {
    final serie = serieDiasReporte(
      {'2026-11-03': 600.0, '2026-11-12': 1400.0, '2026-10-31': 999.0},
      2026,
      11,
      30,
    );
    expect(serie.length, 30);
    expect(serie[2], 600);
    expect(serie[11], 1400);
    expect(serie.fold<double>(0, (a, b) => a + b), 2000);
    expect(mejorDiaReporte(serie), 11);
    expect(mejorDiaReporte(const [0, 0]), -1);
  });

  test('T77: número de tarjeta agrupado de 4 en 4', () {
    expect(numeroTarjetaAgrupado('9224129972035419'),
        '9224 1299 7203 5419');
    expect(numeroTarjetaAgrupado('9224 1299 7203 5419'),
        '9224 1299 7203 5419');
    expect(numeroTarjetaAgrupado('123'), '123');
  });

  test('T77: envíos agrupados por mes, reciente primero', () {
    final grupos = gruposEnviosPorMes([
      {'enviada_ts': '2026-10-30T21:14:00'},
      {'enviada_ts': '2026-11-02T09:00:00'},
      {'enviada_ts': '2026-11-20T10:00:00'},
      {'enviada_ts': ''},
    ]);
    expect(grupos.length, 3);
    expect(grupos[0].titulo, 'Noviembre 2026');
    expect(grupos[0].envios.length, 2);
    expect(grupos[1].titulo, 'Octubre 2026');
    expect(grupos[2].titulo, 'Sin fecha');
  });

  test('T79: totales de mis ventas del mes por tipo', () {
    final t = totalesVentasMesPorTipo([
      {'origen': 'servicio', 'fecha': '2026-11-03', 'monto': 600},
      {'origen': 'servicio', 'fecha': '2026-11-04', 'monto': 900},
      {'origen': 'suplemento', 'fecha': '2026-11-05', 'precio': 2500},
      {'origen': 'suplemento', 'fecha': '2026-10-31', 'precio': 9999},
    ], '2026-11');
    expect(t.dosis, 1500);
    expect(t.nDosis, 2);
    expect(t.suplementos, 2500);
    expect(t.nSuplementos, 1);
  });
}
