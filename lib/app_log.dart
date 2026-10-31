import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'localdb.dart';

/// Bitácora local v3.0 (v1.3.1).
/// Telemetría robusta y desacoplada para diagnóstico forense.
///
/// Mejoras Gemini (v2.0):
/// - 5 niveles (debug/info/aviso/error/critico)
/// - Contexto estructurado JSON + stack recortado
/// - Correlación por opId
/// - Métricas automáticas (medir)
/// - Buffer asíncrono con flush por lotes
/// - Interceptores globales (main.dart)
/// - Centinela de crash previo
/// - Sanitización de tokens
///
/// Mejoras Argón (v3.0):
/// - Ring Buffer en RAM (50 eventos): todo entra aquí primero;
///   breadcrumbs completos en ERROR/CRITICO/FATAL, últimos 5 en
///   avisos no-perf, nada en debug (cero costo en release)
/// - Crash Handler: solo errores async no manejados vuelcan
///   SÍNCRONO a last_crash.json; se ingesta como FATAL al reiniciar
///   y el archivo se borra solo tras insert exitoso
/// - Poda por severidad: ERROR/CRITICO/FATAL con corte 30d + tope
///   1000 filas; DEBUG/INFO/AVISO con corte 7d + cuota 4000
/// - Métricas por umbral: medirLento() solo registra si supera el umbral
/// - Modo Diagnóstico 24h: DEBUG persistente en release bajo demanda
class AppLog {
  AppLog._();

  // --- Buffer asíncrono (Gemini #1) ---
  static final List<Map<String, dynamic>> _buffer = [];
  static Timer? _flushTimer;
  static int _contador = 0;

  // === v3.0: Ring Buffer en RAM (Argón) ===
  // FIFO circular de los últimos 50 eventos. Todo evento (incluso
  // DEBUG) entra aquí primero. Solo RAM, nunca disco directamente.
  static const int _ringCapacidad = 50;
  static final List<Map<String, dynamic>> _ring = [];

  // Ruta de documentos cacheada (para el volcado síncrono de crash).
  static String? _docsPath;

  // v3.0: modo diagnóstico (cache en memoria de applog_diag_hasta).
  static const String _keyDiag = 'applog_diag_hasta';
  static DateTime? _diagHasta;

  static void _ringAdd(String nivel, String modulo, String mensaje,
      {String? detalle, Map<String, dynamic>? ctxSanitizado}) {
    _ring.add({
      'ts': DateTime.now().toIso8601String(),
      'nivel': nivel,
      'modulo': modulo,
      'mensaje': _sanitizarTexto(mensaje),
      if (detalle != null) 'detalle': detalle,
      if (ctxSanitizado != null && ctxSanitizado.isNotEmpty)
        'contexto': ctxSanitizado,
    });
    if (_ring.length > _ringCapacidad) {
      _ring.removeRange(0, _ring.length - _ringCapacidad);
    }
  }

  // Solo error, critico y fatal arrastran los 50 breadcrumbs completos
  // (Argón: aviso ya no, para no inflar el disco con medirLento).
  static bool _esNivelAlto(String nivel) =>
      nivel == 'error' || nivel == 'critico' || nivel == 'fatal';

  /// v3.0: ¿debe persistir en SQLite este nivel?
  /// Release sin diagnóstico: desde INFO. En diagnóstico o debug: desde DEBUG.
  static bool _deberiaPersistir(String nivel) {
    const orden = [
      'debug',
      'info',
      'aviso',
      'error',
      'critico',
      'fatal'
    ];
    final idx = orden.indexOf(nivel);
    if (idx < 0) return true; // nivel desconocido: no filtrar
    final enDiag =
        _diagHasta != null && DateTime.now().isBefore(_diagHasta!);
    final minimo = (enDiag || !kReleaseMode) ? 0 : 1;
    return idx >= minimo;
  }

