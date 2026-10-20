// Test v1.4.1 (Pieza 4, hallazgo 4.1 de Argón): guarda de sincronía de
// versión. AppConfig.appVersion se mantiene a mano en lib/config.dart y
// en la build 1.4.0+58 quedó desactualizado ('1.3.4+52'). Este test
// falla si el literal no coincide con la línea `version:` de
// pubspec.yaml, para que el desfase no vuelva a llegar a una build.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';

void main() {
  test('AppConfig.appVersion coincide con pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml sin línea version:');
    expect(AppConfig.appVersion, m!.group(1),
        reason:
            'Actualiza AppConfig.appVersion en lib/config.dart al subir la versión');
  });
}
