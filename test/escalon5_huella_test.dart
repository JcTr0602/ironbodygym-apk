/// Escalón 5 (1.32) · Pieza 1 — M5 lado app: la huella del
/// dispositivo en `public.sync_dispositivos`.
///
/// La tabla puede NO existir todavía en Supabase (la crea la
/// fase de servidor): el emisor traga todo error, lo registra
/// y conserva el payload como pendiente («último gana»). El
/// transporte se inyecta: aquí jamás se toca la red real.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/huella_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _uid = '844eceac-767d-4294-8301-527b19e5a516';
const _ahora = 1794500000;

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_e5_huella.db';
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_e5_huella.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
}

/// Transporte falso: registra la llamada y responde [codigo]
/// (o no responde nunca si [colgar]).
class _TransporteFalso {
  _TransporteFalso(this.codigo, {this.colgar = false});
  final int codigo;
  final bool colgar;
  int llamadas = 0;
  Uri? url;
  Map<String, String>? headers;
  Map<String, dynamic>? cuerpo;

  Future<int> call(Uri u, Map<String, String> h, String body) {
    llamadas++;
    url = u;
    headers = h;
    cuerpo = Map<String, dynamic>.from(jsonDecode(body) as Map);
    if (colgar) return Completer<int>().future;
    return Future.value(codigo);
  }
}

Future<bool> _cerrar(
  HuellaSync huella, {
  String? userId = _uid,
  String tipo = 'completa',
  String origen = 'manual',
  String estado = 'completa',
  int subidos = 0,
  int bajados = 0,
  Future<Map<String, int>> Function()? conteos,
}) {
  return huella.registrarCierre(
    userId: userId,
    deviceTag: 'apk-test-1',
    corridaId: 'corrida-1',
    tipo: tipo,
    origen: origen,
    estado: estado,
    subidos: subidos,
    bajados: bajados,
    serverSeq: 212500,
    watermarkMin: 212000,
    rol: 'entrenador',
    versionApp: '1.32.0+93',
    ahoraEpoch: _ahora,
    obtenerConteos: conteos,
  );
}

