/// H-C2 (1.36) G4 Turnos/nómina/admin — 136-792,
/// 136-814, 136-847.
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
/// (filas PARCIALES: solo la parte confirmada).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/cierre_mes.dart';
import 'package:ironbody_gym/tarifa_especial.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';

void main() {
  group('136-792 la correspondencia cierre↔apertura casa por día', () {
    test('fecha del cierre con hora corresponde a la apertura del día',
        () {
      final cierre = <String, dynamic>{
        'fecha': '2026-11-18T23:40:00',
        'turno': 'tarde',
        'telegram_id': 111,
      };
      final apertura = <String, dynamic>{
        'fecha_turno': '2026-11-18',
        'turno': 'tarde',
        'telegram_id': 111,
      };
      expect(cierreCorrespondeApertura(cierre, apertura), isTrue);
    });

    test('otro día no corresponde', () {
      final cierre = <String, dynamic>{
        'fecha': '2026-11-19T01:10:00',
        'turno': 'tarde',
        'telegram_id': 111,
      };
      final apertura = <String, dynamic>{
        'fecha_turno': '2026-11-18',
        'turno': 'tarde',
        'telegram_id': 111,
      };
      expect(cierreCorrespondeApertura(cierre, apertura), isFalse);
    });

    test('fechaDiaTurno normaliza y deja pasar lo ilegible tal cual',
        () {
      expect(fechaDiaTurno('2026-11-18T23:40:00'), '2026-11-18');
      expect(fechaDiaTurno('2026-11-18'), '2026-11-18');
      expect(fechaDiaTurno('ayer'), 'ayer');
      expect(fechaDiaTurno(null), '');
    });
  });

  group('136-814 pasoNoComprobadoCierre', () {
    test('el paso fallido es no verificable y no verificado', () {
      final p = pasoNoComprobadoCierre('sync', 'Sincronización al día',
          destinoId: 'sync');
      expect(p.verificado, isFalse);
      expect(p.noVerificable, isTrue);
      expect(p.estadoPaso, EstadoPasoCierre.noVerificable);
      expect(p.bloqueos, isNotEmpty);
    });
  });

  group('136-847 estadoRevisionTarifa parsea el sello', () {
    test('sello con offset se convierte a su día de La Habana', () {
      // 2026-11-25T01:30+03:00 = 2026-11-24 17:30 en La
      // Habana: el día de negocio es el 24, no el 25.
      final fila = <String, dynamic>{
        'vigente_hasta': '2026-11-25T01:30:00+03:00',
      };
      // Hoy 2026-11-18: faltan 6 días para el 24 → por vencer.
      expect(estadoRevisionTarifa(fila, '2026-11-18'), 'por_vencer');
      // Hoy 2026-11-25: el día Habana (24) ya pasó → vencida.
      expect(estadoRevisionTarifa(fila, '2026-11-25'), 'vencida');
    });

    test('sello no-texto o ilegible → sin_fecha, sin lanzar', () {
      expect(
          estadoRevisionTarifa(
              <String, dynamic>{'vigente_hasta': 20261125}, '2026-11-18'),
          'sin_fecha');
      expect(
          estadoRevisionTarifa(
              <String, dynamic>{'vigente_hasta': 'pronto'}, '2026-11-18'),
          'sin_fecha');
    });

    test('fecha sola sigue comparando como antes', () {
      expect(
          estadoRevisionTarifa(
              <String, dynamic>{'vigente_hasta': '2026-11-30'},
              '2026-11-18'),
          'vigente');
    });
  });
}
