// JORNADA 1 · S19 — Sync: foto única, cortacircuitos de
// red hostil, idempotencia y diario persistido.
//
// El guión asigna a la superficie TEST «la lógica de
// reintento/idempotencia» y reserva la convergencia viva
// (cola drenada contra el servidor real, server_seq de la
// corrida, segundo teléfono, huella M5) a la compuerta de
// BANCO con dos dispositivos. Este archivo ejecuta esa
// lógica sin fingir la parte de banco:
//  (a) la FOTO es única: fotoEstado() —la misma que leen
//      la píldora, el héroe del Centro y la tarjeta— cuenta
//      las 3 ops sembradas, y el Centro pinta «3 por subir»
//      desde esa foto, sin decir «al día»;
//  (b) el cortacircuitos de arranque (la defensa contra la
//      red COLGADA: timeout que nunca responde) corta por
//      racha de fallos de transporte y por presupuesto, y
//      una respuesta 5xx NO reinicia la racha;
//  (c) la cola es idempotente por op_uuid: encolar dos
//      veces el mismo uuid deja UNA fila (la base de que
//      reintentar al volver la red no duplica);
//  (d) el fallo queda en el DIARIO persistido
//      (sync_corridas): una corrida cerrada con error se
//      lee desde la BD con su código y detalle — sobrevive
//      al reinicio, no vive en memoria.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/diario_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/centro_sync.dart';

import 'jornada_ayudas.dart';

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S19 · sync', () {
    testWidgets(
        'foto única: el Centro pinta «3 por subir» desde la '
        'misma foto que lee la píldora', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await LocalDb.instance.upsertMirror('clientes', 20, {
        'id': 20,
        'nombre': 'Sync Jornada',
        'estado': 'activo',
      }, 1);
      for (final (uuid, tipo) in [
        ('s19-uuid-1', 'pago_mensual'),
        ('s19-uuid-2', 'venta_servicio'),
        ('s19-uuid-3', 'gasto'),
      ]) {
        await LocalDb.instance.queueOp(
            opUuid: uuid, tipo: tipo, payload: const {});
      }
      // La foto compartida (la computa la cáscara para la
      // píldora; aquí se pide explícita, acotada).
      SyncStatus? foto;
      await tester.runAsync(() async {
        foto = await SyncEngine.instance
            .fotoEstado()
            .timeout(const Duration(seconds: 30),
                onTimeout: () => SyncEngine.instance.currentStatus);
      });
      expect(foto!.pending, 3,
          reason: 'la foto única cuenta la cola real');
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const CentroSyncScreen(),
      ));
      await jornadaEsperar(tester, find.text('3 por subir'),
          intentos: 90);
      expect(find.text('3 por subir'), findsOneWidget,
          reason: 'el héroe del Centro lee la MISMA foto: '
              'con 3 en cola no hay «al día» que valga');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'cortacircuitos de red hostil, idempotencia por '
        'op_uuid y diario persistido', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);

      // (b) Red colgada = fallos de transporte seguidos:
      // el corte salta a los 3 sin quemar el presupuesto.
      var minutos = Duration.zero;
      final corte = CorteManifiesto(
        presupuesto: const Duration(seconds: 150),
        maxFallosTransporte: 3,
        reloj: () => minutos,
      );
      corte.registrarTransporte(false);
      expect(corte.agotado, isFalse);
      corte.registrarTransporte(false);
      expect(corte.agotado, isFalse);
      corte.registrarTransporte(false);
      expect(corte.agotado, isTrue,
          reason: 'tres fallos de transporte seguidos '
              'cortan el ciclo: la red colgada no se quema '
              'tabla a tabla durante minutos');
      // Un 5xx es transporte, no respuesta (no reinicia).
      expect(huboRespuestaManifiesto(502), isFalse);
      expect(huboRespuestaManifiesto(400), isTrue);
      // Y el presupuesto manda aunque haya respuestas:
      final corteTiempo = CorteManifiesto(
        presupuesto: const Duration(seconds: 150),
        reloj: () => minutos,
      );
      minutos = const Duration(seconds: 151);
      expect(corteTiempo.agotado, isTrue);

      // (c) Idempotencia: mismo uuid dos veces = una fila.
      await LocalDb.instance.queueOp(
          opUuid: 's19-idem-1',
          tipo: 'gasto',
          payload: const {'concepto': 'Hielo', 'monto': 100});
      await LocalDb.instance.queueOp(
          opUuid: 's19-idem-1',
          tipo: 'gasto',
          payload: const {'concepto': 'Hielo', 'monto': 100});
      final ops = await jornadaOpsTodas('gasto');
      expect(ops, hasLength(1),
          reason: 'reintentar el encolado no duplica: la '
              'idempotencia por op_uuid está en la propia '
              'cola (D13)');
      expect(ops.single['op_uuid'], 's19-idem-1');

      // (d) El diario persiste el fallo nombrado.
      final corridaId = await DiarioSync.instance.abrirCorrida(
          tipo: 'completa', origen: 'jornada_s19');
      await DiarioSync.instance.cerrarCorrida(corridaId,
          estado: 'error',
          duracionMs: 4200,
          errorCodigo: 'timeout',
          errorDetalle: 'La bajada de clientes falló: '
              'el servidor no respondió');
      final historial = await DiarioSync.instance.historial();
      expect(historial, isNotEmpty);
      final ultima = historial.first;
      expect(ultima.id, corridaId);
      expect(ultima.estado, 'error');
      expect(ultima.errorCodigo, 'timeout');
      expect(ultima.errorDetalle, contains('La bajada'),
          reason: 'la pata fallida queda nombrada en '
              'español llano y persistida en la BD: '
              'sobrevive al reinicio de la app');
      await jornadaCerrarCascara(tester);
    });
  });
}
