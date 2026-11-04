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

  test('1.23 tipo_objetivo: el dominio sale de la vía elegida',
      () {
    expect(
        tipoObjetivoCandado(
            personaTipo: 'entrenador',
            esInvitado: false,
            idManual: false,
            objetivo: '969869611'),
        'telegram');
    expect(
        tipoObjetivoCandado(
            personaTipo: 'cliente',
            esInvitado: false,
            idManual: false,
            objetivo: '205'),
        'cliente');
    expect(
        tipoObjetivoCandado(
            personaTipo: 'cliente',
            esInvitado: true,
            idManual: false,
            objetivo: 'uuid-invitado'),
        'invitado');
    // Vía manual: numérico = cliente; uuid = invitado. Un id de
    // cliente que coincida con un telegram ya NO se rechaza:
    // el dominio declarado hace la colisión inocua.
    expect(
        tipoObjetivoCandado(
            personaTipo: 'cliente',
            esInvitado: false,
            idManual: true,
            objetivo: '969869611'),
        'cliente');
    expect(
        tipoObjetivoCandado(
            personaTipo: 'cliente',
            esInvitado: false,
            idManual: true,
            objetivo: '9d2f1c44-1111-2222-3333-444455556666'),
        'invitado');
  });

  test('1.23 C-1: la app del candado se deriva del objetivo '
      '(regla D), como hace el bot', () {
    // Persona: entrenador (dominio telegram) → Gestión;
    // cliente/invitado (dominio Clientes) → Clientes.
    expect(
        appForzadaCandado(
            alcance: 'persona', rol: 'entrenador',
            personaTipo: 'entrenador'),
        'gestion');
    expect(
        appForzadaCandado(
            alcance: 'persona', rol: 'entrenador',
            personaTipo: 'cliente'),
        'clientes');
    // Rol: entrenadores → Gestión; clientes/invitados →
    // Clientes.
    expect(
        appForzadaCandado(
            alcance: 'rol', rol: 'entrenador',
            personaTipo: 'entrenador'),
        'gestion');
    expect(
        appForzadaCandado(
            alcance: 'rol', rol: 'cliente',
            personaTipo: 'entrenador'),
        'clientes');
    expect(
        appForzadaCandado(
            alcance: 'rol', rol: 'invitado',
            personaTipo: 'entrenador'),
        'clientes');
    // Sin dominio que ate la app: selector libre (null).
    expect(
        appForzadaCandado(
            alcance: 'app', rol: 'entrenador',
            personaTipo: 'entrenador'),
        isNull);
    expect(
        appForzadaCandado(
            alcance: 'global', rol: 'entrenador',
            personaTipo: 'entrenador'),
        isNull);
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
