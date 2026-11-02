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

  /// 1.21 (Argón 121B): corte duro de texto con marca visible.
  static String _cortar(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…(cortado)';

  static void _ringAdd(String nivel, String modulo, String mensaje,
      {String? detalle, Map<String, dynamic>? ctxSanitizado}) {
    // BT-01 (Argón 121B): una tormenta del mismo error no debe
    // expulsar del ring las migas de UI que la precedieron: si
    // el último elemento es el mismo módulo+evento+nivel, solo
    // se cuenta la repetición sobre ese mismo elemento.
    if (_ring.isNotEmpty) {
      final ult = _ring.last;
      if (ult['modulo'] == modulo &&
          ult['mensaje'] == mensaje &&
          ult['nivel'] == nivel) {
        ult['ts'] = DateTime.now().toIso8601String();
        ult['repetido'] = ((ult['repetido'] as int?) ?? 1) + 1;
        return;
      }
    }
    // BT-01: las migas viven en RAM y se copian a cada error
    // alto; detalle y contexto entran ya cortados a 200
    // caracteres (una miga no necesita más).
    final ctxCorto = ctxSanitizado == null
        ? null
        : ctxSanitizado.map((k, v) =>
            MapEntry(k, v is String ? _cortar(v, 200) : v));
    _ring.add({
      'ts': DateTime.now().toIso8601String(),
      'nivel': nivel,
      'modulo': modulo,
      'mensaje': _sanitizarTexto(mensaje),
      if (detalle != null) 'detalle': _cortar(detalle, 200),
      if (ctxCorto != null && ctxCorto.isNotEmpty)
        'contexto': ctxCorto,
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
    // 1.21 (Argón 121B): topes de peso por fila — detalle a
    // 2000 caracteres y valores de contexto a 1000; sin ellos,
    // 5000 filas de tormenta pesaban ~15 MB al exportar.
    final detSan = detalle != null
        ? _cortar(_sanitizarTexto(detalle), 2000)
        : null;
    final ctxLimpio = contexto != null
        ? _sanitizar(contexto).map((k, v) =>
            MapEntry(k, v is String ? _cortar(v, 1000) : v))
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
      // BT-01 (Argón 121B): solo las ÚLTIMAS 10 migas (antes se
      // copiaba el ring entero de 50 en cada error y la fila se
      // disparaba a decenas de KB).
      final skip = _ring.length > 10 ? _ring.length - 10 : 0;
      ctxDb['breadcrumbs'] = _ring.sublist(skip);
    } else if (nivel == 'aviso' && modulo != 'perf') {
      final skip = _ring.length > 5 ? _ring.length - 5 : 0;
      ctxDb['breadcrumbs'] = _ring.sublist(skip);
    }

    // Stack recortado a 15 líneas.
    var stackRecortado = stack
        ?.toString()
        .split('\n')
        .take(15)
        .join('\n');
    // Argón 121B: tope defensivo de 4 KB tras el recorte por
    // líneas (una línea minificada gigante no debe romper la
    // cota de peso por fila).
    if (stackRecortado != null) {
      stackRecortado = _cortar(stackRecortado, 4096);
    }

    final ts = DateTime.now().toIso8601String();
    return {
      'ts': ts,
      'modulo': modulo,
      'evento': evento,
      'detalle': detSan,
      'nivel': nivel,
      'contexto':
          ctxDb.isNotEmpty ? jsonEncode(ctxDb) : null,
      'op_id': opId,
      'stack': stackRecortado,
      // 1.21 (Argón 121B): agrupación de tormentas — la firma
      // solo se calcula en niveles altos; repeticiones y
      // primer_ts alimentan el UPDATE de _flush y la exportación.
      'firma': _firmaDe(nivel, modulo, evento, detSan),
      'repeticiones': 1,
      'primer_ts': ts,
    };
  }

  /// Firma de tormenta: módulo + evento + detalle normalizado
  /// (los dígitos son la parte variable típica: errno, ids,
  /// conteos). Solo niveles altos; el resto no se agrupa.
  static String? _firmaDe(String nivel, String modulo,
      String evento, String? detalle) {
    if (!_esNivelAlto(nivel)) return null;
    final base =
        (detalle ?? '').replaceAll(RegExp(r'\d+'), '#');
    return '$modulo|$evento|'
        '${base.length <= 120 ? base : base.substring(0, 120)}';
  }

  /// ¿[tsNuevo] cae dentro de la ventana de tormenta (10 min)
  /// posterior a [tsFila]?
  static bool _dentroDeVentana(String tsFila, String tsNuevo) {
    final a = DateTime.tryParse(tsFila);
    final b = DateTime.tryParse(tsNuevo);
    if (a == null || b == null) return false;
    return !b.isBefore(a) &&
        b.difference(a) < const Duration(minutes: 10);
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
    // BT-02 (Argón 121B) etapa 1 — colapso en RAM: si el buffer
    // ya trae un evento con la misma firma dentro de la ventana
    // de tormenta, se suman las repeticiones en ESA fila (su ts
    // pasa a ser el de la última repetición y primer_ts conserva
    // el primero) en vez de encolar otra fila idéntica.
    final firma = log['firma'] as String?;
    if (firma != null) {
      for (final item in _buffer) {
        if (item['firma'] == firma &&
            _dentroDeVentana('${item['ts']}', '${log['ts']}')) {
          item['repeticiones'] =
              ((item['repeticiones'] as int?) ?? 1) +
                  ((log['repeticiones'] as int?) ?? 1);
          item['ts'] = log['ts'];
          if (inmediato) unawaited(_flush());
          return;
        }
      }
    }
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
      // BT-02 (Argón 121B) etapa 2: el batch ciego no podía
      // decidir INSERT vs UPDATE; ahora una transacción: si ya
      // hay fila con la misma firma dentro de la ventana, la
      // tormenta se absorbe como repeticiones (conservando el
      // detalle y el contexto de la PRIMERA ocurrencia).
      await db.transaction((txn) async {
        for (final item in lote) {
          final firma = item['firma'] as String?;
          var absorbido = false;
          if (firma != null) {
            final prev = await txn.query('app_log',
                columns: ['id', 'ts'],
                where: 'firma = ?',
                whereArgs: [firma],
                orderBy: 'id DESC',
                limit: 1);
            if (prev.isNotEmpty &&
                _dentroDeVentana(
                    '${prev.first['ts']}', '${item['ts']}')) {
              await txn.rawUpdate(
                  'UPDATE app_log SET repeticiones = '
                  'repeticiones + ?, ts = ? WHERE id = ?',
                  [
                    (item['repeticiones'] as int?) ?? 1,
                    item['ts'],
                    prev.first['id'],
                  ]);
              absorbido = true;
            }
          }
          if (!absorbido) await txn.insert('app_log', item);
        }
      });
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
        'stack': stack == null
            ? null
            : _cortar(
                stack.toString().split('\n').take(25).join('\n'),
                4096),
        // 1.21: últimas 10 migas, como en _crear (BT-01).
        'breadcrumbs': _ring.sublist(
            _ring.length > 10 ? _ring.length - 10 : 0),
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
      // 1.21 (Argón 121B BT-04): poda por PESO. Las cuotas por
      // filas no acotan los bytes (5000 filas pesaron ~15 MB).
      // El peso se mide sumando las longitudes de las columnas
      // de app_log — nunca el archivo de la BD, que contiene
      // todas las tablas del gimnasio. Se sacrifican primero
      // las filas ligeras más viejas (debug/info/aviso).
      var peso = await _pesoTabla(b);
      var guard = 0;
      while (peso > 6 * 1024 * 1024 && guard++ < 20) {
        final n = await b.delete('app_log',
            where: 'id IN (SELECT id FROM app_log '
                "WHERE nivel IN ('debug','info','aviso') "
                'ORDER BY id ASC LIMIT 500)');
        if (n == 0) break;
        peso = await _pesoTabla(b);
      }
    } catch (_) {}
  }

  /// Peso estimado en bytes de la tabla app_log (BT-04).
  /// OJO: el SQL va en comillas dobles de Dart a propósito — con
  /// comillas simples, el '' de SQL se come como fin de cadena
  /// y el COALESCE queda roto (bug cazado en test, 1.21).
  static Future<int> _pesoTabla(Database b) async {
    final r = await b.rawQuery(
        "SELECT COALESCE(SUM(LENGTH(COALESCE(detalle,'')) + "
        "LENGTH(COALESCE(contexto,'')) + "
        "LENGTH(COALESCE(stack,'')) + 100), 0) AS p FROM app_log");
    return (r.first['p'] as num?)?.toInt() ?? 0;
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

  // === 1.21 (Argón 121B): delta, reinicio y marca ===

  static const String _kMarcaDelta = 'bitacora_ultimo_id_exportado';

  /// Último id de bitácora cuya exportación el usuario confirmó.
  static Future<int> _marcaDelta() async {
    final v = await LocalDb.instance.getMeta(_kMarcaDelta);
    return int.tryParse(v ?? '') ?? 0;
  }

  /// Avanza la marca del delta hasta [maxId]. La llaman los
  /// flujos de UI SOLO tras un compartido exitoso (o el botón
  /// «Exportar y reiniciar», cuya intención ya es explícita):
  /// exportar() nunca la mueve por su cuenta, porque si el
  /// usuario cancela al compartir, el delta siguiente saldría
  /// vacío y perdería esos registros (Argón 121B, pregunta 3).
  static Future<void> confirmarMarcaExportada(int maxId) async {
    final actual = await _marcaDelta();
    if (maxId > actual) {
      await LocalDb.instance.setMeta(_kMarcaDelta, '$maxId');
    }
  }

  /// Reinicia la bitácora (pedido de Jc): la tabla queda vacía
  /// con una única fila semilla que conserva el resumen de lo
  /// borrado (conteos por nivel y rango de fechas), como
  /// trazabilidad forense. Devuelve ese resumen.
  ///
  /// BT-03 (Argón 121B): antes de borrar hay que aquietar todo
  /// lo que pueda volcar logs viejos encima de la tabla recién
  /// vaciada: se cancela el temporizador, se espera a que un
  /// flush en curso termine (su lote caerá ANTES del DELETE y
  /// también se borra) y se vacían buffer, ring y —con el
  /// buffer— las firmas de tormenta en RAM.
  static Future<Map<String, dynamic>> reiniciar() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    for (var i = 0; i < 40 && _flushing; i++) {
      await Future<void>.delayed(
          const Duration(milliseconds: 50));
    }
    _buffer.clear();
    _ring.clear();
    final db = await LocalDb.instance.db;
    final resumen = await db.rawQuery(
        'SELECT nivel, COUNT(*) AS c, MIN(ts) AS mn, '
        'MAX(ts) AS mx FROM app_log GROUP BY nivel');
    var total = 0;
    final porNivel = <String, dynamic>{};
    String? desde;
    String? hasta;
    for (final r in resumen) {
      total += (r['c'] as num).toInt();
      porNivel['${r['nivel']}'] = (r['c'] as num).toInt();
      final mn = '${r['mn']}';
      final mx = '${r['mx']}';
      if (desde == null || mn.compareTo(desde) < 0) desde = mn;
      if (hasta == null || mx.compareTo(hasta) > 0) hasta = mx;
    }
    await db.delete('app_log');
    final ahora = DateTime.now().toIso8601String();
    await db.insert('app_log', {
      'ts': ahora,
      'modulo': 'app',
      'evento': 'bitacora.reiniciada',
      'detalle': 'Bitácora reiniciada manualmente.',
      'nivel': 'info',
      'contexto': jsonEncode({
        'borrados_total': total,
        'por_nivel': porNivel,
        'desde': desde,
        'hasta': hasta,
      }),
      'op_id': null,
      'stack': null,
      'firma': null,
      'repeticiones': 1,
      'primer_ts': ahora,
    });
    return {
      'total': total,
      'por_nivel': porNivel,
      'desde': desde,
      'hasta': hasta,
    };
  }

  /// Exporta la bitácora en Markdown y devuelve (ruta, maxId).
  ///
  /// Con [soloNovedades], solo las filas posteriores a la marca
  /// confirmada (ver confirmarMarcaExportada); la marca NO se
  /// mueve aquí. El encabezado lleva versión de la app, tipo de
  /// exportación, rango de fechas cubierto y registros por
  /// nivel: lo que antes había que deducir a mano del archivo.
  static Future<(String, int?)> exportar(
      {bool soloNovedades = false, String versionApp = ''}) async {
    await _flush(); // vaciar buffer antes
    final db = await LocalDb.instance.db;
    await podar(db);
    final desdeId = soloNovedades ? await _marcaDelta() : 0;
    final filas = await db.query('app_log',
        where: soloNovedades ? 'id > ?' : null,
        whereArgs: soloNovedades ? [desdeId] : null,
        orderBy: 'id ASC',
        limit: 5000);
    final maxId =
        filas.isEmpty ? null : (filas.last['id'] as num).toInt();
    var quedanMas = false;
    if (filas.length == 5000 && maxId != null) {
      final extra = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM app_log WHERE id > ?',
          [maxId]);
      quedanMas = ((extra.first['c'] as num?)?.toInt() ?? 0) > 0;
    }

    // Resumen 24h (se mantiene el de siempre).
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
    // Conteos por nivel de TODO lo exportado (encabezado 1.21).
    final porNivel = <String, int>{};
    for (final f in filas) {
      porNivel.update('${f['nivel']}', (v) => v + 1,
          ifAbsent: () => 1);
    }

    final sb = StringBuffer();
    sb.writeln('# Bitácora IronBody Gym');
    sb.writeln('');
    sb.writeln(
        'Exportado: ${DateTime.now().toIso8601String()}');
    if (versionApp.isNotEmpty) {
      sb.writeln('Versión de la app: $versionApp');
    }
    sb.writeln(soloNovedades
        ? 'Tipo: novedades (desde el id $desdeId)'
        : 'Tipo: completa');
    if (filas.isNotEmpty) {
      sb.writeln(
          'Rango: ${filas.first['ts']} — ${filas.last['ts']}');
    }
    sb.writeln('Registros: ${filas.length}');
    if (porNivel.isNotEmpty) {
      sb.writeln(
          'Por nivel: ${porNivel.entries.map((e) => '${e.key} ${e.value}').join(' · ')}');
    }
    if (quedanMas) {
      sb.writeln(
          'OJO: quedan registros sin exportar tras este corte de 5000.');
    }
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
      final reps = (f['repeticiones'] as num?)?.toInt() ?? 1;
      if (reps > 1) {
        sb.writeln(
            '  Repetido ×$reps (primero: ${f['primer_ts']}, último: ${f['ts']})');
      }
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
    return (path, maxId);
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
