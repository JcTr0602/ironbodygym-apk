/// Contratos de fuente de la corrección ARG136:
///
/// - ARG136-08 (MEDIA): los disparos de push sin captura
///   de los archivos adjudicados migran a
///   `SyncEngine.instance.pushEnSegundoPlano()`, la vía
///   que consume el error a propósito. Un `push()` sin
///   captura deja el fallo asíncrono como error no
///   manejado de zona, que app_log vuelca como crash
///   «fatal» falso. Alcance EXACTO de la adjudicación:
///   centro_compras (×2), historial_ventas, admin (×5),
///   categorias_suplemento (×2), detalle_suplemento y
///   buscar. En admin queda UN `push()` legítimo: el de
///   `_syncSilencioso`, con await dentro de try/catch y
///   encadenado al pull — no es un disparo sin captura.
/// - ARG136-13 (BAJA): el selector de rango de Actividad
///   abría el calendario con `initialDate: DateTime.now()`
///   contra `lastDate: ahoraHabana()`: con el huso del
///   dispositivo adelantado respecto a La Habana cerca de
///   medianoche, initialDate cae tras lastDate
///   (AssertionError; en release, selector degradado).
///   Ambos initialDate pasan a ahoraHabana(). El rojo de
///   esta fila no es reproducible en el entorno de test
///   (exige el huso del dispositivo adelantado): el
///   contrato de fuente es su fijación.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('ARG136-08 · pushEnSegundoPlano en los archivos '
      'adjudicados', () {
    final sinPushCrudo = <String, int>{
      'lib/ui/centro_compras.dart': 2,
      'lib/ui/historial_ventas.dart': 1,
      'lib/ui/categorias_suplemento.dart': 2,
      'lib/ui/detalle_suplemento.dart': 1,
      'lib/ui/buscar.dart': 1,
    };
    sinPushCrudo.forEach((ruta, migrados) {
      test('$ruta: sin push() crudo y con $migrados '
          'pushEnSegundoPlano()', () {
        final src = _src(ruta);
        expect(src.contains('SyncEngine.instance.push()'), isFalse,
            reason: 'todo disparo de esta pantalla va por la '
                'vía que consume el error');
        expect(
            'SyncEngine.instance.pushEnSegundoPlano()'
                .allMatches(src)
                .length,
            greaterThanOrEqualTo(migrados));
      });
    });

    test('lib/ui/admin.dart: solo queda el push() con '
        'await y captura de _syncSilencioso', () {
      final src = _src('lib/ui/admin.dart');
      expect('SyncEngine.instance.push()'.allMatches(src).length,
          1,
          reason: 'los 5 disparos sin captura migraron; el '
              'único push() restante es el esperado de '
              '_syncSilencioso');
      expect(src.contains('await SyncEngine.instance.push();'),
          isTrue);
      expect(
          'SyncEngine.instance.pushEnSegundoPlano()'
              .allMatches(src)
              .length,
          greaterThanOrEqualTo(5));
    });
  });

  group('ARG136-13 · el selector de rango abre en hora '
      'Habana', () {
    test('elegirRangoSheet no usa DateTime.now() y acota '
        'con ahoraHabana()', () {
      final src = _src('lib/ui/actividad.dart');
      final i = src.indexOf('elegirRangoSheet()');
      expect(i, greaterThanOrEqualTo(0));
      final cuerpo = src.substring(i, i + 1200);
      expect(cuerpo.contains('DateTime.now()'), isFalse,
          reason: 'initialDate tras lastDate rompe el '
              'selector con husos adelantados');
      expect('initialDate: rIni ?? ahoraHabana()'
          .allMatches(cuerpo)
          .length, 1);
      expect('initialDate: rFin ?? ahoraHabana()'
          .allMatches(cuerpo)
          .length, 1);
    });
  });
}
