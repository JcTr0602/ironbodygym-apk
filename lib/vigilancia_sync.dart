/// Vigilancia proactiva de la sincronización (1.32,
/// O2F2S, M4 del diseño de detalle de sync, según la
/// adjudicación). Se construye SOBRE cargarSaludSync()/
/// semaforoTabla (salud_sync.dart) y sobre el diario de
/// corridas (M1): no duplica lógica de semáforos ni de
/// watermarks, solo REGLAS de aviso sobre esas fotos.
///
/// M4 solo detecta y propone acciones que YA existen
/// (Sincronizar ahora, Bajada completa, Salud, Cola): no
/// repara nada por su cuenta.
library;

import 'diario_sync.dart';
import 'localdb.dart';
import 'salud_sync.dart';
import 'sync.dart';
import 'tiempo.dart';

enum SeveridadAvisoSync { alta, media, info }

/// Un aviso de la vigilancia. [destino] nombra la acción
/// existente que lo atiende ('bajada', 'salud', 'cola',
/// 'reloj'); null = solo informativo.
class AvisoSync {
  final String regla;
  final SeveridadAvisoSync severidad;
  final String titulo;
  final String detalle;
  final String? tabla;
  final String? destino;

  const AvisoSync({
    required this.regla,
    required this.severidad,
    required this.titulo,
    required this.detalle,
    this.tabla,
    this.destino,
  });
}

/// A3 (PURA): tablas que salen 'fallida' en sus últimas 3
/// apariciones en el diario. [apariciones] va de más
/// reciente a más antigua; cada entrada es (tabla, fallida)
/// de UNA corrida que contiene a esa tabla.
Set<String> tablasFallidasTresCorridas(
    List<({String tabla, bool fallida})> apariciones) {
  final porTabla = <String, List<bool>>{};
  for (final a in apariciones) {
    porTabla.putIfAbsent(a.tabla, () => []).add(a.fallida);
  }
  final r = <String>{};
  porTabla.forEach((tabla, fallos) {
    if (fallos.length >= 3 &&
        fallos[0] &&
        fallos[1] &&
        fallos[2]) {
      r.add(tabla);
    }
  });
  return r;
}

/// A2 rama diario (PURA): tablas 'fallida' en 2 o más
/// corridas recientes del diario.
Set<String> tablasFallidasDosCorridas(
    List<({String tabla, bool fallida})> apariciones) {
  final conteo = <String, int>{};
  for (final a in apariciones) {
    if (a.fallida) conteo[a.tabla] = (conteo[a.tabla] ?? 0) + 1;
  }
  return {
    for (final e in conteo.entries)
      if (e.value >= 2) e.key,
  };
}

/// A1 (PURA): la primera bajada (corrida de instalación)
/// quedó cortada/parcial y NINGUNA corrida posterior la
/// completó. [corridas] de más reciente a más antigua.
bool primeraBajadaIncompleta(List<CorridaSync> corridas) {
  for (var i = 0; i < corridas.length; i++) {
    final c = corridas[i];
    if (c.origen != OrigenCorrida.instalacion) continue;
    if (c.estado != EstadoCorrida.cortada &&
        c.estado != EstadoCorrida.parcial) {
      return false;
    }
    // ¿Alguna corrida POSTERIOR (índice menor) completó?
    final huboCompletaDespues = corridas
        .take(i)
        .any((x) => x.estado == EstadoCorrida.completa);
    return !huboCompletaDespues;
  }
  return false;
}

