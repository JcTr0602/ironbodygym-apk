/// UI136-05 (adjudicación ARGON-136-UI, hallazgo H2; extiende
/// la fila abierta 136-115): la norma de la casa — sobre
/// AppColores.naranja va AppColores.sobreMarca (el blanco da
/// 2,75:1) y el texto de alerta va con alertaTexto(context)
/// (el ámbar crudo da ~1,96:1 en tema claro). Los iconos de
/// aviso y el blanco sobre rojo/verde NO son alcance.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('UI136-05 · botones naranja sin blanco', () {
    test('pago_diario: ningún foreground blanco en el archivo', () {
      expect(
          _src('lib/ui/pago_diario.dart')
              .contains('foregroundColor: Colors.white'),
          isFalse);
    });
    test('actividad: ningún botón naranja con blanco', () {
      final s = _src('lib/ui/actividad.dart');
      final patron = RegExp(
          r'AppColores\.naranja,?\s*\n\s*foregroundColor: Colors\.white');
      expect(patron.hasMatch(s), isFalse,
          reason: 'queda un botón naranja con texto blanco');
      // Los dos sitios nombrados llevan sobreMarca.
      expect('foregroundColor: AppColores.sobreMarca'.allMatches(s).length,
          greaterThanOrEqualTo(2));
    });
    test('usuarios: Copiar/Cambiar/Crear con sobreMarca', () {
      final s = _src('lib/ui/usuarios.dart');
      expect('foregroundColor: AppColores.sobreMarca'.allMatches(s).length,
          3);
    });
  });

  group('UI136-05 · textos de alerta con su token de texto', () {
    test('por_decidir: la línea sin verificar usa alertaTexto', () {
      final s = _src('lib/ui/por_decidir.dart');
      expect(s.contains('.copyWith(color: AppColores.alerta)'), isFalse);
      expect(s.contains('AppColores.alertaTexto(context)'), isTrue);
    });
    test('actividad: el aviso de tasa usa alertaTexto', () {
      final s = _src('lib/ui/actividad.dart');
      expect(s.contains('color: AppColores.alerta))'), isFalse);
      expect(s.contains('AppColores.alertaTexto(context)'), isTrue);
    });
    test('nomina: el aviso de exceso usa alertaTexto', () {
      final s = _src('lib/ui/nomina.dart');
      expect(s.contains('.copyWith(color: AppColores.alerta)'), isFalse);
      expect(s.contains('AppColores.alertaTexto(context)'), isTrue);
    });
  });
}
