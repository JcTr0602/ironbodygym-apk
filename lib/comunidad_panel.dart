// lib/comunidad_panel.dart
// 1.27 (Comunidad MVP, Pieza G): interpretación del
// jsonb de admin_comunidad_perfiles. Tolerante como el
// resto de paneles: una fila rara se salta, nunca
// tumba la pantalla.

/// Un perfil de cliente en la Comunidad, tal como lo
/// ve la administración.
class PerfilComunidadAdmin {
  final int clienteId;
  final String nombre;

  /// 1.29 (Comunidad C3): el Nick del cliente, si lo
  /// tiene. Aquí SÍ se ve el nombre real detrás: el
  /// dueño modera sabiendo quién es quién.
  final String? nick;
  final bool visible;
  final bool ocultoAdmin;
  final bool mostrarMarcas;
  final bool mostrarActividad;
  final bool mostrarRutina;
  final bool mostrarConstancia;

  /// 1.29 (Comunidad C1/C3): los interruptores que
  /// nacieron con la 0.19.
  final bool mostrarFoto;
  final bool mostrarNivel;
  final bool mostrarLogros;
  final bool mostrarCumple;

  /// Alta en la Comunidad (ISO), si el servidor la
  /// trae (COM-24: la fecha da contexto al moderar).
  final String? altaEn;

  /// Última vez que la app publicó el resumen
  /// (ISO), si viene.
  final String? resumenEn;

  const PerfilComunidadAdmin({
    required this.clienteId,
    required this.nombre,
    this.nick,
    required this.visible,
    required this.ocultoAdmin,
    required this.mostrarMarcas,
    required this.mostrarActividad,
    required this.mostrarRutina,
    required this.mostrarConstancia,
    this.mostrarFoto = false,
    this.mostrarNivel = false,
    this.mostrarLogros = false,
    this.mostrarCumple = false,
    this.altaEn,
    this.resumenEn,
  });

  /// Los bloques que el cliente tiene encendidos, en
  /// texto corto para la tarjeta.
  List<String> get bloquesActivos => [
        if (mostrarMarcas) 'Marcas',
        if (mostrarActividad) 'Actividad',
        if (mostrarRutina) 'Rutina',
        if (mostrarConstancia) 'Constancia',
        if (mostrarNivel) 'Nivel',
        if (mostrarLogros) 'Logros',
        if (mostrarFoto) 'Foto',
        if (mostrarCumple) 'Cumpleaños',
      ];

  /// «Nuevo esta semana» (COM-25): alta en los
  /// últimos 7 días.
  /// Yunque B (YB-FLU-05): la comparación es entre INSTANTES
  /// — [ahora] debe ser el instante real (ahoraUtcReal) y
  /// [altaEn] el instante del servidor. Antes el llamador
  /// pasaba ahoraHabana() (hora de pared en el marco del
  /// dispositivo) y el conteo «nuevos» se adelantaba o
  /// atrasaba horas en el borde de los 7 días.
  bool esNuevo(DateTime ahora) {
    final a = DateTime.tryParse(altaEn ?? '');
    if (a == null) return false;
    return ahora.difference(a).inDays < 7 &&
        !a.isAfter(ahora);
  }

  PerfilComunidadAdmin conOculto(bool oculto) => PerfilComunidadAdmin(
        clienteId: clienteId,
        nombre: nombre,
        nick: nick,
        visible: visible,
        ocultoAdmin: oculto,
        mostrarMarcas: mostrarMarcas,
        mostrarActividad: mostrarActividad,
        mostrarRutina: mostrarRutina,
        mostrarConstancia: mostrarConstancia,
        mostrarFoto: mostrarFoto,
        mostrarNivel: mostrarNivel,
        mostrarLogros: mostrarLogros,
        mostrarCumple: mostrarCumple,
        altaEn: altaEn,
        resumenEn: resumenEn,
      );

