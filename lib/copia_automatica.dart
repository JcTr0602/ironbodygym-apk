/// Copia de seguridad AUTOMÁTICA semanal (1.28, M1-B6).
///
/// El respaldo manual de Ajustes depende de que alguien se
/// acuerde de pulsar el botón. Esta copia corre sola: tras
/// una sincronización exitosa, si la última copia automática
/// tiene más de [diasEntreCopiasAuto] días (o nunca se hizo),
/// genera una copia en frío de la BD (la misma maquinaria
/// del respaldo manual, con candado y latido — M1-A12) y la
/// guarda en la carpeta de documentos, conservando las
/// últimas [copiasAutoConservar].
///
/// Reglas de seguridad: NUNCA lanza (un fallo de la copia no
/// puede romper el sync que la disparó); el fallo queda
/// registrado en la meta copia_auto_error y es visible en la
/// pantalla de Salud de la sincronización — sin avisos
/// ruidosos por una sola caída pasajera.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'auth.dart';
import 'copia_seguridad.dart';
import 'localdb.dart';
import 'tiempo.dart';

/// Días mínimos entre dos copias automáticas.
const int diasEntreCopiasAuto = 7;

/// Cuántas copias automáticas se conservan (rotación).
const int copiasAutoConservar = 4;

/// Meta con el ISO (Habana) de la última copia automática OK.
const String metaCopiaAutoUltima = 'copia_auto_ultima';

/// Meta con el último error de la copia automática ('' = sin
/// error vigente). La lee la pantalla de Salud.
const String metaCopiaAutoError = 'copia_auto_error';

/// ¿Toca hacer la copia automática? Función pura: toca si
/// nunca se hizo o si la última tiene ≥ [diasEntreCopiasAuto]
/// días.
bool copiaAutoToca({required DateTime? ultima, required DateTime ahora}) {
  if (ultima == null) return true;
  return ahora.difference(ultima) >=
      const Duration(days: diasEntreCopiasAuto);
}

/// Rotación: de los nombres de copia presentes (el nombre
/// lleva la fecha ISO ordenable: ironbody-auto-AAAAMMDD-HHMMSS.db),
/// cuáles hay que borrar para conservar solo las
/// [conservar] más recientes. Función pura.
List<String> copiasAutoParaBorrar(List<String> nombres,
    {int conservar = copiasAutoConservar}) {
  final ordenados = [...nombres]..sort();
  if (ordenados.length <= conservar) return const [];
  return ordenados.sublist(0, ordenados.length - conservar);
}

String _nombreCopia(DateTime ahora) {
  String d2(int n) => n.toString().padLeft(2, '0');
  return 'ironbody-auto-${ahora.year}${d2(ahora.month)}${d2(ahora.day)}'
      '-${d2(ahora.hour)}${d2(ahora.minute)}${d2(ahora.second)}.db';
}

/// Hace la copia automática si toca. Devuelve true si se
/// hizo una copia nueva. NUNCA lanza.
///
/// NO engancharla dentro del ciclo de sync: la copia en frío
/// toma el candado con reintentos (~15 s de espera si el
/// ciclo lo tiene), así que se llama DESDE el gancho
/// post-sync (main.dart, _trasSyncExitosa), donde el ciclo
/// ya soltó el candado.
Future<bool> copiaAutomaticaSiToca() async {
  final db = LocalDb.instance;
  try {
    // Yunque B (YB-TRA-03): la copia automática SOLO corre
    // en el teléfono del dueño. En el de un entrenador
    // generaba copias íntegras de la BD fuera de todo
    // control de rotación (y de necesidad: su respaldo es
    // el servidor, no su teléfono).
    var esDueno = false;
    try {
      esDueno = AuthService().isOwner;
    } catch (_) {}
    if (!esDueno) return false;
    final ultimaTxt = await db.getMeta(metaCopiaAutoUltima);
    final ultima = ultimaTxt == null ? null : DateTime.tryParse(ultimaTxt);
    final ahora = ahoraHabana();
    if (!copiaAutoToca(ultima: ultima, ahora: ahora)) return false;

    // Yunque B (YB-TRA-03): la copia en frío se escribe
    // DIRECTAMENTE en copias_auto — antes pasaba por
    // copias_manuales y la intermedia quedaba sin rotar
    // para siempre (+1 BD completa por semana y teléfono).
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'copias_auto'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final destino = File(p.join(dir.path, _nombreCopia(ahora)));
    await exportarCopiaFria(destinoDirecto: destino);

    // Rotación: conservar las últimas N.
    final nombres = <String>[
      await for (final e in dir.list())
        if (e is File && p.basename(e.path).startsWith('ironbody-auto-'))
          p.basename(e.path),
    ];
    for (final vieja in copiasAutoParaBorrar(nombres)) {
      try {
        await File(p.join(dir.path, vieja)).delete();
      } catch (_) {}
    }

    await db.setMeta(metaCopiaAutoUltima, isoHabana(ahora));
    await db.setMeta(metaCopiaAutoError, '');
    AppLog.info('copia', 'copia_automatica_ok',
        d: 'archivo=${p.basename(destino.path)}');
    return true;
  } catch (e) {
    // Fallo VISIBLE pero silencioso: queda en la meta (la
    // Salud lo muestra) y en bitácora; no se lanza jamás.
    try {
      final msg = '$e';
      await db.setMeta(metaCopiaAutoError,
          msg.length > 200 ? msg.substring(0, 200) : msg);
    } catch (_) {}
    AppLog.error('copia', 'copia_automatica_fallo', d: '$e');
    return false;
  }
}
