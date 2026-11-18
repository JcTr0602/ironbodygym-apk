/// H-B1 (1.36): acceso/auth/ficha —
/// 136-448, 136-449, 136-451, 136-452, 136-455, 136-458,
/// 136-460, 136-469, 136-471, 136-473, 136-476, 136-478,
/// 136-479, 136-482.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/ui/acciones_acceso.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-451 · mensajeErrorAcceso en sencillo', () {
    test('timeout → tiempo de espera', () {
      expect(mensajeErrorAcceso(TimeoutException('x')),
          contains('Se acabó el tiempo de espera'));
    });
    test('red → sin conexión', () {
      expect(mensajeErrorAcceso(Exception('SocketException: failed')),
          contains('Sin conexión'));
    });
    test('RPC → el mensaje del servidor', () {
      expect(
          mensajeErrorAcceso(const PostgrestException(
              message: 'Solo el dueño puede hacer esto')),
          'Solo el dueño puede hacer esto');
    });
    test('desconocido → genérico amable, nunca el error crudo', () {
      final m = mensajeErrorAcceso(StateError('raro interno'));
      expect(m, contains('No se pudo completar'));
      expect(m, isNot(contains('raro interno')));
    });
  });

  test('136-460 · textoSesionMuerta no pide cerrar lo cerrado', () {
    expect(AuthService.textoSesionMuerta,
        'Tu sesión venció: entra de nuevo.');
  });

  group('contratos de fuente', () {
    test('136-458 · la purga de signOut no bloquea la salida', () {
      final s = _src('lib/auth.dart');
      final i = s.indexOf('purga_cierre_sesion_fallo');
      expect(i, greaterThan(0));
      expect(s.substring(i), contains('await _c.auth.signOut();'));
    });
    test('136-449/452 · acciones de acceso', () {
      final s = _src('lib/ui/acciones_acceso.dart');
      expect(s, contains('AccesoAppCache.instance.esPersistido'));
      expect(s, contains('peligro: peligro'));
      expect(s, isNot(contains("'Error: \$e'")));
    });
    test('136-455 · confirmación del candado con resumen', () {
      final s = _src('lib/ui/panel_candado.dart');
      expect(s, contains('Objetivo: \$objetivoTxt'));
      expect(s, contains('App: \$appEfectiva'));
      expect(s, contains('caducidadTxt'));
    });
    test('136-448 · blancos subidos en candado y vista previa', () {
      expect(_src('lib/ui/capa_candado.dart'),
          contains('color: Colors.white54'));
      final vp = _src('lib/ui/vista_previa_cliente.dart');
      expect('Colors.white54'.allMatches(vp).length,
          greaterThanOrEqualTo(2));
    });
    test('136-469/471/473/476/478/482 · ficha', () {
      final s = _src('lib/ui/ficha.dart');
      expect(s, contains('selected: activa'));
      expect(s, contains('Foto no disponible'));
      expect(s, contains('AppColores.casaMarco'));
      expect(s, contains('_incidenciasExpandidas'));
      expect(s, contains('Sin suplementos disponibles'));
      expect(s, contains('if (cambio) _cargar();'));
    });
    test('136-473 · token casaMarco en el tema', () {
      expect(_src('lib/ui/diseno.dart'),
          contains('static const casaMarco'));
    });
    test('136-479 · el modal de tarifa devuelve cambio', () {
      final s = _src('lib/ui/tarifas_especiales.dart');
      expect(s, contains('Future<bool> mostrarModalTarifaEspecial'));
      expect(s, contains('revocada: true'));
    });
  });
}
