/// UI136-01 (adjudicación ARGON-136-UI, hallazgo H4): familia de errores
/// crudos fuera del censo ERR-G01. La cura de la casa es
/// `mensajeErrorAmable` (lib/errores_sync.dart): ningún `_errorCarga`
/// puede guardar el `$e` a pelo ni ningún snack puede interpolar la
/// excepción cruda.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';

String _src(String p) => File(p).readAsStringSync();

/// Los 18 archivos con asignaciones `_errorCarga = '$e'` en el censo
/// de la adjudicación (23 asignaciones en lib/ui/).
const _archivosErrorCarga = [
  'lib/ui/categorias_suplemento.dart',
  'lib/ui/centro_compras.dart',
  'lib/ui/congelados.dart',
  'lib/ui/historial_ventas.dart',
  'lib/ui/incidencias/tipos_incidencia.dart',
  'lib/ui/mi_nomina.dart',
  'lib/ui/nomina.dart',
  'lib/ui/panel_bloque2.dart',
  'lib/ui/panel_resto_caja.dart',
  'lib/ui/panel_resto_config.dart',
  'lib/ui/panel_resto_sistema.dart',
  'lib/ui/papelera.dart',
  'lib/ui/reporte_margenes.dart',
  'lib/ui/reservas.dart',
  'lib/ui/riesgo.dart',
  'lib/ui/solicitudes_adelanto.dart',
  'lib/ui/tarifas_especiales.dart',
  'lib/ui/usuarios.dart',
];

void main() {
  group('UI136-01 · familia _errorCarga', () {
    test('ningún archivo de lib/ guarda el error crudo en _errorCarga', () {
      final ui = Directory('lib/ui');
      final ofensores = <String>[];
      for (final f in ui.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.readAsStringSync().contains("_errorCarga = '\$e'")) {
          ofensores.add(f.path);
        }
      }
      expect(ofensores, isEmpty,
          reason: 'siguen crudos: ${ofensores.join(', ')}');
    });

    test('los 18 archivos del censo curan con mensajeErrorAmable', () {
      for (final a in _archivosErrorCarga) {
        final s = _src(a);
        expect(s.contains('_errorCarga = mensajeErrorAmable(e)'), isTrue,
            reason: '$a no asigna la versión amable');
      }
    });
  });

  group('UI136-01 · los 3 snacks fuera del censo ERR-G01', () {
    test('mantenimiento: fuera «No se pudo completar: \$e»', () {
      final s = _src('lib/ui/panel_resto_sistema.dart');
      expect(s.contains('No se pudo completar: \$e'), isFalse);
      expect(s.contains("mensajeErrorAmable(e)"), isTrue);
    });

    test('mi_turno repetir venta: fuera el \$e con replaceFirst', () {
      final s = _src('lib/ui/mi_turno.dart');
      expect(s.contains("'\$e'.replaceFirst('Exception: ', '')"), isFalse);
      expect(s.contains('mensajeErrorAmable(e)'), isTrue);
    });

    test('nomina adelanto: fuera el ternario con \$err a pelo', () {
      final s = _src('lib/ui/nomina.dart');
      expect(s.contains("err is StateError ? err.message : '\$err'"),
          isFalse);
      expect(s.contains('mensajeErrorAmable(err)'), isTrue);
    });
  });

  group('UI136-01 · la cura conserva el mensaje de negocio', () {
    test('StateError en español limpio pasa tal cual', () {
      expect(mensajeErrorAmable(StateError('El adelanto supera el neto')),
          'El adelanto supera el neto');
    });
    test('excepción técnica cae al genérico, nunca al crudo', () {
      final r = mensajeErrorAmable(
          Exception('DatabaseException: no such table: secreta'));
      expect(r, isNot(contains('DatabaseException')));
      expect(r, isNot(contains('secreta')));
    });
  });
}
