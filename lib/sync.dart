/// Motor de sincronización offline-first.
///
/// Subida (push): ops de `ops_queue` -> POST /rest/v1/sync_ops (idempotente
///           por op_uuid; un 409 se trata como "ya encolada").
///           Luego consulta `aplicada` de cada op propia (policy
///           "ver propias ops") y marca la cola.
/// Bajada (pull): espejos + borrados con sync_seq > watermark local, aplica
///           y guarda el watermark. También trae `ajustes` (precios).
/// Fotos:    las fotos de inscripciones se suben cuando la op de
///           inscripción ya fue aplicada (se conoce el cliente_id) y se
///           encolan como op tipo 'foto'.
///
/// Cadencia: pull frecuente (ver cambios de otros entrenadores),
/// push cada hora o manual.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'config.dart';
import 'localdb.dart';

enum SyncPhase { idle, uploading, downloading, photos, error }

class SyncStatus {
  final SyncPhase phase;
  final int pending;
  final DateTime? lastOk;
  final String? lastError;

  /// Progreso 0..1 de la fase actual (null = indeterminado).
  final double? progreso;

  /// Detalle legible del progreso, ej. "Subiendo foto 2 de 5…".
  final String? detalle;
  const SyncStatus(
      {this.phase = SyncPhase.idle,
      this.pending = 0,
      this.lastOk,
      this.lastError,
      this.progreso,
      this.detalle});
}

/// Detalle de la última sincronización (para la pantalla de Sync).
class SyncDetalle {
  final DateTime? ultimaPull;
  final DateTime? ultimaPush;
  final int subidos;
  final int bajados;
  final String? error;
  const SyncDetalle(
      {this.ultimaPull,
      this.ultimaPush,
      this.subidos = 0,
      this.bajados = 0,
      this.error});
}

class SessionExpired implements Exception {
  final String message;
  SessionExpired([this.message = 'sesión vencida, entra de nuevo']);
  @override
  String toString() => message;
}

