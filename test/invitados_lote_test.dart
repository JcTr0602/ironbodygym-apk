// v1.8.0 — Invitados desarrollados: modelos Plus/lote y el ciclo
// de vida del op_id (G4.3 de Argón: mismo op_id SOLO ante fallo
// de transporte; op_id nuevo tras cualquier respuesta válida).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';

Map<String, dynamic> _respLote({bool repetida = false}) => {
      'ok': true,
      'accion': 'plus_cortesia',
      'aplicados': 1,
      'omitidos': 1,
      'fallidos': 1,
      if (repetida) 'repetida': true,
      'items': [
        {
          'id': 'a',
          'ok': true,
          'codigo': 'aplicada',
          'plus_hasta': '2026-11-22T00:00:00Z',
        },
        {
          'id': 'b',
          'ok': false,
          'codigo': 'convertido',
          'motivo': 'Ya es cliente: la acción no aplica',
        },
        {
          'id': 'c',
          'ok': false,
          'codigo': 'error',
          'motivo': 'boom',
        },
      ],
    };

void main() {
  group('modelos v2', () {
    test('InvitadoResumen parsea el Plus y el teléfono-cliente', () {
      final r = InvitadoResumen.fromJson({
        'id': 'x',
        'nombre': 'Ana',
        'telefono': '58112233',
        'estado': 'activo',
        'dias_restantes': 20,
        'plus_activo': true,
        'plus_hasta': '2026-11-02T00:00:00Z',
        'plus_dias_restantes': 5,
        'plus_origen': 'cortesia',
        'telefono_ya_cliente': true,
      });
      expect(r.plusActivo, isTrue);
      expect(r.plusDiasRestantes, 5);
      expect(r.plusOrigen, 'cortesia');
      expect(r.plusPorVencer, isTrue);
      expect(r.telefonoYaCliente, isTrue);
      // Ida y vuelta para la caché offline (G1).
      final r2 = InvitadoResumen.fromJson(r.toJson());
      expect(r2.plusActivo, isTrue);
      expect(r2.plusDiasRestantes, 5);
      expect(r2.nombre, 'Ana');
    });

    test('InvitadoResumen sin la oleada SQL: Plus ausente, no rompe',
        () {
      final r = InvitadoResumen.fromJson({
        'id': 'x',
        'nombre': 'Ana',
        'telefono': '58112233',
        'estado': 'activo',
      });
      expect(r.plusActivo, isFalse);
      expect(r.plusHasta, isNull);
      expect(r.plusOrigen, isNull);
    });

    test('PlusDetalle con estado revocado e historial (G5)', () {
      final d = InvitadoDetalle.fromJson({
        'invitado': {
          'id': 'x',
          'nombre': 'Ana',
          'telefono': '58112233',
          'estado': 'activo',
          'telefono_ya_cliente': true,
        },
        'plus': {
          'estado': 'revocado',
          'activo': false,
          'hasta': '2026-10-23T00:00:00Z',
          'historial': [
            {
              'tipo': 'plus_quitar',
              'fecha': '2026-10-23T00:00:00Z',
              'actor': 'jc@ironbody.gym',
              'motivo': 'Cortesía mal aplicada',
            },
            {
              'tipo': 'reporte_confirmado',
              'fecha': '2026-10-01T00:00:00Z',
              'monto_cup': 1000,
            },
          ],
        },
        'staff_acciones': [
          {
            'accion': 'plus_quitar',
            'actor': 'jc@ironbody.gym',
            'fecha': '2026-10-23T00:00:00Z',
            'detalle': {'motivo': 'Cortesía mal aplicada'},
          },
        ],
      });
      expect(d.telefonoYaCliente, isTrue);
      expect(d.plus!.estado, 'revocado');
      expect(d.plus!.activo, isFalse);
      expect(d.plus!.historial.length, 2);
      expect(d.plus!.historial.first.tipo, 'plus_quitar');
      expect(d.staffAcciones.single.detalle['motivo'],
          'Cortesía mal aplicada');
    });

    test('InvitadosConteos parsea la cabecera', () {
      final c = InvitadosConteos.fromJson({
        'total': 148,
        'plus': 23,
        'plus_por_vencer': 4,
        'solicitudes': 6,
        'por_expirar': 9,
        'nuevos': 3,
      });
      expect(c.total, 148);
      expect(c.plusPorVencer, 4);
    });

    test('ResultadoLote parsea aplicados/omitidos/fallidos', () {
      final r = ResultadoLote.fromJson(_respLote());
      expect(r.aplicados, 1);
      expect(r.omitidos, 1);
      expect(r.fallidos, 1);
      expect(r.items[1].codigo, 'convertido');
      expect(r.items[0].plusHasta, isNotNull);
    });
  });

  group('AccionLoteInvitados — ciclo del op_id (G4.3)', () {
    test('fallo de transporte conserva el op_id; el éxito lo consume',
        () async {
      final opIdsVistos = <String>[];
      var fallar = true;
      final svc = InvitadosService(rpc: (nombre, params) async {
        opIdsVistos.add('${params?['p_op_id']}');
        if (fallar) throw Exception('SocketException: timeout');
        return _respLote();
      });
      final lote = AccionLoteInvitados();
      // 1) Transporte falla → InvitadoError RED y op_id conservado.
      await expectLater(
        lote.ejecutar(svc,
            ids: const ['a', 'b'],
            accion: 'plus_cortesia',
            dias: 30,
            motivo: 'Cortesía'),
        throwsA(isA<InvitadoError>()),
      );
      // 2) Reintento idéntico → MISMO op_id.
      fallar = false;
      await lote.ejecutar(svc,
          ids: const ['a', 'b'],
          accion: 'plus_cortesia',
          dias: 30,
          motivo: 'Cortesía');
      expect(opIdsVistos.length, 2);
      expect(opIdsVistos[1], opIdsVistos[0]);
      // 3) Tras la respuesta válida, repetir la MISMA intención
      //    genera un op_id NUEVO (la anterior se consumió).
      await lote.ejecutar(svc,
          ids: const ['a', 'b'],
          accion: 'plus_cortesia',
          dias: 30,
          motivo: 'Cortesía');
      expect(opIdsVistos[2], isNot(opIdsVistos[0]));
    });

    test('intención distinta (otros ids) genera op_id nuevo', () async {
      final opIdsVistos = <String>[];
      final svc = InvitadosService(rpc: (nombre, params) async {
        opIdsVistos.add('${params?['p_op_id']}');
        return _respLote();
      });
      final lote = AccionLoteInvitados();
      await lote.ejecutar(svc,
          ids: const ['a'], accion: 'vida_extender', dias: 30);
      await lote.ejecutar(svc,
          ids: const ['c'], accion: 'vida_extender', dias: 30);
      expect(opIdsVistos[0], isNot(opIdsVistos[1]));
    });

    test('tope de 50 en el cliente: no llama a la RPC (G3)', () async {
      var llamo = false;
      final svc = InvitadosService(rpc: (nombre, params) async {
        llamo = true;
        return _respLote();
      });
      await expectLater(
        svc.accionLote(
          ids: [for (var i = 0; i < 51; i++) 'id$i'],
          accion: 'vida_extender',
          dias: 30,
          opId: 'op-x',
        ),
        throwsA(isA<InvitadoError>()),
      );
      expect(llamo, isFalse);
    });
  });
}
