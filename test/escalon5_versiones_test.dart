/// Escalón 5 (1.32) · Piezas 2+3 — COMPUERTA de versión y
/// novedades.
///
/// La 1.31 salió SIN su entrada en «Lo Nuevo» (la lista se
/// quedó en 1.30.0) y AppConfig.appVersion quedó una versión
/// por detrás del pubspec. Esta compuerta ata las TRES fuentes
/// para que no vuelva a pasar: la suite FALLA si la primera
/// entrada de `novedades` no coincide con la versión de la app
/// en pubspec.yaml y en AppConfig, o si AppConfig y pubspec se
/// desafasan entre sí (literal completo, con build).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/novedades.dart';

File? _buscarPubspec() {
  var dir = Directory.current;
  while (true) {
    final f = File('${dir.path}/pubspec.yaml');
    if (f.existsSync()) return f;
    final padre = dir.parent;
    if (padre.path == dir.path) return null;
    dir = padre;
  }
}

String _versionPubspec() {
  final pubspec = _buscarPubspec();
  expect(pubspec, isNotNull,
      reason: 'No se encontró pubspec.yaml sobre el directorio actual');
  final m = RegExp(r'''^version:\s*["']?([^"'\s]+)["']?\s*$''',
          multiLine: true)
      .firstMatch(pubspec!.readAsStringSync());
  expect(m, isNotNull, reason: 'pubspec.yaml sin línea version:');
  return m!.group(1)!;
}

void main() {
  test('compuerta: pubspec y AppConfig.appVersion son el mismo literal',
      () {
    expect(AppConfig.appVersion, _versionPubspec(),
        reason:
            'Al subir la versión hay que tocar pubspec.yaml Y '
            'AppConfig.appVersion en lib/config.dart a la vez');
  });

  test('compuerta: la primera novedad es la versión actual', () {
    final semantica = _versionPubspec().split('+').first;
    expect(novedades, isNotEmpty);
    expect(novedades.first.version, semantica,
        reason:
            'La última entrada de «Lo Nuevo» (lib/novedades.dart) '
            'debe ser la versión del pubspec: $semantica');
    expect(novedades.first.cambios, isNotEmpty,
        reason: 'la versión actual debe traer cambios que contar');
    // Y la versión según AppConfig (sin build) es la misma.
    expect(AppConfig.appVersion.split('+').first, semantica);
  });

  test('la doble entrada de la 1.32: 1.31.0 existe y no está vacía',
      () {
    // La 1.31.0 se entregó sin entrada propia; la 1.32 la trae
    // de forma retroactiva. Si alguien la «limpia», la suite
    // grita: los teléfonos que saltan de la 1.30 a la 1.32
    // merecen leer también lo que trajo la 1.31.
    final e131 = novedades.where((n) => n.version == '1.31.0').toList();
    expect(e131, hasLength(1),
        reason: 'falta la entrada retroactiva de la 1.31.0');
    expect(e131.single.cambios, isNotEmpty);
  });
}
