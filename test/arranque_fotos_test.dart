/// Adenda de campo 1.31 (2026-11-09) — arranque y fotos con
/// red mala: contratos de fuente de las tres piezas.
/// 1) El registro de WorkManager no se espera antes de
///    runApp (hasta ~10 s de logo con el canal colgado).
/// 2) Los widgets de lista no descargan fotos: solo disco
///    (foto_local → enCache) + precarga encolada de FotoCache.
/// 3) El ciclo de sync de arranque lleva presupuesto total
///    con cortacircuitos, como la pasada del manifiesto.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos.dart';

String _src(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('pieza 1 · arranque sin esperar a WorkManager', () {
    final main = _src('lib/main.dart');

    test('main() dispara el registro sin await', () {
      expect(main.contains('unawaited(_programarSubidaFondo())'), isTrue,
          reason: 'el registro de fondo no bloquea el primer pintado');
      expect(main.contains('await _programarSubidaFondo()'), isFalse,
          reason: 'ningún await al registro antes de runApp');
    });

    test('el registro conserva sus timeouts como cota propia', () {
      // Fuera del camino crítico, los timeouts de YB-TRA-09
      // siguen acotando el registro en segundo plano.
      final cuerpo = main.substring(
          main.indexOf('Future<void> _programarSubidaFondo()'),
          main.indexOf('/// 1.23: tarea ÚNICA de subida'));
      expect('timeout('.allMatches(cuerpo).length, greaterThanOrEqualTo(2));
    });
  });

  group('pieza 2 · avatar en dos fases (contratos de fuente)', () {
    test('la fila de Buscar y AvatarClienteConFoto ya no descargan', () {
      for (final ruta in ['lib/ui/buscar.dart', 'lib/ui/componentes.dart']) {
        final src = _src(ruta);
        expect(src.contains('FotoCache.instance.obtener('), isFalse,
            reason: '$ruta: la lista no espera descargas (obtener '
                'queda para la ficha)');
        expect(src.contains('FotoCache.instance.precargar('), isTrue,
            reason: '$ruta: la red va por la cola de precarga');
        expect(src.contains('aterrizajes'), isTrue,
            reason: '$ruta: repinta por escucha al aterrizar la foto');
      }
    });

    test('la ficha conserva su descarga deliberada con obtener()', () {
      expect(
          _src('lib/ui/ficha.dart')
              .contains('FotoCache.instance\n            .obtener('),
          isTrue);
    });
  });

  group('pieza 2 · ColaPrecargaFotos (política pura)', () {
    var reloj = DateTime(2026, 11, 9, 12);
    ColaPrecargaFotos colaCon(
      Future<File?> Function(String, Duration) descargador, {
      int concurrencia = 3,
    }) =>
        ColaPrecargaFotos(
          descargador: descargador,
          concurrencia: concurrencia,
          ahora: () => reloj,
        );

    setUp(() => reloj = DateTime(2026, 11, 9, 12));

    test('concurrencia: nunca más de N descargas a la vez', () async {
      var enVuelo = 0;
      var maxEnVuelo = 0;
      final compuertas = <String, Completer<File?>>{};
      final cola = colaCon((ruta, t) {
        enVuelo++;
        if (enVuelo > maxEnVuelo) maxEnVuelo = enVuelo;
        final c = Completer<File?>();
        compuertas[ruta] = c;
        return c.future.whenComplete(() => enVuelo--);
      }, concurrencia: 2);
      cola.encolar(['a', 'b', 'c', 'd']);
      expect(compuertas.keys.toSet(), {'a', 'b'});
      compuertas['a']!.complete(File('a'));
      await Future<void>.delayed(Duration.zero);
      expect(compuertas.keys.toSet(), {'a', 'b', 'c'});
      compuertas['b']!.complete(File('b'));
      compuertas['c']!.complete(File('c'));
      await Future<void>.delayed(Duration.zero);
      expect(compuertas.keys.toSet(), {'a', 'b', 'c', 'd'});
      compuertas['d']!.complete(File('d'));
      await Future<void>.delayed(Duration.zero);
      expect(maxEnVuelo, 2);
    });

    test('deduplicación: la misma ruta no se baja dos veces', () async {
      var llamadas = 0;
      final cola = colaCon((ruta, t) async {
        llamadas++;
        return File(ruta);
      });
      cola.encolar(['x', 'x']);
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(llamadas, 1);
    });

    test('el timeout que recibe el descargador es el corto de la cola',
        () async {
      Duration? visto;
      final cola = colaCon((ruta, t) async {
        visto = t;
        return File(ruta);
      });
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(visto, const Duration(seconds: 10));
    });

    test('caché negativa: el fallo bloquea reintentos hasta el backoff',
        () async {
      var llamadas = 0;
      final cola = colaCon((ruta, t) async {
        llamadas++;
        return null; // descarga fallida
      });
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(llamadas, 1);
      expect(cola.enBackoff('x'), isTrue);
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(llamadas, 1, reason: 'en backoff no se reintenta');
      reloj = reloj.add(const Duration(minutes: 3, seconds: 1));
      expect(cola.enBackoff('x'), isFalse);
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(llamadas, 2, reason: 'pasado el backoff sí se reintenta');
    });

    test('aterrizaje: el éxito avisa la ruta y limpia el fallo', () async {
      var debeFallar = true;
      final cola = colaCon((ruta, t) async =>
          debeFallar ? null : File(ruta));
      final avisos = <String>[];
      final sub = cola.aterrizajes.listen(avisos.add);
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(cola.enBackoff('x'), isTrue);
      cola.olvidarFallo('x');
      debeFallar = false;
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(avisos, ['x']);
      expect(cola.enBackoff('x'), isFalse);
      await sub.cancel();
    });

    test('registrarFallo externo también frena la cola', () async {
      var llamadas = 0;
      final cola = colaCon((ruta, t) async {
        llamadas++;
        return File(ruta);
      });
      cola.registrarFallo('x'); // p. ej. la ficha falló con obtener()
      cola.encolar(['x']);
      await Future<void>.delayed(Duration.zero);
      expect(llamadas, 0);
    });
  });
}
