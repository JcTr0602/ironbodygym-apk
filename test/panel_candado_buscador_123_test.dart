/// 1.23 (campo 2026-11-03) — Buscador de persona del Panel del
/// candado: la unión clientes+invitados y su filtro son la
/// lógica que decide a quién se le aplica el candado por
/// persona; el id devuelto es el objetivo exacto que evalúa el
/// servidor (cliente_id / invitado_id como texto).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/ui/panel_candado.dart';

InvitadoResumen _inv(String id, String nombre, String estado,
        {String telefono = ''}) =>
    InvitadoResumen(
        id: id, nombre: nombre, telefono: telefono, estado: estado);

void main() {
  final clientes = <Map<String, dynamic>>[
    {'id': 205, 'nombre': 'Jctr0602', 'telefono': '58191577'},
    {'id': 77, 'nombre': 'María Pérez', 'telefono': '53220011'},
    {'id': 78, 'nombre': 'Mario Ruiz', 'telefono': '54998877'},
  ];
  final invitados = <InvitadoResumen>[
    _inv('uuid-1', 'Mario Invitado', 'activo', telefono: '51001122'),
    _inv('uuid-2', 'Lucía Convertida', 'convertido'),
    _inv('uuid-3', 'Pedro Plus', 'en_conversion'),
  ];

  test('sin consulta: todos los clientes y los invitados vivos', () {
    final r = personasCandadoFiltradas(
        clientes: clientes, invitados: invitados, consulta: '');
    expect(r.length, 5);
    expect(r.where((p) => p.esInvitado).length, 2);
    // La convertida NO entra: su identidad viva es de cliente.
    expect(r.any((p) => p.id == 'uuid-2'), isFalse);
  });

  test('filtra por nombre sin distinción de mayúsculas', () {
    final r = personasCandadoFiltradas(
        clientes: clientes, invitados: invitados, consulta: 'mario');
    expect(r.map((p) => p.nombre),
        containsAll(['Mario Ruiz', 'Mario Invitado']));
    expect(r.length, 2);
  });

  test('filtra por teléfono y por id de cliente', () {
    final porTel = personasCandadoFiltradas(
        clientes: clientes, invitados: invitados, consulta: '5819');
    expect(porTel.single.nombre, 'Jctr0602');
    final porId = personasCandadoFiltradas(
        clientes: clientes, invitados: invitados, consulta: '205');
    expect(porId.single.id, '205');
  });

  test('delta del panel H2: el teléfono pegado con espacios, '
      'guiones o +53 encuentra su fila', () {
    for (final consulta in ['58 19 15 77', '5819-1577', '+53 58191577']) {
      final r = personasCandadoFiltradas(
          clientes: clientes, invitados: invitados, consulta: consulta);
      expect(r.map((p) => p.nombre), contains('Jctr0602'),
          reason: 'consulta: $consulta');
    }
  });

  test('el nombre se busca sin tildes: «maria» encuentra a María',
      () {
    final r = personasCandadoFiltradas(
        clientes: clientes, invitados: invitados, consulta: 'maria');
    expect(r.map((p) => p.nombre), contains('María Pérez'));
    expect(r.map((p) => p.nombre), isNot(contains('Mario Ruiz')));
  });

  test('delta del panel (residual H1): un objetivo que coincide '
      'con el telegram_id de un entrenador colisiona', () {
    const telegramIds = ['969869611', '1403501391', '735772141'];
    expect(objetivoCandadoColisiona('969869611', telegramIds),
        isTrue);
    expect(objetivoCandadoColisiona('205', telegramIds), isFalse);
    expect(objetivoCandadoColisiona('uuid-1', telegramIds), isFalse);
  });

  test('el id del cliente viaja como texto (objetivo del servidor)',
      () {
    final r = personasCandadoFiltradas(
        clientes: clientes, invitados: invitados, consulta: 'Jctr');
    expect(r.single.id, '205');
    expect(r.single.esInvitado, isFalse);
    expect(r.single.detalle, 'Cliente #205');
  });
}
