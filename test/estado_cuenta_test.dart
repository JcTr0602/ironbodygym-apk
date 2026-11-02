/// T24 (1.20): el texto del estado de cuenta — vigencia
/// según el caso (Casa, vencido, al día), pagos sin
/// cortesías, deuda solo si la hay y cierre automático.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  Map<String, dynamic> cliente(Map<String, dynamic> extra) => {
        'nombre': 'Ana Prueba',
        'pagado_hasta': '2026-11-20',
        ...extra,
      };

  test('al día: vigencia con días, pagos y total', () {
    final t = textoEstadoCuenta(
      cliente: cliente({}),
      pagos: [
        {
          'fecha': '2026-10-21',
          'metodo': 'transferencia',
          'monto': 2500,
        },
        {'fecha': '2026-09-21', 'metodo': 'efectivo', 'monto': 2000},
        // La cortesía no es un pago: no sale ni suma.
        {'fecha': '2026-08-21', 'metodo': 'cortesia', 'monto': 0},
      ],
      ventas: const [],
      servicios: const [],
      fiadoPendiente: const {'CUP': 0.0, 'USD': 0.0},
      hoyIso: '2026-11-01',
    );
    expect(t, contains('Cliente: Ana Prueba'));
    expect(t, contains('Activo hasta el 20/11/2026 (quedan 19 días)'));
    expect(t, contains('*Pagos* (2)'));
    expect(t, contains('Transferencia · 2500 CUP'));
    expect(t, contains('Total pagado: 4500 CUP'));
    expect(t, isNot(contains('Deuda pendiente')));
    expect(t, contains('Mensaje automático'));
  });

  test('Casa: sin vencimiento; con deuda la muestra', () {
    final t = textoEstadoCuenta(
      cliente: cliente({'cuenta_casa': 1, 'pagado_hasta': null}),
      pagos: const [],
      ventas: const [],
      servicios: const [],
      fiadoPendiente: const {'CUP': 1500.0, 'USD': 0.0},
      hoyIso: '2026-11-01',
    );
    expect(t, contains('Cuenta a la Casa: sin vencimiento.'));
    expect(t, contains('*Deuda pendiente (fiado)*'));
    expect(t, contains('1500 CUP'));
  });

  test('vencido: lo dice con los días; Plus residual suma su línea',
      () {
    final t = textoEstadoCuenta(
      cliente: cliente({'pagado_hasta': '2026-10-28'}),
      pagos: const [],
      ventas: [
        {
          'fecha': '2026-10-10',
          'suplemento_nombre': 'Proteína X',
          'cantidad': 2,
          'precio': 5000,
          'moneda': 'CUP',
        },
      ],
      servicios: [
        {
          'fecha': '2026-10-11',
          'tipo': 'dosis_con_agua',
          'cantidad': 3,
          'precio_unitario': 900,
        },
      ],
      fiadoPendiente: const {'CUP': 0.0, 'USD': 0.0},
      plusResidualTexto: 'Activo hasta 05/01/2027 · quedan 65 días',
      hoyIso: '2026-11-01',
    );
    expect(t, contains('Venció el 28/10/2026 (hace 4 días)'));
    expect(t, contains('Plus: Activo hasta 05/01/2027'));
    expect(t, contains('Proteína X x2 · 10000 CUP'));
    expect(t, contains('3 dosis en total · 2700 CUP en servicios.'));
  });

  test('FIN-13: una dosis revertida no se cobra en el resumen',
      () {
    final t = textoEstadoCuenta(
      cliente: cliente({}),
      pagos: const [],
      ventas: const [],
      servicios: [
        {
          'fecha': '2026-10-11',
          'tipo': 'dosis_con_agua',
          'cantidad': 2,
          'precio_unitario': 900,
        },
        // El reverso viaja con cantidad negativa y reverso_de.
        {
          'fecha': '2026-10-11',
          'tipo': 'dosis_con_agua',
          'cantidad': -2,
          'precio_unitario': 900,
          'reverso_de': 7,
        },
        {
          'fecha': '2026-10-12',
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 600,
        },
      ],
      fiadoPendiente: const {'CUP': 0.0, 'USD': 0.0},
      hoyIso: '2026-11-01',
    );
    expect(t, contains('1 dosis en total · 600 CUP en servicios.'));
  });
}
