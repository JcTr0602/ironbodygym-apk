/// 1.25 T87: la clave de identidad de las visitas del
/// invitado (la que agrupa sus conteos en el detalle y
/// alimenta la insignia de candidato) y el conteo por
/// invitado_id que usa la lista.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/visitas_invitados.dart';

void main() {
  group('claveIdentidadInvitado', () {
    test('el carnet de 11 dígitos manda', () {
      expect(
        claveIdentidadInvitado(
          carnet: '95062012345',
          telefono: '58191577',
          nombre: 'Pepe',
        ),
        'ci:95062012345',
      );
    });

    test('sin carnet, el teléfono de 8 (sin el 53)', () {
      expect(
        claveIdentidadInvitado(telefono: '5358191577'),
        'tel:58191577',
      );
      expect(
        claveIdentidadInvitado(telefono: '58191577'),
        'tel:58191577',
      );
    });

    test('sin carnet ni teléfono, el nombre normalizado', () {
      expect(
        claveIdentidadInvitado(nombre: '  Juan   Pérez '),
        'nom:juan perez',
      );
    });

    test('sin ningún dato, clave vacía', () {
      expect(claveIdentidadInvitado(), '');
      expect(claveIdentidadInvitado(carnet: '123'), '');
    });
  });
}
