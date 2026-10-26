/// Copia de seguridad H5 (1.14, M6.30): copia en frío de la BD.
/// Vuelca el WAL a la BD antes de copiar, para que el archivo no
/// salga incompleto ni corrupto. NUNCA VACUUM sobre la BD activa.
/// Solo se copia ironbody.db: las fotos viven fuera de la BD y el
/// directorio destino nace vacío, así que la copia no las arrastra.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'localdb.dart';

/// Copia la BD a un directorio temporal nuevo y devuelve el
/// archivo copiado (la pantalla lo comparte y audita).
Future<File> exportarCopiaFria() async {
  final d = await LocalDb.instance.db;
  // Panel 1.14 (Luna + Kimi): si el WAL no se puede volcar (otra
  // conexión leyendo), NO se comparte una copia sin los últimos
  // commits. El pragma puede devolver busy == 1 o lanzar por
  // bloqueo según la plataforma; ambos casos se normalizan a
  // StateError (la pantalla ya muestra el error si se lanza).
  try {
    final res = await d.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    final busy =
        res.isNotEmpty ? (res.first['busy'] as num?)?.toInt() ?? 1 : 1;
    if (busy != 0) {
      throw StateError(
          'No se pudo volcar el WAL (checkpoint ocupado); reintenta');
    }
  } catch (e) {
    if (e is StateError) rethrow;
    throw StateError('No se pudo volcar el WAL ($e); reintenta');
  }
  final dir = await getDatabasesPath();
  final origen = File(p.join(dir, 'ironbody.db'));
  final tmp = await Directory.systemTemp.createTemp('ironbody_backup');
  final destino = File(p.join(tmp.path, 'ironbody_backup.db'));
  await origen.copy(destino.path);
  return destino;
}