void main() {
  group('freno de emisión M5-R2 (puro)', () {
    bool freno({
      String tipo = 'completa',
      String origen = 'automatica',
      int subidos = 0,
      int bajados = 0,
      String resultado = 'completa',
      String? ultimoRes = 'completa',
      int? ultimoOk = _ahora - 60,
      int ahora = _ahora,
    }) =>
        frenoEmisionHuella(
          tipo: tipo,
          origen: origen,
          subidos: subidos,
          bajados: bajados,
          resultado: resultado,
          ultimoResultadoConfirmado: ultimoRes,
          ultimoConfirmadoEpoch: ultimoOk,
          ahoraEpoch: ahora,
        );

    test('chequeo automático vacío y reciente: NO emite', () {
      expect(freno(), isFalse);
    });
    test('(a) manual / instalación / bajada completa: emite', () {
      expect(freno(origen: 'manual'), isTrue);
      expect(freno(origen: 'instalacion'), isTrue);
      expect(freno(tipo: 'bajada_completa'), isTrue);
    });
    test('(b) con movimiento: emite', () {
      expect(freno(subidos: 1), isTrue);
      expect(freno(bajados: 3), isTrue);
    });
    test('(c) cambió el resultado (o nunca se confirmó): emite', () {
      expect(freno(resultado: 'parcial'), isTrue);
      expect(freno(ultimoRes: null, ultimoOk: null), isTrue);
    });
    test('(d) ≥30 min desde el último confirmado: emite', () {
      expect(freno(ultimoOk: _ahora - 30 * 60), isTrue);
      expect(freno(ultimoOk: _ahora - 30 * 60 + 1), isFalse);
    });
  });

  group('HuellaSync.registrarCierre', () {
    setUp(() async => _init());

    test('éxito: upsert a su fila, sellos en meta, sin pendiente',
        () async {
      final t = _TransporteFalso(201);
      final huella = HuellaSync(transporte: t.call);
      var conteosCalculados = false;
      final ok = await _cerrar(huella, conteos: () async {
        conteosCalculados = true;
        return {'clientes': 186, 'pagos': 950};
      });
      expect(ok, isTrue);
      expect(t.llamadas, 1);
      expect(t.url!.path, '/rest/v1/sync_dispositivos');
      expect(t.url!.queryParameters['on_conflict'], 'user_id,device_tag');
      expect(t.headers!['Prefer'],
          'resolution=merge-duplicates,return=minimal');
      final c = t.cuerpo!;
      expect(c['user_id'], _uid);
      expect(c['device_tag'], 'apk-test-1');
      expect(c['corrida_id'], 'corrida-1');
      expect(c['resultado'], 'completa');
      expect(c['server_seq'], 212500);
      expect(c['watermark_minimo'], 212000);
      expect(c['rol'], 'entrenador');
      expect(c['version_app'], '1.32.0+93');
      expect((c['conteos'] as Map)['clientes'], 186);
      expect(conteosCalculados, isTrue,
          reason: 'los conteos solo se calculan al emitir de verdad');
      final db = LocalDb.instance;
      expect(await db.getMeta(metaHuellaUltimoOkEpoch), '$_ahora');
      expect(await db.getMeta(metaHuellaUltimoResultado), 'completa');
      expect(await db.getMeta(metaReportePendiente), isNull);
      expect(await db.getMeta(metaHuellaUltimoError), isNull);
    });

    test('tabla ausente (404): se traga, registra y deja pendiente',
        () async {
      final t = _TransporteFalso(404);
      final huella = HuellaSync(transporte: t.call);
      final ok = await _cerrar(huella);
      expect(ok, isFalse);
      expect(await LocalDb.instance.getMeta(metaHuellaUltimoError),
          'HTTP 404');
      final pend = await LocalDb.instance.getMeta(metaReportePendiente);
      expect(pend, isNotNull);
      final m = Map<String, dynamic>.from(jsonDecode(pend!) as Map);
      expect(m['corrida_id'], 'corrida-1');
      expect(m['user_id'], _uid);
      expect(await LocalDb.instance.getMeta(metaHuellaUltimoOkEpoch),
          isNull);
    });

    test('timeout: el tope de emisión corta y el fallo se registra',
        () async {
      final t = _TransporteFalso(201, colgar: true);
      final huella = HuellaSync(
          transporte: t.call,
          timeoutEmision: const Duration(milliseconds: 300));
      final crono = Stopwatch()..start();
      final ok = await _cerrar(huella);
      crono.stop();
      expect(ok, isFalse);
      expect(crono.elapsedMilliseconds, lessThan(5000),
          reason: 'la emisión no puede colgar el cierre');
      final err = await LocalDb.instance.getMeta(metaHuellaUltimoError);
      expect(err, isNotNull);
      expect(err, contains('TimeoutException'));
      expect(await LocalDb.instance.getMeta(metaReportePendiente),
          isNotNull);
    });

    test('transporte que lanza (red caída): se traga igual',
        () async {
      final huella = HuellaSync(
          transporte: (u, h, b) async =>
              throw const SocketException('sin red'));
      final ok = await _cerrar(huella);
      expect(ok, isFalse);
      expect(await LocalDb.instance.getMeta(metaHuellaUltimoError),
          contains('SocketException'));
    });

    test('sin sesión: no emite ni llama al transporte', () async {
      final t = _TransporteFalso(201);
      final huella = HuellaSync(transporte: t.call);
      expect(await _cerrar(huella, userId: null), isFalse);
      expect(t.llamadas, 0);
    });

    test('freno cerrado y sin pendiente: no emite ni calcula conteos',
        () async {
      final db = LocalDb.instance;
      await db.setMeta(metaHuellaUltimoResultado, 'completa');
      await db.setMeta(metaHuellaUltimoOkEpoch, '${_ahora - 60}');
      final t = _TransporteFalso(201);
      final huella = HuellaSync(transporte: t.call);
      var conteosCalculados = false;
      final ok = await _cerrar(huella,
          origen: 'automatica',
          conteos: () async {
            conteosCalculados = true;
            return {};
          });
      expect(ok, isFalse);
      expect(t.llamadas, 0);
      expect(conteosCalculados, isFalse);
    });

    test('pendiente propio: se reintenta en el siguiente cierre',
        () async {
      final db = LocalDb.instance;
      await db.setMeta(metaHuellaUltimoResultado, 'completa');
      await db.setMeta(metaHuellaUltimoOkEpoch, '${_ahora - 60}');
      await db.setMeta(
          metaReportePendiente,
          jsonEncode({
            'user_id': _uid,
            'device_tag': 'apk-test-1',
            'corrida_id': 'corrida-vieja',
            'resultado': 'parcial',
          }));
      final t = _TransporteFalso(200);
      final huella = HuellaSync(transporte: t.call);
      final ok = await _cerrar(huella, origen: 'automatica');
      expect(ok, isTrue);
      expect(t.cuerpo!['corrida_id'], 'corrida-vieja',
          reason: 'viaja el pendiente, no la corrida de este cierre');
      expect(await db.getMeta(metaReportePendiente), isNull);
      expect(await db.getMeta(metaHuellaUltimoResultado), 'parcial');
    });

    test('pendiente de OTRO usuario: no se escribe por otro', () async {
      final db = LocalDb.instance;
      await db.setMeta(metaHuellaUltimoResultado, 'completa');
      await db.setMeta(metaHuellaUltimoOkEpoch, '${_ahora - 60}');
      await db.setMeta(
          metaReportePendiente,
          jsonEncode({
            'user_id': 'otro-usuario',
            'device_tag': 'apk-ajeno',
            'corrida_id': 'corrida-ajena',
            'resultado': 'completa',
          }));
      final t = _TransporteFalso(200);
      final huella = HuellaSync(transporte: t.call);
      final ok = await _cerrar(huella, origen: 'automatica');
      expect(ok, isFalse);
      expect(t.llamadas, 0);
      expect(await db.getMeta(metaReportePendiente), isNull,
          reason: 'el pendiente ajeno se descarta, no se conserva');
    });

    test('último gana: el cierre nuevo sustituye al pendiente viejo',
        () async {
      final db = LocalDb.instance;
      await db.setMeta(
          metaReportePendiente,
          jsonEncode({
            'user_id': _uid,
            'device_tag': 'apk-test-1',
            'corrida_id': 'corrida-vieja',
            'resultado': 'fallida',
          }));
      final t = _TransporteFalso(503);
      final huella = HuellaSync(transporte: t.call);
      final ok = await _cerrar(huella); // manual → emite la nueva
      expect(ok, isFalse);
      expect(t.cuerpo!['corrida_id'], 'corrida-1');
      final pend = await db.getMeta(metaReportePendiente);
      final m = Map<String, dynamic>.from(jsonDecode(pend!) as Map);
      expect(m['corrida_id'], 'corrida-1',
          reason: 'lo que queda pendiente es lo nuevo, no lo viejo');
    });
  });
}
