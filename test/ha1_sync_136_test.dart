/// H-A1 (1.36): filas Hy4 de núcleo sync/BD — 136-892,
/// 136-897, 136-908, 136-917, 136-919, 136-925, 136-929,
/// 136-930, 136-325, 136-689, 136-940.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
/// Este archivo reúne las pruebas puras y de contrato de
/// fuente; las de BD viven en ha1_sync_bd_136_test.dart.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/centro_sync.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-892: resumenMostradorSync — prioridad documentada '
      '(pendientes → sin conexión → novedades → error)', () {
    test('un fallo viejo NO tapa «Sin conexión»', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: false,
              hayError: true,
              hayNovedades: false),
          contains('Sin conexión'));
    });

    test('un fallo viejo NO tapa «Hay novedades»', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: true,
              hayNovedades: true),
          contains('Hay novedades'));
    });

    test('el error persistido tampoco tapa «Sin conexión»', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: false,
              hayError: false,
              hayNovedades: false,
              avisoPersistido: true),
          contains('Sin conexión'));
    });

    test('sin conexión ni novedades, el error sí se dice', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: true,
              hayNovedades: false),
          contains('falló'));
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: false,
              avisoPersistido: true),
          contains('falló'));
    });

    test('el error manda sobre «sin verificar» y los '
        'pendientes mandan sobre todo', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: true,
              hayNovedades: null),
          contains('falló'));
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 2,
              enLinea: false,
              hayError: true,
              hayNovedades: true),
          'Faltan 2 por subir');
    });

    test('fueraCola (C-3) sigue tras los pendientes y antes '
        'del resto', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: false,
              hayError: true,
              hayNovedades: true,
              fueraCola: 3),
          contains('fuera de la cola'));
    });
  });

  group('136-897: Salud del Sync — error con reintento, '
      'nunca «cargando» eterno', () {
    test('la pantalla captura el fallo de la lectura', () {
      final s = _src('lib/ui/salud_sync_screen.dart');
      expect(s, contains('_errorCarga'),
          reason: 'la pantalla declara su estado de error');
      expect(s, contains('EstadoError('),
          reason: 'el fallo se pinta con el componente de '
              'error de la casa');
      expect(s, contains('onReintentar'),
          reason: 'el error ofrece reintento');
      // El _cargar ya no es un await desnudo.
      final i = s.indexOf('Future<void> _cargar()');
      final tramo = s.substring(i, i + 1400);
      expect(tramo, contains('try {'));
      expect(tramo, contains('cargarSaludSync()'));
      expect(tramo, contains('catch'));
    });

    test('cargarSaludSync guarda su primera lectura', () {
      final s = _src('lib/salud_sync.dart');
      final i = s.indexOf("getMeta('server_seq')");
      final antes = s.substring(i - 500, i);
      expect(antes, contains('try {'),
          reason: 'un fallo leyendo server_seq no tumba '
              'toda la foto de salud');
    });
  });

  group('136-908: diagnóstico de espejo — verificación con '
      'filas legibles y ciclo comprobado', () {
    test('la tarjeta verifica con conteoMirrorLegible y '
        'mira el desenlace del ciclo', () {
      final s = _src('lib/ui/diagnostico_espejo_card.dart');
      expect(s, contains('conteoMirrorLegible'));
      expect(s, contains('res.error == null'),
          reason: 'el ciclo solo es ok si corrió y sin error');
      expect(s, isNot(contains("contar('clientes')")),
          reason: 'fuera el conteo crudo en la verificación');
    });
  });

  group('136-917: sellos del pull y reloj medible', () {
    test('el sello global last_remote_sync_ok exige bajada '
        'sin errores, sin no-intentadas y sin fallidas', () {
      final s = _src('lib/sync.dart');
      final i = s.indexOf("setMeta('last_remote_sync_ok',");
      final antes = s.substring(i - 900, i);
      expect(antes, contains('erroresTablas.isEmpty'));
      expect(antes, contains('noIntentadas.isEmpty'));
      expect(antes, contains('fallidas == 0'));
    });

    test('verificarReloj distingue «no se pudo medir» de '
        '«sin desfase»', () {
      final s = _src('lib/sync.dart');
      final i = s.indexOf('Future<int?> verificarReloj()');
      final tramo = s.substring(i, i + 2200);
      expect(tramo, contains('reloj_medicion_fallo'),
          reason: 'el fallo de medición deja su propia marca');
    });
  });

  group('136-919: _pullIncidenciasHistorial como sus hermanas',
      () {
    test('pagina, cierra retenciones en finally y registra '
        'wm_err_incidencias_historial', () {
      final s = _src('lib/sync.dart');
      final i = s.indexOf('Future<void> _pullIncidenciasHistorial()');
      final tramo = s.substring(i, i + 9000);
      expect(tramo, contains('while (true)'),
          reason: 'paginación hasta página corta');
      expect(tramo, contains('wm_err_incidencias_historial'));
      expect(tramo, contains('finally'));
      expect(tramo, contains('_cerrarRetencionesPull'));
    });
  });
}
