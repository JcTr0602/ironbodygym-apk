/// Bandeja de solicitudes GymPedia (1.19, v49).
///
/// La bandeja la ve el dueño siempre, y cada entrenador solo si Jc le
/// otorgó el permiso (fila en el espejo `permisos_bandeja`, revocable).
/// Alcance del permiso (decisión de Jc 2026-10-30): ver + descartar +
/// borradores; publicar sigue siendo solo dueño.
///
/// Lecturas: espejos locales v49 (`gympedia_solicitudes`,
/// `permisos_bandeja`, `espejo_gympedia_borradores`) + ops pendientes
/// en cola (fusión optimista, mismo patrón que los bonos de nómina).
/// Escrituras: solo ops (`gympedia_solicitud_descartar`,
/// `permiso_bandeja`, `gympedia_borrador_upsert`); publicar viaja
/// dentro de `gympedia_upsert_publicado` con `solicitud_id` (el
/// servidor cierra la solicitud DESPUÉS de persistir el artículo;
/// ante conflicto la op se completa con aviso y NUNCA revierte).
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'localdb.dart';

/// Tipos de op de la bandeja (CHECK sync_ops, v2.2).
const kTipoOpDescartarSolicitud = 'gympedia_solicitud_descartar';
const kTipoOpPermisoBandeja = 'permiso_bandeja';
const kTipoOpBorradorUpsert = 'gympedia_borrador_upsert';

/// Publicar un artículo (no es op de bandeja, pero su overlay SÍ
/// afecta a la bandeja: lleva `solicitud_id` en la raíz del payload
/// cuando se publica desde una solicitud).
const kTipoOpPublicar = 'gympedia_upsert_publicado';

/// Estados de `estado_bandeja` en el espejo de solicitudes.
/// El puente escribe `resultado` o 'pendiente' (nunca null).
const kBandejaPendiente = 'pendiente';
const kBandejaPublicada = 'publicada';
const kBandejaDescartada = 'descartada';

/// Slug desde un título: mismo algoritmo que el editor de GymPedia
/// (minúsculas, sin acentos, separadores a '-', máx. 80).
String slugBandeja(String titulo) {
  var s = titulo.toLowerCase().trim();
  const con = 'áéíóúüñ';
  const sin = 'aeiouun';
  for (var i = 0; i < con.length; i++) {
    s = s.replaceAll(con[i], sin[i]);
  }
  s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  s = s.replaceAll(RegExp(r'^-+|-+$'), '');
  return s.length > 80 ? s.substring(0, 80) : s;
}

/// Filtra solicitudes por estado (función pura, testeable).
List<Map<String, dynamic>> solicitudesPorEstado(
    List<Map<String, dynamic>> todas, String estado) {
  return [
    for (final s in todas)
      if ('${s['estado_bandeja'] ?? kBandejaPendiente}' == estado) s
  ];
}

