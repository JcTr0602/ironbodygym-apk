/// Copia de seguridad H5 (1.14, M6.30): copia en frío de la BD.
/// Vuelca el WAL a la BD antes de copiar, para que el archivo no
/// salga incompleto ni corrupto. NUNCA VACUUM sobre la BD activa.
/// Solo se copia ironbody.db: las fotos viven fuera de la BD y el
/// directorio destino nace vacío, así que la copia no las arrastra.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'localdb.dart';

/// Copia la BD a un directorio temporal nuevo y devuelve el
/// archivo copiado (la pantalla lo comparte y audita).
Future<File> exportarCopiaFria() async {
  // 1.24 Bloque 5 (F5): el mismo rigor que el export de Ajustes
  // y que la importación — candado de sync tomado durante el
  // checkpoint y la copia (ningún ciclo hace checkpoint a
  // media copia) y volcado exigido COMPLETO (busy == 0 Y
  // log == checkpointed; antes aquí solo se pedía busy == 0).
  String? candado;
  for (var i = 0; i < 25 && candado == null; i++) {
    candado = await LocalDb.instance.adquirirSyncLock();
    if (candado == null) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
  }
  if (candado == null) {
    throw StateError('Hay una sincronización en curso; '
        'espera a que termine y reintenta');
  }
  try {
    final d = await LocalDb.instance.db;
    // Panel 1.14 (Luna + Kimi): si el WAL no se puede volcar (otra
    // conexión leyendo), NO se comparte una copia sin los últimos
    // commits. El pragma puede devolver busy == 1 o lanzar por
    // bloqueo según la plataforma; ambos casos se normalizan a
    // StateError (la pantalla ya muestra el error si se lanza).
    try {
      final res = await d.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      if (res.isEmpty) {
        throw StateError('No se pudo volcar el WAL; reintenta');
      }
      final fila = res.first;
      final busy = (fila['busy'] as num?)?.toInt() ?? 1;
      final log = (fila['log'] as num?)?.toInt() ?? -1;
      final checkpointed = (fila['checkpointed'] as num?)?.toInt() ?? -2;
      if (busy != 0 || log != checkpointed) {
        throw StateError(
            'No se pudo volcar el WAL (checkpoint ocupado); reintenta');
      }
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('No se pudo volcar el WAL ($e); reintenta');
    }
    // La ruta sale de LocalDb.dbPath() (única fuente): antes se
    // reconstruía a mano como getDatabasesPath() + 'ironbody.db',
    // lo que en los tests paralelos (P1) apuntaba a otro archivo.
    final origen = File(await LocalDb.instance.dbPath());
    final tmp = await Directory.systemTemp.createTemp('ironbody_backup');
    final destino = File(p.join(tmp.path, 'ironbody_backup.db'));
    await origen.copy(destino.path);
    return destino;
  } finally {
    try {
      await LocalDb.instance.liberarSyncLock(candado);
    } catch (_) {}
  }
}
