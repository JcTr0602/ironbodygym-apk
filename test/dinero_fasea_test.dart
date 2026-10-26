/// Tests de la Fase A 2026-10-25 (dinero + pulls 1.10/1.11).
///
/// Todo puro (sin BD) salvo la migración v45, que vive en
/// migracion_v45_test.dart, y el rechazo M1, en
/// adelantos_m1_test.dart.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/bloque3.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/nomina_bonos.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/precio_cobro.dart';
import 'package:ironbody_gym/tarifa_especial.dart';

const _precios = {
  'mensual': 2000.0,
  'menores': 1500.0,
  'transfer': 2500.0,
  'diario': 200.0,
  'semanal': 600.0,
  'quincenal': 1200.0,
};

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload) => {
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

void main() {
  group('A1: método del pago diario', () {
    test('sin método = efectivo (legacy)', () {
      expect(esPagoDiarioEfectivo({}), isTrue);
      expect(esPagoDiarioEfectivo({'metodo': 'efectivo'}), isTrue);
    });

    test('transferencia no es efectivo', () {
      expect(esPagoDiarioEfectivo({'metodo': 'transferencia'}), isFalse);
    });

    test('columna del espejo: sin método = efectivo', () {
      expect(LocalDb.metodoPagoDiarioDe({}), 'efectivo');
      expect(LocalDb.metodoPagoDiarioDe({'metodo': 'transferencia'}),
          'transferencia');
    });
  });

  group('Hallazgo A: inscripcion_venta_suplemento y método real', () {
    Map<String, dynamic> payload(String? metodo) => {
          if (metodo != null) 'metodo_pago': metodo,
          'cliente': {
            'periodo': 'mensual',
            'meses': 1,
            'monto': 2000,
          },
          'venta': {'moneda': 'CUP', 'cantidad': 2, 'precio': 500},
        };

    test('efectivo suma mensualidad + venta', () {
      final v = montoEfectivoOp(
          _op('inscripcion_venta_suplemento', payload('efectivo')),
          _precios);
      expect(v, 3000);
    });

    test('sin método (op vieja) se asume efectivo', () {
      final v = montoEfectivoOp(
          _op('inscripcion_venta_suplemento', payload(null)), _precios);
      expect(v, 3000);
    });

    test('transferencia NO suma nada al pendiente en efectivo', () {
      final v = montoEfectivoOp(
          _op('inscripcion_venta_suplemento', payload('transferencia')),
          _precios);
      expect(v, 0);
    });

    test('inscribir por transferencia tampoco suma (regresión)', () {
      final v = montoEfectivoOp(
          _op('inscribir', {
            'periodo': 'mensual',
            'meses': 1,
            'metodo_pago': 'transferencia',
            'monto': 2000,
          }),
          _precios);
      expect(v, 0);
    });
  });

  group('1.14 (D17): pago_diario y método en montoEfectivoOp', () {
    test('diario en efectivo suma', () {
      final v = montoEfectivoOp(
          _op('pago_diario', {'cantidad': 3, 'metodo': 'efectivo'}),
          _precios);
      expect(v, 600);
    });

    test('diario sin método (op vieja) se asume efectivo', () {
      final v = montoEfectivoOp(
          _op('pago_diario', {'cantidad': 3}), _precios);
      expect(v, 600);
    });

    test('diario por transferencia NO suma al pendiente en efectivo', () {
      final v = montoEfectivoOp(
          _op('pago_diario', {'cantidad': 3, 'metodo': 'transferencia'}),
          _precios);
      expect(v, 0);
    });
  });

  group('A3: solo las mensualidades generan comisión', () {
    test('mensual cuenta; semanal y quincenal no', () {
      expect(NominaCalc.esPagoMensualidad({'periodo': 'mensual'}), isTrue);
      expect(NominaCalc.esPagoMensualidad({'periodo': 'semanal'}), isFalse);
      expect(
          NominaCalc.esPagoMensualidad({'periodo': 'quincenal'}), isFalse);
    });

    test('sin periodo = mensual (default del resto del código)', () {
      expect(NominaCalc.esPagoMensualidad({}), isTrue);
      expect(
          NominaCalc.esPagoMensualidad({'tipo_id': 'menores'}), isTrue);
    });

    test('personalizado y ofertas: solo si cubren 30 días o más', () {
      expect(
          NominaCalc.esPagoMensualidad(
              {'periodo': 'personalizado', 'dias': 15}),
          isFalse);
      expect(
          NominaCalc.esPagoMensualidad(
              {'periodo': 'personalizado', 'dias': 30}),
          isTrue);
      expect(
          NominaCalc.esPagoMensualidad(
              {'periodo': 'tipo:oferta50', 'dias': 30}),
          isTrue);
      expect(
          NominaCalc.esPagoMensualidad(
              {'periodo': 'tipo:oferta50', 'dias': 7}),
          isFalse);
      // Sin días no se puede probar cobertura mensual: no cuenta.
      expect(
          NominaCalc.esPagoMensualidad({'periodo': 'personalizado'}),
          isFalse);
    });

    test('idsDesdePagos no filtra por sí solo (el filtro vive en _conjunto)',
        () {
      final ids = NominaCalc.idsDesdePagos([
        {'cliente_id': 1, 'periodo': 'mensual'},
        {'cliente_id': 2, 'periodo': 'semanal'},
      ]);
      expect(ids, {1, 2});
    });
  });

  group('A4: fusión de bonos', () {
    List<Map<String, dynamic>> ops(List<Map<String, dynamic>> payloads) =>
        [
          for (final p in payloads)
            {
              'tipo': p.remove('__tipo') as String,
              'payload': jsonEncode(p),
            },
        ];

    test('espejo + op pendiente del mismo bono no se duplica', () {
      final out = fusionarBonosNomina(
        espejo: [
          {
            'bono_uuid': 'a',
            'mes': '2026-10',
            'entrenador': 'ambos',
            'monto': 100,
          },
        ],
        opsPendientes: ops([
          {
            '__tipo': 'registrar_bono_nomina',
            'bono_uuid': 'a',
            'mes': '2026-10',
            'entrenador': 'ambos',
            'monto': 100,
          },
        ]),
      );
      expect(out.length, 1);
      expect(out.first['id'], 'a');
    });

    test('op eliminar pendiente oculta la fila del espejo', () {
      final out = fusionarBonosNomina(
        espejo: [
          {
            'bono_uuid': 'a',
            'mes': '2026-10',
            'entrenador': 'duany',
            'monto': 50,
          },
        ],
        opsPendientes: ops([
          {'__tipo': 'eliminar_bono_nomina', 'bono_uuid': 'a'},
        ]),
      );
      expect(out, isEmpty);
    });

    test('fila del espejo marcada eliminada se descarta', () {
      final out = fusionarBonosNomina(
        espejo: [
          {
            'bono_uuid': 'a',
            'mes': '2026-10',
            'entrenador': 'ambos',
            'monto': 100,
            'eliminada': 1,
          },
        ],
        opsPendientes: const [],
      );
      expect(out, isEmpty);
    });
  });

  group('MIN: menor vs oferta', () {
    PrecioCobro precio({bool menor = true, double? oferta}) =>
        calcularPrecioCobro(
          periodo: 'mensual',
          metodo: 'efectivo',
          esCasa: false,
          esMenor: menor,
          precios: _precios,
          montoOferta: oferta,
          hoyHabana: '2026-10-25',
        );

    test('menor con Oferta 50% (1000) cobra 1000, no 1500', () {
      final r = precio(oferta: 1000);
      expect(r.monto, 1000);
      expect(r.escalon, 'oferta');
    });

    test('menor con oferta más cara que menores sigue en 1500', () {
      final r = precio(oferta: 2000);
      expect(r.monto, 1500);
      expect(r.escalon, 'menores');
    });

    test('menor sin oferta cobra 1500', () {
      final r = precio();
      expect(r.monto, 1500);
      expect(r.escalon, 'menores');
    });

    test('adulto con oferta cobra la oferta', () {
      final r = precio(menor: false, oferta: 1000);
      expect(r.monto, 1000);
      expect(r.escalon, 'oferta');
    });

    test('especial vigente sigue ganando a menor y oferta', () {
      final r = calcularPrecioCobro(
        periodo: 'mensual',
        metodo: 'efectivo',
        esCasa: false,
        esMenor: true,
        precios: _precios,
        especial: {
          'periodo': 'mensual',
          'monto_efectivo': 1200,
          'vigente_desde': '2026-10-01',
        },
        montoOferta: 1000,
        hoyHabana: '2026-10-25',
      );
      expect(r.monto, 1200);
      expect(r.escalon, 'especial');
    });
  });

  group('B1: transferencia + pendiente se fuerza a nomina', () {
    test('transferencia + pendiente = nomina', () {
      expect(
          destinoEfectivoF3(
              metodo: 'transferencia', destino: 'pendiente'),
          'nomina');
    });

    test('efectivo + pendiente se queda pendiente', () {
      expect(
          destinoEfectivoF3(metodo: 'efectivo', destino: 'pendiente'),
          'pendiente');
    });

    test('nomina no cambia con ningún método', () {
      expect(
          destinoEfectivoF3(metodo: 'transferencia', destino: 'nomina'),
          'nomina');
      expect(
          destinoEfectivoF3(metodo: 'efectivo', destino: 'nomina'),
          'nomina');
    });
  });

  group('Pulls Fase A: fusión espejo + local', () {
    test('tarifas: el espejo gana por id y el historial lista se normaliza',
        () {
      final out = fusionarTarifasEspeciales(
        [
          {
            'id': 'x',
            'cliente_id': 10,
            'periodo': 'mensual',
            'activa': 1,
            'actualizada_ts': '2026-10-20',
          },
        ],
        [
          {
            'id': 'x',
            'cliente_id': 10,
            'periodo': 'mensual',
            'activa': 0,
            'historial': [
              {'evento': 'revocada'}
            ],
            'actualizada_ts': '2026-10-24',
          },
          {
            'id': 'y',
            'cliente_id': 11,
            'periodo': 'mensual',
            'activa': 1,
            'actualizada_ts': '2026-10-24',
          },
        ],
      );
      expect(out.length, 2);
      final x = out.firstWhere((f) => f['id'] == 'x');
      expect(x['activa'], 0);
      expect(x['historial'], isA<String>());
      expect(jsonDecode(x['historial'] as String).first['evento'],
          'revocada');
    });

    test('entregas: mismo op_uuid no se duplica', () {
      final out = fusionarEntregasEfectivo(
        [
          {
            'op_uuid': 'u1',
            'entrenador_telegram_id': 5,
            'monto_entregado': 500,
          },
        ],
        [
          {
            'op_uuid': 'u1',
            'entrenador_telegram_id': 5,
            'monto_entregado': 500,
          },
          {
            'op_uuid': 'u2',
            'entrenador_telegram_id': 5,
            'monto_entregado': 300,
          },
        ],
      );
      expect(out.length, 2);
      final total = out.fold<double>(
          0, (s, f) => s + ((f['monto_entregado'] as num?)?.toDouble() ?? 0));
      expect(total, 800);
    });

    test('recordatorios: el espejo trae el disparado masivo; el '
        'inactivo sin fila local no resucita', () {
      final out = LocalDb.fusionarRecordatorios(
        [
          {
            'id': 'r1',
            'titulo': 'Cumpleaños',
            'tipo': 'personalizado',
            'alcance': 'todos',
            'activa': 1,
            'creada_ts': '2026-10-01',
          },
        ],
        [
          {
            'id': 'r1',
            'titulo': 'Cumpleaños',
            'tipo': 'personalizado',
            'alcance': 'todos',
            'activa': 1,
            'disparado_en_fecha_habana': '2026-10-25',
            'creada_ts': '2026-10-01',
          },
          {
            'id': 'r2',
            'titulo': 'Borrado',
            'tipo': 'personalizado',
            'alcance': 'todos',
            'activa': 0,
            'creada_ts': '2026-10-02',
          },
          {
            'id': 'r3',
            'titulo': 'Nuevo en otro teléfono',
            'tipo': 'personalizado',
            'alcance': 'todos',
            'activa': 1,
            'creada_ts': '2026-10-03',
          },
        ],
      );
      expect(out.map((f) => f['id']).toSet(), {'r1', 'r3'});
      expect(
          out.firstWhere((f) => f['id'] == 'r1')['disparado_en_fecha_habana'],
          '2026-10-25');
    });
  });
}
