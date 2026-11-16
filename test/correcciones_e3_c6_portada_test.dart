/// 1.35 (corrección E3, C6-01 del Yunque de Cambios): la
/// portada del dueño anunciaba el mismo pendiente dos
/// veces — adelantos y rellenos en «Por Decidir» Y en la
/// tarjeta del Buzón (mismos conteos de ConteoBuzon);
/// incidencias en «Por Decidir» Y en la fila de la tira
/// de alertas; solicitudes de inscripción y reportes
/// Plus fila a fila en «Por Decidir» Y agregados en la
/// fila «Esperando atención» de la tira.
///
/// Criterio: «Por Decidir» es la bandeja ÚNICA de la
/// portada. El Buzón anuncia en portada solo lo que Por
/// Decidir no cubre (reservas y conciliaciones); la tira
/// pierde las filas «Esperando atención» e «Incidencias»
/// (la señal de atención y el conteo de incidencias se
/// quedan donde ya eran la voz única: la insignia de
/// urgencias de la barra y Por Decidir). La bandeja del
/// Buzón (su pantalla) no cambia: usa `partes` entero.
///
/// Verificación: la pieza de la portada es un getter puro
/// (probado aquí directamente) + contratos de fuente del
/// cableado en home.dart. El arnés de la Home ensamblada
/// no aterriza los valores de _cargar bajo FakeAsync
/// (limitación conocida de la casa, documentada en
/// fase4_mostrador_test), así que el montaje completo no
/// es el discriminante: sobre la base de074a6 los
/// contratos de fuente son rojos (la tira trae las dos
/// filas y la tarjeta itera `partes` entero).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/buzon_dueno.dart';

void main() {
  group('E3 · C6-01: la voz del Buzón en la portada', () {
    test('partesPortada: solo reservas y conciliaciones, '
        'en su orden', () {
      const b = ConteoBuzon(
          reservas: 2, adelantos: 3, rellenos: 1, conciliaciones: 4);
      expect(
          b.partesPortada.map((p) => p.destino).toList(),
          [DestinoBuzon.reservas, DestinoBuzon.conciliaciones]);
      // La bandeja no cambia: partes sigue entero.
      expect(b.partes, hasLength(4));
      expect(b.hay, isTrue);
    });

    test('hayPortada: con solo adelantos o rellenos la '
        'tarjeta no existe en la portada', () {
      expect(const ConteoBuzon(adelantos: 2).hayPortada, isFalse);
      expect(const ConteoBuzon(rellenos: 1).hayPortada, isFalse);
      expect(const ConteoBuzon().hayPortada, isFalse);
      expect(const ConteoBuzon(reservas: 1).hayPortada, isTrue);
      expect(
          const ConteoBuzon(conciliaciones: 1).hayPortada, isTrue);
      // Y sin partes de portada, la lista sale vacía.
      expect(const ConteoBuzon(adelantos: 2).partesPortada,
          isEmpty);
    });
  });

  group('E3 · C6-01: el cableado de la portada', () {
    final home = File('lib/ui/home.dart').readAsStringSync();

    test('la tarjeta del Buzón itera partesPortada y su '
        'presencia la manda hayPortada', () {
      expect(home, contains('_buzon.partesPortada'));
      expect(home, contains('hayBuzon: _buzon.hayPortada'));
    });

    test('la tira ya no trae «Esperando atención» ni la '
        'fila «Incidencias»', () {
      expect(home, isNot(contains('Esperando atención')));
      expect(home, isNot(contains("texto: 'Incidencias'")));
    });
  });
}
