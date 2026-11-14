/// Yunque 2.34 — pins del clúster D restantes:
/// - D-4: `accionPrincipalBuscar` sin botón fantasma en pausa.
/// - D-5/D-6: contratos de fuente del teléfono (validar el
///   valor sanitizado; el diálogo no trunca el pegado).
/// - D-7: la Auditoría de persona no suma pagos anulados
///   (marca en la fila ni anulación viva en la cola), en el
///   resumen y en la serie diaria.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auditoria_persona.dart';
import 'package:ironbody_gym/ui/buscar.dart';

void main() {
  test('D-4: en pausa no hay acción fantasma en Buscar', () {
    // Vencido CON teléfono y en pausa: antes salía «Cobrar».
    expect(
        accionPrincipalBuscar(
            dias: -2,
            esCasa: false,
            protegido: false,
            seleccion: false,
            tieneTelefonoWa: true,
            enPausa: true),
        isNull);
    // Por vencer en pausa: antes salía «Avisar».
    expect(
        accionPrincipalBuscar(
            dias: 3,
            esCasa: false,
            protegido: false,
            seleccion: false,
            tieneTelefonoWa: true,
            enPausa: true),
        isNull);
    // Sin pausa, el comportamiento de siempre.
    expect(
        accionPrincipalBuscar(
            dias: -2,
            esCasa: false,
            protegido: false,
            seleccion: false,
            tieneTelefonoWa: true),
        'cobrar');
    expect(
        accionPrincipalBuscar(
            dias: 3,
            esCasa: false,
            protegido: false,
            seleccion: false,
            tieneTelefonoWa: true),
        'avisar');
  });

  test('D-5: la venta con inscripción valida el teléfono '
      'sanitizado', () {
    final f = File('lib/ui/venta_suplemento_inscripcion.dart')
        .readAsStringSync();
    expect(f, contains('sanitizarTelefono(telCrudo)'));
    final i = f.indexOf('sanitizarTelefono(telCrudo)');
    final j = f.indexOf('validarTelefono(tel)', i);
    expect(j, greaterThan(i),
        reason: 'la validación va DESPUÉS de sanitizar');
    // La asignación cruda vieja (validar sobre lo tecleado)
    // no vuelve.
    expect(f, isNot(contains('final tel = _telefono.text.trim();')));
  });

  test('D-6: el diálogo de teléfono no trunca el pegado', () {
    final f = File('lib/ui/dialogo_telefono.dart').readAsStringSync();
    expect(f, isNot(contains('maxLength: 8')),
        reason: 'con maxLength 8, pegar 5358191577 guardaba '
            '53581915: otro número, pero válido');
    expect(f, contains('sanitizarTelefono(crudo)'));
  });

  group('D-7: pagos anulados fuera de la Auditoría de persona',
      () {
    const duany =
        PersonaApk(id: 'uuid-duany', telegramId: 111, nombre: 'Duany');
    final pagos = <Map<String, dynamic>>[
      {
        'id': 1,
        'fecha': '2026-10-05',
        'monto': 2000.0,
        'metodo': 'efectivo',
        'registrado_por': 111,
        'entregado': 0
      },
      // Anulado con marca en la propia fila.
      {
        'id': 2,
        'fecha': '2026-10-05',
        'monto': 2000.0,
        'metodo': 'efectivo',
        'registrado_por': 111,
        'entregado': 0,
        'anulado': 1
      },
      // Anulado solo en la cola (la fila aún no lo refleja).
      {
        'id': 3,
        'fecha': '2026-10-06',
        'monto': 2500.0,
        'metodo': 'transferencia',
        'registrado_por': 111,
        'entregado': 0
      },
    ];

    test('auditarDineroPersona los excluye', () {
      final d = auditarDineroPersona(
        persona: duany,
        desdeIso: '2026-10-01',
        hastaIso: '2026-10-31',
        pagos: pagos,
        pagosDiarios: const [],
        ventasSuplementos: const [],
        ventasServicios: const [],
        cierres: const [],
        anuladosEnCola: const {3},
      );
      expect(d.pagosMes, 1);
      expect(d.mensualEfectivo, 2000);
      expect(d.mensualTransferencia, 0);
    });

    test('serieCobrosPorDia los excluye con la misma regla', () {
      final s = serieCobrosPorDia(
        persona: duany,
        desdeIso: '2026-10-05',
        hastaIso: '2026-10-06',
        pagos: pagos,
        pagosDiarios: const [],
        ventasSuplementos: const [],
        ventasServicios: const [],
        anuladosEnCola: const {3},
      );
      final porFecha = {
        for (final d in s) '${d['fecha']}': d['total'] as int
      };
      expect(porFecha['2026-10-05'], 2000);
      expect(porFecha['2026-10-06'], 0);
    });
  });
}