  /// v3.0: inicialización. Carga el modo diagnóstico, cachea la ruta
  /// de documentos, ingesta un crash previo (last_crash.json) y
  /// engancha los manejadores globales de error.
  /// Llamar una vez desde main() al arrancar.
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_keyDiag);
      if (ts != null) {
        final hasta = DateTime.fromMillisecondsSinceEpoch(ts);
        if (hasta.isAfter(DateTime.now())) _diagHasta = hasta;
      }
    } catch (_) {}
    try {
      _docsPath = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {}
    await _ingerirCrashPrevio();
    _instalarManejadores();
  }

  /// Niveles: debug < info < aviso < error < critico < fatal
  static void debug(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          String? opId}) {
    final log = _crear(m, e, 'debug', d, contexto, null, opId);
    // v3.0: _crear retorna null si no debe persistir (ej. debug en release).
    if (log != null) _encolar(log);
  }

  static void info(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          String? opId}) {
    final log = _crear(m, e, 'info', d, contexto, null, opId);
    if (log != null) _encolar(log);
  }

  static void aviso(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          String? opId}) {
    final log = _crear(m, e, 'aviso', d, contexto, null, opId);
    if (log != null) _encolar(log);
  }

  static void error(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          StackTrace? stack,
          String? opId}) {
    final log = _crear(m, e, 'error', d, contexto, stack, opId);
    if (log != null) _encolar(log, inmediato: true);
  }

  static void critico(String m, String e,
          {String? d,
          Map<String, dynamic>? contexto,
          StackTrace? stack,
          String? opId}) {
    final log = _crear(m, e, 'critico', d, contexto, stack, opId);
    if (log != null) {
      _encolar(log, inmediato: true);
    }
  }

  /// v3.0: breadcrumb de navegación/acción UI. Solo RAM, nunca disco.
  /// Se adjunta automáticamente al contexto de ERROR/CRITICO/FATAL.
  static void breadcrumb(String mensaje,
      [Map<String, dynamic>? contexto]) {
    _ringAdd('debug', 'ui', mensaje,
        ctxSanitizado:
            contexto != null ? _sanitizar(contexto) : null);
  }

  /// v3.0 (Argón): registra AVISO solo si [duracionMs] supera [umbralMs].
  /// Para detectar queries/operaciones lentas sin ruido en la bitácora.
  static void medirLento(String nombre, int duracionMs,
      {int umbralMs = 300}) {
    if (duracionMs < umbralMs) return;
    aviso('perf', 'lento_$nombre', contexto: {
      'duracion_ms': duracionMs,
      'umbral_ms': umbralMs,
    });
  }

  /// v3.0: activa persistencia de DEBUG en release por 24h.
  /// Se desactiva solo por TTL.
  static Future<void> activarModoDiagnostico() async {
    final hasta =
        DateTime.now().add(const Duration(hours: 24));
    _diagHasta = hasta;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _keyDiag, hasta.millisecondsSinceEpoch);
    } catch (_) {}
    info('app', 'modo_diagnostico_activado',
        d: 'DEBUG persistente por 24h',
        contexto: {'hasta': hasta.toIso8601String()});
  }

  static Map<String, dynamic>? _crear(
      String modulo,
      String evento,
      String nivel,
      String? detalle,
      Map<String, dynamic>? contexto,
      StackTrace? stack,
      String? opId) {
    // 1. Sanitizar UNA sola vez.
    final detSan =
        detalle != null ? _sanitizarTexto(detalle) : null;
    final ctxLimpio = contexto != null
        ? Map<String, dynamic>.from(_sanitizar(contexto))
        : <String, dynamic>{};

    // 2. Ring Buffer recibe copia limpia (sin breadcrumbs) para no
    //    contaminar RAM ni crear referencia circular.
    _ringAdd(nivel, modulo, evento,
        detalle: detSan,
        ctxSanitizado: ctxLimpio.isNotEmpty
            ? Map<String, dynamic>.from(ctxLimpio)
            : null);

    // 3. Si no debe persistir en disco, salir sin jsonEncode.
    if (!_deberiaPersistir(nivel)) return null;

    // 4. Contexto exclusivo para SQLite (sin mutar lo del ring).
    final ctxDb = Map<String, dynamic>.from(ctxLimpio);
    if (_esNivelAlto(nivel)) {
      ctxDb['breadcrumbs'] =
          List<Map<String, dynamic>>.from(_ring);
    } else if (nivel == 'aviso' && modulo != 'perf') {
      final skip = _ring.length > 5 ? _ring.length - 5 : 0;
      ctxDb['breadcrumbs'] = _ring.sublist(skip);
    }

    // Stack recortado a 15 líneas.
    final stackRecortado = stack
        ?.toString()
        .split('\n')
        .take(15)
        .join('\n');

    return {
      'ts': DateTime.now().toIso8601String(),
      'modulo': modulo,
      'evento': evento,
      'detalle': detSan,
      'nivel': nivel,
      'contexto':
          ctxDb.isNotEmpty ? jsonEncode(ctxDb) : null,
      'op_id': opId,
      'stack': stackRecortado,
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
      v = v.replaceAllMapped(
          RegExp(r'(token|api_key|password)=([^&\s]+)',
              caseSensitive: false),
          (m) => '${m[1]}=***');
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
    // M1 (Argón): también ocultar token/api_key/password en texto.
    v = v.replaceAllMapped(
        RegExp(r'(token|api_key|password)\s*[:=]\s*\S+',
            caseSensitive: false),
        (m) => '${m[1]}=***');
    // v1.3.2 (Argón #19): también con comillas JSON ("password": "...").
    v = v.replaceAllMapped(
        RegExp(r'"(token|api_key|password)"\s*:\s*"[^"]*"',
            caseSensitive: false),
        (m) => '"${m[1]}":"***"');
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

  static bool _flushing = false;

  static Future<void> _flush() async {
    // M2 (Argón): evitar ejecuciones concurrentes.
    if (_flushing) return;
    _flushing = true;
    try {
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
    } finally {
      _flushing = false;
      // v1.3.1 (M2): si llegaron logs durante el flush, reprogramar.
      if (_buffer.isNotEmpty && _flushTimer == null) {
        _flushTimer = Timer(const Duration(seconds: 2), _flush);
      }
    }
  }

  /// Genera un ID corto para correlación (Gemini #3).
  static String nuevoOpId(String prefijo) =>
      '${prefijo}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

  // === v3.0: Crash Handler (Argón) ===
  // Engancha los manejadores globales ENCADENANDO los previos
  // (p. ej. los de main.dart), para no romper su comportamiento.

  static void _instalarManejadores() {
    final previoFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      // Fix C (Argón): errores de Flutter (renderizado, recursos) NO
      // son crashes fatales. No llamar _volcarCrashSync aquí: haría
      // escritura síncrona en el hilo principal (jank) y generaría
      // falsos FATAL al reiniciar. El handler encadenado (main.dart)
      // los registra por el flujo normal.
      if (previoFlutter != null) {
        previoFlutter(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    try {
      final previoAsync =
          PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError =
          (error, stack) {
        _volcarCrashSync(
            'async_error', '$error', stack);
        if (previoAsync != null) {
          return previoAsync(error, stack);
        }
        return true;
      };
    } catch (_) {}
  }

  /// Volcado SÍNCRONO del crash a last_crash.json.
  /// No usa SQLite ni el buffer asíncrono: el SO puede matar
  /// el proceso en milisegundos y el buffer nunca se vaciaría.
  static void _volcarCrashSync(
      String tipo, String error, StackTrace? stack) {
    try {
      final dir = _docsPath;
      if (dir == null) return;
      final err = error.length > 2000
          ? error.substring(0, 2000)
          : error;
      final mapa = <String, dynamic>{
        'ts': DateTime.now().toIso8601String(),
        'tipo': tipo,
        'error': _sanitizarTexto(err),
        'stack': stack
            ?.toString()
            .split('\n')
            .take(25)
            .join('\n'),
        'breadcrumbs':
            List<Map<String, dynamic>>.from(_ring),
      };
      File('$dir/last_crash.json')
          .writeAsStringSync(jsonEncode(mapa));
    } catch (_) {
      // Nunca propagar desde el manejador de crash.
    }
  }

  /// Al iniciar: si existe last_crash.json de una corrida previa,
  /// insertarlo como FATAL y borrar el archivo.
  static Future<void> _ingerirCrashPrevio() async {
    try {
      final dir = _docsPath;
      if (dir == null) return;
      final f = File('$dir/last_crash.json');
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      Map<String, dynamic> data;
      try {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        // JSON corrupto: borrar para no ciclar y salir.
        await f.delete();
        return;
      }
      final db = await LocalDb.instance.db;
      await db.insert('app_log', {
        'ts':
            '${data['ts'] ?? DateTime.now().toIso8601String()}',
        'modulo': 'app',
        'evento':
            "crash_${data['tipo'] ?? 'desconocido'}",
        'detalle':
            _sanitizarTexto('${data['error'] ?? '?'}'),
        'nivel': 'fatal',
        'contexto': jsonEncode({
          'breadcrumbs': data['breadcrumbs'],
        }),
        'op_id': null,
        'stack': data['stack'] as String?,
      });
      // Fix B (Argón): borrar SOLO después de haber insertado
      // con éxito en SQLite. Si el insert falla, el archivo queda
      // para el próximo arranque.
      await f.delete();
    } catch (_) {}
  }

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

  /// Poda por severidad (v3.0, Argón):
  /// - ERROR/CRITICO/FATAL: corte 30 días + tope de seguridad de 1000
  ///   filas (una tormenta de errores no puede crecer sin límite).
  /// - DEBUG/INFO/AVISO: corte 7 días + cuota de 4000 filas.
  static Future<void> podar([Database? db]) async {
    try {
      final b = db ?? await LocalDb.instance.db;
      // Corte ISO desde Dart (no datetime('now') UTC).
      final corte30 = DateTime.now()
          .subtract(const Duration(days: 30))
          .toIso8601String();
      await b.execute(
        "DELETE FROM app_log "
        "WHERE nivel IN ('error','critico','fatal') "
        "AND (ts < ? OR id NOT IN ("
        "SELECT id FROM app_log "
        "WHERE nivel IN ('error','critico','fatal') "
        "ORDER BY id DESC LIMIT 1000))",
        [corte30],
      );
      final corte7 = DateTime.now()
          .subtract(const Duration(days: 7))
          .toIso8601String();
      await b.execute(
        "DELETE FROM app_log "
        "WHERE nivel NOT IN ('error','critico','fatal') "
        'AND (ts < ? OR id NOT IN ('
        'SELECT id FROM app_log '
        "WHERE nivel NOT IN ('error','critico','fatal') "
        'ORDER BY id DESC LIMIT 4000))',
        [corte7],
      );
    } catch (_) {}
  }

  /// Exporta en Markdown con resumen (Gemini #6).
  /// Módulo 6: últimos eventos persistidos, para el diagnóstico
  /// de datos visibles (sin exportar archivo). Vacía el buffer
  /// antes, igual que exportar(). Con [modulo], solo ese módulo
  /// (p. ej. 'sync' para el historial de sync).
  static Future<List<Map<String, dynamic>>> eventosRecientes(
      {int limite = 50, String? modulo}) async {
    await _flush();
    final db = await LocalDb.instance.db;
    return db.query('app_log',
        where: modulo == null ? null : 'modulo = ?',
        whereArgs: modulo == null ? null : [modulo],
        orderBy: 'id DESC', limit: limite);
  }

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
      if ('${f['ts']}'.compareTo(hace24h) < 0) {
        continue;
      }
      switch ('${f['nivel']}') {
        case 'error':
          nErr++;
          break;
        case 'aviso':
          nAviso++;
          break;
        case 'critico':
        case 'fatal': // v3.0
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
