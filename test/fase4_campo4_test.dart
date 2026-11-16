/// 1.35 (CAMPO-4 + M-6) — el icono de sync de la cabecera.
///
/// La función pura replica la precedencia honesta de la
/// píldora (SYNC-12): el error manda; sincronizando gira;
/// los pendientes llevan su cifra; el aviso persistido
/// manda sobre el verde; sin lectura hecha, neutro «sin
/// verificar» — jamás un verde falso.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/widgets.dart';

SyncStatus _estado({
  SyncPhase phase = SyncPhase.idle,
  int pending = 0,
  bool? hayNovedades = false,
  String? aviso,
  DateTime? avisoTs,
  DateTime? ultimoOk,
}) {
  return SyncStatus(
    phase: phase,
    pending: pending,
    hayNovedades: hayNovedades,
    avisoSyncCorto: aviso,
    avisoSyncTs: avisoTs,
    ultimoSincronizado: ultimoOk,
  );
}

void main() {
  final ahora = DateTime(2026, 11, 15, 12, 0);

  group('estadoSyncCabecera', () {
    test('al día verificado: check verde con su hace', () {
      final e = estadoSyncCabecera(
          _estado(ultimoOk: ahora.subtract(const Duration(minutes: 5))),
          ahora: ahora);
      expect(e.icono, Icons.check_circle_outline_rounded);
      expect(e.color, AppColores.exito);
      expect(e.texto, 'Al día · hace 5 min');
      expect(e.pendientes, 0);
    });

    test('sin verificar: neutro, nunca verde falso', () {
      final e = estadoSyncCabecera(_estado(hayNovedades: null),
          ahora: ahora);
      expect(e.icono, Icons.help_outline_rounded);
      expect(e.color, isNot(AppColores.exito));
      expect(e.texto, contains('sin verificar'));
    });

    test('pendientes: reloj ámbar con la cifra', () {
      final e =
          estadoSyncCabecera(_estado(pending: 4), ahora: ahora);
      expect(e.icono, Icons.schedule_rounded);
      expect(e.color, AppColores.alerta);
      expect(e.texto, '4 por subir');
      expect(e.pendientes, 4);
    });

    test('el aviso persistido manda sobre el verde', () {
      final e = estadoSyncCabecera(
          _estado(
            aviso: 'Falló la sincronización',
            avisoTs: ahora.subtract(const Duration(minutes: 1)),
            ultimoOk: ahora.subtract(const Duration(minutes: 5)),
          ),
          ahora: ahora);
      expect(e.icono, Icons.sync_problem_rounded);
      expect(e.color, AppColores.alerta);
      expect(e.texto, 'Falló la sincronización · hace 1 min');
    });

    test('error de fase manda sobre todo', () {
      final e = estadoSyncCabecera(
          _estado(phase: SyncPhase.error, pending: 3),
          ahora: ahora);
      expect(e.icono, Icons.error_outline_rounded);
      expect(e.color, AppColores.error);
    });

    test('sincronizando: el glifo que gira', () {
      final e = estadoSyncCabecera(
          _estado(phase: SyncPhase.downloading, pending: 2),
          ahora: ahora);
      expect(e.icono, Icons.sync_rounded);
      expect(e.texto, 'Sincronizando…');
      expect(e.pendientes, 2);
    });
  });
}