  PerfilComunidadAdmin sinNick() => PerfilComunidadAdmin(
        clienteId: clienteId,
        nombre: nombre,
        visible: visible,
        ocultoAdmin: ocultoAdmin,
        mostrarMarcas: mostrarMarcas,
        mostrarActividad: mostrarActividad,
        mostrarRutina: mostrarRutina,
        mostrarConstancia: mostrarConstancia,
        mostrarFoto: mostrarFoto,
        mostrarNivel: mostrarNivel,
        mostrarLogros: mostrarLogros,
        mostrarCumple: mostrarCumple,
        altaEn: altaEn,
        resumenEn: resumenEn,
      );
}

/// 1.28 (M5-B4): los conteos de cabecera de la lista de
/// Comunidad. «Con vitrina» = el CLIENTE la encendió
/// (su decisión; el dueño nunca la enciende por él);
/// «visibles» = los que hoy salen en el directorio
/// (vitrina encendida y no ocultos por el dueño);
/// «ocultos por ti» = los que el dueño retiró.
({int conVitrina, int visibles, int ocultosPorTi}) conteosComunidad(
    List<PerfilComunidadAdmin> perfiles) {
  var conVitrina = 0;
  var visibles = 0;
  var ocultos = 0;
  for (final p in perfiles) {
    if (p.visible) conVitrina++;
    if (p.visible && !p.ocultoAdmin) visibles++;
    if (p.ocultoAdmin) ocultos++;
  }
  return (
    conVitrina: conVitrina,
    visibles: visibles,
    ocultosPorTi: ocultos,
  );
}

/// Quita acentos y pasa a minúsculas para comparar
/// nombres sin que «José» y «jose» sean dos mundos.
/// Corrección A2-D5 (auditorías 1.28): también pliega
/// los acentos DESCOMPUESTOS (letra + marca combinante
/// U+0301, como llegan de algunos teclados): sin esto,
/// buscar «jose» no encontraba un «José» descompuesto
/// porque la marca sobrevivía a la comparación.
String _sinAcentos(String s) {
  const mapa = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u',
    'ü': 'u', 'ñ': 'n',
  };
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    // Marcas combinantes (U+0300–U+036F): se descartan;
    // la letra base queda y pasa por el mapa igual.
    if (r >= 0x0300 && r <= 0x036F) continue;
    final ch = String.fromCharCode(r);
    b.write(mapa[ch] ?? ch);
  }
  return b.toString();
}

/// 1.28 (M5-B4): el buscador de la lista de Comunidad —
/// filtra por nombre, sin acentos ni mayúsculas.
/// Consulta vacía = la lista entera.
List<PerfilComunidadAdmin> filtrarPerfilesComunidad(
    List<PerfilComunidadAdmin> perfiles, String consulta) {
  final q = _sinAcentos(consulta.trim());
  if (q.isEmpty) return perfiles;
  return perfiles
      // (1.36 H-B4 136-969) también por Nick: es como los
      // clientes se conocen en el directorio.
      .where((p) =>
          _sinAcentos(p.nombre).contains(q) ||
          (p.nick != null && _sinAcentos(p.nick!).contains(q)))
      .toList();
}

/// Interpreta {ok, perfiles:[...]} de
/// admin_comunidad_perfiles. Si ok no es true o la
/// forma no es la esperada, devuelve lista vacía.
List<PerfilComunidadAdmin> parsePerfilesComunidad(
    Map<String, dynamic> json) {
  if (json['ok'] != true) return const [];
  final lista = json['perfiles'];
  if (lista is! List) return const [];
  final out = <PerfilComunidadAdmin>[];
  for (final e in lista) {
    if (e is! Map) continue;
    // 1.28 (M5-A2/C-R3M5-H8): el id también vale como
    // TEXTO parseable: con la exigencia de num, un
    // perfil cuyo id bajara como cadena se saltaba en
    // silencio y quedaba INMODERABLE desde el panel.
    final idCrudo = e['cliente_id'];
    final id = idCrudo is num
        ? idCrudo.toInt()
        : int.tryParse('${idCrudo ?? ''}');
    if (id == null) continue;
    // Un nombre vacío (o de solo espacios) pintaba una
    // tarjeta sin título que no se podía identificar:
    // cae a «Sin nombre» como el resto de la casa.
    final nombreCrudo = '${e['nombre'] ?? ''}'.trim();
    final nickCrudo = '${e['nick'] ?? ''}'.trim();
    out.add(PerfilComunidadAdmin(
      clienteId: id,
      nombre: nombreCrudo.isEmpty ? 'Sin nombre' : nombreCrudo,
      nick: nickCrudo.isEmpty ? null : nickCrudo,
      visible: e['visible'] == true,
      ocultoAdmin: e['oculto_admin'] == true,
      mostrarMarcas: e['mostrar_marcas'] == true,
      mostrarActividad: e['mostrar_actividad'] == true,
      mostrarRutina: e['mostrar_rutina'] == true,
      mostrarConstancia: e['mostrar_constancia'] == true,
      mostrarFoto: e['mostrar_foto'] == true,
      mostrarNivel: e['mostrar_nivel'] == true,
      mostrarLogros: e['mostrar_logros'] == true,
      mostrarCumple: e['mostrar_cumple'] == true,
      altaEn: e['alta_en']?.toString(),
      resumenEn: e['resumen_en']?.toString(),
    ));
  }
  return out;
}

