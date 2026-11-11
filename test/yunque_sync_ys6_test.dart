/// Yunque de Sincronización · YS-6 — A-2 cerrado a favor del
/// código: el sello de éxito juzga ESTA corrida, no la
/// historia de la cola.
///
/// La pregunta de A-2: una op que quedó en 'error' en una
/// corrida ANTERIOR y que en esta corrida ni se intenta (sigue
/// en su backoff, o su turno no llegó), ¿bloquea el sello de
/// «sincronizado»? Decisión: NO. El sello responde «esta
/// corrida subió y bajó limpio», no «la cola está
/// históricamente vacía de errores» — para eso están las
/// puertas y contadores (YS-2). Si el sello mirara el estado
/// acumulado, una sola op envenenada condenaría el indicador
/// para siempre aunque todo lo demás fluya.
///
/// El mecanismo que lo garantiza ya vive en el código:
/// `_fallosUltimoPush` se REINICIA a la entrada de cada
/// `_doPush` y SOLO se incrementa dentro de
/// `_bumpConReversion` (el golpe contra la pared de ESTA
/// corrida). Lo que no existía era el pin: si alguien mueve
/// el incremento a otro sitio (p. ej. al marcar una op en
/// error) o quita el reinicio, el criterio se rompe en
/// silencio. Estos pines estructurales lo fijan (mismo patrón
/// que el grupo A-2 de la Auditoría Definitiva).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sync = File('lib/sync.dart').readAsStringSync();

  group('YS-6 · el sello juzga solo esta corrida', () {
    test('el contador de fallos se reinicia a la entrada de '
        '_doPush', () {
      final i = sync.indexOf('Future<int> _doPush(');
      expect(i, isNonNegative, reason: 'no se encontró _doPush');
      final fin = sync.indexOf('\n  Future<', i + 10);
      final cuerpo = sync.substring(i, fin < 0 ? sync.length : fin);
      expect(cuerpo, contains('_fallosUltimoPush = 0;'),
          reason: 'sin el reinicio, los fallos de corridas '
              'anteriores bloquearían el sello para siempre');
      // Y el reinicio ocurre exactamente una vez en el
      // archivo (la declaración `int _fallosUltimoPush = 0;`
      // no cuenta: el regex exige la asignación pelada al
      // inicio de la sentencia).
      expect(
          RegExp(r'^\s+_fallosUltimoPush = 0;', multiLine: true)
              .allMatches(sync)
              .length,
          1,
          reason: 'apareció otro reinicio del contador: el '
              'criterio de la corrida se vuelve ambiguo');
    });

    test('el contador SOLO se incrementa en un sitio: el bump '
        'de esta corrida', () {
      expect('_fallosUltimoPush++'.allMatches(sync).length, 1,
          reason: 'otro sitio incrementa el contador (¿al '
              'marcar error una op vieja?): el sello pasaría a '
              'juzgar la historia, no la corrida');
      final i = sync.indexOf('Future<void> _bumpConReversion');
      expect(i, isNonNegative);
      final cuerpo = sync.substring(i, i + 500);
      expect(cuerpo, contains('_fallosUltimoPush++'),
          reason: 'el incremento único ya no está en el bump');
    });

    test('el veredicto de la corrida depende solo del '
        'contador', () {
      expect(sync,
          contains('bool get _ultimoPushLimpio => _fallosUltimoPush == 0;'),
          reason: 'el getter cambió: el sello ya no es función '
              'pura de los golpes de esta corrida');
      expect(sync, contains('pushOk = _ultimoPushLimpio;'),
          reason: 'run() dejó de sellar con el veredicto de '
              'la corrida');
    });
  });
}
