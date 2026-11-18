/// H-C2 (1.36) G6 GymPedia/plan/comunidad/plantillas/
/// recordatorios — 136-956, 136-975, 136-976.
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
/// (filas PARCIALES: solo la parte confirmada).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/gympedia_validacion.dart';
import 'package:ironbody_gym/plantilla_mensaje.dart';

void main() {
  group('136-956 coincideBusqueda ignora acentos', () {
    final articulo = <String, dynamic>{
      'titulo': 'Nutrición para ganar masa',
      'slug': 'nutricion-ganar-masa',
      'categoria': 'nutricion',
    };

    test('«nutricion» encuentra «Nutrición»', () {
      expect(GympediaValidacion.coincideBusqueda(articulo, 'nutricion'),
          isTrue);
      expect(GympediaValidacion.coincideBusqueda(articulo, 'NUTRICIÓN'),
          isTrue);
    });

    test('la categoría también casa sin acentos', () {
      final otro = <String, dynamic>{
        'titulo': 'Dormir mejor',
        'slug': 'dormir-mejor',
        'categoria': 'descanso',
      };
      expect(GympediaValidacion.coincideBusqueda(otro, 'recuperacion'),
          isTrue);
    });

    test('lo que no coincide sigue sin coincidir', () {
      expect(GympediaValidacion.coincideBusqueda(articulo, 'pesas'),
          isFalse);
    });
  });

  group('136-976 renderPlantilla en una sola pasada', () {
    test('un valor con llaves NO se re-sustituye', () {
      final r = renderPlantilla('Hola {{nombre}}', {
        'nombre': '{dias_restantes}',
        'dias_restantes': '5',
      });
      expect(r.texto, 'Hola {dias_restantes}');
    });

    test('la doble prohibida queda literal y se reporta una vez', () {
      final r = renderPlantilla(
          'Motivo: {{motivo}} y otra vez {{motivo}}', const {});
      expect(r.texto, 'Motivo: {{motivo}} y otra vez {{motivo}}');
      expect(r.bloqueadas, ['motivo']);
    });

    test('la sintaxis simple sigue funcionando', () {
      final r = renderPlantilla('Hola {nombre}', {'nombre': 'Ana'});
      expect(r.texto, 'Hola Ana');
    });
  });

  group('136-975 avisoFrescura normaliza el sello', () {
    test('sello UTC de hace 5 h avisa; el de hace 1 h no', () {
      final ahora = DateTime(2026, 11, 18, 12, 0); // pared Habana
      final viejo = DateTime.utc(2026, 11, 18, 12, 0)
          .toIso8601String(); // 07:00 Habana = hace 5 h
      final fresco = DateTime.utc(2026, 11, 18, 16, 0)
          .toIso8601String(); // 11:00 Habana = hace 1 h
      expect(
          avisoFrescura(
              ultimoPullIso: viejo, opsPendientes: 0, ahora: ahora),
          isNotNull);
      expect(
          avisoFrescura(
              ultimoPullIso: fresco, opsPendientes: 0, ahora: ahora),
          isNull);
    });
  });
}
