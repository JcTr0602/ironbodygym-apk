/// Lote Stats 2026-10-28 (reporte de Jc: la pantalla mostraba
/// inversión en botes 0, margen -2913 y neto -3311 con 8 dosis
/// vendidas a 600 y un bote C4 de 20800/60).
///
/// Cubre `calcular1B` (lib/estadisticas_servicios.dart) con los
/// datos reales de gym.db:
/// - caso fresco: 8 dosis comerciales (6×600 sin agua, 2×900 con
///   agua) + 1 Casa con agua + 1 agua suelta (2×300). Los snapshots
///   viejos a 800 de las 2 primeras dosis NO deben contaminar el
///   costo: el costo es el actual del bote (20800/60).
/// - caso pantalla vieja: las mismas ventas en el estado previo a
///   la corrección del 2026-10-28 (las 2 con agua figuraban sin
///   agua a 600) + una salida de agua del staff: el staff NO es
///   merma y la inversión en botes sigue siendo 20800.
/// - caso vacío: sin ventas no revienta ni divide entre cero.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';

const _unit = 20800.0 / 60;

Map<String, dynamic> _dosis({
  required int id,
  required int lote,
  required String tipo,
  required double precio,
  required double snapDosis,
  double? snapAgua,
  int casa = 0,
  double comision = 50,
}) =>
    {
      'id': id,
      'lote_id': lote,
      'tipo': tipo,
      'cantidad': 1,
      'precio_unitario': precio,
      'costo_dosis_snapshot': snapDosis,
      'costo_agua_snapshot': snapAgua,
      'casa': casa,
      'comision_unitaria': comision,
    };

List<Map<String, dynamic>> _ventasFrescas() => [
      // 2 primeras dosis con snapshot viejo (800, era 48000).
      _dosis(id: 1, lote: 2, tipo: 'dosis_sin_agua', precio: 600, snapDosis: 800),
      _dosis(id: 2, lote: 2, tipo: 'dosis_sin_agua', precio: 600, snapDosis: 800),
      // Casa con agua (precio 0, no es venta).
      _dosis(
          id: 3,
          lote: 2,
          tipo: 'dosis_con_agua',
          precio: 0,
          snapDosis: _unit,
          snapAgua: 220,
          casa: 1,
          comision: 0),
      _dosis(id: 4, lote: 2, tipo: 'dosis_sin_agua', precio: 600, snapDosis: _unit),
      // Omar y Yaniel: con agua tras la corrección.
      _dosis(
          id: 5,
          lote: 1,
          tipo: 'dosis_con_agua',
          precio: 900,
          snapDosis: _unit,
          snapAgua: 220),
      _dosis(id: 6, lote: 1, tipo: 'dosis_sin_agua', precio: 600, snapDosis: _unit),
      _dosis(id: 7, lote: 1, tipo: 'dosis_sin_agua', precio: 600, snapDosis: _unit),
      _dosis(
          id: 8,
          lote: 1,
          tipo: 'dosis_con_agua',
          precio: 900,
          snapDosis: _unit,
          snapAgua: 220),
      _dosis(id: 9, lote: 1, tipo: 'dosis_sin_agua', precio: 600, snapDosis: _unit),
      // Agua suelta (2 unidades).
      {
        'id': 10,
        'lote_id': null,
        'tipo': 'agua_suelta',
        'cantidad': 2,
        'precio_unitario': 300.0,
        'costo_dosis_snapshot': null,
        'costo_agua_snapshot': 220.0,
        'casa': 0,
        'comision_unitaria': 0.0,
      },
    ];

