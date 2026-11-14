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

  test('T77: septiembre NO salta por encima de octubre', () {
    // Autoauditoría ronda 2: con la clave sin cero,
    // '2026-9' ordenaba por encima de '2026-10'.
    final grupos = gruposEnviosPorMes([
      {'enviada_ts': '2026-09-15T10:00:00'},
      {'enviada_ts': '2026-10-03T10:00:00'},
      {'enviada_ts': '2026-12-01T10:00:00'},
    ]);
    expect(grupos.map((g) => g.titulo).toList(),
        ['Diciembre 2026', 'Octubre 2026', 'Septiembre 2026']);
  });

  test('T79: totales de mis ventas del mes por tipo', () {
    // Yunque 2.34 (C-1): las filas llevan la forma REAL del
    // espejo. El fixture viejo sembraba una clave `monto` que
    // servicio_ventas no tiene y la tarjeta «Dosis» sumaba 0
    // en producción con el test verde.
    final t = totalesVentasMesPorTipo([
      // Servicio: precio_unitario × cantidad (600 y 450×2).
      {'origen': 'servicio', 'fecha': '2026-11-03', 'precio_unitario': 600, 'cantidad': 1},
      {'origen': 'servicio', 'fecha': '2026-11-04', 'precio_unitario': 450, 'cantidad': 2},
      // Suplemento: manda el total registrado (2500×2).
      {'origen': 'suplemento', 'fecha': '2026-11-05', 'precio': 2500, 'cantidad': 2, 'total': 5000},
      // Suplemento USD: no entra en la tarjeta rotulada CUP.
      {'origen': 'suplemento', 'fecha': '2026-11-06', 'precio': 20, 'cantidad': 1, 'total': 20, 'moneda': 'USD'},
      // Fuera del mes: no entra.
      {'origen': 'suplemento', 'fecha': '2026-10-31', 'precio': 9999, 'cantidad': 1},
    ], '2026-11');
    expect(t.dosis, 1500);
    expect(t.nDosis, 2);
    expect(t.suplementos, 5000);
    expect(t.nSuplementos, 1);
  });
}
