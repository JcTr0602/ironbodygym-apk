/// H-B3 (136-710/711): formato de números y plurales de
/// Invitados, y lo que el servicio antes tragaba en silencio
/// (omitidas, error del resumen, URL del grupo, motivos).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';

void main() {
  group('136-710 fmtNumInvitado', () {
    test('entero sin decimales', () {
      expect(fmtNumInvitado(82), '82');
    });
    test('máximo 2 decimales, sin cola larga ni ceros de relleno', () {
      expect(fmtNumInvitado(82.30000000000001), '82.3');
      expect(fmtNumInvitado(18.25), '18.25');
      expect(fmtNumInvitado(18.2), '18.2');
      expect(fmtNumInvitado(0.5), '0.5');
    });
    test('el resumen de la medida usa el formato nuevo', () {
      const m = MedidaInvitado(
          id: '1', pesoKg: 82.30000000000001, grasaPct: 18.25);
      expect(m.resumen, '82.3 kg · 18.25 % grasa');
    });
  });

  group('136-710 ResultadoMedidasInvitado.texto', () {
    test('plural real en singular y plural, sin «(s)»', () {
      const uno = ResultadoMedidasInvitado(
          estado: 'verificadas', importadas: 1, descartadas: 1);
      expect(uno.texto, contains('1 importada'));
      expect(uno.texto, contains('1 descartada'));
      expect(uno.texto, isNot(contains('(s)')));
      const varios = ResultadoMedidasInvitado(
          estado: 'verificadas', importadas: 3, descartadas: 2);
      expect(varios.texto, contains('3 importadas'));
      expect(varios.texto, contains('2 descartadas'));
    });
    test('sin mayúsculas de máquina en el no verificado', () {
      const r = ResultadoMedidasInvitado(estado: 'no_verificadas');
      expect(r.texto, contains('no se importaron'));
      expect(r.texto, isNot(contains('NO se importaron')));
    });
  });

  group('136-711 validarValorInfoPublica whatsapp_grupo_url', () {
    test('acepta el enlace del grupo y vacío (borrar)', () {
      expect(
          validarValorInfoPublica(
              'whatsapp_grupo_url', 'https://chat.whatsapp.com/AbC123'),
          isNull);
      expect(validarValorInfoPublica('whatsapp_grupo_url', ''), isNull);
    });
    test('rechaza texto libre y http', () {
      expect(
          validarValorInfoPublica('whatsapp_grupo_url', 'el grupo del gym'),
          isNotNull);
      expect(
          validarValorInfoPublica(
              'whatsapp_grupo_url', 'http://chat.whatsapp.com/x'),
          isNotNull);
      expect(
          validarValorInfoPublica(
              'whatsapp_grupo_url', 'https://example.com/x'),
          isNotNull);
    });
    test('el teléfono sigue validándose como antes', () {
      expect(validarValorInfoPublica('whatsapp_dueno', '58191577'), isNull);
      expect(validarValorInfoPublica('whatsapp_dueno', '123'), isNotNull);
    });
  });

  group('136-711 servicio expone lo que tragaba', () {
    test('listar cuenta las filas omitidas', () async {
      final svc = InvitadosService(rpc: (nombre, params) async {
        return {
          'invitados': [
            {'id': 'a', 'nombre': 'Ana', 'telefono': '58190001'},
            {'id': 'b', 'nombre': 'Beto', 'telefono': '58190002'},
            'fila-sucia',
            42,
          ],
        };
      });
      final lista = await svc.listar();
      expect(lista.length, 2);
      expect(svc.omitidasUltimaLista, 2);
    });

    test('resumen distingue fallo de RPC ausente', () async {
      final falla = InvitadosService(rpc: (nombre, params) async {
        throw Exception('boom de red simulado');
      });
      expect(await falla.resumen(), isNull);
      expect(falla.errorUltimoResumen, isNotNull);

      final ausente = InvitadosService(rpc: (nombre, params) async {
        return 'respuesta-no-mapa';
      });
      expect(await ausente.resumen(), isNull);
      expect(ausente.errorUltimoResumen, isNull);
    });

    test('purgar con respuesta malformada deja motivo legible', () async {
      final svc = InvitadosService(rpc: (nombre, params) async => null);
      final res = await svc.purgarVencidos();
      expect(res.ok, isFalse);
      expect(svc.motivoUltimoPurgar, isNotNull);
      expect(svc.motivoUltimoPurgar, isNotEmpty);
    });

    test('rechazar con ok:false deja el motivo del servidor', () async {
      final svc = InvitadosService(rpc: (nombre, params) async {
        return {'ok': false, 'motivo': 'ya fue atendida'};
      });
      expect(await svc.rechazarSolicitud('x', 'duplicada'), isFalse);
      expect(svc.motivoUltimoRechazo, 'ya fue atendida');
    });
  });
}