void main() {
  const botes = [
    {
      'id': 2,
      'suplemento_id': 5,
      'dosis_rendimiento': 60,
      'costo_bote': 20800.0,
    },
  ];
  const boteDeLote = {1: 2, 2: 2};
  const movsAgua = [
    {'tipo': 'entrada', 'cantidad': 24, 'costo_unitario': 220.0},
  ];

  test('caso fresco: números que cuadran con la libreta de Jc', () {
    final r = calcular1B(
      ventas: _ventasFrescas(),
      salidas: const [],
      botes: botes,
      boteDeLote: boteDeLote,
      movsAgua: movsAgua,
    );
    final b = r.b;
    expect(b['inversion_botes'], 20800.0);
    expect(b['inversion_agua'], 5280.0);
    expect(b['ing_sin'], 3600.0);
    expect(b['ing_con'], 1800.0);
    expect(b['ing_agua'], 600.0);
    expect(b['ingresos'], 6000.0);
    // 8 comerciales × 346.67 (NO los snapshots viejos a 800).
    expect(b['costo_dosis'], closeTo(8 * _unit, 0.01));
    // Agua comercial: 2 con agua + agua suelta (2×220).
    expect(b['costo_agua'], 880.0);
    expect(b['mermas_costo'], 0.0);
    expect(b['margen'], closeTo(6000 - 8 * _unit - 880, 0.01));
    expect(b['comision'], 400.0);
    expect(b['neto_dueno'], closeTo(6000 - 8 * _unit - 880 - 400, 0.01));
    expect(b['casa_costo'], closeTo(_unit + 220, 0.01));
    expect(b['casa_n'], 1);
    // Margen medio: el agua de los combos resta su costo (2×220),
    // si no quedaba inflado +80 por combo (Argón stats MEDIO 1).
    expect(b['margen_medio'], closeTo((5400 - 8 * _unit - 440) / 8, 0.01));
    expect(b['pct_con_agua'], 25.0);
    expect(r.nDosis, 8);
    // Agregados por bote con la MISMA base (para Margen %): el costo
    // del bote incluye el agua de los combos (2×220), si no el
    // Margen % del bote trataba el agua como ganancia del polvo.
    expect(r.costoBoteV[2], closeTo(8 * _unit + 440, 0.01));
    expect(r.ingBote[2], 5400.0);
    expect(r.dosisBote[2], 8);
  });

  test('caso pantalla vieja: staff no es merma, costo no usa snapshots', () {
    final ventas = _ventasFrescas().sublist(0, 9).map((v) {
      final m = Map<String, dynamic>.from(v);
      // Antes de la corrección: las con agua figuraban sin agua a 600.
      if (m['id'] == 5 || m['id'] == 8) {
        m['tipo'] = 'dosis_sin_agua';
        m['precio_unitario'] = 600.0;
        m['costo_agua_snapshot'] = null;
      }
      return m;
    }).toList();
    const salidas = [
      {
        // Panel Luna P2 (lote 3): lote MAPEADO a propósito. Con
        // lote_id null el costo ya sería 0 aunque se valorizara
        // toda salida como dosis, y el test no probaría nada: con
        // lote 1, que el costo sea 0 prueba el filtro por motivo.
        'lote_id': 1,
        'dosis': 1,
        'motivo': 'consumo_staff',
        'tipo_item': 'agua',
      },
    ];
    final r = calcular1B(
      ventas: ventas,
      salidas: salidas,
      botes: botes,
      boteDeLote: boteDeLote,
      movsAgua: movsAgua,
    );
    final b = r.b;
    expect(b['inversion_botes'], 20800.0);
    expect(b['ing_sin'], 4800.0);
    expect(b['ing_con'], 0.0);
    expect(b['ingresos'], 4800.0);
    // Costo comercial con base actual (no 4026.67 de snapshots).
    expect(b['costo_dosis'], closeTo(8 * _unit, 0.01));
    expect(b['costo_agua'], 0.0);
    // El consumo staff de agua NO se valoriza como merma.
    expect(b['mermas_costo'], 0.0);
    expect(b['margen'], closeTo(4800 - 8 * _unit, 0.01));
    expect(b['neto_dueno'], closeTo(4800 - 8 * _unit - 400, 0.01));
  });

  test('caso vacío: ceros sin divisiones entre cero', () {
    final r = calcular1B(
      ventas: const [],
      salidas: const [],
      botes: botes,
      boteDeLote: boteDeLote,
      movsAgua: const [],
    );
    expect(r.b['ingresos'], 0.0);
    expect(r.b['margen'], 0.0);
    expect(r.b['margen_medio'], 0.0);
    expect(r.b['pct_con_agua'], 0.0);
    expect(r.b['inversion_botes'], 20800.0);
    expect(r.nDosis, 0);
  });

  test('indicadoresBote con combos: el agua no infla el margen %', () {
    // Argón stats M8: el resultado de calcular1B alimenta directo a
    // indicadoresBote. Con 2 combos, el costo del bote lleva el agua
    // (3213.33) y el margen % es 40.49, no 48.65; el equilibrio usa
    // el costo efectivo por dosis (401.67), no solo el polvo.
    final r = calcular1B(
      ventas: _ventasFrescas(),
      salidas: const [],
      botes: botes,
      boteDeLote: boteDeLote,
      movsAgua: movsAgua,
    );
    final ind = indicadoresBote(
      costoBote: 20800.0,
      rendimiento: 60,
      ingresosComerciales: r.ingBote[2] ?? 0,
      dosisComerciales: r.dosisBote[2] ?? 0,
      costosComerciales: r.costoBoteV[2] ?? 0,
    );
    expect(ind.pendiente, isFalse);
    expect(ind.margenPct, closeTo(40.49, 0.01));
    expect(ind.puntoEquilibrioDosis, closeTo(76.10, 0.01));
  });

  test('dosis comercial huérfana: respaldo al snapshot', () {
    // Panel Luna P2a: sin lote mapeado no hay costo actual del bote;
    // la comercial usa su snapshot (la Casa ya lo hacía).
    final r = calcular1B(
      ventas: [
        _dosis(
            id: 1,
            lote: 99,
            tipo: 'dosis_sin_agua',
            precio: 600,
            snapDosis: 500),
      ],
      salidas: const [],
      botes: botes,
      boteDeLote: boteDeLote,
      movsAgua: movsAgua,
    );
    expect(r.nDosis, 1);
    expect(r.b['costo_dosis'], 500.0);
    expect(r.costoBoteV, isEmpty);
  });

  test('diasDesdePrimeraVenta: denominador real en modo todo', () {
    final ventas = [
      {'fecha': '2026-10-01'},
      {'fecha': '2026-10-28'},
    ];
    expect(diasDesdePrimeraVenta(ventas, DateTime(2026, 10, 28)), 28);
    expect(
        diasDesdePrimeraVenta(
            [
              {'fecha': '2026-10-28'}
            ],
            DateTime(2026, 10, 28)),
        1);
    expect(diasDesdePrimeraVenta(const [], DateTime(2026, 10, 28)), 30);
  });

  test('Casa con precio > 0 no infla ingresos ni margen (Terra)', () {
    // Antes la Casa sumaba en ing_sin/ing_con si su precio era > 0,
    // aunque costo y dosis ya la excluían: margen inflado.
    final ventas = [
      _dosis(
          id: 1,
          lote: 2,
          tipo: 'dosis_sin_agua',
          precio: 600,
          snapDosis: _unit),
      _dosis(
          id: 2,
          lote: 2,
          tipo: 'dosis_sin_agua',
          precio: 600,
          snapDosis: _unit,
          casa: 1,
          comision: 0),
    ];
    final r = calcular1B(
      ventas: ventas,
      salidas: const [],
      botes: botes,
      boteDeLote: boteDeLote,
      movsAgua: movsAgua,
    );
    final b = r.b;
    expect(b['ing_sin'], 600.0);
    expect(b['ingresos'], 600.0);
    expect(b['margen'], closeTo(600 - _unit, 0.01));
    expect(b['margen_medio'], closeTo(600 - _unit, 0.01));
    expect(b['casa_n'], 1);
    expect(b['casa_costo'], closeTo(_unit, 0.01));
    expect(r.nDosis, 1);
    expect(r.ingBote[2], 600.0);
  });

  test('diasDesdePrimeraVenta: venta a las 23:00 cuenta el día', () {
    // Terra: difference() medía periodos de 24 h y daba 27 en vez
    // de 28 para una primera venta a las 23:00 del día 1.
    expect(
        diasDesdePrimeraVenta(
            [
              {'fecha': '2026-10-01T23:00:00'}
            ],
            DateTime(2026, 10, 28, 10)),
        28);
  });

  test('ultimaEntradaAguaCosto: elige por fecha e id, no por orden', () {
    expect(
        ultimaEntradaAguaCosto([
          {
            'tipo': 'entrada',
            'fecha': '2026-10-28',
            'id': 9,
            'costo_unitario': 300.0
          },
          {
            'tipo': 'entrada',
            'fecha': '2026-10-20',
            'id': 3,
            'costo_unitario': 220.0
          },
          {
            'tipo': 'salida',
            'fecha': '2026-10-29',
            'id': 10,
            'costo_unitario': 999.0
          },
        ]),
        300.0);
    // Empate de fecha: gana el id mayor.
    expect(
        ultimaEntradaAguaCosto([
          {
            'tipo': 'entrada',
            'fecha': '2026-10-28',
            'id': 5,
            'costo_unitario': 250.0
          },
          {
            'tipo': 'entrada',
            'fecha': '2026-10-28',
            'id': 8,
            'costo_unitario': 260.0
          },
        ]),
        260.0);
    expect(ultimaEntradaAguaCosto(const []), 0);
  });

  // ─── Argón Estadísticas 1.21 (#1, #2, #8) ───────────────────
  // #2: dos botes del mismo suplemento: la venta por pomo se
  // atribuye al bote cuya ventana [abierto_en, cerrado_en)
  // contiene su fecha, NO al bote abierto actual.
  group('Argón Estadísticas #2: atribución por ventana de bote', () {
    const botesDos = [
      {
        'id': 11,
        'suplemento_id': 5,
        'dosis_rendimiento': 60,
        'costo_bote': 30000.0,
        'abierto_en': '2026-09-01',
        'cerrado_en': '2026-10-15',
        'estado': 'cerrado',
      },
      {
        'id': 12,
        'suplemento_id': 5,
        'dosis_rendimiento': 60,
        'costo_bote': 20000.0,
        'abierto_en': '2026-10-15',
        'cerrado_en': null,
        'estado': 'abierto',
      },
    ];

    Map<String, dynamic> ventaPomo(String fecha, int cantidad) => {
          'id': 1,
          'pomo_id': 7,
          'lote_id': null,
          'tipo': 'dosis_sin_agua',
          'cantidad': cantidad,
          'precio_unitario': 600.0,
          'costo_dosis_snapshot': null,
          'costo_agua_snapshot': null,
          'casa': 0,
          'comision_unitaria': 50.0,
          'fecha': fecha,
        };

    test('la venta de octubre va al bote cerrado; la de noviembre, al abierto',
        () {
      final r = calcular1B(
        ventas: [ventaPomo('2026-10-10', 10), ventaPomo('2026-11-02', 3)],
        salidas: const [],
        botes: botesDos,
        boteDeLote: const {},
        // El respaldo estático apunta al bote NUEVO (el
        // comportamiento viejo): la ventana debe corregirlo.
        boteDePomo: const {7: 12},
        suplementoDePomo: const {7: 5},
        movsAgua: const [],
      );
      expect(r.dosisBote[11], 10, reason: 'bote cerrado con SUS dosis');
      expect(r.dosisBote[12], 3, reason: 'bote abierto solo con las suyas');
      expect(r.ingBote[11], 6000.0);
      expect(r.ingBote[12], 1800.0);
      // El costo también se resuelve por bote correcto:
      // 10 × (30000/60) y 3 × (20000/60).
      expect(r.costoBoteV[11], closeTo(5000.0, 0.01));
      expect(r.costoBoteV[12], closeTo(1000.0, 0.01));
    });

    test('sin suplementoDePomo se conserva el respaldo estático', () {
      final r = calcular1B(
        ventas: [ventaPomo('2026-10-10', 10)],
        salidas: const [],
        botes: botesDos,
        boteDeLote: const {},
        boteDePomo: const {7: 12},
        movsAgua: const [],
      );
      expect(r.dosisBote[12], 10);
      expect(r.dosisBote[11], isNull);
    });

    test('botePorVentana: bordes y respaldo', () {
      // El día del cierre ya pertenece al bote nuevo.
      expect(botePorVentana(botesDos, '2026-10-15'), 12);
      // Antes de cualquier apertura: respaldo.
      expect(botePorVentana(botesDos, '2026-08-01', respaldo: 99), 99);
      // Sin fecha: respaldo.
      expect(botePorVentana(botesDos, null, respaldo: 99), 99);
      // Bote sin cerrado_en registrado: el último abierto
      // antes de la fecha manda.
      expect(
          botePorVentana([
            {
              'id': 21,
              'suplemento_id': 5,
              'abierto_en': '2026-09-01',
              'cerrado_en': null
            },
            {
              'id': 22,
              'suplemento_id': 5,
              'abierto_en': '2026-10-15',
              'cerrado_en': null
            },
          ], '2026-10-10'),
          21);
    });
  });

  group('Argón Estadísticas #1: inversión acotada al mes', () {
    const botesMes = [
      {
        'id': 11,
        'suplemento_id': 5,
        'dosis_rendimiento': 60,
        'costo_bote': 60000.0,
        'abierto_en': '2026-10-05',
      },
      {
        'id': 12,
        'suplemento_id': 5,
        'dosis_rendimiento': 60,
        'costo_bote': 20000.0,
        'abierto_en': '2026-11-02',
      },
      {
        // Sin abierto_en: no se ubica en el tiempo; con mes
        // no cuenta, sin mes sí (acumulado).
        'id': 13,
        'suplemento_id': 6,
        'dosis_rendimiento': 60,
        'costo_bote': 5000.0,
      },
    ];
    const aguaMes = [
      {'tipo': 'entrada', 'cantidad': 10, 'costo_unitario': 200.0, 'fecha': '2026-10-20'},
      {'tipo': 'entrada', 'cantidad': 5, 'costo_unitario': 200.0, 'fecha': '2026-11-01'},
      {'tipo': 'salida_sin_venta', 'cantidad': 3, 'costo_unitario': 200.0, 'fecha': '2026-11-01'},
    ];

    test('con mesInversion solo suman las compras del mes', () {
      final r = calcular1B(
        ventas: const [],
        salidas: const [],
        botes: botesMes,
        boteDeLote: const {},
        mesInversion: '2026-11',
        movsAgua: aguaMes,
      );
      expect(r.b['inversion_botes'], 20000.0);
      expect(r.b['inversion_agua'], 1000.0);
    });

    test('sin mesInversion la inversión es la acumulada de siempre', () {
      final r = calcular1B(
        ventas: const [],
        salidas: const [],
        botes: botesMes,
        boteDeLote: const {},
        movsAgua: aguaMes,
      );
      expect(r.b['inversion_botes'], 85000.0);
      expect(r.b['inversion_agua'], 3000.0);
    });
  });

  test('Argón Estadísticas #8: textoResumenSemanal sin artefactos IEEE 754',
      () {
    final t = textoResumenSemanal(
      lunes: '2026-10-26',
      domingo: '2026-11-01',
      dosis: 10,
      pomosSueltos: 2,
      ingresos: 3119.9999999999995,
      comisiones: 0.1 + 0.2,
    );
    expect(t, contains('Ingresos: 3120 CUP'));
    expect(t, contains('Comisiones: 0.3 CUP'));
    expect(t, isNot(contains('3120.00')));
  });
}
