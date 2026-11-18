// H-B4 (136-870/880): contratos de congelaciones.
// - 880: los mensajes amables de la capa de servicio son los
//   que viajan en el sobre {ok:false,error:...} cuando la RPC
//   de resolver/cerrar/listar lanza.
// - 870: la atribución de inscripciones reusa la pura de
//   identidad: registrado_por numérico (telegram id) manda
//   sobre el nombre; sin id, manda el nombre normalizado.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/congelaciones_gestion.dart';
import 'package:ironbody_gym/entrenador_identidad.dart';

void main() {
  group('136-880 mensajes amables del sobre', () {
    test('listar/resolver/cerrar devuelven su rama propia', () {
      expect(mensajeListarCongelacionesFallido('boom'),
          contains('No se pudieron cargar las congelaciones'));
      expect(mensajeResolverCongelacionFallido('boom'),
          contains('No se pudo resolver la solicitud'));
      expect(mensajeCerrarCongelacionFallido('boom'),
          contains('No se pudo cerrar la congelación'));
      // Ninguna rama filtra el error crudo del servidor.
      for (final m in [
        mensajeListarCongelacionesFallido('boom'),
        mensajeResolverCongelacionFallido('boom'),
        mensajeCerrarCongelacionFallido('boom'),
      ]) {
        expect(m, isNot(contains('boom')));
      }
    });
  });

  group('136-870 atribución de inscripciones por id', () {
    test('registrado_por numérico manda sobre el nombre', () {
      final fila = {
        'registrado_por': '735772141',
        'registrado_por_nombre': 'Otro Nombre',
        'telegram_user_id': '735772141',
      };
      expect(
        filaEsDelEntrenador(fila, telegramId: 735772141, nombre: 'X'),
        isTrue,
      );
      expect(
        filaEsDelEntrenador(fila, telegramId: 111, nombre: 'Otro Nombre'),
        isFalse,
      );
    });

    test('sin id, el nombre normalizado decide', () {
      final fila = {
        'registrado_por': 'Duany',
        'registrado_por_nombre': '',
        'telegram_user_id': 'Duany',
      };
      expect(
        filaEsDelEntrenador(fila, telegramId: null, nombre: 'duany'),
        isTrue,
      );
      expect(
        filaEsDelEntrenador(fila, telegramId: null, nombre: 'Gabriel'),
        isFalse,
      );
    });
  });
}
