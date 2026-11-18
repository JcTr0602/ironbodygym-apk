/// H-B3 (136-730/732/736): normalización y contratos de
/// lib/servicios.dart y guardia CSV / franja de
/// lib/estadisticas_servicios.dart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';
import 'package:ironbody_gym/servicios.dart';

void main() {
  group('136-730 parseIdClienteServicio compartido', () {
    test('acepta número y texto, rechaza basura', () {
      expect(parseIdClienteServicio(7), 7);
      expect(parseIdClienteServicio('7'), 7);
      expect(parseIdClienteServicio(' 12 '), 12);
      expect(parseIdClienteServicio('abc'), isNull);
      expect(parseIdClienteServicio(null), isNull);
    });
    test('el nombre se resuelve con el id en texto', () {
      expect(nombreClienteVentaServicio({'cliente_id': '9'}),
          'Cliente 9');
      expect(nombreClienteVentaServicio({'cliente_id': 9}), 'Cliente 9');
      expect(nombreClienteVentaServicio({}), 'Sin identificar');
    });
    test('el ranking ya no descarta la venta con id en texto', () {
      final r = rankingServicios([
        {
          'cliente_id': '9',
          'cantidad': 2,
          'precio_unitario': 100.0,
          'tipo': 'dosis_sin_agua',
          'fecha': '2026-11-10',
        },
      ]);
      expect(r.length, 1);
      expect(r.first['cliente_id'], 9);
      expect(r.first['monto'], 200.0);
    });
  });

  group('136-730 contarOpsServiciosEnCola desde creada_ts', () {
    test('op sin fecha en payload usa creada_ts para el período', () {
      final ops = <Map<String, dynamic>>[
        {
          'tipo': 'venta_servicio',
          'creada_ts': '2026-11-05T10:00:00',
          'payload': '{}',
        },
        {
          'tipo': 'venta_servicio',
          'creada_ts': '2026-10-01T10:00:00',
          'payload': '{}',
        },
      ];
      final c = contarOpsServiciosEnCola(ops,
          desde: '2026-11-01', hasta: '2026-11-30');
      expect(c.total, 1);
      expect(c.ventas, 1);
    });
    test('sin fecha ni creada_ts cuenta como de hoy, no en cualquier período',
        () {
      final ops = <Map<String, dynamic>>[
        {'tipo': 'venta_servicio', 'payload': '{}'},
      ];
      // Un período que NO contiene hoy (octubre de 2020):
      // la op sin ninguna fecha ya no cuenta «en cualquier
      // período» como antes de 136-730.
      final c = contarOpsServiciosEnCola(ops,
          desde: '2020-10-01', hasta: '2020-10-31');
      expect(c.total, 0);
      // Sin cotas se sigue contando (compatibilidad).
      expect(contarOpsServiciosEnCola(ops).total, 1);
    });
  });

  group('136-732 contratos de lib/servicios.dart', () {
    test('estado detallado con código/severidad/etiqueta corta', () {
      final sinPrecio = estadoBotonVentaServicioDetallado(
        tipo: 'dosis_sin_agua',
        tienePomo: true,
        dosisRestantes: 5,
        pomos: 1,
        esDueno: true,
        precio: 0,
      );
      expect(sinPrecio.habilitado, isFalse);
      expect(sinPrecio.codigo, 'precio_sin_fijar');
      expect(sinPrecio.etiquetaCorta, 'Sin precio');
      final ok = estadoBotonVentaServicioDetallado(
        tipo: 'dosis_sin_agua',
        tienePomo: true,
        dosisRestantes: 5,
        pomos: 1,
        esDueno: true,
        precio: 100,
      );
      expect(ok.codigo, 'ok');
      expect(ok.etiquetaCorta, 'Vender');
    });
    test('método desconocido mapeado, conocidos intactos', () {
      expect(etiquetaMetodoServicio('efectivo'), 'Efectivo');
      expect(etiquetaMetodoServicio('transferencia'), 'Transferencia');
      expect(etiquetaMetodoServicio('cheque'), 'Otro método');
      expect(etiquetaMetodoServicio(''), '');
      expect(etiquetaMetodoServicio(null), '');
    });
    test('salidas con hora «—», cruda y nota', () {
      final e = entradasHistorialServicios(
        ventas: const [],
        salidas: [
          {'id': 3, 'fecha': '2026-11-10', 'motivo': 'merma', 'dosis': 2},
        ],
        reversadas: const {},
      );
      expect(e.single['hora'], '—');
      expect(e.single['nota'], 'merma');
      expect(e.single['cruda'], isNotNull);
    });
    test('segundos restantes de deshacer acotados 0..15', () {
      final t0 = DateTime(2026, 11, 10, 10, 0, 0);
      expect(segundosRestantesDeshacer(t0, t0.add(const Duration(seconds: 4))), 11);
      expect(segundosRestantesDeshacer(t0, t0.add(const Duration(seconds: 40))), 0);
      expect(segundosRestantesDeshacer(t0, t0), 15);
    });
    test('motivo de vacío del ranking distingue los casos', () {
      expect(motivoRankingVacio(const [], const []), 'sin_ventas');
      expect(
          motivoRankingVacio([
            {'cliente_id': 1}
          ], const []),
          'solo_casa_o_sin_monto');
      expect(
          motivoRankingVacio([
            {'cliente_id': 1}
          ], [
            {'cliente_id': 1}
          ]),
          '');
    });
    test('ServicioError conserva el mensaje en toString', () {
      const e = ServicioError('validacion', 'Cantidad inválida');
      expect(e.codigo, 'validacion');
      expect('$e', 'Cantidad inválida');
    });
  });

  group('136-726 textoBusquedaServicios sin tildes', () {
    test('«pena» encuentra «Peña» y las mayúsculas no importan', () {
      expect(textoBusquedaServicios('Peña'), 'pena');
      expect(textoBusquedaServicios('JOSÉ Ángel'), 'jose angel');
      expect(textoBusquedaServicios('pena'),
          textoBusquedaServicios('Peña'));
    });
  });

  group('136-736 estadísticas', () {
    test('franjaDeHora exige el separador :', () {
      expect(franjaDeHora('12:45'), 'tarde');
      expect(franjaDeHora('12x45'), 'sin_hora');
      expect(franjaDeHora('08:00'), 'manana');
    });
    test('el CSV no marca los números negativos como texto', () {
      final csv = csvEstadisticas(
        ['Concepto', 'Margen'],
        [
          ['Proteína', '-250.5'],
          ['Fórmula', '-=2+5'],
          ['Suma', '=1+1'],
        ],
      );
      expect(csv, contains('Proteína,-250.5'));
      expect(csv, contains("'-=2+5"));
      expect(csv, contains("'=1+1"));
    });
  });
}