/// 1.29 (Comunidad C3): la raíz de
/// admin_comunidad_perfiles — el denominador de
/// clientes del gym (COM-24) y los reportes
/// pendientes (COM-25: el distintivo de la tarjeta).
({int totalClientes, int reportesPendientes})
    parseRaizComunidad(Map<String, dynamic> json) {
  int entero(dynamic v) =>
      v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
  if (json['ok'] != true) {
    return (totalClientes: 0, reportesPendientes: 0);
  }
  return (
    totalClientes: entero(json['total_clientes']),
    reportesPendientes: entero(json['reportes_pendientes']),
  );
}

/// 1.29 (Comunidad C3, DF-27) → 1.30 (A1-M5-01):
/// reportes NUEVOS = los pendientes cuyo ID supera
/// la marca de vistos (el id mayor que la pantalla
/// de Comunidad guardó al abrirse). Antes la marca
/// era un CONTEO y las resoluciones lo movían:
/// resolver un reporte viejo hacía «nuevo» a otro
/// ya visto (y uno nuevo podía quedar tapado). Un
/// conteo que baja ya no engaña: cada reporte se
/// compara por su propio id.
int reportesNuevosComunidad(List<int> idsPendientes, int maxIdVisto) {
  return idsPendientes.where((id) => id > maxIdVisto).length;
}

/// Los ids de los reportes pendientes, del payload
/// de admin_comunidad_perfiles (A1-M5-01).
List<int> parseIdsReportesPendientes(Map<String, dynamic> json) {
  if (json['ok'] != true) return const [];
  final lista = json['reportes_pendientes_ids'];
  if (lista is! List) return const [];
  final out = <int>[];
  for (final e in lista) {
    final id = e is num ? e.toInt() : int.tryParse('${e ?? ''}');
    if (id != null) out.add(id);
  }
  return out;
}

/// 1.32 (H-RPC-5/B1-H5): el desenlace del contador de
/// reportes nuevos a partir de la respuesta CRUDA de
/// `admin_comunidad_perfiles`. El `{ok:false}` de la RPC
/// (la sesión dejó de ser admin, la guarda cambió) NO es
/// «0 reportes»: es «no se pudo saber» (null), la misma
/// regla del contador hermano de vales. Sin esta puerta,
/// el parseo degradaba a [] y el Panel pintaba un 0
/// mentiroso con reportes reales pendientes. Función
/// pura, sin red ni estado.
int? reportesNuevosDesdeRespuesta(Object? res, int maxIdVisto) {
  if (res is! Map) return null;
  final json = Map<String, dynamic>.from(res);
  if (json['ok'] != true) return null;
  return reportesNuevosComunidad(
      parseIdsReportesPendientes(json), maxIdVisto);
}

/// La clave de la marca de vistos de reportes
/// (SharedPreferences), por telegram del dueño.
/// Desde A1-M5-01 la marca es el ID MAYOR visto (no
/// un conteo): la clave cambia de nombre para no
/// leer la marca vieja como si fuera un id.
String claveReportesComunidadVistos(int telegramId) =>
    'comunidad_reportes_vistos_maxid_$telegramId';