/// Fusión de borradores compartidos: espejo + ops pendientes.
///
/// - Las tumbas del espejo (eliminado=true) SE CONSERVAN durante la
///   fusión: el servidor fusiona sobre la tumba y conserva texto,
///   autor y demás claves; una op pendiente con eliminado=false la
///   revive con ese contenido, no con una base vacía.
/// - Una op pendiente `gympedia_borrador_upsert` con eliminado=true
///   oculta el borrador; sin eliminado, fusiona sus claves sobre el
///   espejo (misma semántica de merge del servidor: lo que el
///   payload no pisa, se conserva) o lo crea si aún no bajó.
/// - Las filas de ops pendientes llevan `'pendiente': true` para que
///   la UI las marque «Por subir», y su autor optimista es el
///   telegram_id firmante de la op (el servidor conserva el autor
///   original cuando edita el dueño; para un borrador nuevo, el
///   firmante ES el autor).
/// - Al final se filtran las tumbas; orden: más recientemente
///   actualizado primero (una op pendiente usa su creada_ts como
///   fecha optimista).
List<Map<String, dynamic>> fusionarBorradoresBandeja({
  required List<Map<String, dynamic>> espejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  final porSlug = <String, Map<String, dynamic>>{};
  for (final e in espejo) {
    final slug = '${e['id'] ?? ''}';
    if (slug.isEmpty) continue;
    porSlug[slug] = Map<String, dynamic>.from(e);
  }
  for (final op in opsPendientes) {
    if (op['tipo'] != kTipoOpBorradorUpsert) continue;
    Map<String, dynamic> p;
    try {
      p = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final slug = '${p['slug'] ?? ''}';
    if (slug.isEmpty) continue;
    if (p['eliminado'] == true) {
      final base = porSlug[slug] ?? {'id': slug, 'slug': slug};
      porSlug[slug] = {
        ...base,
        'id': slug,
        'slug': slug,
        'eliminado': true,
        'pendiente': true,
      };
      continue;
    }
    final data = p['data'] is Map<String, dynamic>
        ? p['data'] as Map<String, dynamic>
        : <String, dynamic>{};
    final esNuevo = !porSlug.containsKey(slug);
    final base = porSlug[slug] ?? {'id': slug, 'slug': slug};
    final fusion = {
      ...base,
      ...data,
      'id': slug,
      'slug': slug,
      'eliminado': false,
      'pendiente': true,
    };
    if (esNuevo && op['telegram_id'] != null) {
      fusion['autor_telegram_id'] = op['telegram_id'];
    }
    if (op['creada_ts'] != null) {
      fusion['actualizado_en'] = op['creada_ts'];
    }
    porSlug[slug] = fusion;
  }
  final lista = [
    for (final b in porSlug.values)
      if (b['eliminado'] != 1 && b['eliminado'] != true) b
  ];
  lista.sort((a, b) =>
      '${b['actualizado_en'] ?? ''}'.compareTo('${a['actualizado_en'] ?? ''}'));
  return lista;
}

/// Acceso a la bandeja, función pura (testeable).
///
/// El dueño siempre; si no, la fila del espejo da el acceso inicial
/// y las ops pendientes se aplican DESPUÉS en orden de cola: la
/// última acción manda (una revocación pendiente sobre un permiso
/// del espejo CIERRA el acceso, y un otorgar posterior lo reabre).
bool accesoBandeja({
  required bool esDueno,
  required int? tid,
  required List<Map<String, dynamic>> permisosEspejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  if (esDueno) return true;
  if (tid == null) return false;
  var otorgado = permisosEspejo.any((p) =>
      '${p['telegram_id'] ?? p['id'] ?? ''}' == '$tid');
  for (final op in opsPendientes) {
    if (op['tipo'] != kTipoOpPermisoBandeja) continue;
    Map<String, dynamic> p;
    try {
      p = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if ('${p['telegram_id'] ?? ''}' != '$tid') continue;
    final accion = '${p['accion'] ?? ''}'.toLowerCase();
    if (accion == 'otorgar') {
      otorgado = true;
    } else if (accion == 'revocar') {
      otorgado = false;
    }
  }
  return otorgado;
}

/// ¿El usuario actual puede abrir la bandeja? Carga espejo + ops y
/// delega en [accesoBandeja] (sin retorno anticipado por espejo).
Future<bool> tieneAccesoBandeja() async {
  final auth = AuthService();
  if (auth.isOwner) return true;
  final tid = auth.telegramId;
  if (tid == null) return false;
  final db = LocalDb.instance;
  final permisos = await db.allMirror('permisos_bandeja');
  final ops = await db.pendingOps();
  return accesoBandeja(
    esDueno: false,
    tid: tid,
    permisosEspejo: permisos,
    opsPendientes: ops,
  );
}

/// Solicitudes tras aplicar los descartes pendientes (función pura).
/// Una solicitud con descarte en cola ya no es pendiente para el
/// usuario: se oculta hasta que el espejo la traiga como descartada
/// (el diálogo ya avisó «Se descartará al sincronizar»).
/// Overlay de ops pendientes sobre el espejo de solicitudes
/// (función pura, testeable).
///
/// - Una op `gympedia_solicitud_descartar` pendiente OCULTA la
///   solicitud (el descarte ya se decidió, aunque aún no suba).
/// - Una op `gympedia_upsert_publicado` pendiente con
///   `solicitud_id` NO la oculta: la mueve optimísticamente a
///   estado `publicada` con `'pendiente': true` («Por subir»).
///   Así el badge de Home deja de contarla, la tarjeta ya no
///   ofrece Descartar/Escribir, y la solicitud aparece en la
///   pestaña Publicadas hasta que el servidor la confirme.
///   Sin esto, publicar offline y volver a la bandeja dejaba la
///   solicitud en Pendientes con acciones duplicadas (Argón
///   Gmail-15 #2).
/// - Una op `gympedia_borrador_upsert` pendiente NO cambia el
///   estado: redactar un borrador no es publicar. La UI marca
///   «Con borrador» en la tarjeta (Q7.2 de Argón).
/// - Descarte y publicación pendientes a la vez: manda el
///   descarte (la solicitud sale de pendientes de todos modos).
/// - Las filas devueltas con overlay son COPIAS: el mapa del
///   espejo no se muta.
List<Map<String, dynamic>> solicitudesTrasDescartes(
    List<Map<String, dynamic>> espejo,
    List<Map<String, dynamic>> opsPendientes) {
  final descartadas = <String>{};
  final publicadasPendientes = <String>{};
  for (final op in opsPendientes) {
    final tipo = op['tipo'];
    if (tipo != kTipoOpDescartarSolicitud &&
        tipo != kTipoOpPublicar) {
      continue;
    }
    try {
      final p =
          jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final sid = '${p['solicitud_id'] ?? ''}';
      if (sid.isEmpty) continue;
      if (tipo == kTipoOpDescartarSolicitud) {
        descartadas.add(sid);
      } else {
        publicadasPendientes.add(sid);
      }
    } catch (_) {}
  }
  final lista = <Map<String, dynamic>>[];
  for (final s in espejo) {
    final id = '${s['id']}';
    if (descartadas.contains(id)) continue;
    if (publicadasPendientes.contains(id)) {
      lista.add(Map<String, dynamic>.from(s)
        ..['estado_bandeja'] = kBandejaPublicada
        ..['pendiente'] = true);
    } else {
      lista.add(s);
    }
  }
  return lista;
}

/// Solicitudes del espejo, ordenadas por creación (más nuevas
/// primero), con los descartes pendientes aplicados.
///
/// LANZA ante un fallo de lectura: un [] ambiguo haría que Home
/// pusiera el badge en 0 y la pantalla dijera «Sin solicitudes»
/// cuando en realidad no se pudo leer. Quien llama distingue error
/// de lista vacía.
Future<List<Map<String, dynamic>>> solicitudesBandeja() async {
  final db = LocalDb.instance;
  final todas = await db.allMirror('gympedia_solicitudes');
  final ops = await db.pendingOps();
  final lista = solicitudesTrasDescartes(todas, ops);
  lista.sort((a, b) =>
      '${b['creada_en'] ?? ''}'.compareTo('${a['creada_en'] ?? ''}'));
  return lista;
}

/// Borradores fusionados (espejo + ops pendientes).
///
/// LANZA ante un fallo de lectura (Argón Gmail-15 #5): el catch
/// silencioso con `const []` hacía que un espejo ilegible se
/// presentara como «Sin borradores compartidos». Quien llama
/// (_cargar de BandejaScreen) distingue error de vacío con
/// _errorCarga, igual que ya hace solicitudesBandeja.
Future<List<Map<String, dynamic>>> borradoresBandeja() async {
  final db = LocalDb.instance;
  final espejo = await db.allMirror('espejo_gympedia_borradores');
  final ops = await db.pendingOps();
  return fusionarBorradoresBandeja(espejo: espejo, opsPendientes: ops);
}

/// Nombres de todos los usuarios de la app (meta usuarios_apk),
/// para resolver autores en la bandeja SIN depender de ser dueño
/// (Argón Gmail-15 #3: un entrenador veía «Entrenador <id>» en
/// borradores ajenos porque _entrenadores solo se cargaba para
/// el dueño). Meta corrupta o ausente → mapa vacío (el llamador
/// usa el fallback «Entrenador <id>»).
Future<Map<String, String>> mapaNombresBandeja() async {
  final nombres = <String, String>{};
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw != null && raw.isNotEmpty) {
      for (final u in jsonDecode(raw) as List) {
        final m = Map<String, dynamic>.from(u as Map);
        final tid = '${m['telegram_id'] ?? ''}';
        if (tid.isEmpty) continue;
        nombres[tid] = '${m['nombre'] ?? m['username'] ?? tid}';
      }
    }
  } catch (_) {}
  return nombres;
}

/// Entrenadores (meta usuarios_apk, sin el dueño) con su estado de
/// permiso de bandeja (espejo + overlay de ops pendientes).
Future<List<Map<String, dynamic>>> entrenadoresBandeja() async {
  final db = LocalDb.instance;
  final auth = AuthService();
  List<Map<String, dynamic>> usuarios = [];
  try {
    final raw = await db.getMeta('usuarios_apk');
    if (raw != null && raw.isNotEmpty) {
      usuarios = (jsonDecode(raw) as List)
          .map((u) => Map<String, dynamic>.from(u as Map))
          .toList();
    }
  } catch (_) {}
  final conPermiso = <String>{};
  try {
    final permisos = await db.allMirror('permisos_bandeja');
    for (final p in permisos) {
      conPermiso.add('${p['telegram_id'] ?? p['id'] ?? ''}');
    }
    for (final op in await db.pendingOps()) {
      if (op['tipo'] != kTipoOpPermisoBandeja) continue;
      Map<String, dynamic> p;
      try {
        p = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final tid = '${p['telegram_id'] ?? ''}';
      if ('${p['accion'] ?? ''}'.toLowerCase() == 'otorgar') {
        conPermiso.add(tid);
      } else {
        conPermiso.remove(tid);
      }
    }
  } catch (_) {}
  final lista = <Map<String, dynamic>>[];
  for (final u in usuarios) {
    final tid = '${u['telegram_id'] ?? ''}';
    if (tid.isEmpty || tid == '${auth.telegramId ?? ''}') continue;
    lista.add({
      'telegram_id': tid,
      'nombre': '${u['nombre'] ?? u['username'] ?? tid}',
      'permiso': conPermiso.contains(tid),
    });
  }
  lista.sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
  return lista;
}

/// Encola una op de bandeja (el push la sube en el siguiente ciclo).
Future<void> _encolarBandeja(String tipo, Map<String, dynamic> payload) {
  return LocalDb.instance.queueOp(
    opUuid: const Uuid().v4(),
    tipo: tipo,
    payload: payload,
  );
}

/// Descarta una solicitud pendiente (dueño o entrenador con permiso).
Future<void> descartarSolicitudBandeja(String solicitudId) =>
    _encolarBandeja(
        kTipoOpDescartarSolicitud, {'solicitud_id': solicitudId});

/// Otorga o revoca el permiso de bandeja a un entrenador (solo dueño).
Future<void> cambiarPermisoBandeja(int telegramId, bool otorgar) =>
    _encolarBandeja(kTipoOpPermisoBandeja, {
      'telegram_id': telegramId,
      'accion': otorgar ? 'otorgar' : 'revocar',
    });

/// Crea o actualiza un borrador compartido. El servidor valida el
/// título sobre el merge y conserva el autor original cuando edita
/// el dueño. Sin título y sin eliminado → error del servidor.
/// El texto viaja SIEMPRE (incluso vacío): el servidor conserva las
/// claves omitidas, así que omitirlo impediría borrar el texto.
Future<void> guardarBorradorBandeja({
  required String slug,
  required String titulo,
  String texto = '',
  String? solicitudId,
  bool eliminado = false,
}) {
  final data = <String, dynamic>{'titulo': titulo, 'texto': texto};
  if (solicitudId != null && solicitudId.isNotEmpty) {
    data['solicitud_id'] = solicitudId;
  }
  return _encolarBandeja(kTipoOpBorradorUpsert, {
    'slug': slug,
    'data': data,
    'eliminado': eliminado,
  });
}

/// Marca un borrador como eliminado (soft-delete; el texto se conserva
/// en el servidor y se puede restaurar con eliminado=false).
Future<void> eliminarBorradorBandeja(String slug) => _encolarBandeja(
      kTipoOpBorradorUpsert,
      {'slug': slug, 'data': <String, dynamic>{}, 'eliminado': true},
    );
