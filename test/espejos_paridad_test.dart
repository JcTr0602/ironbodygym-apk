// Paridad de espejos del pull (auditoría 1.21, A-01).
//
// El bug: las 4 tablas de la 1.20 (suplemento_ajustes,
// nomina_liquidada_snapshot, nomina_confirmaciones,
// diferencias_caja) estaban en supTablas (el mapa nombre local ->
// tabla de Supabase) y con el watermark sembrado en 0, pero
// FALTABAN en tablasEspejo (la lista que el pull recorre): nunca
// se descargaban y F5/T22/T5 quedaban inertes. Los tests de cada
// función no lo cazaron porque siembran el espejo directo.
//
// Este test lee el código fuente (como version_guard_test lee el
// pubspec) y exige que las tres listas no vuelvan a divergir:
//  1. supTablas y tablasEspejo contienen EXACTAMENTE las mismas
//     tablas (una en el mapa pero no en la lista = nunca baja;
//     una en la lista pero no en el mapa = el pull no sabe cómo
//     pedirla).
//  2. Toda tabla de tablasEspejo está en tablasConWatermark
//     (su descarga se evalúa en el mínimo global) SALVO las
//     exenciones deliberadas de abajo.
//  3. Las 4 tablas de la 1.20 están además en la rama id TEXT +
//     data jsonb de _prepararFilaMirror (sin esa rama, el
//     conversor genérico de id entero descartaría cada fila).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tablas que bajan pero NO entran en el mínimo de watermarks:
/// las tres de bandeja usan secuencia PROPIA de Postgres
/// (triggers v2.2, su sync_seq no es el serverSeq global) y
/// cliente_mediciones quedó fuera del mínimo en su arreglo
/// H-05 (1.19). Si una tabla nueva no va en tablasConWatermark,
/// su exención se declara AQUÍ a propósito, no por olvido.
const exentasDeWatermark = {
  'gympedia_solicitudes',
  'permisos_bandeja',
  'espejo_gympedia_borradores',
  'cliente_mediciones',
};

const tablas120 = {
  'suplemento_ajustes',
  'nomina_liquidada_snapshot',
  'nomina_confirmaciones',
  'diferencias_caja',
};

Set<String> _entradas(String fuente, String inicio, String fin) {
  final i = fuente.indexOf(inicio);
  expect(i, isNonNegative, reason: 'no se encontró el bloque: $inicio');
  final j = fuente.indexOf(fin, i);
  expect(j, isNonNegative, reason: 'bloque sin cierre: $inicio');
  final bloque = fuente.substring(i, j);
  return RegExp(r"'([a-z_0-9]+)'")
      .allMatches(bloque)
      .map((m) => m.group(1)!)
      .toSet();
}

Set<String> _clavesMapa(String fuente, String inicio, String fin) {
  final i = fuente.indexOf(inicio);
  expect(i, isNonNegative, reason: 'no se encontró el bloque: $inicio');
  final j = fuente.indexOf(fin, i);
  expect(j, isNonNegative, reason: 'bloque sin cierre: $inicio');
  final bloque = fuente.substring(i, j);
  return RegExp(r"'([a-z_0-9]+)':")
      .allMatches(bloque)
      .map((m) => m.group(1)!)
      .toSet();
}

/// Lee y extrae las tres listas. Se invoca DENTRO de cada test:
/// un expect fuera del cuerpo de un test lanza
/// OutsideTestException al cargar el archivo.
({Set<String> tablasEspejo, Set<String> supTablas, Set<String> conWatermark})
    _sets() {
  final sync = File('lib/sync.dart').readAsStringSync();
  final localdb = File('lib/localdb.dart').readAsStringSync();
  return (
    tablasEspejo: _entradas(
        sync, 'static const List<String> tablasEspejo = [', '];'),
    supTablas: _clavesMapa(sync, 'const supTablas = {', '};'),
    conWatermark: _entradas(
        localdb, 'static const tablasConWatermark = [', '];'),
  );
}

