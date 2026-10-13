import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'localdb.dart';

/// Bitácora local v2.0 (v1.3.0).
/// Telemetría robusta y desacoplada para diagnóstico forense.
///
/// Mejoras Gemini:
/// - 5 niveles (debug/info/aviso/error/critico)
/// - Contexto estructurado JSON + stack recortado
/// - Correlación por opId
/// - Métricas automáticas (medir)
/// - Buffer asíncrono con flush por lotes
/// - Poda por cuota rígida (tiempo + 5000 filas)
/// - Interceptores globales (main.dart)
/// - Centinela de crash previo
/// - Sanitización de tokens
class AppLog {
  AppLog._();

  // --- Buffer asíncrono (Gemini #1) ---
  static final List<Map<String, dynamic>> _buffer = [];
  static Timer? _flushTimer;
  static int _contador = 0;

  /// Niveles: debug < info < aviso < error < critico
  static void debug(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          String? opId}) {
    if (kReleaseMode) return; // debug no se guarda en release
    _encolar(_crear(
        m, e, 'debug', d, contexto, null, opId));
  }

  static void info(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          String? opId}) =>
      _encolar(
          _crear(m, e, 'info', d, contexto, null, opId));

  static void aviso(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          String? opId}) =>
      _encolar(
          _crear(m, e, 'aviso', d, contexto, null, opId));

  static void error(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          StackTrace? stack,
          String? opId}) =>
      _encolar(
          _crear(m, e, 'error', d, contexto, stack, opId),
          inmediato: true);

  static void critico(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          StackTrace? stack,
          String? opId}) =>
      _encolar(
          _crear(m, e, 'critico', d, contexto, stack, opId),
          inmediato: true);

  static Map<String, dynamic> _crear(
      String modulo,
      String evento,
      String nivel,
      String? detalle,
      Map<String, dynamic>? contexto,
      StackTrace? stack,
      String? opId) {
    // Sanitizar (Gemini #8)
    final ctxSan = contexto != null
        ? _sanitizar(contexto)
        : null;
    final detSan = detalle != null
        ? _sanitizarTexto(detalle)
        : null;
    // Stack recortado a 12 líneas (Gemini #2)
    String? stackStr;
    if (stack != null) {
      final lineas =
          stack.toString().split('\n').take(12);
      stackStr = lineas.join('\n');
    }
    return {
      'ts': DateTime.now().toIso8601String(),
      'modulo': modulo,
      'evento': evento,
      'detalle': detSan,
      'nivel': nivel,
      'contexto': ctxSan != null
          ? jsonEncode(ctxSan)
          : null,
      'op_id': opId,
      'stack': stackStr,
    };
  }

  /// Sanitiza tokens y passwords (Gemini #8).
  static Map<String, dynamic> _sanitizar(
      Map<String, dynamic> ctx) {
    final out = <String, dynamic>{};
    for (final e in ctx.entries) {
      var v = '${e.value}';
      v = v.replaceAll(
          RegExp(r'Bearer\s+\S+',
              caseSensitive: false),
          'Bearer ***');
      v = v.replaceAll(
          RegExp(r'(token|api_key|password)=([^&\s]+)',
              caseSensitive: false),
          r'$1=***');
      out[e.key] = v;
    }
    return out;
  }

  static String _sanitizarTexto(String t) {
    var v = t;
    v = v.replaceAll(
        RegExp(r'Bearer\s+\S+',
            caseSensitive: false),
        'Bearer ***');
    return v;
  }

  static void _encolar(Map<String, dynamic> log,
      {bool inmediato = false}) {
    _buffer.add(log);
    if (inmediato || _buffer.length >= 25) {
      unawaited(_flush());
    } else {
      _flushTimer ??=
          Timer(const Duration(seconds: 3), () {
        unawaited(_flush());
      });
    }
  }

  /// Fix #21 (Sol): no descartar el lote si falla el insert.
  /// Se reencola al inicio del buffer (con límite para evitar
  /// crecimiento infinito si la BD está rota).
  static int _fallosFlush = 0;

  static Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isEmpty) return;
    final lote =
        List<Map<String, dynamic>>.from(_buffer);
    _buffer.clear();
    try {
      final db = await LocalDb.instance.db;
      final batch = db.batch();
      for (final item in lote) {
        batch.insert('app_log', item);
      }
      await batch.commit(noResult: true);
      _contador += lote.length;
      _fallosFlush = 0; // éxito: resetear contador
      if (_contador >= 100) {
        _contador = 0;
        unawaited(podar(db));
      }
    } catch (e) {
      _fallosFlush++;
      // Reencolar al inicio (máx 3 reintentos, luego descartar
      // para no bloquear el buffer con logs imposibles de guardar).
      if (_fallosFlush <= 3) {
        _buffer.insertAll(0, lote);
        // Reintentar en 10 segundos.
        _flushTimer ??= Timer(
            const Duration(seconds: 10), () {
          unawaited(_flush());
        });
      } else {
        _fallosFlush = 0;
        if (kDebugMode) {
          debugPrint(
              '[AppLog] lote descartado tras 3 fallos: $e');
        }
      }
      if (kDebugMode) {
        debugPrint('[AppLog flush error]: $e');
      }
    }
  }

  /// Genera un ID corto para correlación (Gemini #3).
  static String nuevoOpId(String prefijo) =>
      '${prefijo}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

  /// Mide duración automáticamente (Gemini #4).
  static Future<T> medir<T>(
    String modulo,
    String evento,
    Future<T> Function() accion, {
    String? opId,
    Map<String, dynamic>? contexto,
  }) async {
    final reloj = Stopwatch()..start();
    info(modulo, '${evento}_ini',
        opId: opId, contexto: contexto);
    try {
      final resultado = await accion();
      reloj.stop();
      info(modulo, '${evento}_ok',
          opId: opId,
          contexto: {
            ...?contexto,
            'duracion_ms':
                reloj.elapsedMilliseconds
          });
      return resultado;
    } catch (e, st) {
      reloj.stop();
      error(modulo, '${evento}_fallo',
          opId: opId,
          contexto: {
            ...?contexto,
            'duracion_ms':
                reloj.elapsedMilliseconds,
            'error': e.toString()
          },
          stack: st);
      rethrow;
    }
  }

  /// Poda dual: por tiempo Y por cuota rígida (Gemini #2).
  static Future<void> podar([Database? db]) async {
    try {
      final b = db ?? await LocalDb.instance.db;
      await b.execute("""
        DELETE FROM app_log
        WHERE ts < datetime('now', '-7 days')
           OR id NOT IN (
             SELECT id FROM app_log ORDER BY id DESC LIMIT 5000
           )
      """);
    } catch (_) {}
  }

  /// Exporta en Markdown con resumen (Gemini #6).
  static Future<String> exportar() async {
    await _flush(); // vaciar buffer antes
    final db = await LocalDb.instance.db;
    await podar(db);
    final filas = (await db.query('app_log',
            orderBy: 'id DESC', limit: 5000))
        .reversed
        .toList();

    // Resumen 24h
    final hace24h = DateTime.now()
        .subtract(const Duration(hours: 24))
        .toIso8601String();
    var nErr = 0, nAviso = 0, nCrit = 0;
    for (final f in filas) {
      if ('${f['ts']}' .compareTo(hace24h) < 0)
        continue;
      switch ('${f['nivel']}') {
        case 'error':
          nErr++;
          break;
        case 'aviso':
          nAviso++;
          break;
        case 'critico':
          nCrit++;
          break;
      }
    }

    final sb = StringBuffer();
    sb.writeln('# Bitácora IronBody Gym');
    sb.writeln('');
    sb.writeln(
        'Exportado: ${DateTime.now().toIso8601String()}');
    sb.writeln('Registros: ${filas.length}');
    sb.writeln('');
    sb.writeln('## Resumen últimas 24h');
    sb.writeln('');
    sb.writeln('- Críticos: $nCrit');
    sb.writeln('- Errores: $nErr');
    sb.writeln('- Avisos: $nAviso');
    sb.writeln('');
    sb.writeln('## Eventos');
    sb.writeln('');
    String? opActual;
    for (final f in filas) {
      final opId = f['op_id'] as String?;
      if (opId != null && opId != opActual) {
        opActual = opId;
        sb.writeln('### Operación `$opId`');
        sb.writeln('');
      }
      sb.writeln(
          '- `[${f['ts']}]` **[${f['nivel']}]** `${f['modulo']}.${f['evento']}`');
      if (f['detalle'] != null) {
        sb.writeln('  ${f['detalle']}');
      }
      if (f['contexto'] != null) {
        sb.writeln('  ```json');
        sb.writeln('  ${f['contexto']}');
        sb.writeln('  ```');
      }
      if (f['stack'] != null) {
        sb.writeln('  ```');
        sb.writeln('  ${f['stack']}');
        sb.writeln('  ```');
      }
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/bitacora-ironbody-${DateTime.now().millisecondsSinceEpoch}.md';
    await File(path).writeAsString(sb.toString());
    return path;
  }
}

/// Centinela de crash previo (Gemini #4).
class CentinelaApp {
  static const _key = 'tarea_activa';

  static Future<void> marcarInicio(
      String tarea) async {
    final prefs =
        await SharedPreferences.getInstance();
    await prefs.setString(_key,
        '$tarea|${DateTime.now().toIso8601String()}');
  }

  static Future<void> marcarFin() async {
    final prefs =
        await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<void> verificarArranque() async {
    final prefs =
        await SharedPreferences.getInstance();
    final pendiente = prefs.getString(_key);
    if (pendiente != null) {
      final partes = pendiente.split('|');
      AppLog.aviso('sistema',
          'cierre_anormal_detectado',
          contexto: {
            'tarea_inconclusa': partes[0],
            'iniciada_en':
                partes.length > 1 ? partes[1] : '?',
          });
      await prefs.remove(_key);
    }
  }
}