class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  final _status = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _status.stream;
  SyncStatus _current = const SyncStatus();
  bool _running = false;

  /// Se llama cuando el servidor rechaza la sesión (401).
  void Function()? onSessionExpired;

  final _auth = AuthService();
  final _db = LocalDb.instance;

  String get _base => AppConfig.supabaseUrl;

  Map<String, String> _headers({String? contentType}) => {
        'apikey': AppConfig.anonKey,
        'Authorization': 'Bearer ${_auth.session?.accessToken ?? ''}',
        if (contentType != null) 'Content-Type': contentType,
      };

  void _emit(SyncPhase phase,
      {String? error, double? progreso, String? detalle}) async {
    final pending = await _db.countPendingOps();
    final lastOk = await _ultimaOk();
    _current = SyncStatus(
        phase: phase,
        pending: pending,
        lastOk: lastOk,
        lastError: error,
        progreso: progreso,
        detalle: detalle);
    _status.add(_current);
  }

  /// Describe un error de red en lenguaje del entrenador (punto 20):
  /// distingue "sin internet" de "error del servidor".
  String _describeError(Object e) {
    final s = e.toString();
    final l = s.toLowerCase();
    if (e is SocketException ||
        l.contains('socketexception') ||
        l.contains('failed host lookup') ||
        l.contains('network is unreachable') ||
        l.contains('no address associated with hostname')) {
      return 'Sin conexión a internet';
    }
    if (e is TimeoutException || l.contains('timeout')) {
      return 'Conexión muy lenta (tiempo agotado)';
    }
    final m51 = RegExp(r'http 5\d\d').firstMatch(l);
    if (m51 != null) return 'Error del servidor (reintenta luego)';
    if (l.contains('http 401') || l.contains('401')) {
      return 'Sesión vencida';
    }
    final corto = s.length > 90 ? '${s.substring(0, 90)}…' : s;
    return 'Error de red: $corto';
  }

  Future<DateTime?> _ultimaOk() async {
    final v = await _db.getMeta('last_sync_ok');
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<void> _marcarOk() =>
      _db.setMeta('last_sync_ok', DateTime.now().toIso8601String());

  Future<SyncDetalle> detalle() async {
    DateTime? pull, push;
    final p1 = await _db.getMeta('last_pull_ok');
    final p2 = await _db.getMeta('last_push_ok');
    if (p1 != null) pull = DateTime.tryParse(p1);
    if (p2 != null) push = DateTime.tryParse(p2);
    return SyncDetalle(
      ultimaPull: pull,
      ultimaPush: push,
      subidos: int.tryParse(await _db.getMeta('last_uploaded') ?? '0') ?? 0,
      bajados: int.tryParse(await _db.getMeta('last_downloaded') ?? '0') ?? 0,
      error: await _db.getMeta('last_sync_error'),
    );
  }

  void _sesionVencida() {
    _auth.signOut();
    onSessionExpired?.call();
  }

  /// Ciclo completo: push + pull (botón "Sincronizar ahora", al entrar).
  Future<void> run() async {
    if (_running || !_auth.loggedIn) return;
    _running = true;
    try {
      await push();
      await pull();
      await _marcarOk();
      await _db.setMeta('last_sync_error', '');
      _emit(SyncPhase.idle);
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
    } catch (e) {
      await _db.setMeta('last_sync_error', _describeError(e));
      _emit(SyncPhase.error, error: _describeError(e));
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
    } finally {
      _running = false;
    }
  }

  /// Solo subida (cada hora o manual).
  Future<void> push() async {
    if (_running || !_auth.loggedIn) return;
    _running = true;
    try {
      _emit(SyncPhase.uploading);
      final n = await _uploadOps();
      _emit(SyncPhase.photos);
      await _uploadFotos();
      await _db.setMeta('last_push_ok', DateTime.now().toIso8601String());
      await _db.setMeta('last_uploaded', '$n');
      _emit(SyncPhase.idle);
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
    } catch (e) {
      _emit(SyncPhase.error, error: _describeError(e));
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
    } finally {
      _running = false;
    }
  }

  /// Solo bajada (frecuente: ver cambios de otros entrenadores).
  Future<void> pull() async {
    if (_running || !_auth.loggedIn) return;
    _running = true;
    try {
      _emit(SyncPhase.downloading);
      final n = await _download();
      await _db.setMeta('last_pull_ok', DateTime.now().toIso8601String());
      await _db.setMeta('last_downloaded', '$n');
      _emit(SyncPhase.idle);
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
    } catch (e) {
      _emit(SyncPhase.error, error: _describeError(e));
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
    } finally {
      _running = false;
    }
  }

  // -- subida ----------------------------------------------------------
  /// Devuelve la cantidad de ops que quedaron aplicadas.
  ///
  /// Envío en lote (punto 19): varias ops por petición PostgREST
  /// (bulk + on_conflict para idempotencia), menos viajes de ida y vuelta
  /// con conexiones de alta latencia.
  Future<int> _uploadOps() async {
    var aplicadas = 0;
    final ops = await _db.pendingOps();
    // 1) las ya aplicadas se marcan sin reenviar
    final porEnviar = <Map<String, dynamic>>[];
    for (final op in ops) {
      final uuid = op['op_uuid'] as String;
      if (await _opAplicada(uuid)) {
        await _db.markOp(uuid, 'aplicada');
        aplicadas++;
      } else {
        porEnviar.add(op);
      }
    }
    // 2) envío en lotes de 50
    const loteTam = 50;
    for (var i = 0; i < porEnviar.length; i += loteTam) {
      final fin =
          (i + loteTam < porEnviar.length) ? i + loteTam : porEnviar.length;
      final lote = porEnviar.sublist(i, fin);
      _emit(SyncPhase.uploading,
          detalle:
              '⬆️ Subiendo operaciones $fin de ${porEnviar.length}…',
          progreso: fin / porEnviar.length);
      final body = jsonEncode([
        for (final op in lote)
          {
            'op_uuid': op['op_uuid'],
            'device_tag': 'apk-android',
            'tipo': op['tipo'],
            'payload': jsonDecode(op['payload'] as String),
          }
      ]);
      try {
        final r = await http
            .post(
                Uri.parse(
                    '$_base/rest/v1/sync_ops?on_conflict=op_uuid'),
                headers: {
                  ..._headers(),
                  'Content-Type': 'application/json',
                  // duplicados se fusionan: idempotente por op_uuid
                  'Prefer':
                      'resolution=merge-duplicates,return=minimal',
                },
                body: body)
            .timeout(const Duration(seconds: 60));
        if (r.statusCode == 401) throw SessionExpired();
        if (r.statusCode == 200 ||
            r.statusCode == 201 ||
            r.statusCode == 204) {
          for (final op in lote) {
            await _db.markOp(op['op_uuid'] as String, 'enviada');
          }
        } else {
          for (final op in lote) {
            await _db.bumpOp(op['op_uuid'] as String,
                _describeError('HTTP ${r.statusCode}'));
          }
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        for (final op in lote) {
          await _db.bumpOp(
              op['op_uuid'] as String, _describeError(e));
        }
      }
    }
    // 3) segunda pasada: marcar aplicadas (incluye las 'enviada')
    for (final op in await _db.unappliedOps()) {
      final uuid = op['op_uuid'] as String;
      if (await _opAplicada(uuid)) {
        await _db.markOp(uuid, 'aplicada');
        aplicadas++;
      }
    }
    return aplicadas;
  }

  Future<bool> _opAplicada(String uuid) async {
    try {
      final r = await http.get(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=aplicada'),
          headers: _headers()).timeout(const Duration(seconds: 20));
      if (r.statusCode == 401) throw SessionExpired();
      if (r.statusCode != 200) return false;
      final rows = jsonDecode(r.body) as List;
      return rows.isNotEmpty && rows.first['aplicada'] == true;
    } catch (e) {
      if (e is SessionExpired) rethrow;
      return false;
    }
  }

  Future<int?> _clienteDeOp(String uuid) async {
    try {
      final r = await http.get(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=resultado'),
          headers: _headers()).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return null;
      final res = rows.first['resultado'];
      if (res is Map) {
        // El puente guarda el envelope {"ok":..., "resultado": {...}}.
        final inner = res['resultado'];
        final src = inner is Map ? inner : res;
        final cid = src['cliente_id'];
        return cid is int ? cid : int.tryParse('$cid');
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // -- bajada ------------------------------------------------------------
  /// Devuelve la cantidad de filas nuevas bajadas.
  Future<int> _download() async {
    // ajustes + server_seq (informativo)
    try {
      final r = await http.get(
          Uri.parse('$_base/rest/v1/sync_estado?id=eq.1'
              '&select=server_seq,ajustes'),
          headers: _headers()).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final rows = jsonDecode(r.body) as List;
        if (rows.isNotEmpty && rows.first['ajustes'] is Map) {
          await _db.setAjustes(
              Map<String, dynamic>.from(rows.first['ajustes']));
        }
      }
    } catch (_) {}

    var wm = await _db.getWatermark();
    // `since` queda fijo para todo el ciclo: cada tabla consulta desde el
    // watermark inicial y solo al final se consolida el máximo. Así ningún
    // cambio con sync_seq menor que el máximo de otra tabla se omite.
    final since = wm;
    var maxSeq = wm;
    var bajados = 0;
    const tablas = ['clientes', 'pagos', 'pagos_diarios'];
    var ti = 0;
    for (final tabla in tablas) {
      ti++;
      final supTabla =
          {'clientes': 'sync_clientes', 'pagos': 'sync_pagos'}[tabla] ??
              'sync_pagos_diarios';
      _emit(SyncPhase.downloading,
          detalle: '⬇️ Bajando $tabla ($ti de ${tablas.length})…',
          progreso: ti / (tablas.length + 1));
      var pageWm = since;
      while (true) {
        final r = await http.get(
            Uri.parse('$_base/rest/v1/$supTabla?select=id,data,sync_seq'
                '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=500'),
            headers: _headers()).timeout(const Duration(seconds: 30));
        if (r.statusCode == 401) {
          throw SessionExpired();
        }
        if (r.statusCode != 200) {
          throw Exception('bajada $tabla: HTTP ${r.statusCode}');
        }
        final rows = jsonDecode(r.body) as List;
        if (rows.isEmpty) break;
        for (final row in rows) {
          final m = Map<String, dynamic>.from(row as Map);
          final seq = (m['sync_seq'] as int?) ?? 0;
          await _db.upsertMirror(tabla, (m['id'] as int?) ?? 0,
              Map<String, dynamic>.from(m['data'] as Map), seq);
          if (seq > maxSeq) maxSeq = seq;
          bajados++;
        }
        if (rows.length < 500) break;
        pageWm = maxSeq;
      }
    }
    // borrados (tombstones)
    _emit(SyncPhase.downloading,
        detalle: '⬇️ Bajando borrados…',
        progreso: tablas.length / (tablas.length + 1));
    var pageWm = since;
    while (true) {
      final r = await http.get(
          Uri.parse('$_base/rest/v1/sync_borrados'
              '?select=entidad,entidad_id,sync_seq'
              '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=500'),
          headers: _headers()).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        throw Exception('bajada borrados: HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      for (final row in rows) {
        final m = Map<String, dynamic>.from(row as Map);
        final seq = (m['sync_seq'] as int?) ?? 0;
        final tabla = {'clientes': 'clientes', 'pagos': 'pagos'}[
                m['entidad']] ??
            'pagos_diarios';
        await _db.deleteMirror(tabla, (m['entidad_id'] as int?) ?? -1);
        if (seq > maxSeq) maxSeq = seq;
      }
      if (rows.length < 500) break;
      pageWm = maxSeq;
    }
    if (maxSeq > since) {
      await _db.setWatermark(maxSeq);
    }
    return bajados;
  }

  // -- fotos -------------------------------------------------------------
  /// Reduce la foto a máx. 1024px de ancho (JPEG 80) antes de subirla.
  /// Las fotos de cámara a resolución completa (varios MB) no terminan
  /// de subir con conexiones lentas; así quedan en ~150-300 KB.
  Uint8List _comprimirFoto(Uint8List bytes) {
    try {
      final dec = img.decodeImage(bytes);
      if (dec == null || dec.width <= 1024) return bytes;
      final chica = img.copyResize(dec, width: 1024);
      return Uint8List.fromList(img.encodeJpg(chica, quality: 80));
    } catch (_) {
      return bytes; // si falla, se intenta con la original
    }
  }

  /// Crea una subida tus reanudable. Devuelve la URL de subida o null
  /// si tus no está disponible / fue rechazada.
  Future<String?> _tusCrear(String objectPath, int length) async {
    String meta(String k, String v) =>
        '$k ${base64Encode(utf8.encode(v))}';
    try {
      final r = await http
          .post(
            Uri.parse('$_base/storage/v1/upload/resumable'),
            headers: {
              ..._headers(),
              'Tus-Resumable': '1.0.0',
              'Upload-Length': '$length',
              'Upload-Metadata': [
                meta('filename', objectPath.split('/').last),
                meta('bucketName', AppConfig.bucketFotos),
                meta('objectName', objectPath),
                meta('contentType', 'image/jpeg'),
              ].join(','),
            },
          )
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200 && r.statusCode != 201) return null;
      final loc = r.headers['location'];
      if (loc == null || loc.isEmpty) return null;
      return loc.startsWith('http') ? loc : '$_base$loc';
    } catch (_) {
      return null;
    }
  }

  /// Cuánto ya se subió según el servidor: >=0 offset, -1 no existe,
  /// -2 no se pudo averiguar.
  Future<int> _tusOffset(String location) async {
    try {
      final r = await http.head(Uri.parse(location), headers: {
        ..._headers(),
        'Tus-Resumable': '1.0.0',
      }).timeout(const Duration(seconds: 30));
      if (r.statusCode == 404 || r.statusCode == 410) return -1;
      if (r.statusCode != 200) return -2;
      return int.tryParse(r.headers['upload-offset'] ?? '') ?? -2;
    } catch (_) {
      return -2;
    }
  }

  /// Sube la foto por partes con tus (punto 17): si se corta la conexión,
  /// continúa donde quedó en vez de empezar de cero.
  /// Devuelve true si terminó, false si hay que reintentar luego,
  /// null si tus no está disponible (usar el método simple).
  Future<bool?> _subirFotoTus(
      String opUuid, String objectPath, Uint8List bytes) async {
    final locKey = 'tus_loc_$opUuid';
    final offKey = 'tus_offset_$opUuid';
    String? location = await _db.getMeta(locKey);
    if (location != null && location.isEmpty) location = null;
    var offset = int.tryParse(await _db.getMeta(offKey) ?? '0') ?? 0;

    if (location == null) {
      location = await _tusCrear(objectPath, bytes.length);
      if (location == null) return null;
      await _db.setMeta(locKey, location);
      offset = 0;
    } else {
      final remoto = await _tusOffset(location);
      if (remoto == -1) {
        // expiró en el servidor: crear de nuevo
        location = await _tusCrear(objectPath, bytes.length);
        if (location == null) return null;
        await _db.setMeta(locKey, location);
        offset = 0;
      } else if (remoto >= 0) {
        offset = remoto;
      }
      // remoto == -2: no se pudo averiguar; se usa el guardado
    }
    if (offset > bytes.length) offset = 0;
    final url = location;

    const chunk = 256 * 1024;
    while (offset < bytes.length) {
      final fin =
          (offset + chunk < bytes.length) ? offset + chunk : bytes.length;
      var okChunk = false;
      for (var intento = 0; intento < 3 && !okChunk; intento++) {
        try {
          final r = await http
              .patch(
                Uri.parse(url),
                headers: {
                  ..._headers(),
                  'Tus-Resumable': '1.0.0',
                  'Content-Type': 'application/offset+octet-stream',
                  'Upload-Offset': '$offset',
                },
                body: bytes.sublist(offset, fin),
              )
              .timeout(const Duration(seconds: 120));
          if (r.statusCode == 204 || r.statusCode == 200) {
            offset =
                int.tryParse(r.headers['upload-offset'] ?? '') ?? fin;
            okChunk = true;
          } else if (r.statusCode == 404 || r.statusCode == 410) {
            // la subida murió en el servidor: recrearla luego
            await _db.setMeta(locKey, '');
            await _db.setMeta(offKey, '0');
            return false;
          }
        } catch (_) {
          okChunk = false;
        }
      }
      if (!okChunk) {
        await _db.setMeta(offKey, '$offset');
        return false; // se retoma donde quedó
      }
      await _db.setMeta(offKey, '$offset');
    }
    // limpia el estado tus de esta foto
    await _db.setMeta(locKey, '');
    await _db.setMeta(offKey, '0');
    return true;
  }

  /// Método simple (un solo PUT): respaldo si tus no está disponible.
  Future<bool> _subirFotoSimple(String path, Uint8List bytes) async {
    for (var intento = 0; intento < 3; intento++) {
      try {
        final r = await http
            .post(
                Uri.parse('$_base/storage/v1/object/'
                    '${AppConfig.bucketFotos}/$path'),
                headers: {
                  ..._headers(),
                  'Content-Type': 'image/jpeg',
                  'x-upsert': 'true',
                },
                body: bytes)
            .timeout(const Duration(seconds: 120));
        if (r.statusCode == 200 || r.statusCode == 201) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _uploadFotos() async {
    final fotos = await _db.fotosPendientes();
    var i = 0;
    for (final f in fotos) {
      i++;
      final fid = f['id'] as int;
      var clienteId = f['cliente_id'] as int?;
      clienteId ??= await _clienteDeOp(f['op_uuid'] as String);
      if (clienteId == null) continue; // la inscripción aún no se aplica
      if (f['cliente_id'] == null) {
        await _db.setFotoCliente(fid, clienteId);
      }
      final file = File(f['local_path'] as String);
      if (!await file.exists()) {
        await _db.markFotoLista(fid);
        continue;
      }
      var bytes = await file.readAsBytes();
      bytes = _comprimirFoto(bytes);
      final path = 'pendientes/${f['op_uuid']}.jpg';
      _emit(SyncPhase.photos,
          detalle: '📷 Subiendo foto $i de ${fotos.length}…',
          progreso: (i - 1) / fotos.length);
      // reanudable primero; si tus no está disponible, método simple
      final tus =
          await _subirFotoTus(f['op_uuid'] as String, path, bytes);
      final ok = tus ?? await _subirFotoSimple(path, bytes);
      if (!ok) continue;
      _emit(SyncPhase.photos,
          detalle: '📷 Subiendo foto $i de ${fotos.length}…',
          progreso: i / fotos.length);
      // encola la op 'foto' para que el puente la guarde en gym.db
      final d = await _db.db;
      final opUuid = const Uuid().v4();
      await d.insert('ops_queue', {
        'op_uuid': opUuid,
        'tipo': 'foto',
        'payload': jsonEncode(
            {'storage_path': path, 'cliente_id': clienteId}),
        'estado': 'pendiente',
        'creada_ts': DateTime.now().toIso8601String(),
      });
      await _db.markFotoLista(fid);
    }
  }
}
