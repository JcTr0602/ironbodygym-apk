/// Yunque 3 (K7-5) — el editor GymPedia no tenía la red de
/// error que su hermana Guía sí recibió (R5-M6-6): publicar,
/// guardar borrador y retirar fallaban en silencio ante una
/// excepción local (BD bloqueada), con riesgo de re-publicar
/// a ciegas y encolar una segunda op condenada por CAS.
///
/// Sin costura razonable para un widget test (el editor exige
/// sesión de dueño, espejo, borradores e imagen: montar el
/// arnés costaría más que la pieza y probaría el arnés), la
/// corrección se fija con pin de fuente al estilo de la casa
/// (mismo patrón que el pin M6-6 de `yunque_r5_test.dart`
/// sobre guia_editor): los tres métodos llevan catch +
/// AppLog.error con su evento propio + aviso con el motivo,
/// y `_publicar` conserva su finally de `_ocupado`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final editor =
      File('lib/ui/gympedia_editor.dart').readAsStringSync();

  group('K7-5 · red de error del editor GymPedia (espejo R5-M6-6)', () {
    test('importa AppLog', () {
      expect(editor, contains("import '../app_log.dart';"));
    });

    test('los tres métodos dejan asiento en bitácora con su evento', () {
      expect(editor,
          contains("AppLog.error('ui', 'gympedia_borrador_fallo'"));
      expect(editor,
          contains("AppLog.error('ui', 'gympedia_publicar_fallo'"));
      expect(editor,
          contains("AppLog.error('ui', 'gympedia_retirar_fallo'"));
    });

    test('los tres métodos avisan con el motivo', () {
      // ERR-G01 (1.36): el motivo llega por mensajeErrorAmable
      // (el texto de negocio limpio pasa; el técnico, no) y el
      // crudo queda en AppLog — ya no se interpola $e a pelo.
      expect(editor, contains("'No se pudo guardar el borrador: \${mensajeErrorAmable(e)}'"));
      expect(editor, contains("'No se pudo publicar: \${mensajeErrorAmable(e)}'"));
      expect(editor, contains("'No se pudo retirar: \${mensajeErrorAmable(e)}'"));
    });

    test('_publicar conserva el finally que libera _ocupado', () {
      final iCatch = editor.indexOf('gympedia_publicar_fallo');
      final iFinally = editor.indexOf('setState(() => _ocupado = false)',
          iCatch);
      expect(iCatch, greaterThanOrEqualTo(0));
      expect(iFinally, greaterThan(iCatch),
          reason: 'tras el catch de publicar debe seguir el '
              'finally que apaga _ocupado');
    });

    test('la hermana Guía conserva su patrón (el espejo no lo '
        'sustituye)', () {
      final guia = File('lib/ui/guia_editor.dart').readAsStringSync();
      expect(guia, contains("AppLog.error('ui', 'guia_publicar_fallo'"));
      expect(guia, contains("AppLog.error('ui', 'guia_borrador_fallo'"));
      expect(guia, contains("AppLog.error('ui', 'guia_retirar_fallo'"));
    });
  });
}