/// Evalúa todas las reglas M4 y devuelve los avisos
/// activos, ordenados por severidad (alta → media → info).
/// Nunca lanza: un fallo de lectura degrada a menos avisos,
/// jamás a avisos inventados.
Future<List<AvisoSync>> evaluarVigilanciaSync() async {
  final avisos = <AvisoSync>[];
  final db = LocalDb.instance;
  final ahora = ahoraHabana();

  SaludSyncDatos? salud;
  try {
    salud = await cargarSaludSync();
  } catch (_) {}
  List<CorridaSync> corridas = const [];
  try {
    corridas = await DiarioSync.instance.historial(limite: 30);
  } catch (_) {}

  // --- A1: primera bajada incompleta (suprime A2/A3). ---
  final a1 = primeraBajadaIncompleta(corridas);
  if (a1) {
    avisos.add(const AvisoSync(
      regla: 'A1',
      severidad: SeveridadAvisoSync.alta,
      titulo: 'La primera bajada de datos quedó incompleta',
      detalle: 'Este teléfono se instaló y su primera '
          'descarga no terminó; pueden faltar datos. Una '
          'bajada completa lo deja entero.',
      destino: 'bajada',
    ));
  }

  // Apariciones por tabla en el diario (reciente → antigua),
  // para A2-diario y A3: hasta 10 corridas con foto.
  final apariciones = <({String tabla, bool fallida})>[];
  if (!a1) {
    try {
      var revisadas = 0;
      for (final c in corridas) {
        if (c.estado == EstadoCorrida.enCurso) continue;
        if (revisadas >= 10) break;
        final tablas = await DiarioSync.instance.tablasDe(c.id);
        if (tablas.isEmpty) continue;
        revisadas++;
        for (final t in tablas) {
          apariciones.add((
            tabla: t.tabla,
            fallida: t.estado == EstadoTablaDiario.fallida,
          ));
        }
      }
    } catch (_) {}
  }
  final fallidas3 = tablasFallidasTresCorridas(apariciones);
  final fallidas2 = tablasFallidasDosCorridas(apariciones);

  final serverSeq =
      int.tryParse(await _metaSegura(db, 'server_seq') ?? '0') ?? 0;

  if (salud != null) {
    for (final t in salud.tablas) {
      final nombre = t.nombre;
      // --- A7: atasco sin verificar activo → inmediato. ---
      if (t.atascadaSinVerificar) {
        avisos.add(AvisoSync(
          regla: 'A7',
          severidad: SeveridadAvisoSync.alta,
          titulo: '$nombre quedó atascada al bajar',
          detalle: 'Una fila de $nombre no se pudo verificar '
              'en la última bajada y su cursor está topado. '
              'El detalle está en Salud de la sincronización.',
          tabla: t.tablaLocal,
          destino: 'salud',
        ));
        continue;
      }
      if (!a1) {
        // --- A3: la misma tabla falla 3 corridas seguidas. ---
        if (fallidas3.contains(t.tablaLocal)) {
          avisos.add(AvisoSync(
            regla: 'A3',
            severidad: SeveridadAvisoSync.alta,
            titulo: '$nombre falla en las últimas 3 bajadas',
            detalle: 'No es un corte pasajero: la tabla '
                'viene fallando de forma repetida. El error '
                'concreto está en Salud de la sincronización.',
            tabla: t.tablaLocal,
            destino: 'salud',
          ));
          continue;
        }
        // --- A2: doble rama. ---
        var a2 = false;
        // Rama diario: error vigente + fallida en ≥2 corridas.
        if (t.errorBajada.isNotEmpty &&
            fallidas2.contains(t.tablaLocal)) {
          a2 = true;
        }
        // Rama atraso: sin sync OK de la tabla en ≥24 h y el
        // servidor va ≥50 por delante de su watermark. Las
        // tablas de secuencia propia no se comparan contra
        // el seq global (YB-SYNC-06, misma regla que Salud).
        if (!a2 &&
            !SyncEngine.tablasConSecuenciaPropia
                .contains(t.tablaLocal) &&
            serverSeq - t.watermark >= 50) {
          final okTxt =
              await _metaSegura(db, 'last_remote_sync_ok_${t.tablaLocal}');
          final okEn = okTxt == null ? null : DateTime.tryParse(okTxt);
          if (okEn == null ||
              ahora.difference(okEn).inHours >= 24) {
            a2 = true;
          }
        }
        if (a2) {
          avisos.add(AvisoSync(
            regla: 'A2',
            severidad: SeveridadAvisoSync.media,
            titulo: '$nombre lleva tiempo sin bajar bien',
            detalle: 'Su última bajada buena es vieja o su '
                'error se repite en el diario. Sincronizar '
                'ahora lo reintenta; el detalle está en Salud.',
            tabla: t.tablaLocal,
            destino: 'salud',
          ));
        }
      }
    }
    // --- A4: manifiesto divergente o espejo corrupto. ---
    var corruptasTotal = 0;
    for (final t in salud.tablas) {
      corruptasTotal += t.corruptas;
    }
    if (salud.divergentes > 0 || corruptasTotal > 0) {
      final partesA4 = [
        if (salud.divergentes > 0)
          '${salud.divergentes} ${salud.divergentes == 1 ? 'tabla diverge' : 'tablas divergen'} según el manifiesto',
        if (corruptasTotal > 0)
          '$corruptasTotal ${corruptasTotal == 1 ? 'fila dañada' : 'filas dañadas'} en el espejo',
      ].join(' · ');
      avisos.add(AvisoSync(
        regla: 'A4',
        severidad: SeveridadAvisoSync.alta,
        titulo: 'El espejo no coincide con el servidor',
        detalle: '$partesA4. Las tablas afectadas se '
            're-descargan solas en el próximo ciclo.',
        destino: 'salud',
      ));
    }
    // --- A6: sin verificar del manifiesto = neutro. ---
    if (salud.sinVerificar.isNotEmpty) {
      avisos.add(AvisoSync(
        regla: 'A6',
        severidad: SeveridadAvisoSync.info,
        titulo: 'Comprobación parcial del manifiesto',
        detalle: 'No se pudieron verificar '
            '${salud.sinVerificar.length} '
            '${salud.sinVerificar.length == 1 ? 'tabla' : 'tablas'} '
            'en la última comprobación. No es un fallo: se '
            'reintenta en el próximo chequeo diario.',
      ));
    }
  }

  // --- A5: ops rechazadas >24 h sin resolver. ---
  try {
    final d = await db.db;
    final filas = await d.query('ops_queue',
        columns: ['creada_ts'],
        where: "estado IN ('rechazada', 'necesita_revision')");
    var viejas = 0;
    for (final f in filas) {
      final creada = DateTime.tryParse('${f['creada_ts'] ?? ''}');
      if (creada != null && ahora.difference(creada).inHours >= 24) {
        viejas++;
      }
    }
    if (viejas > 0) {
      avisos.add(AvisoSync(
        regla: 'A5',
        severidad: SeveridadAvisoSync.media,
        titulo: '$viejas ${viejas == 1 ? 'operación rechazada lleva' : 'operaciones rechazadas llevan'} más de un día sin resolverse',
        detalle: 'Están en la Cola, esperando decisión. '
            'Sin resolverlas, esos cambios no existen para '
            'el servidor.',
        destino: 'cola',
      ));
    }
  } catch (_) {}

  // --- A8: reloj del teléfono desfasado >15 min. ---
  try {
    // 1.36 (136-917): si la ÚLTIMA medición falló, la
    // vigilancia lo dice como «no se pudo medir» — un resto
    // distinguible de «sin avisos»: el '' de
    // reloj_desfasado_min ya no se lee como un reloj
    // comprobado sano cuando la comprobación ni corrió.
    final medicionFallo =
        await _metaSegura(db, 'reloj_medicion_fallo');
    if (medicionFallo == '1') {
      avisos.add(const AvisoSync(
        regla: 'A8',
        severidad: SeveridadAvisoSync.info,
        titulo: 'No se pudo comprobar el reloj del teléfono',
        detalle: 'La última comparación contra la hora del '
            'servidor falló (sin conexión o sin respuesta). '
            'No es que el reloj esté bien: es que no se '
            'pudo medir.',
        destino: 'reloj',
      ));
    }
    final desfaseTxt = await _metaSegura(db, 'reloj_desfasado_min');
    final desfase = int.tryParse(desfaseTxt ?? '') ?? 0;
    if (desfase > 15) {
      avisos.add(AvisoSync(
        regla: 'A8',
        severidad: SeveridadAvisoSync.media,
        titulo: 'El reloj del teléfono va desfasado $desfase min',
        detalle: 'Contra la hora del servidor. Un reloj mal '
            'puesto desordena pagos, turnos y vencimientos: '
            'ajústalo en los ajustes del teléfono.',
        destino: 'reloj',
      ));
    }
  } catch (_) {}

  int rango(SeveridadAvisoSync s) => switch (s) {
        SeveridadAvisoSync.alta => 0,
        SeveridadAvisoSync.media => 1,
        SeveridadAvisoSync.info => 2,
      };
  avisos.sort((a, b) => rango(a.severidad).compareTo(rango(b.severidad)));
  return avisos;
}

Future<String?> _metaSegura(LocalDb db, String clave) async {
  try {
    return await db.getMeta(clave);
  } catch (_) {
    return null;
  }
}
