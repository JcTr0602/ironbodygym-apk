/// 1.25 T86: la identidad del entrenador es su
/// telegram_id. Dos tocayos no se mezclan; el nombre
/// solo manda en las filas viejas sin ID.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/entrenador_identidad.dart';

void main() {
  group('claveIdentidadEntrenador', () {
    test('con telegram_user_id la clave es el ID', () {
      expect(
        claveIdentidadEntrenador({
          'telegram_user_id': 111,
          'registrado_por_nombre': 'Gabriel',
        }),
        'tid:111',
      );
    });

    test('sin ID pero con nombre que resuelve, también ID', () {
      expect(
        claveIdentidadEntrenador(
          {'registrado_por_nombre': 'Gabriel'},
          tidPorNombre: const {'gabriel': 111},
        ),
        'tid:111',
      );
    });

    test('sin ID ni resolución, clave por nombre', () {
      expect(
        claveIdentidadEntrenador(
          {'registrado_por_nombre': '  Pepe '},
        ),
        'nom:pepe',
      );
    });

    test('el telegram como texto también resuelve', () {
      expect(
        claveIdentidadEntrenador({
          'telegram_user_id': '222',
          'registrado_por_nombre': 'Duany',
        }),
        'tid:222',
      );
    });
  });

  group('filaEsDelEntrenador', () {
    test('tocayo con otro ID NO es suyo', () {
      expect(
        filaEsDelEntrenador(
          {
            'telegram_user_id': 999,
            'registrado_por_nombre': 'Gabriel',
          },
          telegramId: 111,
          nombre: 'Gabriel',
        ),
        isFalse,
      );
    });

    test('mismo ID con nombre cambiado SÍ es suyo', () {
      expect(
        filaEsDelEntrenador(
          {
            'telegram_user_id': 111,
            'registrado_por_nombre': 'Gabo',
          },
          telegramId: 111,
          nombre: 'Gabriel',
        ),
        isTrue,
      );
    });

    test('fila vieja sin ID cae al nombre', () {
      expect(
        filaEsDelEntrenador(
          {'registrado_por_nombre': 'gabriel'},
          telegramId: 111,
          nombre: 'Gabriel',
        ),
        isTrue,
      );
      expect(
        filaEsDelEntrenador(
          {'registrado_por_nombre': 'Duany'},
          telegramId: 111,
          nombre: 'Gabriel',
        ),
        isFalse,
      );
    });

    test('sin ID conocido, manda el nombre', () {
      expect(
        filaEsDelEntrenador(
          {
            'telegram_user_id': 999,
            'registrado_por_nombre': 'Gabriel',
          },
          telegramId: null,
          nombre: 'Gabriel',
        ),
        isTrue,
      );
    });
  });

  group('nombreEntrenadorDeFila', () {
    test('prioriza registrado_por_nombre', () {
      expect(
        nombreEntrenadorDeFila({
          'registrado_por_nombre': ' Gabriel ',
          'registrado_por': 'otro',
        }),
        'Gabriel',
      );
    });

    test('sin nombres, Desconocido', () {
      expect(nombreEntrenadorDeFila({}), 'Desconocido');
    });
  });
}
