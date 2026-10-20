// Test v1.4.1 (Pieza 4, hallazgo 4.1 de Argón): guarda de sincronía de
// versión. AppConfig.appVersion se mantiene a mano en lib/config.dart y
// en la build 1.4.0+58 quedó desactualizado ('1.3.4+52'). Este test
// falla si el literal no coincide con la línea `version:` de
// pubspec.yaml, para que el desfase no vuelva a llegar a una build.
//
// Robustez (revisión de código del panel, 2026-10-20): localiza
// pubspec.yaml subiendo desde el directorio de trabajo (no depende del
// cwd exacto del lanzador) y admite el valor YAML entre comillas.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';

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

void main() {
  test('AppConfig.appVersion coincide con pubspec.yaml', () {
    final pubspec = _buscarPubspec();
    expect(pubspec, isNotNull,
        reason: 'No se encontró pubspec.yaml sobre el directorio actual');
    final contenido = pubspec!.readAsStringSync();
    final m = RegExp(r'''^version:\s*["']?([^"'\s]+)["']?\s*$''',
            multiLine: true)
        .firstMatch(contenido);
    expect(m, isNotNull, reason: 'pubspec.yaml sin línea version:');
    expect(m!.group(1), AppConfig.appVersion,
        reason:
            'Actualiza AppConfig.appVersion en lib/config.dart al subir la versión');
  });
}