/// SL-10 G13-1: la etiqueta humana de un bloque de la
/// vitrina por su clave del servidor. Una clave nueva
/// se presenta capitalizada y sin guiones bajos, nunca
/// la clave cruda como título.
String etiquetaBloqueComunidad(String clave) {
  const mapa = {
    'actividad': 'Actividad',
    'rutina': 'Rutina',
    'logros': 'Logros',
    'marcas': 'Marcas',
    'constancia': 'Constancia',
    'nivel': 'Nivel',
    'foto': 'Foto',
    'cumple': 'Cumpleaños',
    'identidad': 'Identidad',
  };
  final v = mapa[clave];
  if (v != null) return v;
  final limpio = clave.replaceAll('_', ' ').trim();
  if (limpio.isEmpty) return 'Bloque';
  return limpio[0].toUpperCase() + limpio.substring(1);
}

/// El texto humano de un motivo de reporte.
String motivoReporteTexto(String? motivo) {
  switch (motivo) {
    case 'nombre_inadecuado':
      return 'Nombre o Nick inadecuado';
    case 'foto_inadecuada':
      return 'Foto inadecuada';
    case 'contenido_inadecuado':
      return 'Contenido inadecuado';
    case 'otro':
      return 'Otro motivo';
    default:
      return 'Sin motivo';
  }
}

/// Un reporte pendiente de la cola (COM-28): trae la
/// proyección pública compacta del reportado para
/// juzgar sin salir de la tarjeta (A-08.2).
class ReporteComunidadAdmin {
  final int id;
  final String? creadoEn;
  final String motivo;
  final int reportadoId;
  final String? reportadoNick;

  /// El Nick que el reportado tenía ANTES (si la
  /// administración ya le borró uno): contexto.
  final String? reportadoNickAnterior;
  final String reportadoNombreReal;

  /// La proyección pública compacta, tal cual la
  /// sirve el servidor (para el resumen de bloques).
  final Map<String, dynamic> proyeccion;
  final String? reportanteNick;
  final String reportanteNombreReal;

  const ReporteComunidadAdmin({
    required this.id,
    required this.creadoEn,
    required this.motivo,
    required this.reportadoId,
    required this.reportadoNick,
    required this.reportadoNickAnterior,
    required this.reportadoNombreReal,
    required this.proyeccion,
    required this.reportanteNick,
    required this.reportanteNombreReal,
  });

  /// Los bloques que el reportado comparte, leídos
  /// de su proyección (las claves presentes).
  List<String> get bloquesProyeccion => [
        if (proyeccion['marcas'] != null) 'Marcas',
        if (proyeccion['actividad'] != null) 'Actividad',
        if (proyeccion['rutina'] != null) 'Rutina',
        if (proyeccion['constancia'] != null) 'Constancia',
        if (proyeccion['nivel'] != null) 'Nivel',
        if (proyeccion['logros'] != null) 'Logros',
      ];
}

List<ReporteComunidadAdmin> parseReportesComunidad(
    Map<String, dynamic> json) {
  if (json['ok'] != true) return const [];
  final lista = json['reportes'];
  if (lista is! List) return const [];
  final out = <ReporteComunidadAdmin>[];
  for (final e in lista) {
    if (e is! Map) continue;
    final idCrudo = e['id'];
    final id = idCrudo is num
        ? idCrudo.toInt()
        : int.tryParse('${idCrudo ?? ''}');
    final rep = e['reportado'];
    final repMap = rep is Map
        ? Map<String, dynamic>.from(rep)
        : const <String, dynamic>{};
    final repIdCrudo = repMap['cliente_id'];
    final repId = repIdCrudo is num
        ? repIdCrudo.toInt()
        : int.tryParse('${repIdCrudo ?? ''}');
    if (id == null || repId == null) continue;
    final rte = e['reportante'];
    final rteMap = rte is Map
        ? Map<String, dynamic>.from(rte)
        : const <String, dynamic>{};
    String? txt(dynamic v) {
      final s = '${v ?? ''}'.trim();
      return s.isEmpty ? null : s;
    }

    final proy = repMap['proyeccion'];
    out.add(ReporteComunidadAdmin(
      id: id,
      creadoEn: e['creado_en']?.toString(),
      motivo: '${e['motivo'] ?? ''}',
      reportadoId: repId,
      reportadoNick: txt(repMap['nick']),
      reportadoNickAnterior: txt(repMap['nick_anterior']),
      reportadoNombreReal:
          txt(repMap['nombre_real']) ?? 'Sin nombre',
      proyeccion: proy is Map
          ? Map<String, dynamic>.from(proy)
          : const {},
      reportanteNick: txt(rteMap['nick']),
      reportanteNombreReal:
          txt(rteMap['nombre_real']) ?? 'Alguien',
    ));
  }
  return out;
}

