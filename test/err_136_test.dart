/// ERR (1.36): caza Hy4 de mensajes de error — contratos.
/// Fuente: cola-123/hy4_errores/REVISION.md (ERR-G01…G09).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/acciones_acceso.dart';
import 'package:ironbody_gym/ui/salud_sync_screen.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('ERR-G02 · errorSyncLegible nunca devuelve el crudo', () {
    test('error desconocido → frase genérica sin el texto técnico', () {
      final r = errorSyncLegible(
          'PostgrestException: relation "xyz_secreta" does not exist, code 42P01');
      expect(r, 'Hubo un problema al sincronizar. Intenta de nuevo.');
      expect(r, isNot(contains('Postgrest')));
      expect(r, isNot(contains('xyz_secreta')));
    });
    test('404 sin jerga «recurso»', () {
      expect(errorSyncLegible('404 not found'),
          'No se encontró esta información en el servidor.');
    });
    test('red sigue traducida', () {
      expect(errorSyncLegible('SocketException: failed host lookup'),
          contains('Sin conexión'));
    });
  });

  group('ERR-G01 · mensajeErrorAmable es la vía', () {
    test('técnico desconocido → genérico, nunca el crudo', () {
      final r = mensajeErrorAmable(Exception('SocketException: boom interno'));
      expect(r, isNot(contains('boom interno')));
    });
    test('los archivos citados ya no interpolan \$e en snacks visibles', () {
      const archivos = [
        'lib/ui/cola.dart',
        'lib/ui/recordatorios.dart',
        'lib/ui/editor_rutinas_gym.dart',
        'lib/ui/panel_resto_config.dart',
        'lib/ui/servicios_estadisticas.dart',
        'lib/ui/diagnostico_espejo_card.dart',
        'lib/ui/usuarios.dart',
        'lib/ui/avisos_entrenador.dart',
        'lib/ui/admin_secciones.dart',
        'lib/ui/gympedia_editor.dart',
        'lib/ui/pestana_progreso.dart',
      ];
      for (final a in archivos) {
        final s = _src(a);
        expect(s.contains("mostrarSnack(context, 'Error: \$e'"), isFalse,
            reason: a);
        expect(s.contains("No se pudo publicar: \$e"), isFalse, reason: a);
        expect(s.contains("'\$e', significado"), isFalse, reason: a);
      }
      // Ajustes: ningún _msgError con $e crudo.
      expect(_src('lib/ui/ajustes.dart').contains("_msgError('No se pudo"),
          isTrue);
      expect(
          RegExp(r"_msgError\('[^']*: \$e'\)")
              .hasMatch(_src('lib/ui/ajustes.dart')),
          isFalse);
      expect(_src('lib/ui/ajustes.dart').contains('Error al resincronizar: \$e'),
          isFalse);
    });
    test('reintentos de cola suenan a rutina, no a fallo', () {
      final s = _src('lib/ui/cola.dart');
      expect('Sigue pendiente de subir; se reintentará solo.'
          .allMatches(s)
          .length, 2);
    });
    test('mensajeErrorAcceso conserva el texto curado (String)', () {
      expect(mensajeErrorAcceso('Solo el dueño puede hacer esto'),
          'Solo el dueño puede hacer esto');
    });
  });

  group('ERR-G03…G09 · jerga fuera', () {
    test('G03 sin código HTTP en GymPedia', () {
      expect(_src('lib/ui/gympedia_editor.dart').contains('HTTP \$codigo'),
          isFalse);
    });
    test('G04 sin «la RPC» en Caja', () {
      expect(_src('lib/ui/panel_resto_caja.dart')
          .contains('la RPC no devolvió'), isFalse);
    });
    test('G05 sin «volcar el WAL» en copia de seguridad', () {
      final s = _src('lib/copia_seguridad.dart');
      expect(s.contains('No se pudo volcar el WAL'), isFalse);
      expect(s, contains('No se pudo preparar la copia'));
    });
    test('G06 Salud sin diagnóstico especulativo', () {
      final m = mensajeComprobacionSalud(divergentes: -1);
      expect(m.texto, isNot(contains('¿sin conexión?')));
      expect(m.texto, contains('no pudo completarse'));
    });
    test('G07 novedades viejas sin jerga de desarrollo', () {
      final s = _src('lib/novedades.dart');
      for (final j in [
        'bugs corregidos',
        'fix del preview',
        'bug _running',
        'refresca el token',
        'mejor UX',
        'con badge,',
      ]) {
        expect(s.contains(j), isFalse, reason: j);
      }
    });
    test('G09 sin «identificador» como causa visible', () {
      expect(_src('lib/ui/cuentas_por_cobrar.dart')
          .contains('venta sin identificador'), isFalse);
      expect(_src('lib/ui/papelera.dart')
          .contains('cliente sin identificador'), isFalse);
    });
  });
}