void main() {
  test('supTablas y tablasEspejo contienen las mismas tablas', () {
    final (:tablasEspejo, :supTablas, conWatermark: _) = _sets();
    final soloEnMapa = supTablas.difference(tablasEspejo);
    final soloEnLista = tablasEspejo.difference(supTablas);
    expect(soloEnMapa, isEmpty,
        reason: 'en supTablas pero NO en tablasEspejo (nunca '
            'bajarían): $soloEnMapa');
    expect(soloEnLista, isEmpty,
        reason: 'en tablasEspejo pero NO en supTablas (el pull '
            'no sabría pedirlas): $soloEnLista');
  });

  test('toda tabla descargada tiene watermark o exención declarada',
      () {
    final (:tablasEspejo, supTablas: _, :conWatermark) = _sets();
    final sinCubrir =
        tablasEspejo.difference(conWatermark).difference(exentasDeWatermark);
    expect(sinCubrir, isEmpty,
        reason: 'tablas que bajan sin entrar en '
            'tablasConWatermark ni en las exenciones: $sinCubrir');
  });

  test('las 4 tablas de la 1.20 están en las tres listas y en la '
      'rama de id TEXT de _prepararFilaMirror', () {
    final (:tablasEspejo, :supTablas, :conWatermark) = _sets();
    final sync = File('lib/sync.dart').readAsStringSync();
    for (final t in tablas120) {
      expect(tablasEspejo, contains(t), reason: '$t fuera de tablasEspejo');
      expect(supTablas, contains(t), reason: '$t fuera de supTablas');
      expect(conWatermark, contains(t),
          reason: '$t fuera de tablasConWatermark');
    }
    // La rama jsonb de _prepararFilaMirror: del primer nombre de
    // la condición al cierre de su bloque van los nombres de las
    // tablas con forma id TEXT + data.
    final i = sync.indexOf("tabla == 'gympedia_articulos'");
    expect(i, isNonNegative, reason: 'rama jsonb no encontrada');
    final rama = sync.substring(i, i + 1600);
    for (final t in tablas120) {
      expect(rama, contains("tabla == '$t'"),
          reason: '$t fuera de la rama id TEXT + data de '
              '_prepararFilaMirror: caería al genérico de id '
              'entero y cada fila se descartaría');
    }
  });

  test('la tabla del candado (1.21) está en las tres listas y en '
      'la rama de id TEXT de _prepararFilaMirror', () {
    final (:tablasEspejo, :supTablas, :conWatermark) = _sets();
    final sync = File('lib/sync.dart').readAsStringSync();
    expect(tablasEspejo, contains('acceso_bloqueos'),
        reason: 'acceso_bloqueos fuera de tablasEspejo');
    expect(supTablas, contains('acceso_bloqueos'),
        reason: 'acceso_bloqueos fuera de supTablas');
    expect(conWatermark, contains('acceso_bloqueos'),
        reason: 'acceso_bloqueos fuera de tablasConWatermark');
    final i = sync.indexOf("tabla == 'gympedia_articulos'");
    expect(i, isNonNegative, reason: 'rama jsonb no encontrada');
    final cierre = sync.indexOf(') {', i);
    final rama = sync.substring(i, cierre);
    expect(rama, contains("tabla == 'acceso_bloqueos'"),
        reason: 'acceso_bloqueos fuera de la rama id TEXT + data '
            'de _prepararFilaMirror');
    // Y su watermark nace en 0 (no hereda el global).
    final localdb = File('lib/localdb.dart').readAsStringSync();
    expect(localdb, contains("if (tabla == 'acceso_bloqueos') return 0;"),
        reason: 'acceso_bloqueos sin caso return 0 en '
            'getWatermarkTabla: heredaría el watermark global y '
            'la descarga inicial se saltaría los bloqueos');
  });
}
