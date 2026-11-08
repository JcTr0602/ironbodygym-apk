/// Copia de seguridad H5 (1.14, M6.30): copia en frío de la BD.
/// Vuelca el WAL a la BD antes de copiar, para que el archivo no
/// salga incompleto ni corrupto. NUNCA VACUUM sobre la BD activa.
/// Solo se copia ironbody.db: las fotos viven fuera de la BD.
///
/// 1.29 (Oleada 6, D-B3-06): el destino es DURADERO — el
/// directorio de documentos del teléfono, subcarpeta
/// `copias_manuales`, con nombre fechado — y exportar NO
/// borra la copia anterior. Antes la copia iba al temporal
/// del sistema y cada exportación borraba el directorio
/// entero: la pantalla decía «Copia guardada en el
/// teléfono» y el sistema podía barrerla en cualquier
/// momento (y la siguiente exportación la destruía seguro).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'localdb.dart';
import 'tiempo.dart';

/// Nombre de una copia manual: con la fecha y hora (Habana)
/// en el propio nombre, para que dos exportaciones no se
/// pisen y el dueño las distinga en el explorador.
String nombreCopiaManual(DateTime ahora) {
  String d2(int n) => n.toString().padLeft(2, '0');
  return 'ironbody-${ahora.year}${d2(ahora.month)}${d2(ahora.day)}'
      '-${d2(ahora.hour)}${d2(ahora.minute)}${d2(ahora.second)}.db';
}

/// Copia la BD al directorio de documentos y devuelve el
/// archivo copiado (la pantalla lo comparte y audita; la
/// copia automática semanal lo re-copia a su carpeta con
/// su rotación propia).
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
    // 1.28 (M1-A12/R2M1-F10): la copia corre con el LATIDO
    // del lock (conLatidoSyncLock): antes el candado se tomaba
    // sin renovar y, si el volcado+copia superaban los 3 min
    // de expiración, otro isolate robaba el lock y un
    // checkpoint automático a media copia mezclaba páginas de
    // dos instantes. Si el lock se pierde, la copia se aborta.
    return await LocalDb.instance.conLatidoSyncLock(
        candado, () => _copiarConCandado());
  } finally {
    try {
      await LocalDb.instance.liberarSyncLock(candado);
    } catch (_) {}
  }
}

/// El volcado del WAL y la copia del archivo, ya con el
/// candado de sync tomado (ver [exportarCopiaFria]).
Future<File> _copiarConCandado() async {
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
    // 1.29 (Oleada 6, D-B3-06): destino DURADERO en el
    // directorio de documentos (el mismo hogar que la copia
    // automática semanal de la 1.28), subcarpeta propia
    // `copias_manuales` para que la rotación de las
    // automáticas no las toque. NO se borra nada: la
    // exportación anterior queda. Si dos exportaciones
    // caen en el mismo segundo, la segunda lleva sufijo
    // en vez de pisar a la primera.
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'copias_manuales'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final base = nombreCopiaManual(ahoraHabana());
    var destino = File(p.join(dir.path, base));
    var n = 2;
    while (await destino.exists()) {
      destino = File(p.join(
          dir.path, base.replaceFirst('.db', '-$n.db')));
      n++;
    }
    await origen.copy(destino.path);
    return destino;
}
