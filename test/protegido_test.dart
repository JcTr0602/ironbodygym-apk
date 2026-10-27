/// Tests de Cliente Protegido (2026-10-26, diseño Argón).
///
/// Solo el helper puro (sin sesión activa: esVistaProtegida se llama
/// siempre con esDueno explícito, así AuthService nunca se instancia).
/// La UI (candado en listas, ficha bloqueada, selectores) se verifica
/// por analyze + revisión del gating en cada pantalla.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cliente_protegido.dart';

void main() {
  group('clienteEstaProtegido', () {
    test('int 1 es protegido, 0 no', () {
      expect(clienteEstaProtegido({'protegido': 1}), isTrue);
      expect(clienteEstaProtegido({'protegido': 0}), isFalse);
    });
    test('String y bool tolerados (espejo JSON / SQLite)', () {
      expect(clienteEstaProtegido({'protegido': '1'}), isTrue);
      expect(clienteEstaProtegido({'protegido': 'true'}), isTrue);
      expect(clienteEstaProtegido({'protegido': true}), isTrue);
      expect(clienteEstaProtegido({'protegido': '0'}), isFalse);
      expect(clienteEstaProtegido({'protegido': false}), isFalse);
    });
    test('ausente o null no es protegido', () {
      expect(clienteEstaProtegido({}), isFalse);
      expect(clienteEstaProtegido({'protegido': null}), isFalse);
    });
  });
  group('esVistaProtegida', () {
    test('protegido + entrenador = bloqueada', () {
      expect(esVistaProtegida({'protegido': 1}, esDueno: false), isTrue);
    });
    test('protegido + dueño = normal', () {
      expect(esVistaProtegida({'protegido': 1}, esDueno: true), isFalse);
    });
    test('no protegido + entrenador = normal', () {
      expect(esVistaProtegida({'protegido': 0}, esDueno: false), isFalse);
      expect(esVistaProtegida({}, esDueno: false), isFalse);
    });
  });
  test('textos con el mensaje acordado', () {
    expect(mensajeClienteProtegido.contains('dueño'), isTrue);
    expect(bannerClienteProtegido.contains('Jctr0602'), isTrue);
  });
}
