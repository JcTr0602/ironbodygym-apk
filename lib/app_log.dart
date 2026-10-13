import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'localdb.dart';

/// Bitácora local de la app (v1.2.9+46, pedido de Jc 2026-10-13).
/// Registra resultados de todas las lógicas y procesos para
/// diagnóstico forense. Exportable desde Ajustes.
///
/// Diseño certificado por Gemini con ajustes:
/// - Contador secuencial para poda (no millisecond % 50).
/// - Llamadas fire-and-forget desde la lógica de negocio (unawaited).
/// - debugPrint en modo debug si el insert falla.
class AppLog {
  AppLog._();

  static int _contador = 0;

  /// Registra un evento. No lanza: si falla, se ignora en silencio
  /// en release (debugPrint en debug). La bitácora nunca rompe la app.
  static Future<void> registrar(
    String modulo,
    String evento, {
    String? detalle,
    String nivel = 'info', // info | aviso | error
  }) async {
    try {
      final db = await LocalDb.instance.db;
      await db.insert('app_log', {
        'ts': DateTime.now().toIso8601String(),
        'modulo': modulo,
        'evento': evento,
        'detalle': detalle,
        'nivel': nivel,
      });
      _contador++;
      if (_contador >= 100) {
        _contador = 0;
        unawaited(podar(db));
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppLog Error]: $e');
      }
    }
  }

  static void info(String m, String e, {String? d}) =>
      unawaited(registrar(m, e, detalle: d, nivel: 'info'));
  static void aviso(String m, String e, {String? d}) =>
      unawaited(registrar(m, e, detalle: d, nivel: 'aviso'));
  static void error(String m, String e, {String? d}) =>
      unawaited(registrar(m, e, detalle: d, nivel: 'error'));

  /// Borra registros de más de 7 días. Idempotente.
  static Future<void> podar([Database? db]) async {
    try {
      final b = db ?? await LocalDb.instance.db;
      final corte = DateTime.now()
          .subtract(const Duration(days: 7))
          .toIso8601String();
      await b.delete('app_log', where: 'ts < ?', whereArgs: [corte]);
    } catch (_) {}
  }

  /// Exporta la bitácora a un archivo .txt en el directorio temporal.
  /// Retorna la ruta del archivo.
  /// v1.2.9+46 (Gemini): extraer en DESC y revertir — si hay más de 5000
  /// registros, el archivo debe contener los MÁS RECIENTES (los que
  /// explican un crash), no los más viejos.
  static Future<String> exportar() async {
    final db = await LocalDb.instance.db;
    await podar(db);
    final filas = (await db.query('app_log',
            orderBy: 'id DESC', limit: 5000))
        .reversed
        .toList();
    final sb = StringBuffer();
    sb.writeln('BITÁCORA IRONBODY GYM');
    sb.writeln('Exportado: ${DateTime.now().toIso8601String()}');
    sb.writeln('Registros: ${filas.length}');
    sb.writeln('=' * 60);
    for (final f in filas) {
      sb.writeln("[${f['ts']}] [${f['nivel']}] ${f['modulo']}.${f['evento']}");
      if (f['detalle'] != null) sb.writeln('  ${f['detalle']}');
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/bitacora-ironbody-${DateTime.now().millisecondsSinceEpoch}.txt';
    await File(path).writeAsString(sb.toString());
    return path;
  }
}
