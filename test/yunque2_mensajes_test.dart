/// Yunque 2.34 (G-2) — el texto de credenciales del staff
/// cierra con la línea de mensaje automático (regla de Jc
/// 2026-11-01), como todos los demás mensajes que la app
/// compone (el del PIN se cerró en C6-4; este era el que
/// faltaba).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/usuarios.dart';

void main() {
  test('textoCredencialesStaff lleva usuario, contraseña y '
      'la línea automática al cierre', () {
    final t = textoCredencialesStaff('gabriel', 'clave123');
    expect(t, contains('*Usuario:* gabriel'));
    expect(t, contains('*Contraseña:* clave123'));
    expect(t.trimRight().endsWith(lineaMensajeAutomatico.trim()),
        isTrue);
    expect(t, contains('🤖 _Mensaje automático'));
    expect(t, contains('58191577'));
  });
}
