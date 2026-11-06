// 1.25 T115: período legible y las series diarias de la
// Auditoría por persona (la serie de cobros suma lo
// mismo que el total del resumen: mismas reglas).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auditoria_persona.dart';

void main() {
  const duany =
      PersonaApk(id: 'uuid-duany', telegramId: 111, nombre: 'Duany');

  test('el período se lee en fecha, no en ISO', () {
    expect(textoPeriodoLegible('2026-11-01', '2026-11-30'),
        '1 nov → 30 nov 2026');
    expect(textoPeriodoLegible('2026-11-05', '2026-11-05'), '5 nov 2026');
    expect(textoPeriodoLegible('2026-12-15', '2027-01-10'),
        '15 dic 2026 → 10 ene 2027');
  });

  test('minutos por día: suma mañana y tarde, con ceros', () {
    TurnoAuditado t(String iso, int min) => TurnoAuditado(
          fecha: DateTime.parse(iso),
          franja: 'manana',
          eraSuyo: true,
          duracionMin: min,
        );
    final serie = serieMinutosPorDia(
      turnos: [t('2026-11-02', 300), t('2026-11-02', 240), t('2026-11-04', 60)],
      desdeIso: '2026-11-02',
      hastaIso: '2026-11-04',
    );
    expect(serie.map((d) => d['fecha']),
        ['2026-11-02', '2026-11-03', '2026-11-04']);
    expect(serie.map((d) => d['total']), [540, 0, 60]);
  });

  test('la serie de cobros suma el total del resumen', () {
    final pagos = <Map<String, dynamic>>[
      {'fecha': '2026-10-05', 'monto': 2000.0, 'metodo': 'efectivo', 'registrado_por': 111, 'entregado': 0},
      {'fecha': '2026-10-06', 'monto': 2500.0, 'metodo': 'transferencia', 'registrado_por': 111, 'entregado': 0},
      {'fecha': '2026-10-07', 'monto': 2000.0, 'metodo': 'efectivo', 'registrado_por': 222, 'entregado': 0},
      {'fecha': '2026-10-08', 'monto': 2000.0, 'metodo': 'efectivo', 'registrado_por': 111, 'entregado': 1},
    ];
    final diarios = <Map<String, dynamic>>[
      {'fecha': '2026-10-05', 'total': 600.0, 'registrado_por': 111},
    ];
    final sup = <Map<String, dynamic>>[
      {'fecha': '2026-10-05', 'precio': 5000.0, 'cantidad': 1, 'registrado_por': 111, 'estado': 'activa'},
      {'fecha': '2026-10-06', 'precio': 5000.0, 'cantidad': 1, 'registrado_por': 111, 'estado': 'anulada'},
    ];
    final serv = <Map<String, dynamic>>[
      {'fecha': '2026-10-05', 'precio_unitario': 600.0, 'cantidad': 2, 'registrado_por': 111, 'casa': 0},
      {'fecha': '2026-10-05', 'precio_unitario': 900.0, 'cantidad': 1, 'registrado_por': 111, 'casa': 1},
    ];
    final total = auditarDineroPersona(
      persona: duany,
      desdeIso: '2026-10-01',
      hastaIso: '2026-10-31',
      pagos: pagos,
      pagosDiarios: diarios,
      ventasSuplementos: sup,
      ventasServicios: serv,
      cierres: const [],
    ).totalCobrado;
    final serie = serieCobrosPorDia(
      persona: duany,
      desdeIso: '2026-10-01',
      hastaIso: '2026-10-31',
      pagos: pagos,
      pagosDiarios: diarios,
      ventasSuplementos: sup,
      ventasServicios: serv,
    );
    expect(serie.length, 31);
    final sumaSerie =
        serie.fold<int>(0, (a, d) => a + (d['total'] as int));
    expect(sumaSerie, total.round());
    // El 5 concentra mensualidad + diario + suplemento + dosis.
    expect(serie[4]['total'], 2000 + 600 + 5000 + 1200);
  });
}
