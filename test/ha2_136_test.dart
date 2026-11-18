/// H-A2 (1.36): filas Hy4 media de pantallas/negocio —
/// 136-565, 136-632, 136-670, 136-699, 136-708, 136-709.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
/// Pruebas puras + contratos de fuente (patrón H-A1).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/ui/pestana_progreso.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _src(String p) => File(p).readAsStringSync();

Medicion _med(String idCrudo, int id, DateTime t) => Medicion(
      id: id,
      idCrudo: idCrudo,
      clienteId: '7',
      pesoKg: 80,
      registradoPor: '',
      createdAt: t,
    );

ConversionInvitado _conv({
  EstadoConversion estado = EstadoConversion.preparada,
  bool nacidaOffline = false,
}) =>
    ConversionInvitado(
      invitadoId: 'inv-1',
      conversionUuid: 'uuid-1',
      estado: estado,
      nacidaOffline: nacidaOffline,
      creadaEn: '2026-11-01T10:00:00',
      actualizadaEn: '2026-11-01T10:00:00',
    );

void main() {
  group('136-565: fusión RPC + pendientes locales de Progreso', () {
    test('la pendiente local sobrevive a la lista RPC', () {
      final rpc = [_med('10', 10, DateTime(2026, 11, 10))];
      final pend = [_med('uuid-op-1', 0, DateTime(2026, 11, 12))];
      final f = fusionarMedicionesRpcConPendientes(rpc, pend);
      expect(f.length, 2);
      expect(f.first.idCrudo, 'uuid-op-1'); // la más reciente primero
    });

    test('una pendiente ya presente en la RPC no se duplica', () {
      final rpc = [_med('10', 10, DateTime(2026, 11, 10))];
      final pend = [_med('10', 10, DateTime(2026, 11, 10))];
      expect(fusionarMedicionesRpcConPendientes(rpc, pend).length, 1);
    });

    test('_cargar fusiona solo las filas espejado=false', () {
      final s = _src('lib/ui/pestana_progreso.dart');
      expect(s, contains("if (r['espejado'] == false) r,"));
      expect(s, contains('fusionarMedicionesRpcConPendientes(lista, pendientes)'));
    });
  });

  group('136-632: getTiposPago sintetiza menores no visible', () {
    test('la síntesis mira la visibilidad, no solo la presencia', () {
      final s = _src('lib/tipos_pago.dart');
      expect(s, contains('hayMenoresVisible'));
      expect(s, contains("tipos.removeWhere((t) => t.id == 'menores')"));
    });
  });

  group('136-670: _confirmarPorIds descuenta el autoritativo', () {
    test('el setState optimista descuenta totalCup y recalcula ajuste', () {
      final s = _src('lib/ui/pendiente.dart');
      final i = s.indexOf('136-670');
      expect(i, greaterThan(0));
      final trozo = s.substring(i, i + 700);
      expect(trozo, contains('_totalAutoritativoCup! - totalCup'));
      expect(trozo, contains('_ajusteNetoCup'));
    });
  });

  group('136-699: Invitados offline — Rechazar bloqueado antes del diálogo', () {
    test('_rechazar y _cancelarConversion guardan el modo caché', () {
      final s = _src('lib/ui/invitados.dart');
      final i = s.indexOf('Future<void> _rechazar()');
      expect(s.substring(i, i + 400), contains('_offlineCache'));
      final j = s.indexOf('Future<void> _cancelarConversion()');
      expect(s.substring(j, j + 500), contains('!local.nacidaOffline'));
    });
  });

  group('136-708: reanudar offline + op aplicada sin cliente', () {
    test('preparada nacida offline se reanuda sin servidor', () {
      expect(
          reanudarPara(local: _conv(nacidaOffline: true), enServidor: null),
          ReanudarConversion.abrirInscribir);
    });

    test('preparada del servidor sin vigencia no se reanuda', () {
      expect(reaunarSeguro(), ReanudarConversion.ninguna);
    });

    test('op aplicada sin cliente_id es revisión/error, no espera', () {
      expect(
          accionParaConversion(
              conv: _conv(estado: EstadoConversion.opEncolada),
              opEstado: 'aplicada',
              opResultado: const {'ok': true}),
          AccionConversion.opAplicadaSinCliente);
    });

    test('op aplicada con cliente_id confirma en servidor', () {
      expect(
          accionParaConversion(
              conv: _conv(estado: EstadoConversion.opEncolada),
              opEstado: 'aplicada',
              opResultado: const {'cliente_id': 42}),
          AccionConversion.confirmarEnServidor);
    });
  });

  group('136-709: huella de lote y error transporte/servidor', () {
    test('la huella ordena y deduplica los ids', () {
      final s = _src('lib/invitados.dart');
      expect(s, contains('ids.toSet().toList()..sort()'));
    });

    test('PostgrestException es error de servidor, no transporte', () {
      expect(
          esErrorTransporteInvitado(
              PostgrestException(message: 'boom', code: 'P0001')),
          isFalse);
    });

    test('InvitadoError de dominio no es transporte', () {
      expect(
          esErrorTransporteInvitado(
              const InvitadoError('SOLO_DUENO', 'solo dueño')),
          isFalse);
    });

    test('respuesta inesperada no es transporte', () {
      expect(
          esErrorTransporteInvitado(const InvitadoError(
              'RED', 'Respuesta inesperada del servidor.')),
          isFalse);
    });

    test('RED genérico y excepciones de red sí son transporte', () {
      expect(
          esErrorTransporteInvitado(
              const InvitadoError('RED', 'Sin conexión o error del servidor.')),
          isTrue);
      expect(esErrorTransporteInvitado(Exception('socket cerrado')), isTrue);
    });

    test('prepararConversion valida el uuid antes de guardar', () {
      final s = _src('lib/invitados.dart');
      final i = s.indexOf('Future<DatosConversionInvitado> prepararConversion(');
      final trozo = s.substring(i, i + 1600);
      expect(trozo, contains("conversion_uuid'] ?? ''}'.trim().isEmpty"));
      expect(trozo.indexOf("trim().isEmpty"),
          lessThan(trozo.indexOf('ConversionInvitadoStore().guardar')));
    });
  });
}

ReanudarConversion reaunarSeguro() =>
    reanudarPara(local: _conv(), enServidor: null);
