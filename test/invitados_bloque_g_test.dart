// Tests del Bloque G de Invitados (v1.5.0):
// - Validación de fecha del carnet (decisión de Jc 2026-10-22):
//   avisa SIN bloquear solo si hay 6+ dígitos y no forman una
//   fecha AAMMDD real; la fuente de verdad es fechaNacDeCarnet.
// - Mapeo del resultado de medidas de la op `inscribir` (Bloque B).
// - Máquina de estados local de la conversión + reanudación
//   durable («Reanudar inscripción» tras cerrar la app a mitad).
// - Ronda de corrección del panel (G1–G6): durabilidad atómica
//   registro/op, confirmación automática tras sync, lock vencido,
//   eliminar bloqueado, fechas en hora de La Habana y teléfonos
//   de información pública normalizados.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('carnetFechaInvalida (aviso sin bloquear)', () {
    test('«122303» (mes 23, día/mes invertidos) AVISA', () {
      expect(carnetFechaInvalida('122303'), isTrue);
    });

    test('«120323» (12 = 2012, 03 marzo, 23) no avisa', () {
      expect(carnetFechaInvalida('120323'), isFalse);
    });

    test('vacío o corto no avisa ni bloquea', () {
      expect(carnetFechaInvalida(''), isFalse);
      expect(carnetFechaInvalida(null), isFalse);
      expect(carnetFechaInvalida('123'), isFalse);
      expect(carnetFechaInvalida('12345'), isFalse);
    });

    test('fecha imposible de calendario avisa (31 de febrero)', () {
      expect(carnetFechaInvalida('990231'), isTrue);
      // 29/02/2001: 2001 no es bisiesto.
      expect(carnetFechaInvalida('010229'), isTrue);
    });

    test('29/02/2000 (bisiesto) no avisa', () {
      expect(carnetFechaInvalida('000229'), isFalse);
    });

    test('carnet completo de 11 dígitos se juzga por sus 6 primeros',
        () {
      expect(carnetFechaInvalida('95031012345'), isFalse);
      expect(carnetFechaInvalida('95131012345'), isTrue); // mes 13
    });

    test('ignora caracteres no numéricos como el resto de la casa',
        () {
      expect(carnetFechaInvalida('12-23-03'), isTrue);
      expect(carnetFechaInvalida('12 03 23'), isFalse);
    });
  });

  group('resultadoMedidasDeOp (mapeo del resultado de la op)', () {
    test('verificadas: importa conteos y compone el texto', () {
      final r = resultadoMedidasDeOp({
        'cliente_id': 42,
        'medidas_invitado': {
          'estado': 'verificadas',
          'importadas': 2,
          'duplicadas': 1,
          'descartadas': 0,
        },
      });
      expect(r, isNotNull);
      expect(r!.verificadas, isTrue);
      expect(r.importadas, 2);
      expect(r.duplicadas, 1);
      expect(r.texto, contains('2 importada(s)'));
      expect(r.texto, contains('1 ya existían'));
    });

    test('acepta el resultado envuelto en «resultado» (pull)', () {
      final r = resultadoMedidasDeOp({
        'resultado': {
          'cliente_id': 7,
          'medidas_invitado': {
            'estado': 'verificadas',
            'importadas': 3,
            'duplicadas': 0,
            'descartadas': 1,
          },
        },
      });
      expect(r, isNotNull);
      expect(r!.importadas, 3);
      expect(r.texto, contains('1 descartada(s)'));
    });

    test('no_verificadas: texto claro con el motivo legible', () {
      final r = resultadoMedidasDeOp({
        'cliente_id': 9,
        'medidas_invitado': {
          'estado': 'no_verificadas',
          'importadas': 0,
          'duplicadas': 0,
          'descartadas': 4,
          'motivo': 'consulta_fallida',
        },
      });
      expect(r, isNotNull);
      expect(r!.verificadas, isFalse);
      expect(r.texto, contains('NO se importaron'));
      expect(r.texto, contains('no se pudo consultar'));
    });

    test('sin medidas en el resultado → null (inscripción normal)',
        () {
      expect(resultadoMedidasDeOp({'cliente_id': 3}), isNull);
      expect(resultadoMedidasDeOp(null), isNull);
      expect(resultadoMedidasDeOp('basura'), isNull);
    });

    test('roundtrip JSON del resumen (persistencia en meta)', () {
      const r = ResultadoMedidasInvitado(
        estado: 'no_verificadas',
        importadas: 0,
        duplicadas: 0,
        descartadas: 2,
        motivo: 'conversion_otro_cliente',
      );
      final vuelta = ResultadoMedidasInvitado.fromJson(r.toJson());
      expect(vuelta.estado, r.estado);
      expect(vuelta.descartadas, 2);
      expect(vuelta.motivo, 'conversion_otro_cliente');
      expect(vuelta.texto, contains('otro cliente'));
    });
  });

  group('payload de medidas y carnet sugerido', () {
    test('MedidaInvitado.aPayload usa origen_medicion_id y omite nulos',
        () {
      const m = MedidaInvitado(
        id: 'med-uuid-1',
        fecha: '2026-10-01',
        pesoKg: 82.5,
        cinturaCm: 90,
      );
      final p = m.aPayload();
      expect(p['origen_medicion_id'], 'med-uuid-1');
      expect(p['fecha'], '2026-10-01');
      expect(p['peso_kg'], 82.5);
      expect(p['cintura_cm'], 90.0);
      expect(p.containsKey('grasa_pct'), isFalse);
      expect(p.containsKey('notas'), isFalse);
    });

    test('carnetDesdeFechaNac deriva AAMMDD', () {
      expect(carnetDesdeFechaNac('1995-10-20'), '951020');
      expect(carnetDesdeFechaNac('2000-02-29'), '000229');
      expect(carnetDesdeFechaNac(null), isNull);
      expect(carnetDesdeFechaNac(''), isNull);
      expect(carnetDesdeFechaNac('no-es-fecha'), isNull);
    });

    test('Ronda 17 M5-H1: desborde de fecha no se normaliza', () {
      // 30-feb no existe: antes DateTime lo corría a 2-mar y
      // el carnet salía 230302; ahora es null.
      expect(carnetDesdeFechaNac('2023-02-30'), isNull);
      expect(carnetDesdeFechaNac('2023-02-29'), isNull);
      expect(carnetDesdeFechaNac('2023-13-01'), isNull);
      expect(carnetDesdeFechaNac('2024-02-29'), '240229');
    });

    test('Ronda 17 M5-H1: validarCarnetInvitado11', () {
      expect(validarCarnetInvitado11('95102012345'), isTrue);
      expect(validarCarnetInvitado11('00022912345'), isTrue);
      // Fecha imposible en los primeros 6 (mes 23, 30-feb).
      expect(validarCarnetInvitado11('12230312345'), isFalse);
      expect(validarCarnetInvitado11('23023012345'), isFalse);
      // Formato: no son 11 dígitos.
      expect(validarCarnetInvitado11('9510201234'), isFalse);
      expect(validarCarnetInvitado11('951020123456'), isFalse);
      expect(validarCarnetInvitado11(null), isFalse);
      expect(validarCarnetInvitado11(''), isFalse);
    });

    test('el carnet sugerido de una fecha real NO dispara el aviso',
        () {
      expect(carnetFechaInvalida(carnetDesdeFechaNac('2012-03-23')),
          isFalse);
    });
  });

  group('modelos de las RPC (formas reales de producción)', () {
    test('InvitadoResumen.fromJson', () {
      final r = InvitadoResumen.fromJson({
        'id': 'inv-1',
        'nombre': 'Ana Barbara Duran',
        'telefono': '53112233',
        'telefono_verificado': false,
        'estado': 'activo',
        'creado_en': '2026-10-20T10:00:00-04:00',
        'caduca_en': '2027-01-18T10:00:00-04:00',
        'dias_restantes': 3,
        'tiene_solicitud_pendiente': true,
        'solicitud_desde': '2026-10-21T09:00:00-04:00',
        'convertido_en': null,
        'cliente_id': null,
      });
      expect(r.nombre, 'Ana Barbara Duran');
      expect(r.tieneSolicitudPendiente, isTrue);
      expect(r.caducaPronto, isTrue);
      expect(r.convertido, isFalse);
    });

    test('InvitadoDetalle.fromJson con medidas y conversión', () {
      final d = InvitadoDetalle.fromJson({
        'ok': true,
        'invitado': {
          'id': 'inv-1',
          'nombre': 'Ana',
          'telefono': '53112233',
          'telefono_verificado': false,
          'fecha_nac': '2012-03-23',
          'estado': 'en_conversion',
          'creado_en': '2026-10-20T10:00:00-04:00',
          'caduca_en': '2027-01-18T10:00:00-04:00',
          'caducado': false,
          'convertido_en': null,
          'cliente_id': null,
        },
        'ultima_sync': '2026-10-22T08:30:00-04:00',
        'mediciones_sincronizadas': 1,
        'mediciones': [
          {
            'id': 'med-1',
            'fecha': '2026-10-21',
            'peso_kg': 55.0,
            'grasa_pct': null,
            'pecho_cm': null,
            'brazo_cm': 24.0,
            'cintura_cm': null,
            'cadera_cm': null,
            'muslo_cm': null,
            'notas': null,
            'actualizado_en': '2026-10-22T08:30:00-04:00',
          },
        ],
        'solicitud': {
          'estado': 'pendiente',
          'creada_en': '2026-10-21T09:00:00-04:00',
          'atendida_en': null,
          'atendido_por': null,
          'resultado': null,
        },
        'conversion_preparada': {
          'conversion_uuid': 'conv-1',
          'preparada_por': 'gabriel@ironbody.gym',
          'preparada_en': '2026-10-22T09:00:00-04:00',
          'expira_lock_en': '2026-10-22T09:15:00-04:00',
          'lock_vigente': true,
        },
      });
      expect(d.medicionesSincronizadas, 1);
      expect(d.mediciones.single.pesoKg, 55.0);
      expect(d.solicitud!.pendiente, isTrue);
      expect(d.conversionPreparada!.lockVigente, isTrue);
      expect(d.ultimaSync, isNotNull);
    });
  });

  ConversionInvitado conv(EstadoConversion e,
          {String? opUuid}) =>
      ConversionInvitado(
        invitadoId: 'inv-1',
        conversionUuid: 'conv-1',
        estado: e,
        opUuid: opUuid,
        creadaEn: '2026-10-22T09:00:00-04:00',
        actualizadaEn: '2026-10-22T09:00:00-04:00',
      );

  InvitadoDetalle detalleTest({
    ConversionServidor? conversion,
    String estado = 'en_conversion',
  }) =>
      InvitadoDetalle(
        id: 'inv-1',
        nombre: 'Ana',
        telefono: '53112233',
        estado: estado,
        conversionPreparada: conversion,
      );

  group('máquina de estados: accionParaConversion', () {
    test('confirmada → yaConfirmada, sin tocar nada más', () {
      expect(
          accionParaConversion(
              conv: conv(EstadoConversion.confirmada),
              opEstado: 'aplicada',
              opResultado: {'cliente_id': 5}),
          AccionConversion.yaConfirmada);
    });

    test('preparada o cancelada → ninguna (aún no hay op)', () {
      for (final e in [
        EstadoConversion.preparada,
        EstadoConversion.cancelada,
      ]) {
        expect(
            accionParaConversion(
                conv: conv(e), opEstado: null, opResultado: null),
            AccionConversion.ninguna);
      }
    });

    test('opEncolada + op aplicada con cliente_id → confirmar', () {
      expect(
          accionParaConversion(
              conv: conv(EstadoConversion.opEncolada, opUuid: 'op-1'),
              opEstado: 'aplicada',
              opResultado: {'cliente_id': 42}),
          AccionConversion.confirmarEnServidor);
    });

    test('opEncolada + op aplicada SIN cliente_id → esperar', () {
      expect(
          accionParaConversion(
              conv: conv(EstadoConversion.opEncolada, opUuid: 'op-1'),
              opEstado: 'aplicada',
              opResultado: {'pagado_hasta': '2026-11-22'}),
          AccionConversion.ninguna);
    });

    test('opEncolada + op rechazada → marcarOpRechazada', () {
      expect(
          accionParaConversion(
              conv: conv(EstadoConversion.opEncolada, opUuid: 'op-1'),
              opEstado: 'rechazada',
              opResultado: null),
          AccionConversion.marcarOpRechazada);
    });

    test('opEncolada + op en vuelo → ninguna (esperar al pull)', () {
      for (final est in ['pendiente', 'enviada', 'error', null]) {
        expect(
            accionParaConversion(
                conv: conv(EstadoConversion.opEncolada, opUuid: 'op-1'),
                opEstado: est,
                opResultado: null),
            AccionConversion.ninguna);
      }
    });
  });

  group('máquina de estados: reanudarPara («Reanudar inscripción»)', () {
    test('preparada local + vigente en el servidor → '
        'abrirInscribir (mismo uuid durable)', () {
      expect(
          reanudarPara(
              local: conv(EstadoConversion.preparada),
              enServidor: const ConversionServidor(
                  conversionUuid: 'conv-1', lockVigente: true)),
          ReanudarConversion.abrirInscribir);
    });

    test('G3: preparada con lock vencido, preparación ajena o '
        'sin preparación en el servidor → ninguna (no se reanuda '
        'con un uuid muerto)', () {
      final local = conv(EstadoConversion.preparada);
      expect(reanudarPara(local: local, enServidor: null),
          ReanudarConversion.ninguna);
      expect(
          reanudarPara(
              local: local,
              enServidor: const ConversionServidor(
                  conversionUuid: 'conv-1', lockVigente: false)),
          ReanudarConversion.ninguna);
      expect(
          reanudarPara(
              local: local,
              enServidor: const ConversionServidor(
                  conversionUuid: 'conv-OTRA', lockVigente: true)),
          ReanudarConversion.ninguna);
    });

    test('opEncolada → esperandoSync', () {
      expect(
          reanudarPara(
              local: conv(EstadoConversion.opEncolada, opUuid: 'op-1'),
              enServidor: null),
          ReanudarConversion.esperandoSync);
    });

    test('confirmada → verResultado; rechazada → revisarFallo', () {
      expect(
          reanudarPara(
              local: conv(EstadoConversion.confirmada),
              enServidor: null),
          ReanudarConversion.verResultado);
      expect(
          reanudarPara(
              local: conv(EstadoConversion.opRechazada),
              enServidor: null),
          ReanudarConversion.revisarFallo);
    });

    test('cancelada o sin registro → ninguna', () {
      expect(
          reanudarPara(
              local: conv(EstadoConversion.cancelada),
              enServidor: null),
          ReanudarConversion.ninguna);
      // Preparada en el servidor pero de OTRO teléfono: no se
      // reanuda desde aquí (Convertir dará CONVERSION_EN_CURSO).
      expect(
          reanudarPara(
              local: null,
              enServidor: const ConversionServidor(
                  conversionUuid: 'conv-x', lockVigente: true)),
          ReanudarConversion.ninguna);
    });

    test('la reanudación sobrevive al cierre: JSON roundtrip', () {
      final original = conv(EstadoConversion.preparada);
      final restaurada = ConversionInvitado.fromJson(original.toJson());
      expect(restaurada.conversionUuid, 'conv-1');
      expect(restaurada.estado, EstadoConversion.preparada);
      expect(
          reanudarPara(
              local: restaurada,
              enServidor: const ConversionServidor(
                  conversionUuid: 'conv-1', lockVigente: true)),
          ReanudarConversion.abrirInscribir);
    });

    test('roundtrip con op encolada y resultado de medidas', () {
      final original = ConversionInvitado(
        invitadoId: 'inv-1',
        conversionUuid: 'conv-1',
        estado: EstadoConversion.confirmada,
        opUuid: 'op-1',
        clienteId: 42,
        resultadoMedidas: const ResultadoMedidasInvitado(
            estado: 'verificadas', importadas: 2),
        creadaEn: '2026-10-22T09:00:00-04:00',
        actualizadaEn: '2026-10-22T09:05:00-04:00',
      );
      final restaurada = ConversionInvitado.fromJson(original.toJson());
      expect(restaurada.clienteId, 42);
      expect(restaurada.resultadoMedidas!.importadas, 2);
      expect(
          reanudarPara(local: restaurada, enServidor: null),
          ReanudarConversion.verResultado);
    });
  });

  group('G3: vigenciaPreparada (lock de 15 min contrastado)', () {
    final local = conv(EstadoConversion.preparada);

    test('mismo uuid + lock vigente → vigente', () {
      expect(
          vigenciaPreparada(
              local,
              const ConversionServidor(
                  conversionUuid: 'conv-1', lockVigente: true)),
          VigenciaConversionPreparada.vigente);
    });

    test('mismo uuid + lock vencido → vencida', () {
      expect(
          vigenciaPreparada(
              local,
              const ConversionServidor(
                  conversionUuid: 'conv-1', lockVigente: false)),
          VigenciaConversionPreparada.vencida);
    });

    test('otro uuid en el servidor → ajena', () {
      expect(
          vigenciaPreparada(
              local,
              const ConversionServidor(
                  conversionUuid: 'conv-2', lockVigente: true)),
          VigenciaConversionPreparada.ajena);
    });

    test('sin preparación en el servidor → ausente', () {
      expect(vigenciaPreparada(local, null),
          VigenciaConversionPreparada.ausente);
    });
  });

  group('G1(b): conversionAdoptableDesdeDetalle (adopción)', () {
    ConversionServidor srv(
            {String por = 'gabriel@ironbody.gym',
            bool vigente = true}) =>
        ConversionServidor(
          conversionUuid: 'conv-srv',
          preparadaPor: por,
          preparadaEn: DateTime.utc(2026, 10, 22, 13, 0),
          lockVigente: vigente,
        );

    test('la adopta si la preparó el usuario actual (email alias)',
        () {
      final c = conversionAdoptableDesdeDetalle(
        detalle: detalleTest(conversion: srv()),
        usuarioActual: 'gabriel',
      );
      expect(c, isNotNull);
      expect(c!.estado, EstadoConversion.preparada);
      expect(c.conversionUuid, 'conv-srv');
      expect(c.invitadoId, 'inv-1');
    });

    test('acepta preparada_por como usuario pelado y mayúsculas',
        () {
      final c = conversionAdoptableDesdeDetalle(
        detalle: detalleTest(conversion: srv(por: 'Gabriel')),
        usuarioActual: 'gabriel',
      );
      expect(c, isNotNull);
    });

    test('NO adopta la preparación de otro entrenador', () {
      expect(
          conversionAdoptableDesdeDetalle(
            detalle:
                detalleTest(conversion: srv(por: 'duany@ironbody.gym')),
            usuarioActual: 'gabriel',
          ),
          isNull);
    });

    test('NO adopta con el lock vencido ni sin conversión ni '
        'ya convertido', () {
      expect(
          conversionAdoptableDesdeDetalle(
            detalle: detalleTest(conversion: srv(vigente: false)),
            usuarioActual: 'gabriel',
          ),
          isNull);
      expect(
          conversionAdoptableDesdeDetalle(
            detalle: detalleTest(),
            usuarioActual: 'gabriel',
          ),
          isNull);
      expect(
          conversionAdoptableDesdeDetalle(
            detalle: detalleTest(
                conversion: srv(), estado: 'convertido'),
            usuarioActual: 'gabriel',
          ),
          isNull);
    });
  });

  group('G4: eliminarInvitadoBloqueado', () {
    test('bloquea con registro local activo', () {
      for (final e in [
        EstadoConversion.preparada,
        EstadoConversion.opEncolada,
      ]) {
        expect(
            eliminarInvitadoBloqueado(
                local: conv(e, opUuid: 'op-1'), enServidor: null),
            isTrue);
      }
    });

    test('bloquea con preparación vigente en el servidor', () {
      expect(
          eliminarInvitadoBloqueado(
              local: null,
              enServidor: const ConversionServidor(
                  conversionUuid: 'conv-x', lockVigente: true)),
          isTrue);
    });

    test('permite sin conversión activa (resuelta, vencida o '
        'ausente)', () {
      expect(
          eliminarInvitadoBloqueado(
              local: conv(EstadoConversion.cancelada),
              enServidor: null),
          isFalse);
      expect(
          eliminarInvitadoBloqueado(
              local: conv(EstadoConversion.opRechazada),
              enServidor: const ConversionServidor(
                  conversionUuid: 'conv-x', lockVigente: false)),
          isFalse);
      expect(
          eliminarInvitadoBloqueado(local: null, enServidor: null),
          isFalse);
    });
  });

  group('G5: instanteServidorHabana (hora de La Habana, no la '
      'del teléfono)', () {
    test('UTC de verano → -4 (CDT), sin bandera UTC', () {
      final d = instanteServidorHabana('2026-10-22T13:00:00Z');
      expect(d, isNotNull);
      expect(d!.isUtc, isFalse);
      expect(d.year, 2026);
      expect(d.month, 10);
      expect(d.day, 22);
      expect(d.hour, 9);
      expect(d.minute, 0);
    });

    test('UTC de invierno → -5 (CST)', () {
      final d = instanteServidorHabana('2026-01-15T13:00:00Z');
      expect(d!.day, 15);
      expect(d.hour, 8);
    });

    test('un instante UTC de madrugada es la noche anterior en '
        'La Habana', () {
      final d = instanteServidorHabana('2026-10-22T01:30:00Z');
      expect(d!.day, 21);
      expect(d.hour, 21);
      expect(d.minute, 30);
    });

    test('acepta offset explícito y devuelve lo mismo', () {
      final d = instanteServidorHabana('2026-10-22T09:00:00-04:00');
      expect(d!.day, 22);
      expect(d.hour, 9);
    });

    test('inválido, vacío o nulo → null', () {
      expect(instanteServidorHabana('no-es-fecha'), isNull);
      expect(instanteServidorHabana(''), isNull);
      expect(instanteServidorHabana(null), isNull);
      expect(instanteServidorHabana(42), isNull);
    });

    test('los modelos de la bandeja ya nacen en hora habanera',
        () {
      final r = InvitadoResumen.fromJson({
        'id': 'inv-1',
        'nombre': 'Ana',
        'telefono': '53112233',
        'estado': 'activo',
        'creado_en': '2026-10-22T13:00:00Z',
        'dias_restantes': 90,
      });
      expect(r.creadoEn!.hour, 9);
    });
  });

  group('G6: teléfonos de información pública', () {
    test('normaliza «+53 5819 1577» → 58191577', () {
      expect(normalizarTelefonoInfoPublica('+53 5819 1577'),
          '58191577');
      expect(normalizarTelefonoInfoPublica('58191577'), '58191577');
      expect(normalizarTelefonoInfoPublica('53 58191577'),
          '58191577');
      expect(normalizarTelefonoInfoPublica('(5819) 15-77'),
          '58191577');
    });

    test('7 dígitos (o cualquier otra longitud) → null', () {
      expect(normalizarTelefonoInfoPublica('5819157'), isNull);
      expect(normalizarTelefonoInfoPublica('581915777'), isNull);
      expect(normalizarTelefonoInfoPublica(''), isNull);
      expect(normalizarTelefonoInfoPublica('sin numeros'), isNull);
    });

    test('validarValorInfoPublica: aviso solo en claves de '
        'teléfono con valor presente e inválido', () {
      expect(validarValorInfoPublica('whatsapp_dueno', '5819157'),
          isNotNull);
      expect(
          validarValorInfoPublica('whatsapp_dueno', '+53 5819 1577'),
          isNull);
      // Vacío = borrar la clave: válido.
      expect(validarValorInfoPublica('whatsapp_dueno', ''), isNull);
      // Texto libre: cualquier cosa vale.
      expect(
          validarValorInfoPublica('horario_texto', 'cuando sea'),
          isNull);
      expect(validarValorInfoPublica('precio_diario', '300'),
          isNull);
    });

    test('valorAGuardarInfoPublica normaliza teléfonos y deja '
        'el texto libre tal cual', () {
      expect(
          valorAGuardarInfoPublica(
              'whatsapp_entrenador_duany', '+53 5819 1577'),
          '58191577');
      expect(
          valorAGuardarInfoPublica('ubicacion_texto', '  Calle 1 '),
          'Calle 1');
      expect(esClaveTelefonoInfoPublica('whatsapp_dueno'), isTrue);
      expect(esClaveTelefonoInfoPublica('instagram_usuario'),
          isFalse);
    });
  });

  group('G1(b): reconstruccionDesdeOps (función pura)', () {
    Map<String, dynamic> filaOp({
      required String opUuid,
      String invitadoId = 'inv-1',
      String? conversionUuid = 'conv-1',
      String creadaTs = '2026-10-22T09:00:00-04:00',
      bool conIds = true,
    }) =>
        {
          'op_uuid': opUuid,
          'tipo': 'inscribir',
          'payload': jsonEncode({
            'nombre': 'Ana',
            if (conIds) 'invitado_id': invitadoId,
            if (conIds && conversionUuid != null)
              'conversion_uuid': conversionUuid,
          }),
          'estado': 'pendiente',
          'creada_ts': creadaTs,
        };

    test('sin registro: crea opEncolada con el uuid de la op', () {
      final res = reconstruccionDesdeOps(
        ops: [filaOp(opUuid: 'op-1')],
        existentes: const [],
      );
      expect(res, hasLength(1));
      expect(res.single.estado, EstadoConversion.opEncolada);
      expect(res.single.opUuid, 'op-1');
      expect(res.single.conversionUuid, 'conv-1');
      expect(res.single.invitadoId, 'inv-1');
    });

    test('ignora ops sin ids de conversión y payloads corruptos',
        () {
      final res = reconstruccionDesdeOps(
        ops: [
          filaOp(opUuid: 'op-x', conIds: false),
          {
            'op_uuid': 'op-y',
            'tipo': 'inscribir',
            'payload': '{json roto',
            'estado': 'pendiente',
            'creada_ts': '2026-10-22T09:00:00-04:00',
          },
        ],
        existentes: const [],
      );
      expect(res, isEmpty);
    });

    test('registro preparada con el mismo uuid → opEncolada', () {
      final res = reconstruccionDesdeOps(
        ops: [filaOp(opUuid: 'op-1')],
        existentes: [conv(EstadoConversion.preparada)],
      );
      expect(res, hasLength(1));
      expect(res.single.estado, EstadoConversion.opEncolada);
      expect(res.single.opUuid, 'op-1');
    });

    test('con varias ops del invitado manda la última', () {
      final res = reconstruccionDesdeOps(
        ops: [
          filaOp(
              opUuid: 'op-vieja',
              conversionUuid: 'conv-vieja',
              creadaTs: '2026-10-22T08:00:00-04:00'),
          filaOp(
              opUuid: 'op-nueva',
              conversionUuid: 'conv-1',
              creadaTs: '2026-10-22T09:00:00-04:00'),
        ],
        existentes: const [],
      );
      expect(res, hasLength(1));
      expect(res.single.opUuid, 'op-nueva');
    });

    test('registro resuelto con otro uuid: sigue a la op nueva; '
        'registro activo con otro uuid: no se toca', () {
      final res = reconstruccionDesdeOps(
        ops: [filaOp(opUuid: 'op-2', conversionUuid: 'conv-2')],
        existentes: [conv(EstadoConversion.cancelada)],
      );
      expect(res, hasLength(1));
      expect(res.single.conversionUuid, 'conv-2');
      expect(res.single.estado, EstadoConversion.opEncolada);

      final res2 = reconstruccionDesdeOps(
        ops: [filaOp(opUuid: 'op-2', conversionUuid: 'conv-2')],
        existentes: [conv(EstadoConversion.opEncolada, opUuid: 'op-1')],
      );
      expect(res2, isEmpty);
    });
  });

  group('durabilidad de la conversión (BD ffi + RPC falsa)', () {
    setUp(() async {
      await _abrirBdLimpia();
    });

    test('G1(a): el registro opEncolada con el uuid de la op se '
        'persiste ANTES de encolar la op', () async {
      ConversionInvitado? vistaAlEncolar;
      await encolarInscripcionConversion(
        invitadoId: 'inv-1',
        conversionUuid: 'conv-1',
        opUuid: 'op-1',
        encolar: (uuid) async {
          // En el momento de encolar, el registro YA debe estar
          // persistido con este mismo uuid.
          vistaAlEncolar =
              await ConversionInvitadoStore().leer('inv-1');
          await LocalDb.instance.queueOp(
            opUuid: uuid,
            tipo: 'inscribir',
            payload: const {
              'nombre': 'Ana',
              'invitado_id': 'inv-1',
              'conversion_uuid': 'conv-1',
            },
          );
        },
      );
      expect(vistaAlEncolar, isNotNull);
      expect(vistaAlEncolar!.estado, EstadoConversion.opEncolada);
      expect(vistaAlEncolar!.opUuid, 'op-1');
      final ops = await LocalDb.instance.opsPorUuids(['op-1']);
      expect(ops, hasLength(1));
      expect(
          (await ConversionInvitadoStore().leer('inv-1'))!.estado,
          EstadoConversion.opEncolada);
    });

    test('G1(a): muerte entre persistir y encolar → la '
        'verificación devuelve el registro a preparada', () async {
      var murio = false;
      try {
        await encolarInscripcionConversion(
          invitadoId: 'inv-1',
          conversionUuid: 'conv-1',
          opUuid: 'op-fantasma',
          encolar: (_) async =>
              throw StateError('muerte simulada de la app'),
        );
      } on StateError {
        murio = true;
      }
      expect(murio, isTrue);
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      await svc.verificarConversiones();
      final despues = await ConversionInvitadoStore().leer('inv-1');
      expect(despues, isNotNull);
      expect(despues!.estado, EstadoConversion.preparada);
      expect(despues.opUuid, isNull);
      expect(despues.conversionUuid, 'conv-1');
      // Sin op aplicada no hay nada que confirmar por red.
      expect(rpc.conteo('invitado_confirmar_conversion'), 0);
    });

    test('G1(b)+G2: op huérfana aplicada se reconstruye y se '
        'confirma en la misma pasada', () async {
      await _insertarOpConversion(
        opUuid: 'op-1',
        estado: 'aplicada',
        resultadoServidor: '{"cliente_id": 33}',
      );
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      final n = await svc.verificarConversiones();
      expect(n, 1);
      expect(rpc.conteo('invitado_confirmar_conversion'), 1);
      final llamada = rpc.llamadas
          .firstWhere((l) => l.nombre == 'invitado_confirmar_conversion');
      expect(llamada.params?['p_conversion_uuid'], 'conv-1');
      expect(llamada.params?['p_cliente_id'], 33);
      expect(llamada.params?['p_op_uuid'], 'op-1');
      final reg = await ConversionInvitadoStore().leer('inv-1');
      expect(reg, isNotNull);
      expect(reg!.estado, EstadoConversion.confirmada);
      expect(reg.clienteId, 33);
      expect(reg.opUuid, 'op-1');
    });

    test('G1(b): op huérfana aún pendiente se reconstruye como '
        'opEncolada sin tocar la red', () async {
      await _insertarOpConversion(opUuid: 'op-1', estado: 'pendiente');
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      final n = await svc.verificarConversiones();
      expect(n, 0);
      expect(rpc.llamadas, isEmpty);
      final reg = await ConversionInvitadoStore().leer('inv-1');
      expect(reg, isNotNull);
      expect(reg!.estado, EstadoConversion.opEncolada);
      expect(reg.conversionUuid, 'conv-1');
    });

    test('G2: sin conversiones en curso, verificar no llama a '
        'la red', () async {
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      expect(await svc.verificarConversiones(), 0);
      expect(rpc.llamadas, isEmpty);
    });

    test('G3: cancelar con CONVERSION_INVALIDA cierra el '
        'registro local y no lanza', () async {
      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.preparada));
      final rpc = _RpcFalsa()
        ..errores['invitado_cancelar_conversion'] =
            Exception('CONVERSION_INVALIDA');
      final svc = InvitadosService(rpc: rpc.call);
      await svc.cancelarConversion('conv-1', invitadoId: 'inv-1');
      final despues = await ConversionInvitadoStore().leer('inv-1');
      expect(despues!.estado, EstadoConversion.cancelada);
    });

    test('G3: cancelar con otro error SÍ lanza y el registro '
        'queda preparada', () async {
      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.preparada));
      final rpc = _RpcFalsa()
        ..errores['invitado_cancelar_conversion'] =
            Exception('fallo de red genérico');
      final svc = InvitadosService(rpc: rpc.call);
      await expectLater(
        svc.cancelarConversion('conv-1', invitadoId: 'inv-1'),
        throwsA(isA<InvitadoError>()),
      );
      final despues = await ConversionInvitadoStore().leer('inv-1');
      expect(despues!.estado, EstadoConversion.preparada);
    });

    test('G3: reconciliarPreparadaObsoleta cierra la preparada '
        'sin vigencia y respeta la vigente', () async {
      final svc = InvitadosService(rpc: _RpcFalsa().call);
      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.preparada));
      final local = await ConversionInvitadoStore().leer('inv-1');
      final cerrada =
          await svc.reconciliarPreparadaObsoleta(detalleTest(), local!);
      expect(cerrada.estado, EstadoConversion.cancelada);
      expect(
          (await ConversionInvitadoStore().leer('inv-1'))!.estado,
          EstadoConversion.cancelada);

      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.preparada));
      final local2 = await ConversionInvitadoStore().leer('inv-1');
      final vigente = await svc.reconciliarPreparadaObsoleta(
        detalleTest(
            conversion: const ConversionServidor(
                conversionUuid: 'conv-1', lockVigente: true)),
        local2!,
      );
      expect(vigente.estado, EstadoConversion.preparada);
    });

    test('G1(b): con registro local existente no se adopta '
        'nada del servidor', () async {
      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.opEncolada, opUuid: 'op-1'));
      final svc = InvitadosService(rpc: _RpcFalsa().call);
      final r = await svc.adoptarConversionDelServidor(detalleTest(
          conversion: const ConversionServidor(
              conversionUuid: 'conv-srv',
              preparadaPor: 'gabriel@ironbody.gym',
              lockVigente: true)));
      expect(r, isNull);
      expect(
          (await ConversionInvitadoStore().leer('inv-1'))!
              .conversionUuid,
          'conv-1');
    });

    test('G4: eliminar con conversión activa lanza, no llama a '
        'la RPC y conserva el meta', () async {
      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.opEncolada, opUuid: 'op-1'));
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      await expectLater(
        svc.eliminar('inv-1'),
        throwsA(isA<InvitadoError>()
            .having((e) => e.codigo, 'codigo', 'CONVERSION_ACTIVA')),
      );
      expect(rpc.conteo('invitado_eliminar'), 0);
      expect(await ConversionInvitadoStore().leer('inv-1'),
          isNotNull);
    });

    test('G4: eliminar sin conversión activa llama a la RPC y '
        'borra el meta', () async {
      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.cancelada));
      final rpc = _RpcFalsa();
      final svc = InvitadosService(rpc: rpc.call);
      await svc.eliminar('inv-1');
      expect(rpc.conteo('invitado_eliminar'), 1);
      expect(await ConversionInvitadoStore().leer('inv-1'), isNull);
    });

    test('G4: eliminar sin registro local pero con preparada '
        'vigente en el SERVIDOR lanza CONVERSION_ACTIVA y no '
        'llama a invitado_eliminar', () async {
      // Sin meta local (la BD arranca limpia): la preparación
      // la hizo otro teléfono y solo la ve el servidor.
      final rpc = _RpcFalsa();
      rpc.respuestas['invitado_detalle'] = {
        'invitado': {
          'id': 'inv-1',
          'nombre': 'Ana',
          'telefono': '58191577',
          'estado': 'activo',
        },
        'conversion_preparada': {
          'conversion_uuid': 'conv-ajena',
          'preparada_por': 'duany@ironbody.gym',
          'lock_vigente': true,
        },
      };
      final svc = InvitadosService(rpc: rpc.call);
      await expectLater(
        svc.eliminar('inv-1'),
        throwsA(isA<InvitadoError>()
            .having((e) => e.codigo, 'codigo', 'CONVERSION_ACTIVA')),
      );
      expect(rpc.conteo('invitado_detalle'), 1);
      expect(rpc.conteo('invitado_eliminar'), 0);
    });

    test('G4: eliminar sin registro local y detalle sin '
        'preparada elimina como siempre', () async {
      final rpc = _RpcFalsa();
      rpc.respuestas['invitado_detalle'] = {
        'invitado': {
          'id': 'inv-1',
          'nombre': 'Ana',
          'telefono': '58191577',
          'estado': 'activo',
        },
      };
      final svc = InvitadosService(rpc: rpc.call);
      await svc.eliminar('inv-1');
      expect(rpc.conteo('invitado_detalle'), 1);
      expect(rpc.conteo('invitado_eliminar'), 1);
      expect(await ConversionInvitadoStore().leer('inv-1'), isNull);
    });

    test('G4: eliminar sin registro local y preparada VENCIDA '
        'en el servidor elimina como siempre', () async {
      final rpc = _RpcFalsa();
      rpc.respuestas['invitado_detalle'] = {
        'invitado': {
          'id': 'inv-1',
          'nombre': 'Ana',
          'telefono': '58191577',
          'estado': 'activo',
        },
        'conversion_preparada': {
          'conversion_uuid': 'conv-vieja',
          'lock_vigente': false,
        },
      };
      final svc = InvitadosService(rpc: rpc.call);
      await svc.eliminar('inv-1');
      expect(rpc.conteo('invitado_eliminar'), 1);
    });

    test('G4: eliminar con el detalle inaccesible (red) '
        'propaga el error, no llama a invitado_eliminar ni '
        'borra el meta', () async {
      await ConversionInvitadoStore()
          .guardar(conv(EstadoConversion.cancelada));
      final rpc = _RpcFalsa();
      rpc.errores['invitado_detalle'] = Exception('sin red');
      final svc = InvitadosService(rpc: rpc.call);
      await expectLater(
        svc.eliminar('inv-1'),
        throwsA(isA<InvitadoError>()
            .having((e) => e.codigo, 'codigo', 'RED')),
      );
      expect(rpc.conteo('invitado_eliminar'), 0);
      expect(await ConversionInvitadoStore().leer('inv-1'),
          isNotNull);
    });
  });
}

