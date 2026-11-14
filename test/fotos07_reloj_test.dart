/// 1.34 (FOTOS-07): la política de la cola de precarga
/// (backoff de 45 s y ventana de aterrizaje de 3 min)
/// colgaba del reloj de PARED: un retroceso manual de la
/// hora dejaba diferencias negativas y la ruta quedaba
/// «dentro de ventana» mucho más allá de su plazo. La
/// instancia de producción de FotoCache ahora inyecta
/// [relojMonotonico]. Estos tests fijan el reloj y la
/// política medida con él; el test de caracterización
/// documenta el defecto con el reloj de pared inyectado.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FOTOS-07 · relojMonotonico', () {
    test('avanza con el tiempo real y nunca retrocede', () async {
      final reloj = relojMonotonico();
      final t0 = reloj();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final t1 = reloj();
      final dif = t1.difference(t0);
      expect(dif >= const Duration(milliseconds: 30), isTrue,
          reason: 'el reloj monotónico mide el tiempo '
              'transcurrido de verdad');
      expect(dif < const Duration(seconds: 10), isTrue);
      final t2 = reloj();
      expect(t2.isBefore(t1), isFalse,
          reason: 'monotónico: jamás da un instante '
              'anterior al previo');
    });

    test('cada reloj nace en su propio arranque', () async {
      final a = relojMonotonico();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final b = relojMonotonico();
      expect(b().difference(a()) < const Duration(milliseconds: 40),
          isTrue,
          reason: 'el segundo reloj arranca después: su '
              'instante va por detrás del primero');
    });
  });

  group('FOTOS-07 · la cola medida con el reloj monotónico', () {
    ColaPrecargaFotos colaCorta() => ColaPrecargaFotos(
          descargador: (ruta, timeout) async => null,
          ahora: relojMonotonico(),
          backoffFallo: const Duration(milliseconds: 40),
          ventanaAterrizaje: const Duration(milliseconds: 40),
        );

    test('la ventana de aterrizaje expira por tiempo transcurrido',
        () async {
      final cola = colaCorta();
      cola.registrarAterrizaje('clientes/1/a_display.webp');
      expect(cola.recienAterrizada('clientes/1/a_display.webp'),
          isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cola.recienAterrizada('clientes/1/a_display.webp'),
          isFalse,
          reason: 'pasada la ventana REAL, la ruta puede '
              'volver a pedirse: ningún salto de reloj la '
              'retiene');
    });

    test('el backoff expira por tiempo transcurrido', () async {
      final cola = colaCorta();
      cola.registrarFallo('clientes/1/a_display.webp');
      expect(cola.enBackoff('clientes/1/a_display.webp'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cola.enBackoff('clientes/1/a_display.webp'), isFalse);
    });
  });

  group('FOTOS-07 · caracterización del defecto (reloj de pared)',
      () {
    test('con un reloj de pared que RETROCEDE, la ventana se '
        'extiende sin plazo — por eso producción no lo usa',
        () async {
      var ahora = DateTime(2026, 11, 13, 12, 0);
      final cola = ColaPrecargaFotos(
        descargador: (ruta, timeout) async => null,
        ahora: () => ahora,
        ventanaAterrizaje: const Duration(minutes: 3),
      );
      cola.registrarAterrizaje('clientes/1/a_display.webp');
      // El usuario atrasa la hora del teléfono una hora…
      ahora = ahora.subtract(const Duration(hours: 1));
      expect(cola.recienAterrizada('clientes/1/a_display.webp'),
          isTrue);
      // …y desde esa hora atrasada «pasan» 10 minutos:
      ahora = ahora.add(const Duration(minutes: 10));
      expect(
          cola.recienAterrizada('clientes/1/a_display.webp'),
          isTrue,
          reason: 'documentado: la diferencia con el '
              'instante de aterrizaje sigue siendo NEGATIVA '
              '(−50 min < 3 min) y la ruta se cree recién '
              'aterrizada mucho más allá de su ventana');
    });
  });
}
