/// Historial de caja con USD (1/25 del programa de mejoras): la tarjeta
/// del cierre muestra el cobrado en USD además del CUP, sin mezclar
/// monedas. Cubre agruparCobradosPorFranja (PURO): solo efectivo (H12),
/// sin Casa, dos cierres el mismo día con totales distintos, filas sin
/// hora al primer cierre del día, y el reverso del dueño sin
/// responsable que NO cae en su cuadre (mismo caso -1500).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/historial_caja.dart';

const gabriel = 1403501391;
const dueno = 735772141;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('agruparCobradosPorFranja separa CUP y USD por turno', () {
    final cierres = [
      {'fecha': '2026-10-30', 'turno': 'manana', 'telegram_id': gabriel},
      {'fecha': '2026-10-30', 'turno': 'tarde', 'telegram_id': gabriel},
      {'fecha': '2026-10-30', 'turno': 'tarde', 'telegram_id': dueno},
    ];
    final keys = clavesDeCierres(cierres);
    expect(keys.primerTurno['2026-10-30|$gabriel'], 'manana');

    final res = agruparCobradosPorFranja(
      paresDia: keys.paresDia,
      claves: keys.claves,
      primerTurno: keys.primerTurno,
      pagos: [
        {
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '09:00',
          'telegram_user_id': gabriel,
          'monto': 2000,
        },
        {
          'metodo': 'transferencia',
          'fecha': '2026-10-30',
          'hora': '09:30',
          'telegram_user_id': gabriel,
          'monto': 2500,
        },
        // Sin hora: cae en el primer cierre del día (mañana).
        {
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'telegram_user_id': gabriel,
          'monto': 600,
        },
        // Otro día: fuera, aunque sea efectivo.
        {
          'metodo': 'efectivo',
          'fecha': '2026-10-29',
          'hora': '09:00',
          'telegram_user_id': gabriel,
          'monto': 5000,
        },
      ],
      diarios: [
        {
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '15:00',
          'registrado_por': gabriel,
          'total': 400,
        },
        {
          'metodo': 'transferencia',
          'fecha': '2026-10-30',
          'hora': '15:30',
          'registrado_por': gabriel,
          'total': 200,
        },
      ],
      ventasCup: [
        {
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '10:00',
          'registrado_por': gabriel,
          'moneda': 'CUP',
          'total': 1500,
        },
        {
          'metodo': 'transferencia',
          'fecha': '2026-10-30',
          'hora': '10:30',
          'registrado_por': gabriel,
          'moneda': 'CUP',
          'total': 2000,
        },
      ],
      ventasUsd: [
        {
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '10:30',
          'registrado_por': gabriel,
          'moneda': 'USD',
          'total': 30,
        },
        {
          'metodo': 'transferencia',
          'fecha': '2026-10-30',
          'hora': '11:00',
          'registrado_por': gabriel,
          'moneda': 'USD',
          'total': 50,
        },
        {
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '16:00',
          'registrado_por': gabriel,
          'moneda': 'USD',
          'total': 20,
        },
      ],
      ventasServicio: [
        {
          'casa': 0,
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '11:00',
          'responsable_efectivo_id': gabriel,
          'registrado_por': gabriel,
          'precio_unitario': 900,
          'cantidad': 1,
        },
        {
          'casa': 1,
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '11:30',
          'responsable_efectivo_id': gabriel,
          'registrado_por': gabriel,
          'precio_unitario': 900,
          'cantidad': 1,
        },
        // Reverso del dueño de una venta entregada: responsable en
        // null deliberado; NO resta del cuadre del dueño (ni de nadie).
        {
          'casa': 0,
          'metodo': 'efectivo',
          'fecha': '2026-10-30',
          'hora': '12:30',
          'responsable_efectivo_id': null,
          'registrado_por': dueno,
          'reverso_de': 99,
          'precio_unitario': 900,
          'cantidad': -1,
        },
      ],
    );

    expect(res.cup['2026-10-30|manana|$gabriel'], 5000.0);
    expect(res.cup['2026-10-30|tarde|$gabriel'], 400.0);
    expect(res.usd['2026-10-30|manana|$gabriel'], 30.0);
    expect(res.usd['2026-10-30|tarde|$gabriel'], 20.0);
    expect(res.cup['2026-10-30|tarde|$dueno'] ?? 0, 0.0);
    expect(res.usd['2026-10-30|tarde|$dueno'] ?? 0, 0.0);
  });
}
