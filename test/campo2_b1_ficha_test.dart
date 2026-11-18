// 1.34 Campo 2 — B-1: la ficha respira (órdenes de campo
// de Jc, 2026-11-14):
// - FUERA «Repetir último cobro» de la barra del cobro.
// - FUERA «Dar acceso» de la barra compacta (la tarjeta
//   flotante que molestaba): el acceso vive en su sección
//   de «App Clientes» y en el chip de «Qué le falta».
// - Jerarquía: la pestaña «Pagos y Notas» abre por
//   Membresía (estado/pagado hasta) e Historial; «Qué le
//   falta» e Información personal bajan tras ellos. La
//   cabecera fija se corta con el marcador
//   _FinCabeceraFicha, no con la posición de una sección.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final ficha = File('lib/ui/ficha.dart').readAsStringSync();

  group('B-1 · retiradas', () {
    test('la barra del cobro ya no ofrece repetir el último '
        'cobro', () {
      expect(ficha, isNot(contains('_pagar(repetir: true)')));
      expect(ficha, isNot(contains("'Repetir último cobro · '")));
    });

    test('la barra compacta ya no ofrece «Dar acceso»', () {
      expect(ficha,
          isNot(contains("label: const Text('Dar acceso'")));
      expect(ficha,
          isNot(contains("'Dar acceso', () => _irASeccionAcceso()")));
      // La sección de acceso sigue existiendo en su
      // pestaña: la acción no se pierde.
      expect(ficha, contains('SeccionAccesoAppFicha('));
      expect(ficha, contains('_irASeccionAcceso'));
    });
  });

  group('B-1 · jerarquía de la pestaña de pagos', () {
    test('el corte de cabecera es el marcador, no «qué le '
        'falta»', () {
      expect(ficha, contains('const _FinCabeceraFicha(),'));
      expect(
          ficha,
          contains(
              'items.indexWhere((it) => it.widget is _FinCabeceraFicha)'));
    });

    // 1.36 FICHA (136-193): el orden de B-1 quedó DEROGADO
    // por la auditoría de la ficha — tras Membresía suben
    // los pendientes y los datos personales; Resumen 360
    // e Historial bajan tras ellos.
    test('orden en _seccionesCrudas (136-193): Membresía, '
        '«Qué le falta» e Información personal antes que '
        'Resumen 360 e Historial', () {
      final iMembresia = ficha.indexOf('// Membresía');
      final iHistorial = ficha.indexOf('TarjetaHistorialFicha(');
      final iQueFalta = ficha.indexOf('SeccionQueFaltaFicha(');
      final iInfo = ficha.indexOf('// Información personal');
      expect(iMembresia, greaterThan(0));
      expect(iQueFalta, greaterThan(iMembresia));
      expect(iInfo, greaterThan(iQueFalta));
      expect(iHistorial, greaterThan(iInfo));
    });

    // 1.36 FICHA (136-195): una sola acción principal por
    // estado — la barra inferior sigue la acción del
    // momento y la compacta ya no ofrece una segunda.
    test('la acción principal es una sola (136-195): la '
        'barra inferior, con la acción del momento', () {
      expect(ficha, contains("texto: 'Cobrar'"));
      expect(ficha, contains('accionDelMomentoFicha('));
      expect(ficha, isNot(contains('botonMomento(')));
    });
  });
}
