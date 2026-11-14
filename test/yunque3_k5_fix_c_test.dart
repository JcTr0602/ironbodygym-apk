/// Yunque 3 · Gestión 1.34 · Carril C — correcciones del
/// clúster K5 (Clientes y operación diaria).
///
/// - K5-1: «Mis vencimientos» de Mi Turno excluía ni Casa ni
///   protegidos (lista propia sin los predicados centrales).
/// - K5-2: Reportes Plus desbloqueaba la tarjeta con la
///   decisión en «enviada» (gemelo no propagado de D-B2-02).
/// - K5-3: la medición recién registrada desaparecía de la
///   lista local mientras su op estaba «enviada».
/// - K5-5: «Cambiar teléfono del acceso» truncaba el pegado
///   internacional con maxLength: 8 antes de sanitizar (D-6).
/// - K5-8: filtro/contador «Sin foto» de Buscar ignoraban
///   `foto_local`.
/// - K5-6: el recibo desde la cola decía «Cobrado por: <id
///   numérico de Telegram>».
/// - K5-7: el recibo de una inscripción nueva nunca entraba
///   en la bandeja por la vía de cola (exigía un cliente_id
///   que el payload de inscripción no trae).
/// - K5-4: Listas marcaba «avisado» al ABRIR WhatsApp, sin
///   confirmar el envío (ver el grupo propio al final).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/mi_turno.dart';

void main() {
  group('K5-1 · Mis vencimientos sin Casa ni protegidos', () {
    const hoy = '2026-11-14';
    const limite = '2026-11-21';

    Map<String, dynamic> cli(int id, String nombre, String ph,
            {int? casa, int? protegido}) =>
        {
          'id': id,
          'nombre': nombre,
          'estado': 'activo',
          'pagado_hasta': ph,
          if (casa != null) 'cuenta_casa': casa,
          if (protegido != null) 'protegido': protegido,
        };

    test('la Casa con pagado_hasta pasada atribuida NO aparece; '
        'el cliente normal vencido atribuido SÍ', () {
      final clientes = [
        // Casa: no vence nunca, aunque su fecha guardada pasó.
        cli(198, 'Casa Vencida', '2026-11-01', casa: 1),
        // Protegido: el entrenador no ve sus fechas.
        cli(55, 'Protegida Vencida', '2026-11-02', protegido: 1),
        // Normal vencido atribuido: debe aparecer.
        cli(60, 'Normal Vencido', '2026-11-10'),
        // Normal por vencer dentro de la ventana: aparece.
        cli(61, 'Normal Por Vencer', '2026-11-20'),
        // Fuera de ventana y no atribuido: no aparecen.
        cli(62, 'Normal Lejano', '2026-12-30'),
        cli(63, 'No Atribuido', '2026-11-05'),
      ];
      final out = filtrarMisVencimientos(
        clientes,
        {198, 55, 60, 61, 62},
        hoy: hoy,
        limite: limite,
        esDueno: false,
      );
      final ids = out.map((m) => m['id']).toList();
      expect(ids, contains(60),
          reason: 'el cliente normal vencido atribuido aparece');
      expect(ids, contains(61));
      expect(ids, isNot(contains(198)),
          reason: 'la Cuenta a la Casa no vence: no se lista '
              'como vencida en el teléfono del entrenador');
      expect(ids, isNot(contains(55)),
          reason: 'un protegido no enseña su vencimiento al '
              'entrenador');
      expect(ids, isNot(contains(62)));
      expect(ids, isNot(contains(63)));
      final normal = out.firstWhere((m) => m['id'] == 60);
      expect(normal['vencido'], isTrue);
    });

    test('el dueño SÍ ve al protegido en su lista (la vista '
        'protegida solo bloquea al no-dueño)', () {
      final out = filtrarMisVencimientos(
        [cli(55, 'Protegida Vencida', '2026-11-02', protegido: 1)],
        {55},
        hoy: hoy,
        limite: limite,
        esDueno: true,
      );
      expect(out.map((m) => m['id']), contains(55));
    });
  });
}
