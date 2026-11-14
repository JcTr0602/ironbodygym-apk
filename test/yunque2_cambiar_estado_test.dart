/// Yunque 2.34 (D-1/D-2) — contratos de fuente de la puerta
/// de rol de `cambiar_estado`: la op es SOLO del dueño en el
/// servidor (modo estricto) y ninguna vía de la app puede
/// ofrecerla ni encolarla desde una sesión de entrenador.
/// Las pantallas completas no tienen arnés de widget con
/// sesión en esta suite; el contrato fija la guarda en la
/// ACCIÓN y la oferta condicionada, con el mismo patrón que
/// C5-4 dejó para la congelación legada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  test('ficha: la tarjeta solo ofrece «A papelera» al dueño '
      'y la acción lleva la guarda', () {
    final f = _fuente('lib/ui/ficha.dart');
    expect(f, contains('onPapelera: AuthService().isOwner'));
    final i = f.indexOf('Future<void> _aPapelera()');
    final j = f.indexOf("tipo: 'cambiar_estado'", i);
    expect(i, greaterThan(0));
    expect(j, greaterThan(i));
    expect(f.substring(i, j), contains('!AuthService().isOwner'),
        reason: 'la guarda va ANTES de encolar la op');
  });

  test('papelera: recuperar y recuperar-y-renovar con guarda '
      'previa y botones solo para el dueño', () {
    final f = _fuente('lib/ui/papelera.dart');
    for (final fn in ['_recuperar(', '_recuperarYRenovar(']) {
      final i = f.indexOf('Future<void> $fn');
      expect(i, greaterThan(0), reason: fn);
      final j = f.indexOf('DialogoApp.confirmar', i);
      expect(f.substring(i, j), contains('!AuthService().isOwner'),
          reason: 'la guarda de $fn va antes del diálogo y la op');
    }
    expect(f, contains('trailing: esDueno'));
    // El comentario de cabecera ya no promete que el
    // entrenador puede recuperar.
    expect(f, isNot(contains('los entrenadores solo pueden recuperar')));
  });

  test('congelados: descongelar con guarda de rol y botón '
      'condicionado', () {
    final f = _fuente('lib/ui/congelados.dart');
    final i = f.indexOf('Future<void> _descongelar(');
    final j = f.indexOf("tipo: 'cambiar_estado'", i);
    expect(i, greaterThan(0));
    expect(f.substring(i, j), contains('!AuthService().isOwner'));
    expect(f, contains('trailing: AuthService().isOwner'));
  });

  test('componentes: onPapelera es nullable como onCongelar',
      () {
    final f = _fuente('lib/ui/componentes.dart');
    expect(f, contains('final VoidCallback? onPapelera;'));
    expect(f, contains('if (onPapelera != null)'));
  });
}
