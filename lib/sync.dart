/// Motor de sincronización offline-first.
///
/// Subida:   ops de `ops_queue` -> POST /rest/v1/sync_ops (idempotente por
///           op_uuid; un 409 se trata como "ya encolada").
///           Luego consulta `aplicada` de cada op propia (policy
///           "ver propias ops") y marca la cola.
/// Bajada:   espejos + borrados con sync_seq > watermark local, aplica y
///           guarda el watermark. También trae `ajustes` (precios).
/// Fotos:    las fotos de inscripciones se suben cuando la op de
///           inscripción ya fue aplicada (se conoce el cliente_id) y se
///           encolan como op tipo 'foto'.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
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
  const SyncStatus(
      {this.phase = SyncPhase.idle,
      this.pending = 0,
      this.lastOk,
      this.lastError});
}

class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  final _status = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _status.stream;
  SyncStatus _current = const SyncStatus();
  bool _running = false;

  final _auth = AuthService();
  final _db = LocalDb.instance;

  String get _base => AppConfig.supabaseUrl;

  Map<String, String> _headers({String? contentType}) => {
        'apikey': AppConfig.anonKey,
        'Authorization': 'Bearer ${_auth.session?.accessToken ?? ''}',
        if (contentType != null) 'Content-Type': contentType,
      };

  void _emit(SyncPhase phase, {String? error}) async {
    final pending = await _db.countPendingOps();
    _current = SyncStatus(
        phase: phase,
        pending: pending,
        lastOk: phase == SyncPhase.idle ? DateTime.now() : _current.lastOk,
        lastError: error);
    _status.add(_current);
  }

  /// Ciclo completo. Seguro ante fallos de red: marca y sigue.
  Future<void> run() async {
    if (_running || !_auth.loggedIn) return;
    _running = true;
    try {
      _emit(SyncPhase.uploading);
      await _uploadOps();
      _emit(SyncPhase.downloading);
      await _download();
      _emit(SyncPhase.photos);
      await _uploadFotos();
      _emit(SyncPhase.idle);
    } catch (e) {
      _emit(SyncPhase.error, error: e.toString());
      // vuelve a idle para no trabar la UI
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
    } finally {
      _running = false;
    }
  }

  // -- subida ----------------------------------------------------------
  Future<void> _uploadOps() async {
    final ops = await _db.pendingOps();
    for (final op in ops) {
      final uuid = op['op_uuid'] as String;
      // ¿ya fue aplicada?
      if (await _opAplicada(uuid)) {
        await _db.markOp(uuid, 'aplicada');
        continue;
      }
      final body = jsonEncode({
        'op_uuid': uuid,
        'device_tag': 'apk-android',
        'tipo': op['tipo'],
        'payload': jsonDecode(op['payload'] as String),
      });
      http.Response r;
      try {
        r = await http
            .post(Uri.parse('$_base/rest/v1/sync_ops'),
                headers: {..._headers(), 'Content-Type': 'application/json'},
                body: body)
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        await _db.bumpOp(uuid, 'sin conexión: $e');
        continue;
      }
      if (r.statusCode == 201 || r.statusCode == 200 || r.statusCode == 409) {
        // 409 = ya existe (reintento): idempotente, se sigue.
        await _db.markOp(uuid, 'enviada');
      } else if (r.statusCode == 401) {
        throw Exception('sesión vencida, entra de nuevo');
      } else {
        await _db.bumpOp(uuid, 'HTTP ${r.statusCode}');
      }
    }
    // segunda pasada: marcar aplicadas (incluye las 'enviada')
    for (final op in await _db.unappliedOps()) {
      final uuid = op['op_uuid'] as String;
      if (await _opAplicada(uuid)) {
        await _db.markOp(uuid, 'aplicada');
      }
    }
  }

  Future<bool> _opAplicada(String uuid) async {
    try {
      final r = await http.get(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=aplicada'),
          headers: _headers()).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return false;
      final rows = jsonDecode(r.body) as List;
      return rows.isNotEmpty && rows.first['aplicada'] == true;
    } catch (_) {
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
  Future<void> _download() async {
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
    for (final tabla in ['clientes', 'pagos', 'pagos_diarios']) {
      final supTabla =
          {'clientes': 'sync_clientes', 'pagos': 'sync_pagos'}[tabla] ??
              'sync_pagos_diarios';
      var pageWm = since;
      while (true) {
        final r = await http.get(
            Uri.parse('$_base/rest/v1/$supTabla?select=id,data,sync_seq'
                '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=500'),
            headers: _headers()).timeout(const Duration(seconds: 30));
        if (r.statusCode == 401) {
          throw Exception('sesión vencida, entra de nuevo');
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
        }
        if (rows.length < 500) break;
        pageWm = maxSeq;
      }
    }
    // borrados (tombstones)
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
  }

  // -- fotos -------------------------------------------------------------
  Future<void> _uploadFotos() async {
    final fotos = await _db.fotosPendientes();
    for (final f in fotos) {
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
      final bytes = await file.readAsBytes();
      final path = 'pendientes/${f['op_uuid']}.jpg';
      try {
        final r = await http.post(
            Uri.parse('$_base/storage/v1/object/'
                '${AppConfig.bucketFotos}/$path'),
            headers: {
              ..._headers(),
              'Content-Type': 'image/jpeg',
              'x-upsert': 'true',
            },
            body: bytes).timeout(const Duration(seconds: 60));
        if (r.statusCode != 200 && r.statusCode != 201) continue;
      } catch (_) {
        continue; // reintenta en el próximo ciclo
      }
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
