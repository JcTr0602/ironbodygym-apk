/// 1.25 T101: Equipo en una pantalla — la identidad
/// del entrenador se resuelve por el username del
/// correo contra usuarios_apk (nombre real, no
/// fabricado) y los tres grupos de permisos cubren
/// las 14 claves exactamente una vez.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/entrenador_identidad.dart';
import 'package:ironbody_gym/ui/panel_permisos.dart';

void main() {
  final usuarios = <Map<String, dynamic>>[
    {'username': 'duany', 'nombre': 'Duany', 'telegram_id': 969869611},
    {'username': 'gabriel', 'nombre': 'Gabriel', 'telegram_id': '1403501391'},
    {'username': 'sin_nombre', 'nombre': '', 'telegram_id': 42},
  ];

  group('identidadPorEmail', () {
    test('resuelve nombre real y telegram_id por username', () {
      final d = identidadPorEmail('duany@ironbody.gym', usuarios);
      expect(d?.nombre, 'Duany');
      expect(d?.telegramId, 969869611);
      final g = identidadPorEmail('Gabriel@ironbody.gym', usuarios);
      expect(g?.nombre, 'Gabriel');
      expect(g?.telegramId, 1403501391,
          reason: 'el telegram_id como texto también resuelve');
    });

    test('sin fila en la meta o sin nombre: null (vale el respaldo)', () {
      expect(identidadPorEmail('nadie@ironbody.gym', usuarios), isNull);
      expect(identidadPorEmail('sin_nombre@ironbody.gym', usuarios),
          isNull);
      expect(identidadPorEmail('', usuarios), isNull);
    });
  });

  group('gruposPermisos', () {
    test('las 14 claves, exactamente una vez entre los 3 grupos', () {
      final enGrupos = [
        for (final g in EntrenadorPermiso.gruposPermisos) ...g.$3,
      ];
      final todas =
          EntrenadorPermiso.permisosDisponibles.map((p) => p.$1).toList();
      expect(enGrupos.toSet().length, enGrupos.length,
          reason: 'ninguna clave repetida en dos grupos');
      expect(enGrupos.toSet(), todas.toSet());
      expect(EntrenadorPermiso.gruposPermisos.length, 3);
      for (final g in EntrenadorPermiso.gruposPermisos) {
        expect(g.$2, isNotEmpty, reason: 'cada grupo con su ayuda');
      }
    });

    test('cada clave de grupo existe en porClave', () {
      for (final g in EntrenadorPermiso.gruposPermisos) {
        for (final clave in g.$3) {
          expect(EntrenadorPermiso.porClave[clave], isNotNull,
              reason: clave);
        }
      }
    });
  });
}
