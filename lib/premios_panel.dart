/// Premios (Pieza G, 1.26): modelos y funciones puras de
/// la bandeja «Premios por aprobar» del Panel. La RPC
/// admin_premios_vales devuelve los vales reclamados por
/// los clientes en su app y los resueltos recientes; aquí
/// solo se interpreta su jsonb, sin Flutter ni red.
library;

import 'tiempo.dart';

/// Un vale reclamado, pendiente de decisión del dueño.
class ValePendiente {
  final int id;
  final int clienteId;
  final String nombre;
  final String telefono;
  final String? pagadoHasta;
  final String logroId;
  final int premioDias;
  final int diasAlReclamar;
  final String creadoEn;

  /// 1.27 (S4): el motivo con el que el dueño creó el
  /// vale (solo vales manuales; '' en los de logro).
  final String creadoNota;

  const ValePendiente({
    required this.id,
    required this.clienteId,
    required this.nombre,
    required this.telefono,
    required this.pagadoHasta,
    required this.logroId,
    required this.premioDias,
    required this.diasAlReclamar,
    required this.creadoEn,
    this.creadoNota = '',
  });

  bool get esManual => logroId == 'manual';
}

/// Un vale ya resuelto (contexto reciente de la bandeja).
class ValeReciente {
  final int id;
  final int clienteId;
  final String nombre;
  final int premioDias;
  final String estado; // 'canjeado' | 'rechazado' | 'anulado'
  final String resueltoEn;
  final String resueltoNota;

  /// 1.27 (S4): motivo de creación (vales manuales).
  final String creadoNota;

  /// 1.28 (M5-C4): el logro del vale, para nombrarlo en
  /// «Resueltos recientemente». La RPC viva aún NO lo
  /// devuelve en «recientes» (pendiente de servidor
  /// documentado): el parseo lo lee si viene y la fila
  /// lo enseña cuando exista.
  final String logroId;

  const ValeReciente({
    required this.id,
    required this.clienteId,
    required this.nombre,
    required this.premioDias,
    required this.estado,
    required this.resueltoEn,
    required this.resueltoNota,
    this.creadoNota = '',
    this.logroId = '',
  });

  bool get canjeado => estado == 'canjeado';
}

/// La bandeja completa que devuelve la RPC.
class BandejaPremios {
  final List<ValePendiente> vales;
  final List<ValeReciente> recientes;

  const BandejaPremios({required this.vales, required this.recientes});

  static const vacia = BandejaPremios(vales: [], recientes: []);
}

