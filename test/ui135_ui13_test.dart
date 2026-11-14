/// 1.35 (UI-13): las duraciones de transición de lib/ui
/// salen de AppMovimiento. Los únicos `duration:` con
/// literal que quedan son períodos de bucle o la barra
/// ligada a la cuenta atrás real, comentados en su sitio.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  test('los tokens son los de la casa', () {
    expect(AppMovimiento.corta.inMilliseconds, 150);
    expect(AppMovimiento.media.inMilliseconds, 220);
    expect(AppMovimiento.larga.inMilliseconds, 300);
  });

  test('contrato: las transiciones migradas usan el token '
      'y los literales restantes son los documentados', () {
    String leer(String f) => File(f).readAsStringSync();
    expect(leer('lib/ui/ficha.dart'),
        contains('duration: AppMovimiento.larga'));
    expect(leer('lib/ui/ficha.dart'),
        contains('duration: AppMovimiento.media'));
    expect(leer('lib/ui/listas.dart'),
        contains('duration: AppMovimiento.larga'));
    expect(leer('lib/ui/login.dart'),
        contains('duration: AppMovimiento.larga'));
    expect(leer('lib/ui/marco.dart'),
        contains('duration: AppMovimiento.larga'));
    expect(leer('lib/ui/invitados.dart'),
        contains('duration: AppMovimiento.media'));
    expect(leer('lib/ui/historial_ventas.dart'),
        contains('duration: AppMovimiento.larga'));
    expect(leer('lib/ui/servicios_historial.dart'),
        contains('duration: AppMovimiento.larga'));
    // Los cinco literales supervivientes, todos con su
    // comentario de UI-13 en el sitio.
    const supervivientes = {
      'lib/ui/confirmacion_cobro.dart': 'milliseconds: 950',
      'lib/ui/panel_modulos.dart': 'milliseconds: 1350',
      'lib/ui/skeleton.dart': 'milliseconds: 1200',
      'lib/ui/suplementos.dart': 'milliseconds: 900',
      'lib/ui/widgets.dart': 'seconds: 2',
    };
    supervivientes.forEach((f, lit) {
      final src = leer(f);
      expect(src, contains(lit), reason: f);
      expect(src, contains('UI-13'), reason: f);
    });
    // Y ningún otro duration: con literal en lib/ui.
    var total = 0;
    for (final e in Directory('lib/ui').listSync()) {
      if (e is File && e.path.endsWith('.dart')) {
        total += 'duration: const Duration'
            .allMatches(e.readAsStringSync())
            .length;
      }
    }
    expect(total, 5);
  });
}
