/// 1.34 Campo 2 (P-2a): coalescencia de emisiones
/// ligeras del motor de sync.
///
/// Un pull emite una ligera por tabla (~42) y cada una
/// reconstruía banner/píldora/Centro de Sync en el
/// isolate de UI. La política VentanaEmisionLigera acota
/// las aplicaciones a una por ventana de 250 ms por fase
/// (la retenida que vale es la ÚLTIMA), y un cambio de
/// fase se aplica al momento.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('VentanaEmisionLigera (P-2)', () {
    test('la primera siempre toca; dentro de la ventana, no', () {
      final v = VentanaEmisionLigera();
      expect(v.toca(0, SyncPhase.downloading), isTrue);
      v.registrar(0, SyncPhase.downloading);
      expect(v.toca(100, SyncPhase.downloading), isFalse);
      expect(v.toca(249, SyncPhase.downloading), isFalse);
      expect(v.toca(250, SyncPhase.downloading), isTrue);
    });

    test('un cambio de fase se aplica al momento', () {
      final v = VentanaEmisionLigera();
      v.registrar(0, SyncPhase.downloading);
      expect(v.toca(10, SyncPhase.uploading), isTrue);
      expect(v.toca(10, SyncPhase.idle), isTrue);
    });

    test('simulación: pull de 42 tablas a 5 ms por tabla '
        'aplica un número acotado de emisiones', () {
      // Réplica del bucle del motor: cada ligera pregunta
      // a la ventana; si no toca, queda retenida (vale la
      // última) y se suelta al cerrar la ventana.
      final v = VentanaEmisionLigera();
      var aplicadas = 0;
      var retenida = false;
      for (var tabla = 0; tabla < 42; tabla++) {
        final ahora = tabla * 5; // 5 ms por tabla
        if (v.toca(ahora, SyncPhase.downloading)) {
          v.registrar(ahora, SyncPhase.downloading);
          aplicadas++;
          retenida = false;
        } else {
          retenida = true; // vale la última; la suelta el Timer
        }
      }
      // 42 emisiones en 210 ms: cabe UNA ventana → la
      // aplicada inmediata + la retenida al cierre = 2.
      expect(aplicadas, 1);
      expect(retenida, isTrue);
      // Y al avanzar el reloj más allá de la ventana, la
      // siguiente toca (la retenida se habría soltado).
      expect(v.toca(300, SyncPhase.downloading), isTrue);
    });

    test('el motor usa la ventana y el temporizador '
        '(contrato de fuente)', () {
      final src = File('lib/sync.dart').readAsStringSync();
      expect(src, contains('VentanaEmisionLigera'));
      expect(src, contains('_ligeraRetenida'));
      expect(src, contains('_soltarLigeraRetenida'));
      // Las emisiones completas descartan la retenida.
      expect(src, contains('_descartarLigeraRetenida();\n'
          '    final foto = await _construirFoto'));
    });
  });
}
