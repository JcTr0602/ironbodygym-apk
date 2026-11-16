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
    // Corrección de la reconciliación: el desplazamiento
    // deliberado a un bloque lejano (450 ms) ganó token.
    expect(AppMovimiento.desplazamiento.inMilliseconds, 450);
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
    // Corrección de la reconciliación (§3.4): la cabecera
    // nueva de marco.dart (rediseño de la fase 4) usa los
    // tokens `media` (el nombre que se pliega) y `corta`
    // (la pastilla del pilar) — la expectativa vieja pedía
    // `larga`, que ya no vive en el archivo. (En ambos
    // sitios el token va en la línea siguiente a
    // `duration:`, tras el ternario de animaciones
    // reducidas: se busca el token, no la línea entera.)
    expect(leer('lib/ui/marco.dart'), contains('AppMovimiento.media'));
    expect(leer('lib/ui/marco.dart'), contains('AppMovimiento.corta'));
    expect(leer('lib/ui/marco.dart'),
        isNot(contains('AppMovimiento.larga')));
    // Corrección de la reconciliación (§3.4): los cuatro
    // literales que la fase 4 dejó en home.dart (M-4/M-7)
    // pasaron a tokens.
    expect(leer('lib/ui/home.dart'),
        contains('duration: AppMovimiento.media'));
    expect(leer('lib/ui/home.dart'),
        contains('duration: AppMovimiento.larga'));
    expect(leer('lib/ui/home.dart'),
        contains('duration: AppMovimiento.desplazamiento'));
    expect(leer('lib/ui/invitados.dart'),
        contains('duration: AppMovimiento.media'));
    expect(leer('lib/ui/historial_ventas.dart'),
        contains('duration: AppMovimiento.larga'));
    expect(leer('lib/ui/servicios_historial.dart'),
        contains('duration: AppMovimiento.larga'));
    // Los SEIS literales supervivientes, todos con su
    // comentario de UI-13 en el sitio. widgets.dart lleva
    // DOS giros con el mismo período (el del banner y el
    // del icono de la cabecera, este último documentado
    // como sexto superviviente en la corrección de la
    // reconciliación, §3.4).
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
    expect(
        'duration: const Duration(seconds: 2)'
            .allMatches(leer('lib/ui/widgets.dart'))
            .length,
        2,
        reason: 'los dos giros documentados de widgets.dart');
    // Y ningún otro duration: con literal en lib/ui.
    var total = 0;
    for (final e in Directory('lib/ui').listSync()) {
      if (e is File && e.path.endsWith('.dart')) {
        total += 'duration: const Duration'
            .allMatches(e.readAsStringSync())
            .length;
      }
    }
    expect(total, 6);
  });
}
