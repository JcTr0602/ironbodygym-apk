/// Tests v1.3.4 — Ítem 1 (captura en lote del resultado, sin N+1) e
/// Ítem 4 (batching adaptativo).
///
/// Cubre las funciones puras de `lib/sync.dart` sin red ni BD:
/// - [LoteAdaptativo]: base 20, baja a 10 en fallo, sube a 30/50 en racha.
/// - [normalizarFilaResultado]: filas del RPC y del GET de fallback.
/// - [esRechazoServidor] / [motivoRechazo]: detección del rechazo del puente.
/// - [nucleoResultado] / [extraerIdDeResultado]: desempaquetado del envelope.
/// - [analizarConflictoTurno]: detección de conflicto de turno_id.
/// - [uriSyncOpsBatch]: un solo GET por lote, jamás uno por op.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('LoteAdaptativo (Ítem 4)', () {
    test('arranca en base 20', () {
      final l = LoteAdaptativo();
      expect(l.tam, 20);
    });

    test('un fallo baja a 10 y corta la racha', () {
      final l = LoteAdaptativo();
      l.exito();
      l.exito();
      expect(l.racha, 2);
      l.fallo();
      expect(l.tam, 10);
      expect(l.racha, 0);
    });

    test('3 éxitos seguidos suben de 20 a 30', () {
      final l = LoteAdaptativo();
      l.exito();
      l.exito();
      expect(l.tam, 20); // aún no: faltaba el tercero
      l.exito();
      expect(l.tam, 30);
    });

    test('otra racha de 3 sube de 30 a 50 (tope)', () {
      final l = LoteAdaptativo();
      for (var k = 0; k < 3; k++) {
        l.exito();
      }
      expect(l.tam, 30);
      for (var k = 0; k < 3; k++) {
        l.exito();
      }
      expect(l.tam, 50);
      // Más éxitos no pasan del tope.
      for (var k = 0; k < 10; k++) {
        l.exito();
      }
      expect(l.tam, 50);
    });

    test('un fallo intermedio corta la racha antes de subir', () {
      final l = LoteAdaptativo();
      l.exito();
      l.exito();
      l.fallo();
      expect(l.tam, 10);
      // Desde 10, 3 éxitos seguidos suben a 30.
      l.exito();
      l.exito();
      l.exito();
      expect(l.tam, 30);
    });

    test('fallo repetido se queda en 10', () {
      final l = LoteAdaptativo();
      l.fallo();
      l.fallo();
      expect(l.tam, 10);
    });
  });

  group('normalizarFilaResultado (Ítem 1)', () {
    test('fila del RPC con estado aplicada', () {
      final r = normalizarFilaResultado({
        'op_uuid': 'u1',
        'estado': 'aplicada',
        'resultado': {
          'ok': true,
          'resultado': {'cliente_id': 7}
        },
        'error': null,
      });
      expect(r.estado, 'aplicada');
      expect(r.error, isNull);
      expect((r.resultado as Map)['ok'], true);
    });

    test('fila del RPC con estado rechazada y motivo en columna error', () {
      final r = normalizarFilaResultado({
        'op_uuid': 'u2',
        'estado': 'rechazada',
        'resultado': {'ok': false, 'error': 'carnet duplicado'},
        'error': 'carnet duplicado (columna)',
      });
      expect(r.estado, 'rechazada');
      expect(r.error, 'carnet duplicado (columna)');
    });

    test('fila del GET fallback con aplicada=true → aplicada', () {
      final r = normalizarFilaResultado({
        'op_uuid': 'u3',
        'aplicada': true,
        'resultado': {
          'ok': true,
          'resultado': {'suplemento_id': 12}
        },
      });
      expect(r.estado, 'aplicada');
    });

    test('fila del GET fallback con aplicada=false → pendiente (en vuelo)',
        () {
      final r = normalizarFilaResultado({
        'op_uuid': 'u4',
        'aplicada': false,
        'resultado': null,
      });
      expect(r.estado, 'pendiente');
    });

    test('estado desconocido con aplicada=true → aplicada', () {
      final r = normalizarFilaResultado({
        'op_uuid': 'u5',
        'estado': 'raro',
        'aplicada': true,
        'resultado': {'ok': true},
      });
      expect(r.estado, 'aplicada');
    });

    test('estado necesita_revision se preserva', () {
      final r = normalizarFilaResultado({
        'op_uuid': 'u6',
        'estado': 'necesita_revision',
        'resultado': {'ok': false, 'error': 'revisar manual'},
        'error': null,
      });
      expect(r.estado, 'necesita_revision');
    });
  });

  group('esRechazoServidor', () {
    test('ok:false → rechazada por el puente', () {
      expect(
          esRechazoServidor({
            'ok': false,
            'error': 'el turno ya existe',
            'resultado': {}
          }),
          isTrue);
    });

    test('ok:true → no es rechazo', () {
      expect(
          esRechazoServidor({
            'ok': true,
            'resultado': {'cliente_id': 1}
          }),
          isFalse);
    });

    test('resultado null o no-Map → no es rechazo', () {
      expect(esRechazoServidor(null), isFalse);
      expect(esRechazoServidor('texto'), isFalse);
      expect(esRechazoServidor(42), isFalse);
    });

    test('sin campo ok → no es rechazo (conservador)', () {
      expect(
          esRechazoServidor({
            'resultado': {'cliente_id': 1}
          }),
          isFalse);
    });
  });

  group('motivoRechazo', () {
    test('la columna error del RPC tiene prioridad', () {
      expect(
          motivoRechazo(
              {'ok': false, 'error': 'del envelope'}, 'de la columna'),
          'de la columna');
    });

    test('si no hay columna, usa el error del envelope', () {
      expect(motivoRechazo({'ok': false, 'error': 'del envelope'}, null),
          'del envelope');
    });

    test('sin motivo en ningún lado → null', () {
      expect(motivoRechazo({'ok': false}, null), isNull);
      expect(motivoRechazo(null, null), isNull);
      expect(motivoRechazo({'ok': false, 'error': '  '}, '  '), isNull);
    });
  });

  group('nucleoResultado + extraerIdDeResultado', () {
    test('desempaqueta el envelope del puente', () {
      final src = nucleoResultado({
        'ok': true,
        'resultado': {'cliente_id': 7}
      });
      expect(src, isNotNull);
      expect(src!['cliente_id'], 7);
    });

    test('sin envelope devuelve el mapa tal cual', () {
      final src = nucleoResultado({'cliente_id': 9});
      expect(src!['cliente_id'], 9);
    });

    test('no-Map → null', () {
      expect(nucleoResultado(null), isNull);
      expect(nucleoResultado('x'), isNull);
      expect(nucleoResultado([1, 2]), isNull);
    });

    test('extrae int directo', () {
      expect(
          extraerIdDeResultado({
            'ok': true,
            'resultado': {'cliente_id': 7}
          },
              'cliente_id'),
          7);
    });

    test('extrae string numérico', () {
      expect(
          extraerIdDeResultado({
            'ok': true,
            'resultado': {'suplemento_id': '12'}
          },
              'suplemento_id'),
          12);
    });

    test('clave ausente o no numérica → null', () {
      final res = {
        'ok': true,
        'resultado': {'otro': 1}
      };
      expect(extraerIdDeResultado(res, 'cliente_id'), isNull);
      expect(
          extraerIdDeResultado({
            'ok': true,
            'resultado': {'cliente_id': 'abc'}
          },
              'cliente_id'),
          isNull);
    });
  });

  group('analizarConflictoTurno', () {
    const local = '11111111-1111-4111-8111-111111111111';
    const canonico = '22222222-2222-4222-8222-222222222222';

    test('conflicto válido con UUIDs distintos', () {
      final r = analizarConflictoTurno({
        'ok': true,
        'resultado': {
          'conflicto': true,
          'turno_id': local,
          'turno_id_canonico': canonico,
        }
      });
      expect(r.ok, isTrue);
      expect(r.local, local);
      expect(r.canonico, canonico);
    });

    test('sin conflicto → lectura válida sin conflicto', () {
      final r = analizarConflictoTurno({
        'ok': true,
        'resultado': {'conflicto': false}
      });
      expect(r, (ok: true, local: null, canonico: null));
    });

    test('ids iguales → sin conflicto', () {
      final r = analizarConflictoTurno({
        'ok': true,
        'resultado': {
          'conflicto': true,
          'turno_id': local,
          'turno_id_canonico': local,
        }
      });
      expect(r.local, isNull);
      expect(r.canonico, isNull);
      expect(r.ok, isTrue);
    });

    test('UUIDs inválidos → sin conflicto', () {
      final r = analizarConflictoTurno({
        'ok': true,
        'resultado': {
          'conflicto': true,
          'turno_id': 'no-es-uuid',
          'turno_id_canonico': canonico,
        }
      });
      expect(r.local, isNull);
      expect(r.ok, isTrue);
    });

    test('resultado no-Map → lectura válida sin conflicto', () {
      final r = analizarConflictoTurno(null);
      expect(r, (ok: true, local: null, canonico: null));
    });
  });

  group('uriSyncOpsBatch (Opción B)', () {
    test('un solo GET con filtro in. y select correcto', () {
      final uri = uriSyncOpsBatch(
          ['u1', 'u2', 'u3'], 'https://xyz.supabase.co');
      expect(uri.path, '/rest/v1/sync_ops');
      expect(uri.queryParameters['op_uuid'], 'in.("u1","u2","u3")');
      expect(uri.queryParameters['select'], 'op_uuid,aplicada,resultado');
    });

    test('un solo UUID también forma un lote válido', () {
      final uri = uriSyncOpsBatch(['solo-uno'], 'https://xyz.supabase.co');
      expect(uri.queryParameters['op_uuid'], 'in.("solo-uno")');
    });
  });
}