/// BD limpia (instalación completa) y singleton reseteado —
/// mismo arnés que test/poda_ops_test.dart.
Future<void> _abrirBdLimpia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// Inserta una op `inscribir` de conversión directo en la cola
/// (como la dejaría queueOp tras guardar el formulario).
Future<void> _insertarOpConversion({
  required String opUuid,
  required String estado,
  String? resultadoServidor,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': opUuid,
    'tipo': 'inscribir',
    'payload': jsonEncode({
      'nombre': 'Ana',
      'invitado_id': 'inv-1',
      'conversion_uuid': 'conv-1',
    }),
    'estado': estado,
    'creada_ts': '2026-10-22T09:00:00-04:00',
    'resultado_servidor': resultadoServidor,
  });
}

/// RPC falsa del seam de InvitadosService: registra llamadas y
/// puede fallar por nombre de RPC con el error dado.
class _RpcFalsa {
  final llamadas =
      <({String nombre, Map<String, dynamic>? params})>[];
  final errores = <String, Object>{};
  final respuestas = <String, dynamic>{};

  Future<dynamic> call(
      String nombre, Map<String, dynamic>? params) async {
    llamadas.add((nombre: nombre, params: params));
    final e = errores[nombre];
    if (e != null) throw e;
    return respuestas[nombre] ?? <String, dynamic>{'ok': true};
  }

  int conteo(String nombre) =>
      llamadas.where((l) => l.nombre == nombre).length;
}
