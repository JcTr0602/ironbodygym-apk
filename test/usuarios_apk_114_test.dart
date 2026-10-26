/// Tests 1.14 (M6.9): la validación para crear un usuario APK.
/// Sin nombre válido o con contraseña corta no se encola nada.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/usuarios.dart';

void main() {
  test('nombre vacío no vale', () {
    expect(validarNuevoUsuarioApk('', '123456'),
        'Nombre vacío o contraseña muy corta (mín. 6)');
  });

  test('nombre de solo espacios no vale', () {
    expect(validarNuevoUsuarioApk('   ', '123456'),
        'Nombre vacío o contraseña muy corta (mín. 6)');
  });

  test('contraseña de menos de 6 no vale', () {
    expect(validarNuevoUsuarioApk('gabriel', '12345'),
        'Nombre vacío o contraseña muy corta (mín. 6)');
  });

  test('justo 6 vale; con espacios alrededor del nombre vale', () {
    expect(validarNuevoUsuarioApk('gabriel', '123456'), isNull);
    expect(validarNuevoUsuarioApk('  duany  ', 'abcdef'), isNull);
  });

  test('los espacios de la contraseña cuentan (no se recorta)', () {
    // 6 caracteres aunque sean espacios: la regla solo mide largo.
    expect(validarNuevoUsuarioApk('gabriel', '      '), isNull);
    expect(validarNuevoUsuarioApk('gabriel', '  ab '), isNotNull);
  });
}