int _entero(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// 1.28 (M5-A2/C-R3M5-H3): un CONTEO nunca es negativo:
/// un dato degradado del servidor (-3 días de premio)
/// pintaba cifras imposibles en el panel del dueño. Los
/// ids NO pasan por aquí: su degradación se trata
/// descartando la fila (ver parseBandejaPremios).
int _conteo(Object? v) {
  final n = _entero(v);
  return n < 0 ? 0 : n;
}

String _texto(Object? v) => v == null ? '' : '$v';

/// Interpreta el jsonb de admin_premios_vales. Tolerante:
/// cualquier pieza ausente o de otro tipo se degrada a
/// vacío/0 en vez de romper la bandeja.
BandejaPremios parseBandejaPremios(Object? json) {
  if (json is! Map) return BandejaPremios.vacia;
  final vales = <ValePendiente>[];
  final crudosV = json['vales'];
  if (crudosV is List) {
    for (final e in crudosV) {
      if (e is! Map) continue;
      // 1.28 (M5-A2/C-R3M5-H7): una fila con el id
      // degradado a 0 se DESCARTA: dos filas así
      // colisionaban en la misma marca local
      // «premio_vale_resuelto_0» y aprobar una ocultaba
      // la otra. Mismo criterio que Comunidad con el id.
      final id = _entero(e['id']);
      if (id <= 0) continue;
      vales.add(ValePendiente(
        id: id,
        clienteId: _entero(e['cliente_id']),
        nombre: _texto(e['nombre']),
        telefono: _texto(e['telefono']),
        pagadoHasta: e['pagado_hasta']?.toString(),
        logroId: _texto(e['logro_id']),
        premioDias: _conteo(e['premio_dias']),
        diasAlReclamar: _conteo(e['dias_al_reclamar']),
        creadoEn: _texto(e['creado_en']),
        creadoNota: _texto(e['creado_nota']),
      ));
    }
  }
  final recientes = <ValeReciente>[];
  final crudosR = json['recientes'];
  if (crudosR is List) {
    for (final e in crudosR) {
      if (e is! Map) continue;
      final id = _entero(e['id']);
      if (id <= 0) continue;
      recientes.add(ValeReciente(
        id: id,
        clienteId: _entero(e['cliente_id']),
        nombre: _texto(e['nombre']),
        premioDias: _conteo(e['premio_dias']),
        estado: _texto(e['estado']),
        resueltoEn: _texto(e['resuelto_en']),
        resueltoNota: _texto(e['resuelto_nota']),
        creadoNota: _texto(e['creado_nota']),
        logroId: _texto(e['logro_id']),
      ));
    }
  }
  return BandejaPremios(vales: vales, recientes: recientes);
}

/// 1.28 (M5-C4): nombre humano de CADA logro del
/// catálogo vivo de Clientes (core/logros.dart). Antes
/// solo dos se nombraban y el resto salía crudo
/// («dueno_tarde») en la bandeja, el historial y el
/// sello de medallas del cliente.
const Map<String, String> nombresLogrosPremio = {
  'primer_paso': 'Primer paso',
  'semana_completa': 'Semana completa',
  'imparable': 'Imparable',
  'leyenda': 'Leyenda Iron',
  'constancia_real': 'Constancia real',
  'sesiones_hito': 'Acumulando sesiones',
  'veterano': 'Veterano',
  'toneladas': 'Toneladas levantadas',
  'mananero': 'Mañanero',
  'dueno_tarde': 'Dueño de la tarde',
  'madrugador': 'Madrugador',
  'nocturno': 'Nocturno',
  'primera_medicion': 'Conócete',
  'control_total': 'Control total',
  'primera_marca': 'Primera marca',
  'cinco_marcas': 'Coleccionista de marcas',
  'club100_press': 'Club 100 · Press banca',
  'club100_sentadilla': 'Club 100 · Sentadilla',
  'club100_muerto': 'Club 100 · Peso muerto',
  'diez_ejercicios': 'Explorador',
  'primera_rutina': 'Mi primera rutina',
  'arquitecto': 'Arquitecto',
  'alumno_gym': 'Alumno del gym',
  'semana_planificada': 'Semana planificada',
  'secreto_alba': 'El alba es tuya',
  'secreto_trasnochador': 'El último en salir',
  'reto_del_mes': 'Reto del mes',
  'manual': 'Vale manual',
};

/// El id BASE de un logro: las claves del sello de
/// medallas del reto mensual llevan el mes pegado
/// («reto_del_mes@2026-11»); el nombre y el icono salen
/// de la base.
String logroBasePremio(String logroId) => logroId.split('@').first;

/// Título humano del logro de un vale (el catálogo de
/// Premios vive en la app de Clientes; aquí se nombra
/// entero — ver [nombresLogrosPremio]).
String tituloLogroPremio(String logroId) =>
    nombresLogrosPremio[logroBasePremio(logroId)] ?? logroId;

/// Los pendientes que la pantalla debe mostrar: fuera
/// los ya resueltos EN ESTE teléfono (la op de canje
/// está encolada y el servidor aún los ve reclamados
/// hasta que la aplica; sin este filtro, el dueño
/// podría aprobar dos veces el mismo vale).
List<ValePendiente> valesVisibles(
    List<ValePendiente> vales, Set<int> resueltosLocales) {
  if (resueltosLocales.isEmpty) return vales;
  return vales.where((v) => !resueltosLocales.contains(v.id)).toList();
}

/// 1.28 (M5-B6): reconciliación en LOTE de las marcas
/// locales «premio_vale_resuelto_<id>» → op_uuid contra
/// el estado de su op. Antes la pantalla leía marca y
/// estado vale a vale, en serie (una consulta por
/// pieza); ahora las lecturas van en lote (LocalDb) y
/// la regla vive aquí, pura y testeable:
///
/// - op RECHAZADA por el servidor → la marca se BORRA y
///   el vale vuelve a ser accionable (reintentar).
/// - op en vuelo, aplicada, o sin estado conocido
///   (purgada de la cola: null) → el vale SIGUE OCULTO:
///   lo conservador es no ofrecer aprobar dos veces.
///
/// [marcas] trae TODAS las metas con el prefijo (clave
/// completa → op_uuid); solo importan las de los vales
/// de [valeIds]. Devuelve los ids a ocultar y los ids
/// cuya marca hay que borrar.
({Set<int> ocultos, List<int> marcasABorrar}) reconciliarMarcasVales({
  required Iterable<int> valeIds,
  required Map<String, String> marcas,
  required Map<String, String?> estados,
}) {
  final ocultos = <int>{};
  final borrar = <int>[];
  for (final id in valeIds) {
    final opUuid = marcas['premio_vale_resuelto_$id'];
    if (opUuid == null) continue;
    if (estados[opUuid] == 'rechazada') {
      borrar.add(id);
    } else {
      ocultos.add(id);
    }
  }
  return (ocultos: ocultos, marcasABorrar: borrar);
}

/// Orden del catálogo de logros tal como vive en la app
/// de Clientes (core/logros.dart): la pestaña Catálogo
/// (1.27, S2/G2) ordena por esta lista; lo desconocido
/// (un logro futuro aún no sembrado aquí) va al final.
const List<String> ordenCatalogoLogros = [
  'primer_paso',
  'semana_completa',
  'imparable',
  'leyenda',
  'constancia_real',
  'sesiones_hito',
  'veterano',
  'toneladas',
  'mananero',
  'dueno_tarde',
  'madrugador',
  'nocturno',
  'primera_medicion',
  'control_total',
  'primera_marca',
  'cinco_marcas',
  'club100_press',
  'club100_sentadilla',
  'club100_muerto',
  'diez_ejercicios',
  'primera_rutina',
  'arquitecto',
  'alumno_gym',
  'semana_planificada',
  'secreto_alba',
  'secreto_trasnochador',
  'reto_del_mes',
  'manual',
];

/// Una entrada del catálogo de premios (S2): la fila de
/// premios_catalogo de un logro, con su último cambio
/// auditado si lo hay.
class EntradaCatalogoPremio {
  final String logroId;
  final String nombre;
  final int metaDias;
  final int premioDias;
  final bool activo;
  final String? ultimoCambioTexto;

  const EntradaCatalogoPremio({
    required this.logroId,
    required this.nombre,
    required this.metaDias,
    required this.premioDias,
    required this.activo,
    required this.ultimoCambioTexto,
  });

  /// Sin premio configurado (apagado y 0 días).
  bool get sinPremio => !activo && premioDias == 0;

  /// Etiqueta de estado para la lista del catálogo.
  String get estadoTexto {
    if (activo) return 'Activo: $metaDias días → $premioDias gratis';
    if (premioDias > 0) return 'Apagado: $metaDias días → $premioDias gratis';
    return 'Sin premio';
  }
}

/// Un vale del historial COMPLETO de un cliente (S3):
/// cualquier estado, con sus dos notas y el pago.
class ValeHistorial {
  final int id;
  final String logroId;
  final int premioDias;
  final int diasAlReclamar;
  final String estado; // reclamado|canjeado|rechazado|anulado
  final String creadoEn;
  final String creadoNota;
  final String? resueltoEn;
  final String resueltoNota;
  final String? anuladoEn;
  final String? pagoUuid;

  const ValeHistorial({
    required this.id,
    required this.logroId,
    required this.premioDias,
    required this.diasAlReclamar,
    required this.estado,
    required this.creadoEn,
    required this.creadoNota,
    required this.resueltoEn,
    required this.resueltoNota,
    required this.pagoUuid,
    this.anuladoEn,
  });

  bool get canjeado => estado == 'canjeado';
  bool get reclamado => estado == 'reclamado';
}

/// El detalle de Premios de un cliente (S3) para la
/// pestaña Clientes (G3).
class DetallePremiosCliente {
  final String nombre;
  final String? logroBarraId;
  final int metaDias;
  final int premioDias;
  final int dias;
  final int faltan;
  final String? cicloDesde;
  final List<String> sesionesQueSumaron;
  final List<ValeHistorial> vales;
  final Map<String, String> sello; // logroId -> fecha ISO
  final String? selloActualizadoEn;
  final List<({String desde, String nota})> marcas;

  const DetallePremiosCliente({
    required this.nombre,
    required this.logroBarraId,
    required this.metaDias,
    required this.premioDias,
    required this.dias,
    required this.faltan,
    required this.cicloDesde,
    required this.sesionesQueSumaron,
    required this.vales,
    required this.sello,
    required this.selloActualizadoEn,
    required this.marcas,
  });

  static const vacio = DetallePremiosCliente(
    nombre: '',
    logroBarraId: null,
    metaDias: 0,
    premioDias: 0,
    dias: 0,
    faltan: 0,
    cicloDesde: null,
    sesionesQueSumaron: [],
    vales: [],
    sello: {},
    selloActualizadoEn: null,
    marcas: [],
  );

  /// Fracción de la barra de progreso (0..1).
  double get fraccionBarra =>
      metaDias <= 0 ? 0 : (dias / metaDias).clamp(0.0, 1.0);
}

/// Interpreta el jsonb de admin_premios_cliente (S3).
/// Tolerante como el resto de parsers de este archivo.
DetallePremiosCliente parseDetallePremiosCliente(Object? json) {
  if (json is! Map || json['ok'] != true) {
    return DetallePremiosCliente.vacio;
  }
  final prog = json['progreso'];
  final progMap = prog is Map ? prog : const {};
  final vales = <ValeHistorial>[];
  final crudosV = json['vales'];
  if (crudosV is List) {
    for (final e in crudosV) {
      if (e is! Map) continue;
      vales.add(ValeHistorial(
        id: _entero(e['id']),
        logroId: _texto(e['logro_id']),
        premioDias: _conteo(e['premio_dias']),
        diasAlReclamar: _conteo(e['dias_al_reclamar']),
        estado: _texto(e['estado']),
        creadoEn: _texto(e['creado_en']),
        creadoNota: _texto(e['creado_nota']),
        resueltoEn: e['resuelto_en']?.toString(),
        resueltoNota: _texto(e['resuelto_nota']),
        anuladoEn: e['anulado_en']?.toString(),
        pagoUuid: e['pago_uuid']?.toString(),
      ));
    }
  }
  final sesiones = <String>[];
  final crudosS = json['sesiones_que_sumaron'];
  if (crudosS is List) {
    for (final s in crudosS) {
      if (s != null) sesiones.add('$s');
    }
  }
  final sello = <String, String>{};
  String? selloAct;
  final selloJson = json['sello'];
  if (selloJson is Map) {
    final mapa = selloJson['sello'];
    if (mapa is Map) {
      mapa.forEach((k, v) {
        if (v != null) sello['$k'] = '$v';
      });
    }
    selloAct = selloJson['actualizado_en']?.toString();
  }
  final marcas = <({String desde, String nota})>[];
  final crudosM = json['marcas'];
  if (crudosM is List) {
    for (final e in crudosM) {
      if (e is! Map) continue;
      marcas.add(
          (desde: _texto(e['desde']), nota: _texto(e['nota'])));
    }
  }
  return DetallePremiosCliente(
    nombre: _texto(json['nombre']),
    logroBarraId: progMap['logro_id']?.toString(),
    metaDias: _conteo(progMap['meta_dias']),
    premioDias: _conteo(progMap['premio_dias']),
    dias: _conteo(progMap['dias']),
    faltan: _conteo(progMap['faltan']),
    cicloDesde: progMap['ciclo_desde']?.toString(),
    sesionesQueSumaron: sesiones,
    vales: vales,
    sello: sello,
    selloActualizadoEn: selloAct,
    marcas: marcas,
  );
}

/// S7: días del vale aún NO consumidos (la fórmula de
/// Argón, espejo de la del servidor, que es quien
/// manda: el handler recalcula y rechaza si no
/// coincide). La ventana del vale termina en
/// resuelto_en + premioDias; lo quitable es lo menor
/// entre lo que le queda al pagado_hasta del cliente
/// y lo que le queda a la ventana — así una
/// renovación pagada después del canje nunca se
/// toca. Fechas como ISO (se usan los 10 primeros
/// caracteres); cualquier dato ilegible da 0.
int diasQuitablesVale({
  required String? pagadoHasta,
  required String? resueltoEn,
  required int premioDias,
  required DateTime hoy,
}) {
  // Toda la aritmética en UTC: es matemática de
  // CALENDARIO (como la del servidor en PostgreSQL),
  // no de instantes. Con DateTime local, el cambio de
  // horario de Cuba (1-nov) roba una hora al sumar
  // días y difference().inDays recorta un día de más.
  // Corrección A2-D4 (auditorías 1.28): la puerta
  // estricta de la casa — DateTime.tryParse normaliza
  // las fechas imposibles ('2026-02-31' → 3 de marzo)
  // y el cálculo devolvía días como si la fecha fuera
  // real; fechaIsoEstricta valida el calendario de ida
  // y vuelta y la inventada cuenta como ilegible (0).
  DateTime? fechaDe(String? iso) => fechaIsoEstricta(iso);

  final hasta = fechaDe(pagadoHasta);
  final resuelto = fechaDe(resueltoEn);
  if (hasta == null || resuelto == null || premioDias <= 0) {
    return 0;
  }
  final hoyFecha = DateTime.utc(hoy.year, hoy.month, hoy.day);
  final finVentana = resuelto.add(Duration(days: premioDias));
  final porHasta = hasta.difference(hoyFecha).inDays;
  final porVentana = finVentana.difference(hoyFecha).inDays;
  final k = porHasta < porVentana ? porHasta : porVentana;
  if (k < 0) return 0;
  return k > premioDias ? premioDias : k;
}

/// Interpreta el jsonb de admin_premios_catalogo (S2).
/// Tolerante como parseBandejaPremios y ordenado por
/// [ordenCatalogoLogros].
List<EntradaCatalogoPremio> parseCatalogoPremios(Object? json) {
  if (json is! Map) return const [];
  final crudos = json['items'];
  if (crudos is! List) return const [];
  final entradas = <EntradaCatalogoPremio>[];
  for (final e in crudos) {
    if (e is! Map) continue;
    String? ultimo;
    final uc = e['ultimo_cambio'];
    if (uc is Map) {
      final campo = _texto(uc['campo']);
      final antes = _texto(uc['antes']);
      final despues = _texto(uc['despues']);
      final fecha = _texto(uc['creado_en']);
      if (campo.isNotEmpty) {
        ultimo = 'Último cambio: $campo $antes → $despues'
            '${fecha.length >= 10 ? ' · ${fecha.substring(0, 10)}' : ''}';
      }
    }
    entradas.add(EntradaCatalogoPremio(
      logroId: _texto(e['logro_id']),
      nombre: _texto(e['nombre']),
      metaDias: _conteo(e['meta_dias']),
      premioDias: _conteo(e['premio_dias']),
      activo: e['activo'] == true,
      ultimoCambioTexto: ultimo,
    ));
  }
  int rango(EntradaCatalogoPremio e) {
    final i = ordenCatalogoLogros.indexOf(e.logroId);
    return i < 0 ? ordenCatalogoLogros.length : i;
  }

  entradas.sort((a, b) {
    final r = rango(a).compareTo(rango(b));
    return r != 0 ? r : a.logroId.compareTo(b.logroId);
  });
  return entradas;
}
