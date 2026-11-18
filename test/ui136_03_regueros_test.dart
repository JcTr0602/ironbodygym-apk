/// UI136-03 (adjudicación ARGON-136-UI, hallazgo H5): regueros
/// permanentes contra la Regla 1 de Jc (lo ocasional va plegado o
/// tras un botón con el estado resumido; el espacio permanente es
/// del contenido). Tres escenas:
///  1. Control de acceso: la fila de botones «Adopción / Campaña
///     WA» (navegación ocasional) sale de la pila fija y vive en
///     un menú; el contador deja su fila propia y se une a la
///     fila de filtros.
///  2. Agregar pago: el ChoiceChip «Solo vencidos» deja su fila
///     dedicada y comparte la fila del buscador.
///  3. Pestaña Nómina: «Cierre de mes» deja de tener dos puertas
///     en el primer pantallazo (chip del pilar + tarjeta guiada
///     de la propia pantalla): queda la tarjeta guiada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('UI136-03 · Control de acceso', () {
    final s = _src('lib/ui/control_acceso.dart');
    test('Adopción y Campaña WA ya no son botones en fila fija', () {
      expect(s.contains("label: const Text('Adopción')"), isFalse);
      expect(s.contains("label: const Text('Campaña WA')"), isFalse);
    });
    test('los destinos siguen alcanzables desde un menú', () {
      expect(s.contains('PopupMenuButton'), isTrue);
      expect(s.contains('EstadisticasAdopcionScreen'), isTrue);
      expect(s.contains('CampanaWaScreen'), isTrue);
    });
    test('el contador ya no ocupa una fila propia con Align', () {
      expect(
          s.contains('child: Align(\n            alignment: '
              'Alignment.centerLeft,\n            child: Text(\n              '
              '_vista == '),
          isFalse);
    });
  });

  group('UI136-03 · Agregar pago', () {
    final s = _src('lib/ui/pago.dart');
    test('el chip «Solo vencidos» ya no tiene fila dedicada', () {
      expect(
          s.contains('child: Row(\n              children: [\n'
              '                ChoiceChip('),
          isFalse);
    });
    test('el filtro sigue existiendo, una sola vez', () {
      expect('ChoiceChip('.allMatches(s).length, 1);
      expect(s.contains("'Solo vencidos'"), isTrue);
    });
  });

  group('UI136-03 · Pestaña Nómina sin doble puerta', () {
    final s = _src('lib/ui/pilar_negocio.dart');
    test('el pilar ya no enlaza «Cierre de mes» sobre la nómina', () {
      expect(s.contains("('Cierre de mes', Icons.lock_rounded"), isFalse);
    });
    test('la nómina embebida y los otros dos enlaces se quedan', () {
      expect(s.contains('NominaScreen(embebida: true)'), isTrue);
      expect(s.contains("'Precalculada'"), isTrue);
      expect(s.contains("'Panel del negocio'"), isTrue);
    });
    test('la tarjeta guiada de la pantalla sigue siendo la puerta', () {
      final n = _src('lib/ui/nomina.dart');
      expect(n.contains('Cierre de mes guiado'), isTrue);
    });
  });
}