/// Una entrada del historial de moderación (COM-27).
class EventoModeracionComunidad {
  final int id;
  final String? creadoEn;
  final String accion;
  final int clienteId;
  final String? nombreReal;
  final String? nick;
  final int? reporteId;

  const EventoModeracionComunidad({
    required this.id,
    required this.creadoEn,
    required this.accion,
    required this.clienteId,
    required this.nombreReal,
    required this.nick,
    required this.reporteId,
  });

  /// El texto humano de la acción registrada.
  String get accionTexto {
    switch (accion) {
      case 'ocultar':
        return 'Perfil ocultado';
      case 'desocultar':
        return 'Perfil mostrado de nuevo';
      case 'nick_borrado':
        return 'Nick retirado';
      case 'reporte_oculto':
        return 'Reporte resuelto ocultando el perfil';
      case 'reporte_descartado':
        return 'Reporte descartado';
      default:
        // (1.36 H-B4 136-969) ninguna acción se muestra
        // con su clave cruda: texto humano genérico.
        return 'Acción de moderación';
    }
  }
}

List<EventoModeracionComunidad> parseHistorialComunidad(
    Map<String, dynamic> json) {
  if (json['ok'] != true) return const [];
  final lista = json['eventos'];
  if (lista is! List) return const [];
  final out = <EventoModeracionComunidad>[];
  for (final e in lista) {
    if (e is! Map) continue;
    int? entero(dynamic v) =>
        v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    final id = entero(e['id']);
    final cid = entero(e['cliente_id']);
    if (id == null || cid == null) continue;
    String? txt(dynamic v) {
      final s = '${v ?? ''}'.trim();
      return s.isEmpty ? null : s;
    }

    out.add(EventoModeracionComunidad(
      id: id,
      creadoEn: e['creado_en']?.toString(),
      accion: '${e['accion'] ?? ''}',
      clienteId: cid,
      nombreReal: txt(e['nombre_real']),
      nick: txt(e['nick']),
      reporteId: entero(e['reporte_id']),
    ));
  }
  return out;
}

/// 1.29 (Comunidad C3, COM-26/A-08.3): la respuesta
/// de admin_comunidad_ver_perfil — la proyección
/// PÚBLICA del perfil (la misma que ven los
/// clientes) + el estado administrativo + los
/// bloques que el cliente tiene APAGADOS, por
/// nombre, para juzgar con todo el contexto.
({
  bool ok,
  Map<String, dynamic> proyeccion,
  List<String> apagados,
  bool visible,
  bool ocultoAdmin,
}) parseVerPerfilComunidad(Map<String, dynamic> json) {
  if (json['ok'] != true) {
    return (
      ok: false,
      proyeccion: const {},
      apagados: const [],
      visible: false,
      ocultoAdmin: false,
    );
  }
  final proy = json['perfil'] ?? json['proyeccion'];
  final ap = json['apagados'];
  return (
    ok: true,
    proyeccion:
        proy is Map ? Map<String, dynamic>.from(proy) : const {},
    apagados: [
      if (ap is List)
        for (final a in ap) '$a',
    ],
    visible: json['visible'] == true,
    ocultoAdmin: json['oculto_admin'] == true,
  );
}
