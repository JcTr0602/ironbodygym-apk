/// Yunque de cambios 1.31 — Ronda 4: contratos de las
/// correcciones de la ronda.
///
/// - R4-M3-1: la foto de atascos cuenta las lecturas
///   fallidas (error ≠ vacío también en el diagnóstico) y
///   ninguna superficie declara «todo en orden» con una
///   foto parcial.
/// - R4-M3-3: Reparar sincronización es solo del dueño
///   (misma puerta que la Salud).
/// - R4-M3-5: «Es correcto» (apagar la alarma de espejo
///   vacío) solo lo ve el dueño y deja bitácora con actor.
/// - R4-M3-6: la bitácora de la reparación nombra al actor.
/// - R4-M1-1: la reposición de la alarma tras un reinicio
///   solo reprograma el instante guardado si sigue en el
///   futuro (función pura).
/// - R4-M1-5: la cadena previa a runApp acota los pasos
///   degradables con timeout.
/// - R4-M1-8: el barrido de cierre automático sin caché de
///   horarios deja rastro en bitácora.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/notificaciones_recordatorios.dart';
import 'package:ironbody_gym/reparar_sync.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('R4-M3-1 · foto de atascos honesta', () {
    test('la foto sin fallos es completa; con fallos, parcial', () {
      expect(const FotoAtascos().fotoCompleta, isTrue);
      expect(const FotoAtascos().lecturasFallidas, 0);
      expect(
          const FotoAtascos(lecturasFallidas: 2).fotoCompleta,
          isFalse);
    });

    test('capturarAtascos cuenta y registra cada lectura rota',
        () {
      final s = _fuente('lib/reparar_sync.dart');
      expect(s, contains('fallo('));
      expect(s, contains('reparar_foto_lectura_fallo'));
      expect(s, contains('lecturasFallidas: fallidas'));
    });

    test('la pantalla no declara orden con la foto parcial',
        () {
      final s = _fuente('lib/ui/reparar_sync_screen.dart');
      expect(s, contains('hallazgos.isEmpty && foto.fotoCompleta'));
      expect(
          s, contains('r.antes.fotoCompleta && r.despues.fotoCompleta'));
      expect(s, contains('!r.despues.fotoCompleta'));
    });
  });

  group('R4-M3-3/M3-5/M3-6 · puertas y bitácora', () {
    test('Reparar sincronización exige dueño en el build', () {
      final s = _fuente('lib/ui/reparar_sync_screen.dart');
      expect(s, contains('if (!AuthService().isOwner)'));
      expect(s, contains('La reparación del sync es solo el dueño.'));
    });

    test('la reparación registra al actor en la bitácora', () {
      final s = _fuente('lib/reparar_sync.dart');
      expect(s, contains("actor=\$actor"));
      expect(s, contains('foto_fallos_antes'));
      expect(s, contains('foto_fallos_despues'));
    });

    test('«Es correcto» solo lo ve el dueño y deja bitácora',
        () {
      final s = _fuente('lib/ui/diagnostico_espejo_card.dart');
      expect(s, contains('if (esDueno) ...['));
      expect(s, contains('espejo_vacio_marcado_correcto'));
      expect(s, contains('if (!auth.isOwner) return;'));
    });
  });

  group('R4-M1-1 · reposición de alarma tras reinicio', () {
    const ahora = 1000000;
    test('instante futuro guardado: se repone ESE instante', () {
      expect(epochReprogramacionTrasReinicio('2000000', ahora),
          2000000);
      expect(epochReprogramacionTrasReinicio(' 2000000 ', ahora),
          2000000);
    });
    test('instante pasado o presente: no se repone', () {
      expect(epochReprogramacionTrasReinicio('999999', ahora),
          isNull);
      expect(epochReprogramacionTrasReinicio('1000000', ahora),
          isNull);
    });
    test('marca ausente o ilegible: no se repone', () {
      expect(epochReprogramacionTrasReinicio(null, ahora),
          isNull);
      expect(epochReprogramacionTrasReinicio('', ahora), isNull);
      expect(epochReprogramacionTrasReinicio('ayer', ahora),
          isNull);
    });
  });

  group('R4-M1-5/M1-8 · arranque y cierre automático', () {
    test('los pasos degradables del arranque llevan timeout',
        () {
      final s = _fuente('lib/main.dart');
      expect(s, contains('_pasoArranqueDegradable'));
      expect(
          s, contains("await paso().timeout(const Duration(seconds: 10))"));
      expect(s, contains("'app_log'"));
      expect(s, contains("'centinela'"));
      expect(s, contains("'tema'"));
    });

    test('sin caché de horarios, el barrido deja rastro', () {
      final s = _fuente('lib/cierre_automatico.dart');
      expect(s, contains('sin_cache_horarios'));
    });
  });
}
