/// SL-3 G01-2 (F02-HD z18_tests_sl3-2 r1) — nivel de FUENTE.
///
/// El endurecimiento pedía montar Home tumbando UNA sola de
/// las dos consultas de atención (invitados_listar /
/// plus_reportes_listar) y ver el aviso nombrar solo la
/// caída. Ese nivel de WIDGET no se alcanzó en el arnés:
/// con un servidor que RESPONDE (aunque sea 500), el segundo
/// pase de Home no aterriza en el harness de widgets —
/// probado por el coordinador con tres sondas (falso que
/// 500-todo, falso permisivo que solo tumba las dos RPC y
/// sondeo de 100 vueltas con esperas reales) — mientras que
/// con el servidor muerto (la condición real del aviso) el
/// test histórico de lote135_sl3_g01_2_atencion_test.dart
/// pasa. Lo que SÍ se guarda aquí, por el camino real
/// (HTTP → PostgREST → servicio), es la mitad que faltaba:
/// que el fallo de CADA fuente, por separado, PROPAGA como
/// excepción hasta el llamador (es lo que _cargarAtencionDueno
/// convierte en «sin verificar» por fuente; su lógica de
/// marcado y el texto del aviso ya los guardan los tests
/// puros de SenalAtencion del archivo hermano).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

bool _fallarSolicitudes = false;
bool _fallarReportes = false;

class _RedirigirFuentes extends HttpOverrides {
  final int puerto;
  _RedirigirFuentes(this.puerto);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteFuentes(HttpClient(context: context), puerto);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteFuentes implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  _ClienteFuentes(this._interno, this._puerto);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _interno.openUrl(
          method,
          url.host == '127.0.0.1'
              ? url.replace(port: _puerto)
              : url);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('fuentes: ${invocation.memberName}');
}

Future<HttpServer> _servidorFuentes() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      res.headers.contentType = ContentType.json;
      final path = req.uri.path;
      if (path.endsWith('/rpc/invitados_listar')) {
        if (_fallarSolicitudes) {
          res.statusCode = 500;
          res.write(jsonEncode(
              {'code': '500', 'message': 'Internal server error'}));
        } else {
          res.write(jsonEncode({'invitados': <dynamic>[]}));
        }
      } else if (path.endsWith('/rpc/plus_reportes_listar')) {
        if (_fallarReportes) {
          res.statusCode = 500;
          res.write(jsonEncode(
              {'code': '500', 'message': 'Internal server error'}));
        } else {
          res.write('[]');
        }
      } else if (req.method == 'GET') {
        res.write('[]');
      } else {
        res.write('[]');
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    server = await _servidorFuentes();
    HttpOverrides.global = _RedirigirFuentes(server.port);
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  tearDownAll(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  test('cae SOLO solicitudes: invitados_listar lanza y '
      'plus_reportes_listar devuelve', () async {
    _fallarSolicitudes = true;
    _fallarReportes = false;
    await expectLater(
        InvitadosService().solicitudesPendientes(), throwsA(anything),
        reason: 'el fallo de la fuente de solicitudes PROPAGA '
            '(no se traga en un cero): es lo que levanta su '
            '«sin verificar» en _cargarAtencionDueno');
    await expectLater(PlusReportesService().pendientes(),
        completion(isEmpty),
        reason: 'la fuente sana devuelve su lista (vacía)');
  });

  test('cae SOLO reportes Plus: plus_reportes_listar lanza '
      'e invitados_listar devuelve', () async {
    _fallarSolicitudes = false;
    _fallarReportes = true;
    await expectLater(
        PlusReportesService().pendientes(), throwsA(anything),
        reason: 'el fallo de la fuente de Plus PROPAGA por '
            'separado: la bandera de atención es un OR por '
            'fuente, no un todo-o-nada');
    await expectLater(
        InvitadosService().solicitudesPendientes(),
        completion(isEmpty),
        reason: 'la fuente sana devuelve su lista (vacía)');
  });

  test('control: con las dos sanas, ninguna fuente lanza',
      () async {
    _fallarSolicitudes = false;
    _fallarReportes = false;
    await expectLater(
        InvitadosService().solicitudesPendientes(),
        completion(isEmpty));
    await expectLater(
        PlusReportesService().pendientes(), completion(isEmpty));
  });
}
