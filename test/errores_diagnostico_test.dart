/// resumenErrorDiagnostico (v1.8.0): la pantalla de Diagnóstico
/// pintaba el error crudo guardado en wm_err_<tabla>
/// («ClientException with SocketException: Failed host lookup…»,
/// truncado e ininteligible). La función pura lo traduce a una
/// frase corta en español claro y NUNCA devuelve el texto técnico.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';

void main() {
  test('sin conexión: SocketException / DNS / red inalcanzable', () {
    expect(
      resumenErrorDiagnostico('ClientException with SocketException: '
          'Failed host lookup: mjttljkfzntwnzgwjnkk.supabase.co '
          '(OS Error: No address associated with hostname, errno = 7)'),
      'sin conexión con el servidor',
    );
    expect(
      resumenErrorDiagnostico(
          'SocketException: Connection refused (OS Error: Connection refused, errno = 111)'),
      'sin conexión con el servidor',
    );
    expect(
      resumenErrorDiagnostico(
          'SocketException: Network is unreachable (OS Error: Network is unreachable, errno = 101)'),
      'sin conexión con el servidor',
    );
    expect(
      resumenErrorDiagnostico(
          'SocketException: Connection reset by peer (OS Error: Connection reset by peer, errno = 104)'),
      'sin conexión con el servidor',
    );
  });

  test('sin conexión: fallo TLS (HandshakeException / CERTIFICATE)',
      () {
    expect(
      resumenErrorDiagnostico(
          'HandshakeException: Handshake error in client (CERTIFICATE_VERIFY_FAILED)'),
      'sin conexión con el servidor',
    );
  });

  test('timeout: el servidor tardó demasiado', () {
    expect(
      resumenErrorDiagnostico(
          'TimeoutException after 0:00:30.000000: Future not completed'),
      'el servidor tardó demasiado en responder',
    );
    expect(
      resumenErrorDiagnostico('ClientException: Request timed out'),
      'el servidor tardó demasiado en responder',
    );
  });

  test('401/403: el servidor rechazó el acceso', () {
    expect(
      resumenErrorDiagnostico(
          'ClientException: Error 401 al descargar la tabla'),
      'el servidor rechazó el acceso',
    );
    expect(
      resumenErrorDiagnostico('PostgrestException(message: permission '
          'denied, code: 403)'),
      'el servidor rechazó el acceso',
    );
  });

  test('5xx: error interno del servidor', () {
    for (final codigo in ['500', '502', '503']) {
      expect(
        resumenErrorDiagnostico('ClientException: HTTP $codigo'),
        'error interno del servidor',
        reason: 'código $codigo',
      );
    }
    expect(
      resumenErrorDiagnostico('HttpException: HTTP 500 Internal Server Error'),
      'error interno del servidor',
    );
  });

  test('desconocido: genérico, sin volcar el texto crudo', () {
    const crudo = 'StateError: bad state: algo raro pasó en xyz';
    final r = resumenErrorDiagnostico(crudo);
    expect(r, 'error de sincronización');
    expect(r, isNot(contains('StateError')));
    expect(resumenErrorDiagnostico(''), 'error de sincronización');
  });
}
