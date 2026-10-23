import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/auditoria.dart';

void main() {
  group('descripcionOp', () {
    test('códigos conocidos se traducen', () {
      expect(descripcionOp('regalar_mes_cumpleanos'),
          'Mes de cumpleaños regalado');
      expect(descripcionOp('confirmar_entrega'),
          'Entrega de efectivo confirmada');
      expect(descripcionOp('pago_mensual'), 'Pago de mensualidad');
      expect(descripcionOp('liquidar_caja'), 'Caja liquidada (arqueo)');
    });

    test('fallback: guiones bajos se vuelven espacios', () {
      expect(descripcionOp('tipo_desconocido_xyz'), 'tipo desconocido xyz');
    });
  });

  group('filtro de auditoría (v1.6.0)', () {
    Map<String, dynamic> op({
      String tipo = 'apertura_turno',
      String estado = 'aplicada',
      Map<String, dynamic>? payload,
    }) =>
        {
          'tipo': tipo,
          'estado': estado,
          'payload': payload ?? <String, dynamic>{},
        };

    test('actorDeOp: sin actor en el payload es este dispositivo', () {
      expect(actorDeOp(op()), 'Este dispositivo');
      expect(actorDeOp(op(payload: {'registrado_por': 'Gabriel'})),
          'Gabriel');
      expect(
          actorDeOp(op(payload: {'registrado_por_nombre': 'Duany'})),
          'Duany');
    });

    group('clasificación por actor (panel 1.6.0)', () {
      // La cola local SOLO contiene ops nacidas en este teléfono:
      // «mía» vs «de otro» se decide por el ACTOR firmado en el
      // payload: el nombre comparado contra el displayName de la
      // sesión, o el telegram_id numérico comparado contra el
      // telegramId de la sesión (la sesión puede haber cambiado en
      // el mismo teléfono con ops pendientes en la cola).
      const yo = 'Gabriel';

      test('normalizarActor: trim, minúsculas y sufijo (APK)', () {
        expect(normalizarActor('  Gabriel '), 'gabriel');
        expect(normalizarActor('GABRIEL'), 'gabriel');
        expect(normalizarActor('Gabriel (APK)'), 'gabriel');
        expect(normalizarActor('gabriel (apk)'), 'gabriel');
      });

      test('sin actor en el payload: la op es mía', () {
        expect(actorFirmaDeOp(op()), isNull);
        expect(actorIdNumericoDeOp(op()), isNull);
        expect(esOpMia(op(), miActor: yo), isTrue);
        expect(esOpDeOtro(op(), miActor: yo), isFalse);
        // registrado_por numérico (telegram_id) NO es firma de
        // nombre, pero SÍ es firma numérica: se compara contra la
        // identidad de la sesión, no se da por mía a ciegas.
        expect(
            actorFirmaDeOp(op(payload: {'registrado_por': 123456})),
            isNull);
        expect(actorIdNumericoDeOp(op(payload: {'registrado_por': 123456})),
            123456);
      });

      test('firma numérica (telegram_id): se compara con la sesión', () {
        // La app estampa registrado_por numérico (pago_diario).
        const miId = 735772141;
        const otroId = 111111;
        final opNum = op(payload: {'registrado_por': miId});
        // Coincide con la identidad numérica de la sesión: mía.
        expect(esOpMia(opNum, miActor: yo, miTelegramId: miId), isTrue);
        expect(esOpDeOtro(opNum, miActor: yo, miTelegramId: miId), isFalse);
        // Id de OTRA sesión (quedó en la cola tras un cambio de
        // usuario en el mismo teléfono): de otro, visible en
        // «Otros y alertas».
        expect(esOpMia(opNum, miActor: yo, miTelegramId: otroId), isFalse);
        expect(esOpDeOtro(opNum, miActor: yo, miTelegramId: otroId), isTrue);
        expect(
            opVisibleEnAuditoria(opNum, FiltroAuditoria.otrosYAlertas,
                miActor: yo, miTelegramId: otroId),
            isTrue);
        expect(
            opVisibleEnAuditoria(opNum, FiltroAuditoria.soloMias,
                miActor: yo, miTelegramId: otroId),
            isFalse);
        // Sin identidad numérica de sesión: no se acredita como
        // propia (conservador).
        expect(esOpMia(opNum, miActor: yo), isFalse);
        expect(esOpDeOtro(opNum, miActor: yo), isTrue);
      });

      test('actorDeOp: firma numérica de otra sesión es «Otro usuario»',
          () {
        const miId = 735772141;
        expect(actorDeOp(op(payload: {'registrado_por': miId}),
            miTelegramId: miId), 'Este dispositivo');
        expect(actorDeOp(op(payload: {'registrado_por': miId}),
            miTelegramId: 999), 'Otro usuario');
        // Con nombre en el payload manda el nombre.
        expect(
            actorDeOp(
                op(payload: {
                  'registrado_por': miId,
                  'registrado_por_nombre': 'Duany'
                }),
                miTelegramId: 999),
            'Duany');
      });

      test('actor == mi actor (aun con formato distinto): es mía', () {
        final propia = op(payload: {'registrado_por': 'Gabriel'});
        expect(esOpMia(propia, miActor: yo), isTrue);
        expect(
            esOpMia(op(payload: {'registrado_por': ' gabriel '}),
                miActor: yo),
            isTrue);
        expect(
            esOpMia(op(payload: {'registrado_por': 'Gabriel (APK)'}),
                miActor: yo),
            isTrue);
        // La firma también viaja como registrado_por_nombre.
        expect(
            esOpMia(op(payload: {'registrado_por_nombre': 'Gabriel'}),
                miActor: yo),
            isTrue);
      });

      test('actor distinto: es de otro', () {
        final otra = op(payload: {'registrado_por': 'Duany'});
        expect(esOpMia(otra, miActor: yo), isFalse);
        expect(esOpDeOtro(otra, miActor: yo), isTrue);
        // Sin sesión con quién comparar, una op firmada por
        // alguien no se acredita como mía.
        expect(esOpMia(otra), isFalse);
        expect(esOpDeOtro(otra), isTrue);
      });

      test('default (otrosYAlertas): mía rutinaria fuera, de otro dentro',
          () {
        const f = FiltroAuditoria.otrosYAlertas;
        // Mía con mi propio registrado_por: NO aparece en default…
        final propia = op(payload: {'registrado_por': 'Gabriel'});
        expect(opVisibleEnAuditoria(propia, f, miActor: yo), isFalse);
        // …y SÍ está en «Solo mías».
        expect(
            opVisibleEnAuditoria(propia, FiltroAuditoria.soloMias,
                miActor: yo),
            isTrue);
        // De otro: aparece en default y no en «Solo mías».
        final otra = op(payload: {'registrado_por': 'Duany'});
        expect(opVisibleEnAuditoria(otra, f, miActor: yo), isTrue);
        expect(
            opVisibleEnAuditoria(otra, FiltroAuditoria.soloMias,
                miActor: yo),
            isFalse);
        // Sin actor (= mía): fuera del default, dentro de Solo mías.
        expect(opVisibleEnAuditoria(op(), f, miActor: yo), isFalse);
        expect(
            opVisibleEnAuditoria(op(), FiltroAuditoria.soloMias,
                miActor: yo),
            isTrue);
        // Alerta PROPIA (dinero): aparece en default aunque sea mía.
        final alertaPropia =
            op(tipo: 'pago_mensual', payload: {'registrado_por': 'Gabriel'});
        expect(opVisibleEnAuditoria(alertaPropia, f, miActor: yo),
            isTrue);
      });

      test('todo: siempre visible, firmada o no', () {
        expect(
            opVisibleEnAuditoria(op(payload: {'registrado_por': 'Duany'}),
                FiltroAuditoria.todo,
                miActor: yo),
            isTrue);
        expect(opVisibleEnAuditoria(op(), FiltroAuditoria.todo,
            miActor: yo), isTrue);
      });
    });

    test('esOpAlerta: dinero, eliminaciones y rechazadas', () {
      expect(esOpAlerta(op(tipo: 'pago_mensual')), isTrue);
      expect(esOpAlerta(op(tipo: 'eliminar_cliente')), isTrue);
      expect(esOpAlerta(op(tipo: 'gasto')), isTrue);
      expect(esOpAlerta(op(estado: 'rechazada')), isTrue);
      expect(esOpAlerta(op(estado: 'error')), isTrue);
      expect(esOpAlerta(op()), isFalse);
    });

    test('esOpAlerta: editar_cliente solo si toca el vencimiento', () {
      expect(esOpAlerta(op(tipo: 'editar_cliente')), isFalse);
      expect(
          esOpAlerta(op(
              tipo: 'editar_cliente',
              payload: {'pagado_hasta': '2026-11-22'})),
          isTrue);
    });

    test('otrosYAlertas sin sesión: oculta lo sin actor, muestra alertas',
        () {
      const f = FiltroAuditoria.otrosYAlertas;
      // Sin actor (= mía): oculta.
      expect(opVisibleEnAuditoria(op(), f), isFalse);
      // Alerta sin actor (dinero): visible.
      expect(opVisibleEnAuditoria(op(tipo: 'pago_diario'), f), isTrue);
    });
  });
}
