/// UI136-10 (adjudicación ARGON-136-UI, hallazgo H10): la
/// regla del dueño — el avatar es la FOTO en miniatura y la
/// letra solo es el respaldo. Tres sitios pintaban otra
/// cosa: el Hub con un CircleAvatar manual de inicial (sin
/// foto nunca), Pagaron el mes con un ✓ fijo para todo el
/// que no tenía foto, y Actividad cayendo siempre al icono
/// de categoría aunque hubiera cliente.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

String _tramo(String s, String marca, int chars) {
  final i = s.indexOf(marca);
  expect(i, greaterThanOrEqualTo(0), reason: 'no aparece $marca');
  final fin = i + chars > s.length ? s.length : i + chars;
  return s.substring(i, fin);
}

void main() {
  test('UI136-10 · Hoy trabajan usa AvatarEntrenador (foto real)', () {
    final s = _src('lib/ui/hub_turnos.dart');
    final t = _tramo(s, "const Text('Hoy trabajan:'", 2200);
    expect(t.contains('AvatarEntrenador('), isTrue);
    expect(t.contains('nombre: n, tamano: 26'), isTrue);
    expect(t.contains('colorChipEntrenador(n)'), isFalse,
        reason: 'el CircleAvatar manual de inicial se fue');
  });

  test('UI136-10 · Pagaron el mes: inicial del cliente, no ✓ fijo',
      () {
    final s = _src('lib/ui/pagaron_mes.dart');
    final t = _tramo(s, 'class ClienteAvatarThumb extends', 4600);
    expect(t.contains('final String nombre'), isTrue);
    expect(t.contains('Icons.verified_rounded'), isFalse,
        reason: 'el ✓ fijo para todos desaparece');
    expect(t.contains('toUpperCase()'), isTrue,
        reason: 'el respaldo sin foto es la inicial');
    expect(s.contains("nombre: '\${c['nombre'] ?? ''}'"), isTrue,
        reason: 'el llamador pasa el nombre de la fila');
  });

  test('UI136-10 · Actividad: inicial si hay cliente, icono si no',
      () {
    final s = _src('lib/ui/actividad.dart');
    final t = _tramo(s, 'Widget _avatarActividad(', 1900);
    expect(t.contains('nombreCliente'), isTrue);
    expect(t.contains('toUpperCase()'), isTrue);
    expect(t.contains('_iconoAvatar(color, icono)'), isTrue,
        reason: 'sin nombre real queda el icono de categoría');
    expect(s.contains('nombreCliente:'), isTrue,
        reason: 'el llamador pasa el nombre cuando es real');
  });
}
