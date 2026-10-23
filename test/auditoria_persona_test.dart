// v1.8.0 — Auditoría por persona: resolver P4, tardanza contra
// el EVENTO (P1), dinero por registrado_por sin cruces (P3) y
// cobertura por marca de agua global (P2).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auditoria_persona.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';

void main() {
  const duany = PersonaApk(
      id: 'uuid-duany', telegramId: 111, nombre: 'Duany');
  const gabriel = PersonaApk(
      id: 'uuid-gabriel', telegramId: 222, nombre: 'Gabriel');
  final usuarios = [duany, gabriel];
  final patron = parsePatronTurnos({
    '1': {'manana': 'Gabriel', 'tarde': 'Duany'},
  });

  group('resolver P4 (doble clave, solo lectura)', () {
    test('manda el uuid cuando la fila lo trae', () {
      expect(
          filaEsDePersona(
              {'entrenador_id': 'uuid-duany', 'entrenador_nombre': 'Gabriel'},
              duany),
          isTrue);
      // El nombre NO rescata un uuid ajeno.
      expect(
          filaEsDePersona(
              {'entrenador_id': 'uuid-gabriel', 'entrenador_nombre': 'Duany'},
              duany),
          isFalse);
    });
    test('manda el telegram_id cuando no hay uuid', () {
      expect(
          filaEsDePersona(
              {'registrado_por': 111, 'registrado_por_nombre': 'Otro'},
              duany),
          isTrue);
      expect(filaEsDePersona({'registrado_por': 999}, duany), isFalse);
    });
    test('sin claves: respaldo por nombre normalizado', () {
      expect(
          filaEsDePersona(
              {'registrado_por_nombre': 'duany (APK)'}, duany),
          isTrue);
      expect(
          filaEsDePersona({'entrenador_nombre': 'Gabriel'}, duany),
          isFalse);
    });
  });

  group('turnos: tardanza contra el evento (P1)', () {
    final lunes = DateTime(2026, 10, 26);
    test('abrió 06:20 (tarde 20 min) aunque sincronice luego', () {
      final ts = auditarTurnosPersona(
        persona: gabriel,
        desde: lunes,
        hasta: lunes,
        patron: patron,
        excepciones: const {},
        aperturas: [
          {
            'fecha_turno': '2026-10-26',
            'turno': 'manana',
            'entrenador_id': 'uuid-gabriel',
            'hora_apertura': '2026-10-26T06:20:00-04:00',
          },
        ],
        cierres: const [],
        usuarios: usuarios,
      );
      final t = ts.singleWhere((x) => x.franja == 'manana');
      expect(t.eraSuyo, isTrue);
      expect(t.tardanzaMin, 20);
      expect(t.tarde, isTrue);
      expect(t.noApertura, isFalse);
    });

    test('programado que no abre = no-apertura (con cobertura)', () {
      final ts = auditarTurnosPersona(
        persona: gabriel,
        desde: lunes,
        hasta: lunes,
        patron: patron,
        excepciones: const {},
        aperturas: const [],
        cierres: const [],
        usuarios: usuarios,
      );
      final manana = ts.singleWhere((x) => x.franja == 'manana');
      expect(manana.noApertura, isTrue);
      // La tarde era de Duany: Gabriel no genera fila de tarde.
      expect(ts.where((x) => x.franja == 'tarde'), isEmpty);
    });

    test('abrir sin estar programado = cubrió fuera de plan', () {
      final ts = auditarTurnosPersona(
        persona: gabriel,
        desde: lunes,
        hasta: lunes,
        patron: patron,
        excepciones: const {},
        aperturas: [
          {
            'fecha_turno': '2026-10-26',
            'turno': 'manana',
            'entrenador_id': 'uuid-gabriel',
            'hora_apertura': '2026-10-26T06:02:00-04:00',
          },
          {
            'fecha_turno': '2026-10-26',
            'turno': 'tarde',
            'entrenador_id': 'uuid-gabriel',
            'hora_apertura': '2026-10-26T14:01:00-04:00',
          },
        ],
        cierres: const [],
        usuarios: usuarios,
      );
      final tarde = ts.singleWhere((x) => x.franja == 'tarde');
      expect(tarde.cubrioFueraDePlan, isTrue);
      expect(tarde.eraSuyo, isFalse);
    });

    test('duración y diferencia salen de SU cierre (P3b)', () {
      final ts = auditarTurnosPersona(
        persona: duany,
        desde: lunes,
        hasta: lunes,
        patron: patron,
        excepciones: const {},
        aperturas: [
          {
            'fecha_turno': '2026-10-26',
            'turno': 'tarde',
            'entrenador_id': 'uuid-duany',
            'hora_apertura': '2026-10-26T14:00:00-04:00',
          },
        ],
        cierres: [
          {
            'fecha': '2026-10-26',
            'turno': 'tarde',
            'entrenador_id': 'uuid-duany',
            'cerrado_en': '2026-10-26T20:05:00-04:00',
            'diferencia': -100.0,
          },
        ],
        usuarios: usuarios,
      );
      final t = ts.singleWhere((x) => x.franja == 'tarde');
      expect(t.duracionMin, 365);
      expect(t.diferenciaArqueo, -100.0);
    });
  });

  group('dinero por registrado_por (P3)', () {
    test('suma solo lo suyo, separa métodos y pendiente', () {
      final d = auditarDineroPersona(
        persona: duany,
        desdeIso: '2026-10-01',
        hastaIso: '2026-10-31',
        pagos: [
          {'fecha': '2026-10-05', 'monto': 2000.0, 'metodo': 'efectivo', 'registrado_por': 111, 'entregado': 0},
          {'fecha': '2026-10-06', 'monto': 2500.0, 'metodo': 'transferencia', 'registrado_por': 111, 'entregado': 0},
          {'fecha': '2026-10-07', 'monto': 2000.0, 'metodo': 'efectivo', 'registrado_por': 222, 'entregado': 0},
          {'fecha': '2026-10-08', 'monto': 2000.0, 'metodo': 'efectivo', 'registrado_por': 111, 'entregado': 1},
          {'fecha': '2026-09-30', 'monto': 2000.0, 'metodo': 'efectivo', 'registrado_por': 111, 'entregado': 0},
        ],
        pagosDiarios: [
          {'fecha': '2026-10-05', 'total': 600.0, 'registrado_por': 111},
        ],
        ventasSuplementos: [
          {'fecha': '2026-10-05', 'precio_unitario': 5000.0, 'cantidad': 1, 'registrado_por': 111, 'estado': 'activa'},
          {'fecha': '2026-10-06', 'precio_unitario': 5000.0, 'cantidad': 1, 'registrado_por': 111, 'estado': 'anulada'},
        ],
        ventasServicios: [
          {'fecha': '2026-10-05', 'precio_unitario': 600.0, 'cantidad': 2, 'comision_unitaria': 100.0, 'registrado_por': 111, 'casa': 0},
          {'fecha': '2026-10-05', 'precio_unitario': 0.0, 'cantidad': 1, 'comision_unitaria': 0.0, 'registrado_por': 111, 'casa': 1},
        ],
        cierres: [
          {'fecha': '2026-10-05', 'turno': 'tarde', 'entrenador_id': 'uuid-duany', 'diferencia': -50.0},
        ],
      );
      expect(d.pagosMes, 3);
      expect(d.mensualEfectivo, 4000);
      expect(d.mensualTransferencia, 2500);
      expect(d.pendienteGenerado, 2000);
      expect(d.entregadoConfirmado, 2000);
      expect(d.diarioTotal, 600);
      expect(d.suplementosTotal, 5000); // la anulada no cuenta
      expect(d.dosisTotal, 1200); // Casa fuera
      expect(d.comisionDosis, 200);
      expect(d.arqueos, 1);
      expect(d.diferenciaArqueos, -50);
    });
  });

  group('cobertura P2', () {
    test('sin espejo y con espejo corto avisan; cubierto no', () {
      expect(
          avisoCoberturaAperturas(
              desdeIso: '2026-10-01', minFechaEspejo: null),
          contains('Sin datos'));
      expect(
          avisoCoberturaAperturas(
              desdeIso: '2026-09-01', minFechaEspejo: '2026-10-01'),
          contains('2026-10-01'));
      expect(
          avisoCoberturaAperturas(
              desdeIso: '2026-10-05', minFechaEspejo: '2026-10-01'),
          isNull);
    });
  });
}
